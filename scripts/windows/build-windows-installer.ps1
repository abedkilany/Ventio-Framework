[CmdletBinding()]
param(
  [switch] $SkipFlutterBuild,
  [string] $ReleaseDirectory,
  [string] $HostPayloadDirectory,
  [string] $InstallerOutputDirectory,
  [string] $VCRedistPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$clientRoot = Join-Path $repoRoot 'packages\ventio_native_client'
$releaseDir = if ($ReleaseDirectory) { [IO.Path]::GetFullPath($ReleaseDirectory) } else { Join-Path $clientRoot 'build\windows\x64\runner\Release' }
$hostPayload = if ($HostPayloadDirectory) { [IO.Path]::GetFullPath($HostPayloadDirectory) } else { Join-Path $repoRoot 'packages\ventio_host_api\build\windows\host-payload' }
$installerSource = Join-Path $repoRoot 'installer\windows\ventio.iss'
$installerOutput = if ($InstallerOutputDirectory) { [IO.Path]::GetFullPath($InstallerOutputDirectory) } else { Join-Path $repoRoot 'dist\windows' }
$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
$pubspec = Join-Path $clientRoot 'pubspec.yaml'
$vcRuntimeManifestPath = Join-Path $repoRoot 'installer\windows\prerequisites\vc-runtime-prerequisite.json'
$vcRuntimePackageTest = Join-Path $PSScriptRoot 'test-vc-runtime-package.ps1'
$vcRuntimeHelper = Join-Path $PSScriptRoot 'ensure-vc-runtime-prerequisite.ps1'
$vcRuntimeModule = Join-Path $PSScriptRoot 'vc-runtime-prerequisite.psm1'

if (-not (Test-Path -LiteralPath $iscc -PathType Leaf)) { throw 'Inno Setup 6 compiler is unavailable.' }
if (-not (Test-Path -LiteralPath $installerSource -PathType Leaf)) { throw 'Unified installer source is missing.' }
$vcRuntimeManifest = Get-Content -LiteralPath $vcRuntimeManifestPath -Raw | ConvertFrom-Json
if ($vcRuntimeManifest.formatVersion -ne 1 -or $vcRuntimeManifest.architecture -ne 'x64' -or
    $vcRuntimeManifest.fileName -ne 'vc_redist.x64.exe' -or
    -not (Test-Path -LiteralPath $vcRuntimePackageTest -PathType Leaf) -or
    -not (Test-Path -LiteralPath $vcRuntimeHelper -PathType Leaf) -or
    -not (Test-Path -LiteralPath $vcRuntimeModule -PathType Leaf)) {
  throw 'Microsoft Visual C++ runtime prerequisite metadata or helper is incomplete.'
}
if (-not $VCRedistPath) {
  $VCRedistPath = Join-Path $env:LOCALAPPDATA "VentioFramework\vc-runtime\$($vcRuntimeManifest.packageVersion)\vc_redist.x64.exe"
}
if (-not (Test-Path -LiteralPath $VCRedistPath -PathType Leaf)) {
  throw 'The pinned Microsoft Visual C++ x64 prerequisite is unavailable. Download the official package as documented or pass -VCRedistPath.'
}
$VCRedistPath = (Resolve-Path -LiteralPath $VCRedistPath).Path
$vcRuntimePackageTest = (Resolve-Path -LiteralPath $vcRuntimePackageTest).Path
$vcRuntimeHelper = (Resolve-Path -LiteralPath $vcRuntimeHelper).Path
$vcRuntimeModule = (Resolve-Path -LiteralPath $vcRuntimeModule).Path
$vcRuntimePackageTestResult = & $vcRuntimePackageTest -RuntimeInstallerPath $VCRedistPath
$vcRuntimeMinimumVersion = [string]$vcRuntimeManifest.minimumRuntimeVersion
$pathContractTest = Join-Path $PSScriptRoot 'test-unified-installer-path-contract.ps1'
$hostPrivilegeGuardTest = Join-Path $PSScriptRoot 'test-unified-installer-host-privilege-guard.ps1'
if (-not (Test-Path -LiteralPath $pathContractTest -PathType Leaf)) { throw 'Unified installer path-contract test is missing.' }
if (-not (Test-Path -LiteralPath $hostPrivilegeGuardTest -PathType Leaf)) { throw 'Unified installer Host privilege-guard test is missing.' }
& $pathContractTest
& (Join-Path $PSScriptRoot 'test-vc-runtime-prerequisite.ps1')
if (-not (Test-Path -LiteralPath (Join-Path $hostPayload 'payload-manifest.json') -PathType Leaf)) {
  throw 'Verified Host payload is missing; run build-host-payload.ps1 first.'
}

$manifest = Get-Content -LiteralPath (Join-Path $hostPayload 'payload-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.formatVersion -ne 1 -or $manifest.postgresVersion -ne '16.15' -or
    $manifest.hostExecutable -ne 'ventio_host.exe' -or
    $manifest.migrationExecutable -ne 'ventio_migrate.exe' -or
    $manifest.identityBootstrapExecutable -ne 'ventio_identity_bootstrap.exe' -or
    $manifest.serviceExecutable -ne 'VentioHostService.exe' -or
    $manifest.setupBrokerExecutable -ne 'VentioSetupBroker.exe' -or
    ($manifest.postgresIncludedComponents -join ',') -ne 'bin,lib,share,*.txt' -or
    ($manifest.postgresExcludedComponents -join ',') -ne 'doc,include,pgAdmin 4,StackBuilder' -or
    $manifest.credentialsIncluded -ne $false -or $manifest.databaseIncluded -ne $false) {
  throw 'Host payload manifest is incompatible or contains forbidden state.'
}
$payloadManifestPath = [IO.Path]::GetFullPath((Join-Path $hostPayload 'payload-manifest.json'))
$payloadFiles = @(Get-ChildItem -LiteralPath $hostPayload -File -Recurse |
  Where-Object { -not $_.FullName.Equals($payloadManifestPath, [StringComparison]::OrdinalIgnoreCase) })
if (@($payloadFiles | Where-Object { $_.FullName -match '(?i)[\\/]stackbuilder\.exe$' }).Count -gt 0 -or
    (Test-Path -LiteralPath (Join-Path $hostPayload 'postgresql\StackBuilder'))) {
  throw 'Host payload contains a PostgreSQL component declared as excluded.'
}
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
if (-not @($manifest.verifiedFiles | Where-Object { $_.path -ceq 'VentioSetupBroker.exe' }).Count) {
  throw 'Host setup broker is not covered by the critical payload manifest.'
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
$artifact = Join-Path $installerOutput "Ventio-Setup-$version.exe"
$manifestPath = Join-Path $installerOutput 'Ventio-Setup-SHA256SUMS.txt'
if ((Test-Path -LiteralPath $artifact) -or (Test-Path -LiteralPath $manifestPath)) {
  throw 'Installer output already exists; choose a new isolated output directory to preserve existing artifacts.'
}
[void](New-Item -ItemType Directory -Force -Path $installerOutput)
& $iscc "/DAppVersion=$version" "/DBuildOutput=$releaseDir" "/DHostPayload=$hostPayload" "/DInstallerOutput=$installerOutput" "/DVCRedistPath=$VCRedistPath" "/DVCRuntimeHelperPath=$vcRuntimeHelper" "/DVCRuntimeModulePath=$vcRuntimeModule" "/DVCRuntimeMinimumVersion=$vcRuntimeMinimumVersion" $installerSource
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed with exit code $LASTEXITCODE." }

if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) { throw 'Unified installer artifact was not created.' }
$hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $manifestPath -Encoding ascii -Value "$hash  $([IO.Path]::GetFileName($artifact))"
& $hostPrivilegeGuardTest -InstallerPath $artifact
Get-Item -LiteralPath $artifact | Select-Object FullName, Length
Write-Output "SHA256 $hash"
Write-Output "Bundled Microsoft Visual C++ x64 Redistributable $($vcRuntimeManifest.packageVersion): $($vcRuntimeManifest.sizeBytes) bytes; SHA-256 $($vcRuntimeManifest.sha256); Authenticode verified."
Write-Output "Bundled Host payload: $($manifest.payloadFileCount) files / $payloadBytes bytes; database and service provisioning are deferred until Host is selected in Ventio."
