[CmdletBinding()]
param(
  [switch] $SkipFlutterBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$clientRoot = Join-Path $repoRoot 'packages\ventio_native_client'
$releaseDir = Join-Path $clientRoot 'build\windows\x64\runner\Release'
$hostPayload = Join-Path $repoRoot 'packages\ventio_host_api\build\windows\host-payload'
$installerSource = Join-Path $repoRoot 'installer\windows\ventio.iss'
$installerOutput = Join-Path $repoRoot 'dist\windows'
$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
$pubspec = Join-Path $clientRoot 'pubspec.yaml'

if (-not (Test-Path -LiteralPath $iscc -PathType Leaf)) { throw 'Inno Setup 6 compiler is unavailable.' }
if (-not (Test-Path -LiteralPath $installerSource -PathType Leaf)) { throw 'Unified installer source is missing.' }
$pathContractTest = Join-Path $PSScriptRoot 'test-unified-installer-path-contract.ps1'
$hostPrivilegeGuardTest = Join-Path $PSScriptRoot 'test-unified-installer-host-privilege-guard.ps1'
if (-not (Test-Path -LiteralPath $pathContractTest -PathType Leaf)) { throw 'Unified installer path-contract test is missing.' }
if (-not (Test-Path -LiteralPath $hostPrivilegeGuardTest -PathType Leaf)) { throw 'Unified installer Host privilege-guard test is missing.' }
& $pathContractTest
if (-not (Test-Path -LiteralPath (Join-Path $hostPayload 'payload-manifest.json') -PathType Leaf)) {
  throw 'Verified Host payload is missing; run build-host-payload.ps1 first.'
}

$manifest = Get-Content -LiteralPath (Join-Path $hostPayload 'payload-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.formatVersion -ne 1 -or $manifest.postgresVersion -ne '16.15' -or
    $manifest.hostExecutable -ne 'ventio_host.exe' -or
    $manifest.migrationExecutable -ne 'ventio_migrate.exe' -or
    $manifest.serviceExecutable -ne 'VentioHostService.exe' -or
    ($manifest.postgresIncludedComponents -join ',') -ne 'bin,lib,share,*.txt' -or
    ($manifest.postgresExcludedComponents -join ',') -ne 'doc,include,pgAdmin 4,StackBuilder' -or
    $manifest.credentialsIncluded -ne $false -or $manifest.databaseIncluded -ne $false) {
  throw 'Host payload manifest is incompatible or contains forbidden state.'
}
$payloadManifestPath = [IO.Path]::GetFullPath((Join-Path $hostPayload 'payload-manifest.json'))
$payloadFiles = @(Get-ChildItem -LiteralPath $hostPayload -File -Recurse |
  Where-Object { -not $_.FullName.Equals($payloadManifestPath, [StringComparison]::OrdinalIgnoreCase) })
$payloadBytes = [long](($payloadFiles | Measure-Object Length -Sum).Sum)
if ($payloadFiles.Count -ne [int]$manifest.payloadFileCount -or $payloadBytes -ne [long]$manifest.payloadBytes) {
  throw 'Host payload file inventory does not match its manifest.'
}
foreach ($entry in $manifest.verifiedFiles) {
  $relative = ([string]$entry.path).Replace('/', '\')
  $candidate = [IO.Path]::GetFullPath((Join-Path $hostPayload $relative))
  $prefix = [IO.Path]::GetFullPath($hostPayload).TrimEnd('\') + '\'
  if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw 'A critical Host payload file is missing or outside the payload.'
  }
  $file = Get-Item -LiteralPath $candidate
  if ($file.Length -ne [long]$entry.length -or
      (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$entry.sha256) {
    throw 'A critical Host payload hash differs from its manifest.'
  }
}

$versionLine = Select-String -LiteralPath $pubspec -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+[0-9]+)?\s*$'
if ($null -eq $versionLine) { throw 'Flutter semantic version is invalid.' }
$version = $versionLine.Matches[0].Groups[1].Value
if (-not $SkipFlutterBuild) {
  Push-Location $clientRoot
  try {
    & flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw "Flutter Windows build failed with exit code $LASTEXITCODE." }
  }
  finally { Pop-Location }
}
if (-not (Test-Path -LiteralPath (Join-Path $releaseDir 'ventio_native_client.exe') -PathType Leaf)) {
  throw 'Flutter Windows Release application is missing.'
}
[void](New-Item -ItemType Directory -Force -Path $installerOutput)
& $iscc "/DAppVersion=$version" "/DBuildOutput=$releaseDir" "/DHostPayload=$hostPayload" "/DInstallerOutput=$installerOutput" $installerSource
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed with exit code $LASTEXITCODE." }

$artifact = Join-Path $installerOutput "Ventio-Setup-$version.exe"
if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) { throw 'Unified installer artifact was not created.' }
$hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
$manifestPath = Join-Path $installerOutput 'Ventio-Setup-SHA256SUMS.txt'
Set-Content -LiteralPath $manifestPath -Encoding ascii -Value "$hash  $([IO.Path]::GetFileName($artifact))"
& $hostPrivilegeGuardTest -InstallerPath $artifact
Get-Item -LiteralPath $artifact | Select-Object FullName, Length
Write-Output "SHA256 $hash"
Write-Output "Embedded Host payload: $($manifest.payloadFileCount) files / $payloadBytes bytes; only installed when Host is selected."
