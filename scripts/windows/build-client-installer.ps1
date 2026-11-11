param(
  [switch] $SkipFlutterBuild
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$clientRoot = Join-Path $repoRoot 'packages\ventio_native_client'
$releaseDir = Join-Path $clientRoot 'build\windows\x64\runner\Release'
$installerSource = Join-Path $repoRoot 'installer\windows\ventio-client.iss'
$installerOutput = Join-Path $repoRoot 'dist\windows'
$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
$pubspec = Join-Path $clientRoot 'pubspec.yaml'

if (-not (Test-Path -LiteralPath $iscc -PathType Leaf)) {
  throw "Inno Setup 6 compiler was not found: $iscc"
}
if (-not (Test-Path -LiteralPath $installerSource -PathType Leaf)) {
  throw "Installer source was not found: $installerSource"
}

$versionLine = Select-String -LiteralPath $pubspec -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+[0-9]+)?\s*$'
if ($null -eq $versionLine) {
  throw "A semantic version could not be read from $pubspec"
}
$version = $versionLine.Matches[0].Groups[1].Value

if (-not $SkipFlutterBuild) {
  Push-Location $clientRoot
  try {
    & flutter build windows --release
    if ($LASTEXITCODE -ne 0) {
      throw "Flutter Windows release build failed with exit code $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }
}

$exe = Join-Path $releaseDir 'ventio_native_client.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
  throw "Flutter build did not produce the expected executable: $exe"
}
New-Item -ItemType Directory -Force -Path $installerOutput | Out-Null

& $iscc "/DAppVersion=$version" "/DBuildOutput=$releaseDir" "/DInstallerOutput=$installerOutput" $installerSource
if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup compilation failed with exit code $LASTEXITCODE"
}

$artifact = Join-Path $installerOutput "Ventio-Client-Setup-$version.exe"
if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
  throw "Inno Setup did not produce the expected artifact: $artifact"
}
$hash = Get-FileHash -LiteralPath $artifact -Algorithm SHA256
$manifest = Join-Path $installerOutput 'SHA256SUMS.txt'
Set-Content -LiteralPath $manifest -Encoding ascii -Value "$($hash.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($artifact))"
Get-Item -LiteralPath $artifact | Select-Object FullName, Length
Write-Output "SHA256 $($hash.Hash.ToLowerInvariant())"
