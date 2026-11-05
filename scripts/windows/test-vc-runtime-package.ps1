[CmdletBinding()]
param([string] $RuntimeInstallerPath)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$manifestPath = Join-Path $repoRoot 'installer\windows\prerequisites\vc-runtime-prerequisite.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($null -eq $manifest -or $manifest.formatVersion -ne 1 -or
    $manifest.architecture -ne 'x64' -or $manifest.fileName -ne 'vc_redist.x64.exe') {
  throw 'Visual C++ prerequisite manifest is invalid.'
}

if (-not $RuntimeInstallerPath) {
  $RuntimeInstallerPath = Join-Path $env:LOCALAPPDATA "VentioFramework\vc-runtime\$($manifest.packageVersion)\vc_redist.x64.exe"
}
if (-not (Test-Path -LiteralPath $RuntimeInstallerPath -PathType Leaf)) {
  throw 'The pinned Microsoft Visual C++ x64 Redistributable is unavailable.'
}

$file = Get-Item -LiteralPath $RuntimeInstallerPath
$actualHash = (Get-FileHash -LiteralPath $RuntimeInstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($file.Length -ne [long]$manifest.sizeBytes -or $actualHash -ne [string]$manifest.sha256) {
  throw 'The Visual C++ prerequisite size or SHA-256 differs from the pinned official package.'
}
$packageVersion = [version]::Parse([string]$file.VersionInfo.FileVersion)
$expectedPackageVersion = [version]::Parse([string]$manifest.packageVersion)
$minimumRuntimeVersion = [version]::Parse([string]$manifest.minimumRuntimeVersion)
if ($packageVersion -ne $expectedPackageVersion -or $packageVersion -lt $minimumRuntimeVersion) {
  throw 'The Visual C++ prerequisite version does not satisfy the pinned manifest.'
}
$signature = Get-AuthenticodeSignature -LiteralPath $RuntimeInstallerPath
$publisher = if ($signature.SignerCertificate) {
  $signature.SignerCertificate.GetNameInfo(
    [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
} else { '' }
if ($signature.Status -ne 'Valid' -or $publisher -ne [string]$manifest.publisher) {
  throw 'The Visual C++ prerequisite does not have a valid Microsoft Authenticode signature.'
}

Write-Output "PASS: Microsoft Visual C++ Redistributable x64 $packageVersion; $($file.Length) bytes; SHA-256 $actualHash; Authenticode Valid."
