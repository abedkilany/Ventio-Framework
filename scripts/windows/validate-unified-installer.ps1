[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $InstallerPath
)

$ErrorActionPreference = 'Stop'
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testName = 'VentioUnifiedInstaller-' + [guid]::NewGuid().ToString('N')
$testRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot $testName))
if (-not $testRoot.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $testRoot) -ne $testName) {
  throw 'Unified installer fixture escaped the temporary directory.'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Unified installer lifecycle validation requires an already elevated PowerShell session; no elevation prompt was started.'
}
$installDir = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio'))
$expectedInstallDir = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio'))
$programDataVentio = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio'
$databaseDirectory = Join-Path $programDataVentio 'PostgreSQL\data'
if (-not $installDir.Equals($expectedInstallDir, [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $installDir) -or (Test-Path -LiteralPath $databaseDirectory) -or
    (Get-Service -Name 'VentioPostgres' -ErrorAction SilentlyContinue) -or
    (Get-Service -Name 'VentioHost' -ErrorAction SilentlyContinue)) {
  throw 'Unified installer validation requires a clean isolated Windows host with no existing Ventio installation or data.'
}
$externalData = Join-Path $testRoot 'retained-data'
$marker = Join-Path $externalData 'retention-marker.txt'
$previousTemp = $env:TEMP
$previousTmp = $env:TMP
$process = $null
[void](New-Item -ItemType Directory -Path $testRoot, $externalData -Force)
Set-Content -LiteralPath $marker -Encoding ascii -Value 'unified-installer-retention-fixture'
$env:TEMP = $testRoot
$env:TMP = $testRoot

try {
  $process = Start-Process -FilePath $installer -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
    ('/DIR="' + $installDir + '"'), '/NOICONS'
  ) -Wait -PassThru
  if ($process.ExitCode -ne 0) { throw ('Unified installer failed with exit code ' + $process.ExitCode + '.') }
  if (-not $installDir.Equals($expectedInstallDir, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unified installer did not use the protected machine-wide product directory.'
  }

  foreach ($relative in @(
    'ventio_native_client.exe', 'flutter_windows.dll', 'sqlite3.dll',
    'data\flutter_assets\AssetManifest.bin', 'unins000.exe'
  )) {
    if (-not (Test-Path -LiteralPath (Join-Path $installDir $relative) -PathType Leaf)) {
      throw 'Unified installer is missing a required app file.'
    }
  }

  $hostRoot = Join-Path $installDir 'host-payload'
  $manifestPath = Join-Path $hostRoot 'payload-manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'Unified installer did not install the Host payload required by the first-run Host choice.'
  }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  foreach ($relative in @(
    'ventio_host.exe', 'ventio_migrate.exe', 'ventio_identity_bootstrap.exe', 'VentioHostService.exe',
    'VentioSetupBroker.exe', 'postgresql\bin\postgres.exe', 'postgresql\bin\initdb.exe',
    'postgresql\bin\pg_ctl.exe', 'postgresql\bin\psql.exe',
    'migrations\029_identity_device_activity.sql', 'migrations\030_identity_user_enable.sql',
    'security\bootstrap.sql'
  )) {
    if (-not (Test-Path -LiteralPath (Join-Path $hostRoot $relative) -PathType Leaf)) {
      throw 'Unified installer is missing a required Host runtime component.'
    }
  }
  if ($manifest.postgresVersion -ne '16.15' -or $manifest.credentialsIncluded -ne $false -or
      $manifest.databaseIncluded -ne $false -or
      (Test-Path -LiteralPath (Join-Path $hostRoot 'postgresql\pgAdmin 4')) -or
      (Test-Path -LiteralPath (Join-Path $hostRoot 'postgresql\StackBuilder')) -or
      (Test-Path -LiteralPath (Join-Path $hostRoot 'postgresql\bin\stackbuilder.exe'))) {
    throw 'Installed Host payload differs from the safe runtime-only manifest.'
  }
  if ((Test-Path -LiteralPath $databaseDirectory) -or
      (Get-Service -Name 'VentioPostgres' -ErrorAction SilentlyContinue) -or
      (Get-Service -Name 'VentioHost' -ErrorAction SilentlyContinue)) {
    throw 'Installer provisioned Host database data or services before first-run setup.'
  }
  if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    throw 'Installation changed data outside the selected application directory.'
  }

  $uninstaller = Join-Path $installDir 'unins000.exe'
  $process = Start-Process -FilePath $uninstaller -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
  ) -Wait -PassThru
  if ($process.ExitCode -ne 0) { throw ('Unified uninstaller failed with exit code ' + $process.ExitCode + '.') }
  if (Test-Path -LiteralPath $installDir) { throw 'Uninstaller left files in the temporary application directory.' }
  if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'Uninstallation removed data outside the application directory.' }
  if ((Get-Service -Name 'VentioPostgres' -ErrorAction SilentlyContinue) -or
      (Get-Service -Name 'VentioHost' -ErrorAction SilentlyContinue)) {
    throw 'Uninstallation left Ventio Host services on the clean validation machine.'
  }
  Write-Output 'UNIFIED_INSTALLER_SHARED_APP_AND_HOST_PAYLOAD_INSTALL_UNINSTALL_PASS'
  Write-Output 'UNIFIED_INSTALLER_NO_DATABASE_OR_HOST_SERVICE_PROVISIONING_PASS'
}
finally {
  $env:TEMP = $previousTemp
  $env:TMP = $previousTmp
  $resolved = [IO.Path]::GetFullPath($testRoot)
  if ($resolved.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $resolved) -eq $testName -and (Test-Path -LiteralPath $resolved)) {
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}
