param(
  [Parameter(Mandatory = $true)]
  [string] $BaseInstallerPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$baseInstaller = (Resolve-Path -LiteralPath $BaseInstallerPath).Path
$clientRoot = Join-Path $repoRoot 'packages\ventio_native_client'
$releaseDir = Join-Path $clientRoot 'build\windows\x64\runner\Release'
$installerSource = Join-Path $repoRoot 'installer\windows\ventio-client.iss'
$validator = Join-Path $PSScriptRoot 'validate-client-installer.ps1'
$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
$versionLine = Select-String -LiteralPath (Join-Path $clientRoot 'pubspec.yaml') -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+[0-9]+)?\s*$'

if ($null -eq $versionLine) { throw 'Could not read the current Client package version.' }
$baseVersion = $versionLine.Matches[0].Groups[1].Value
$baseInstallerName = "Ventio-Client-Setup-$baseVersion.exe"
if ([IO.Path]::GetFileName($baseInstaller) -ne $baseInstallerName) {
  throw "The base installer name must match the current package version: $baseInstallerName"
}
$versionParts = $baseVersion.Split('.')
$upgradeVersion = '{0}.{1}.{2}' -f $versionParts[0], $versionParts[1], ([int]$versionParts[2] + 1)
if (-not (Test-Path -LiteralPath $iscc -PathType Leaf)) { throw "Inno Setup compiler was not found: $iscc" }

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRootName = 'VentioInstallerUpgrade-' + [guid]::NewGuid().ToString('N')
$testRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot $testRootName))
if (-not $testRoot.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $testRoot) -ne $testRootName) {
  throw 'Upgrade test directory escaped the system temporary directory.'
}
$outputDir = Join-Path $testRoot 'upgrade-package'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

try {
  & $iscc "/DAppVersion=$upgradeVersion" "/DBuildOutput=$releaseDir" "/DInstallerOutput=$outputDir" $installerSource
  if ($LASTEXITCODE -ne 0) { throw "Could not compile the isolated $upgradeVersion package (exit $LASTEXITCODE)." }
  $upgradeInstaller = Join-Path $outputDir "Ventio-Client-Setup-$upgradeVersion.exe"
  if (-not (Test-Path -LiteralPath $upgradeInstaller -PathType Leaf)) {
    throw 'The isolated upgrade package was not produced.'
  }

  & $validator -InstallerPath $baseInstaller -UpgradeInstallerPath $upgradeInstaller -ExpectedUpgradeVersion $upgradeVersion
  if ($LASTEXITCODE -ne 0) { throw "The isolated Client install/upgrade validation failed with exit code $LASTEXITCODE." }
}
finally {
  $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
  if ($resolvedRoot.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $resolvedRoot) -eq $testRootName -and
      (Test-Path -LiteralPath $resolvedRoot)) {
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
  }
}
