[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $InstallerPath,
  [Parameter(Mandatory = $true)] [ValidateSet('client', 'host')] [string] $SetupType
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
$isHost = $SetupType -eq 'host'
$hostValidationRoot = $null
if ($isHost) {
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Host installer validation requires an already elevated PowerShell session; no elevation prompt was started.'
  }
  $hostValidationRoot = Join-Path (Join-Path $env:ProgramFiles 'Ventio') ('HostInstallerValidation-' + [guid]::NewGuid().ToString('N'))
  $installDir = Join-Path $hostValidationRoot 'app'
  if (-not $hostValidationRoot.StartsWith((Join-Path $env:ProgramFiles 'Ventio') + '\', [StringComparison]::OrdinalIgnoreCase) -or
      (Test-Path -LiteralPath $hostValidationRoot)) {
    throw 'Host validation target is unsafe or already exists.'
  }
} else {
  $installDir = Join-Path $testRoot 'app'
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
    ("/TYPE=$SetupType"), ('/DIR="' + $installDir + '"'), '/NOICONS',
    $(if ($isHost) { '/ALLUSERS' } else { '/CURRENTUSER' })
  ) -Wait -PassThru
  if ($process.ExitCode -ne 0) { throw "Selected $SetupType installation failed with exit code $($process.ExitCode)." }
  if ($isHost -and -not $installDir.StartsWith((Join-Path $env:ProgramFiles 'Ventio') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Host installer validation did not install below the PostgreSQL provisioner product root.'
  }

  foreach ($relative in @(
    'ventio_native_client.exe', 'flutter_windows.dll', 'sqlite3.dll',
    'data\flutter_assets\AssetManifest.bin', 'unins000.exe'
  )) {
    if (-not (Test-Path -LiteralPath (Join-Path $installDir $relative) -PathType Leaf)) {
      throw "Selected $SetupType installation is missing a required app file."
    }
  }

  $hostRoot = Join-Path $installDir 'host-payload'
  if ($SetupType -eq 'client') {
    if (Test-Path -LiteralPath $hostRoot) {
      throw 'Client selection unexpectedly installed Host or PostgreSQL files.'
    }
  } else {
    $manifestPath = Join-Path $hostRoot 'payload-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
      throw 'Host selection did not install the Host payload manifest.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($relative in @(
      'ventio_host.exe', 'ventio_migrate.exe', 'VentioHostService.exe',
      'postgresql\bin\postgres.exe', 'postgresql\bin\initdb.exe',
      'postgresql\bin\pg_ctl.exe', 'postgresql\bin\psql.exe',
      'migrations\029_identity_device_activity.sql', 'security\bootstrap.sql'
    )) {
      if (-not (Test-Path -LiteralPath (Join-Path $hostRoot $relative) -PathType Leaf)) {
        throw 'Host selection is missing a required Host runtime component.'
      }
    }
    if ($manifest.postgresVersion -ne '16.15' -or $manifest.credentialsIncluded -ne $false -or
        $manifest.databaseIncluded -ne $false -or
        (Test-Path -LiteralPath (Join-Path $hostRoot 'postgresql\pgAdmin 4')) -or
        (Test-Path -LiteralPath (Join-Path $hostRoot 'postgresql\StackBuilder'))) {
      throw 'Installed Host payload differs from the safe runtime-only manifest.'
    }
  }
  if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    throw 'Installation changed data outside the selected application directory.'
  }

  $uninstaller = Join-Path $installDir 'unins000.exe'
  $process = Start-Process -FilePath $uninstaller -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
  ) -Wait -PassThru
  if ($process.ExitCode -ne 0) { throw "Selected $SetupType uninstallation failed with exit code $($process.ExitCode)." }
  if (Test-Path -LiteralPath $installDir) { throw 'Uninstaller left files in the temporary application directory.' }
  if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'Uninstallation removed data outside the application directory.' }
  $mode = $SetupType.ToUpperInvariant()
  Write-Output "UNIFIED_INSTALLER_${mode}_INSTALL_UNINSTALL_PASS"
}
finally {
  $env:TEMP = $previousTemp
  $env:TMP = $previousTmp
  $resolved = [IO.Path]::GetFullPath($testRoot)
  if ($resolved.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $resolved) -eq $testName -and (Test-Path -LiteralPath $resolved)) {
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
  if ($hostValidationRoot -and
      $hostValidationRoot.StartsWith((Join-Path $env:ProgramFiles 'Ventio') + '\', [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $hostValidationRoot) -match '^HostInstallerValidation-[0-9a-f]{32}$' -and
      (Test-Path -LiteralPath $hostValidationRoot)) {
    Remove-Item -LiteralPath $hostValidationRoot -Recurse -Force
  }
}
