param(
  [Parameter(Mandatory = $true)]
  [string] $InstallerPath,
  [string] $UpgradeInstallerPath,
  [string] $ExpectedUpgradeVersion
)

$ErrorActionPreference = 'Stop'
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$upgradeInstaller = if ($UpgradeInstallerPath) {
  (Resolve-Path -LiteralPath $UpgradeInstallerPath).Path
} else {
  $null
}
if ($upgradeInstaller -and $ExpectedUpgradeVersion -notmatch '^\d+\.\d+\.\d+$') {
  throw 'ExpectedUpgradeVersion must be provided as a semantic version when testing an upgrade.'
}
$testBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = [IO.Path]::GetFullPath((Join-Path $testBase ("VentioInstallerTest-" + [guid]::NewGuid().ToString('N'))))
$testRootPrefix = $testBase + '\VentioInstallerTest-'
if (-not $testRoot.StartsWith($testRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Temporary test directory escaped the system temporary directory.'
}
$installDir = Join-Path $testRoot 'app'
$dataMarkerDir = Join-Path $testRoot 'preserved-user-data'
$marker = Join-Path $dataMarkerDir 'retention-marker.txt'
$process = $null
$previousTemp = $env:TEMP
$previousTmp = $env:TMP

New-Item -ItemType Directory -Force -Path $testRoot, $dataMarkerDir | Out-Null
Set-Content -LiteralPath $marker -Encoding ascii -Value 'installer validation marker'
$env:TEMP = $testRoot
$env:TMP = $testRoot

try {
  $process = Start-Process -FilePath $installer -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
    ('/DIR="' + $installDir + '"'), '/NOICONS'
  ) -Wait -PassThru
  if ($process.ExitCode -ne 0) {
    throw "Per-user install failed with exit code $($process.ExitCode)"
  }

  $appExe = Join-Path $installDir 'ventio_native_client.exe'
  $uninstaller = Join-Path $installDir 'unins000.exe'
  $requiredFiles = @(
    $appExe,
    (Join-Path $installDir 'flutter_windows.dll'),
    (Join-Path $installDir 'sqlite3.dll'),
    (Join-Path $installDir 'data\flutter_assets\AssetManifest.bin')
  )
  foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
      throw "Installed package is missing a required file: $requiredFile"
    }
  }
  if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
    throw 'Per-user uninstaller was not created.'
  }
  if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    throw 'The first install changed data outside the application directory.'
  }

  $process = Start-Process -FilePath $installer -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
    ('/DIR="' + $installDir + '"'), '/NOICONS'
  ) -Wait -PassThru
  if ($process.ExitCode -ne 0) {
    throw "Repeat per-user install failed with exit code $($process.ExitCode)"
  }
  if (-not (Test-Path -LiteralPath $appExe -PathType Leaf) -or
      -not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    throw 'Repeat install did not preserve the application and external data.'
  }

  if ($upgradeInstaller) {
    $process = Start-Process -FilePath $upgradeInstaller -ArgumentList @(
      '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
      ('/DIR="' + $installDir + '"'), '/NOICONS'
    ) -Wait -PassThru
    if ($process.ExitCode -ne 0) {
      throw "Client upgrade installer failed with exit code $($process.ExitCode)"
    }
    if (-not (Test-Path -LiteralPath $appExe -PathType Leaf) -or
        -not (Test-Path -LiteralPath $marker -PathType Leaf)) {
      throw 'Client upgrade did not preserve the installed application and external data.'
    }
    $installedEntry = Get-ChildItem -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' |
      ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue } |
      Where-Object {
        $_.InstallLocation -and
        [IO.Path]::GetFullPath($_.InstallLocation).TrimEnd('\') -eq $installDir.TrimEnd('\')
      } |
      Select-Object -First 1
    if ($null -eq $installedEntry -or $installedEntry.DisplayVersion -ne $ExpectedUpgradeVersion) {
      throw "Client upgrade did not register the expected package version $ExpectedUpgradeVersion."
    }
  }

  $process = Start-Process -FilePath $uninstaller -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-'
  ) -Wait -PassThru
  if ($process.ExitCode -ne 0) {
    throw "Per-user uninstall failed with exit code $($process.ExitCode)"
  }
  if (Test-Path -LiteralPath $installDir) {
    throw "Uninstaller left application binaries in the test directory: $installDir"
  }
  if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    throw 'Uninstall removed the isolated user-data retention marker.'
  }

  Write-Output 'PASS: per-user install placed the Flutter app and required runtime files.'
  Write-Output 'PASS: repeating the same installer preserved the app and external data.'
  if ($upgradeInstaller) {
    Write-Output "PASS: upgrading from the installed package to version $ExpectedUpgradeVersion preserved the app and external data."
  }
  Write-Output 'PASS: uninstaller removed the test installation directory.'
  Write-Output 'PASS: data outside the installation directory was preserved.'
  Write-Output 'LIMIT: this validates client packaging only; it does not test Host provisioning or service lifecycle.'
} finally {
  $env:TEMP = $previousTemp
  $env:TMP = $previousTmp
  if ($testRoot.StartsWith($testRootPrefix, [StringComparison]::OrdinalIgnoreCase) -and
      (Test-Path -LiteralPath $testRoot)) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
}
