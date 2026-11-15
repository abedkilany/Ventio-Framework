$ErrorActionPreference = 'Stop'
$root = Join-Path $env:RUNNER_TEMP 'ventio-host-security'
if (Test-Path -LiteralPath $root) { throw 'Investigation directory already exists.' }
$evidence = Join-Path $root 'evidence'
[void](New-Item -ItemType Directory -Path $evidence -Force)
$repo = (Get-Location).Path
$source = Join-Path $root 'source'
$original = 'fb341a78eca1bb897e2ce09f1271dae39bbd7d11'
git worktree add --detach $source $original
if ($LASTEXITCODE -ne 0) { throw 'Frozen source checkout failed.' }
$dart = (Get-Command dart).Source
$sdk = Split-Path (Split-Path $dart -Parent) -Parent
$status = Get-MpComputerStatus
$preference = Get-MpPreference
$environment = [ordered]@{
  workflowCommit = (git rev-parse HEAD)
  sourceCommit = $original
  sourceTree = (git -C $source rev-parse 'HEAD^{tree}')
  sdk = (& dart --version 2>&1 | Out-String).Trim()
  runnerImage = $env:ImageVersion
  os = [Environment]::OSVersion.VersionString
  defenderBefore = ($status | Select-Object AMProductVersion,AMEngineVersion,AntivirusSignatureVersion,AntivirusSignatureLastUpdated,AntivirusEnabled,RealTimeProtectionEnabled,AMServiceEnabled)
  samplePolicy = ($preference | Select-Object SubmitSamplesConsent,MAPSReporting)
  sdkFiles = @(Get-ChildItem -LiteralPath (Join-Path $sdk 'bin') -File | Where-Object { $_.Name -in @('dart.exe','dartaotruntime.exe','gen_snapshot.exe') } | ForEach-Object { [ordered]@{name=$_.Name;length=$_.Length;sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash} })
}
$environment | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'environment.json')
if (-not $status.AntivirusEnabled -or -not $status.AMServiceEnabled) {
  throw 'The antivirus service required for an on-demand scan is unavailable.'
}
# Hosted images can have real-time monitoring disabled by their administrator.
# Record that limitation and perform an on-demand scan without changing policy.
# This evidence does not satisfy the physical lab real-time protection gate.
Update-MpSignature
Get-MpComputerStatus | Select-Object AMProductVersion,AMEngineVersion,AntivirusSignatureVersion,AntivirusSignatureLastUpdated,AntivirusEnabled,RealTimeProtectionEnabled,AMServiceEnabled | ConvertTo-Json | Set-Content (Join-Path $evidence 'defender-current.json')
$mp = Get-ChildItem 'C:\ProgramData\Microsoft\Windows Defender\Platform' -Filter MpCmdRun.exe -Recurse | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $mp) { throw 'Defender CLI unavailable.' }
Push-Location (Join-Path $source 'packages/ventio_host_api')
try {
  & dart pub get --enforce-lockfile 2>&1 | Tee-Object (Join-Path $evidence 'dependencies.txt')
  if ($LASTEXITCODE -ne 0) { throw 'Locked dependency resolution failed.' }
  & dart pub deps --json | Set-Content (Join-Path $evidence 'dependency-graph.json')
  Copy-Item pubspec.lock (Join-Path $evidence 'pubspec.lock')
  $outputs = @()
  foreach ($index in @(1,2)) {
    $path = Join-Path $root "host-$index.exe"
    & dart compile exe bin/local_host.dart -o $path 2>&1 | Tee-Object (Join-Path $evidence "compile-$index.txt")
    if ($LASTEXITCODE -ne 0) { throw 'Host compile failed; inspect possible real-time quarantine.' }
    if (-not (Test-Path -LiteralPath $path)) { throw 'Compiled output unavailable; inspect Defender events.' }
    $bytes = [IO.File]::ReadAllBytes($path)
    $pe = [BitConverter]::ToInt32($bytes,60)
    $signature = Get-AuthenticodeSignature -FilePath $path
    $outputs += [ordered]@{file="host-$index.exe";length=$bytes.Length;sha256=(Get-FileHash $path -Algorithm SHA256).Hash;machine=[BitConverter]::ToUInt16($bytes,$pe+4);peTimeDateStamp=[BitConverter]::ToUInt32($bytes,$pe+8);sections=[BitConverter]::ToUInt16($bytes,$pe+6);authenticode=[string]$signature.Status}
    $outputs | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $evidence 'binaries.json')
    & $mp -Scan -ScanType 3 -File $path -DisableRemediation 2>&1 | Tee-Object (Join-Path $evidence "scan-$index.txt")
    $scanExit = $LASTEXITCODE
    [ordered]@{exitCode=$scanExit;existsAfter=(Test-Path -LiteralPath $path);utc=[datetime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $evidence "scan-$index-result.json")
    if ($scanExit -ne 0) { throw 'Defender scan did not complete cleanly; see captured CLI evidence.' }
  }
  [ordered]@{identical=($outputs[0].sha256 -eq $outputs[1].sha256);matchesReported=($outputs[0].sha256.ToLowerInvariant() -eq '5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2')} | ConvertTo-Json | Set-Content (Join-Path $evidence 'comparison.json')
} finally {
  Pop-Location
  Get-MpThreatDetection | Where-Object { ($_.Resources -join ';') -match 'ventio-host-security' } | Select-Object ThreatID,ActionSuccess,Resources,InitialDetectionTime | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $evidence 'defender-detections.json')
}
