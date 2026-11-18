$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted') { throw 'Hosted build required' }
$repo = (Get-Location).Path
$commit = (git rev-parse HEAD).Trim()
if ($commit -cne $env:GITHUB_SHA) { throw 'Wrong source commit' }
$pins = Get-Content tests/wave2/build-inputs.json -Raw | ConvertFrom-Json
$flutter = flutter --version --machine | ConvertFrom-Json
if ($flutter.frameworkVersion -cne $pins.flutter.version -or $flutter.frameworkRevision -cne $pins.flutter.revision) { throw 'Flutter release revision mismatch' }
$client = Join-Path $repo 'packages/ventio_native_client/build/windows/x64/runner/Release'
$hostPayload = Join-Path $repo 'packages/ventio_host_api/build/windows/host-payload'
$host = Get-Content (Join-Path $hostPayload 'payload-manifest.json') -Raw | ConvertFrom-Json
if ($host.sourceCommit -cne $commit -or $host.sourceHasTrackedChanges -ne $false -or $host.hostCompilerVersion -notmatch '^Dart SDK version: 3\.13\.7 ') { throw 'Host provenance mismatch' }
if ((Get-FileHash (Join-Path $client 'pdfium.dll') -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pins.pdfium.dllSha256) { throw 'Unpinned PDFium DLL' }
git diff --ignore-space-at-eol --exit-code -- .
if ($LASTEXITCODE) { throw 'Build changed tracked source semantics' }
$version = [regex]::Match((Get-Content packages/ventio_native_client/pubspec.yaml -Raw),'(?m)^version:\s*(\S+)').Groups[1].Value
$identity = "Ventio-W2B-$version-20261118-$($commit.Substring(0,12))-gh$env:GITHUB_RUN_ID-a$env:GITHUB_RUN_ATTEMPT"
$delivery = Join-Path $env:RUNNER_TEMP 'wave2-delivery'
$package = Join-Path $env:RUNNER_TEMP 'wave2-package'
if ((Test-Path $delivery) -or (Test-Path $package)) { throw 'Fresh immutable output required' }
[void](New-Item -ItemType Directory -Path $delivery,$package)
Copy-Item -LiteralPath $client -Destination (Join-Path $package 'Client') -Recurse
Copy-Item -LiteralPath $hostPayload -Destination (Join-Path $package 'HostPayload') -Recurse
[void](New-Item -ItemType Directory -Path (Join-Path $package 'Prerequisites'),(Join-Path $package 'Evidence'))
Copy-Item "$env:RUNNER_TEMP/wave2-inputs/vc_redist.x64.exe" (Join-Path $package 'Prerequisites/vc_redist.x64.exe')
Copy-Item "$env:RUNNER_TEMP/wave2-installer/Ventio-Setup-*.exe" $package
$evidence = Join-Path $package 'Evidence'
Copy-Item "$env:RUNNER_TEMP/wave2-inputs/*provenance.json","$env:RUNNER_TEMP/wave2-inputs/upstream-inputs.json" $evidence
Copy-Item tests/wave2/build-inputs.json $evidence
git archive --format=zip "--output=$evidence/source-$commit.zip" HEAD
if ($LASTEXITCODE) { throw 'Source archive failed' }
git diff --binary "--output=$evidence/generated-source-overlay.patch"
$flutterRoot = Split-Path -Parent (Split-Path -Parent (Get-Command flutter).Source)
$compilerCommands = @{
  hostDart = (Join-Path $env:VENTIO_HOST_DART_BIN 'dart.exe')
  clientDart = (Join-Path $flutterRoot 'bin/cache/dart-sdk/bin/dart.exe')
  dotnet = (Get-Command dotnet).Source
  inno = "${env:ProgramFiles(x86)}/Inno Setup 6/ISCC.exe"
}
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
if (Test-Path -LiteralPath $vswhere) {
  $instances = & $vswhere -all -products '*' -format json | ConvertFrom-Json
  $instances | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence 'visual-studio-instances.json')
  foreach ($instance in $instances) {
    $versionFile = Join-Path $instance.installationPath 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt'
    if (Test-Path $versionFile) {
      $msvc = (Get-Content $versionFile -Raw).Trim()
      $compilerCommands["msvc-$msvc-cl"] = Join-Path $instance.installationPath "VC/Tools/MSVC/$msvc/bin/Hostx64/x64/cl.exe"
      $compilerCommands["msvc-$msvc-link"] = Join-Path $instance.installationPath "VC/Tools/MSVC/$msvc/bin/Hostx64/x64/link.exe"
    }
  }
}
$compilerFiles = @(foreach ($name in $compilerCommands.Keys) {
  $path=$compilerCommands[$name]
  [pscustomobject]@{name=$name;path=$path;sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant();version=(Get-Item $path).VersionInfo.FileVersion}
})
$dependencies = @(Get-ChildItem packages -Filter pubspec.lock -Recurse -File | ForEach-Object {
  [pscustomobject]@{path=[IO.Path]::GetRelativePath($repo,$_.FullName).Replace('\','/');sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
$tools=[ordered]@{identity=$identity;commit=$commit;sourceTree=(git rev-parse 'HEAD^{tree}');hostDart=$host.hostCompilerVersion;flutter=$flutter;dotnet=(& dotnet --version);dotnetInfo=(& dotnet --info | Out-String);compilerFiles=$compilerFiles;dependencyLockfiles=$dependencies;inno='6.7.4';postgres='16.15-5';imageOS=$env:ImageOS;imageVersion=$env:ImageVersion;runnerEnvironment=$env:RUNNER_ENVIRONMENT;runId=$env:GITHUB_RUN_ID;attempt=$env:GITHUB_RUN_ATTEMPT;bitIdenticalRebuild='NOT_ESTABLISHED';productionSourceChanges='Only recorded generated line-ending overlay allowed'}
$tools | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $evidence 'build-metadata.json')
Get-ChildItem packages -Filter package_config.json -Recurse -Force -File | Where-Object {$_.FullName -match '\.dart_tool[\\/]package_config.json$'} | ForEach-Object { Copy-Item $_.FullName (Join-Path $evidence (($_.FullName.Replace($repo,'').TrimStart('\','/').Replace('\','_').Replace('/','_')))) }
Get-ChildItem installer/windows -Filter project.assets.json -Recurse -File | ForEach-Object { Copy-Item $_.FullName (Join-Path $evidence ($_.Directory.Parent.Name+'-project.assets.json')) }
Get-ChildItem packages/ventio_native_client/build/windows -Filter CMakeCache.txt -Recurse -File | ForEach-Object { Copy-Item $_.FullName (Join-Path $evidence 'client-CMakeCache.txt') }
$signatures=@(Get-ChildItem $package -Recurse -File | Where-Object {$_.Extension -in '.exe','.dll'} | ForEach-Object {
  $sig=Get-AuthenticodeSignature $_.FullName
  if ($sig.Status -notin 'Valid','NotSigned') { throw "Invalid executable signature: $($_.Name) $($sig.Status)" }
  [pscustomobject]@{path=[IO.Path]::GetRelativePath($package,$_.FullName).Replace('\','/');status=$sig.Status.ToString();publisher=$sig.SignerCertificate.Subject;fileVersion=$_.VersionInfo.FileVersion;sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
$signatures | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $evidence 'executable-signatures.json')
Copy-Item docs/wave2/WAVE_2_B_HOSTED_RESUME.md (Join-Path $package 'READ-BEFORE-INSTALL.md')
python tests/wave2/package_manifest.py create $package $delivery $identity
if ($LASTEXITCODE) { throw 'Package manifest/ZIP creation failed' }
$zip = Join-Path $delivery "$identity.zip"
$security=[ordered]@{identity=$identity;commit=$commit;status='BLOCKED_SCAN_NOT_COMPLETED';securityClearance='NOT_ESTABLISHED';scanRootsExcluded='UNKNOWN';scanEvents=@();limitations=@('Clean scans and matching hashes do not establish malware absence or product acceptance')}
try {
  $status=Get-MpComputerStatus -ErrorAction Stop
  $security.protectionBefore=$status | Select-Object AMRunningMode,AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,BehaviorMonitorEnabled,IoavProtectionEnabled,IsTamperProtected,AntivirusSignatureVersion,DefenderSignaturesOutOfDate
  if (-not ($status.AMServiceEnabled -and $status.AntivirusEnabled -and $status.RealTimeProtectionEnabled) -or $status.AMRunningMode -ne 'Normal') { throw 'Defender is not fully operational on this hosted image; no protection setting was changed' }
  Update-MpSignature -ErrorAction Stop
  $preferences=Get-MpPreference
  $security.exclusions=$preferences | Select-Object ExclusionPath,ExclusionExtension,ExclusionProcess,DisableArchiveScanning
  if ($preferences.DisableArchiveScanning -or $preferences.ExclusionExtension -or $preferences.ExclusionPath) { throw 'Scan completeness requires review of existing exclusions/archive policy' }
  $security.scanRootsExcluded=$false
  $before=(Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -MaxEvents 1).RecordId
  foreach ($path in @($package,$zip)) { Start-MpScan -ScanType CustomScan -ScanPath $path -ErrorAction Stop }
  Start-Sleep -Seconds 3
  $events=@(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Defender/Operational';Id=1000,1001,1002,1116,1117,1118,1119} | Where-Object {$_.RecordId -gt $before})
  $security.scanEvents=@($events | Select-Object Id,RecordId,TimeCreated,Message)
  $security.protectionAfter=Get-MpComputerStatus | Select-Object AMRunningMode,RealTimeProtectionEnabled,AntivirusEnabled,AntivirusSignatureVersion,DefenderSignaturesOutOfDate
  $security.threats=@(Get-MpThreat | Select-Object ThreatID,ThreatName,IsActive,DidThreatExecute)
  if (@($events | Where-Object {$_.Id -in 1002,1116,1117,1118,1119}).Count -or @($events | Where-Object Id -eq 1001).Count -lt 2) { throw 'Scan completion/detection evidence requires review' }
  if (-not $security.protectionAfter.RealTimeProtectionEnabled -or $security.protectionAfter.DefenderSignaturesOutOfDate) { throw 'Post-scan protection or signature currency failed' }
  $security.status='COMPLETED_NO_NEW_DETECTIONS_REPORTED'
} catch { $security.reason=$_.Exception.Message }
$security | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $delivery 'security-scan-evidence.json')
python tests/wave2/package_manifest.py verify $package $delivery $identity
if ($LASTEXITCODE) { throw 'Post-scan artifact integrity verification failed' }
"Candidate: $identity" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
"Security evidence: $($security.status)" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
