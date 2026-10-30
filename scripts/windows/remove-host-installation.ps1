param(
  [string] $PayloadDirectory = (Join-Path $env:ProgramFiles 'Ventio\host-payload'),
  [switch] $RemoveData
)

$ErrorActionPreference = 'Stop'
$payload = [IO.Path]::GetFullPath($PayloadDirectory)
$expectedPayload = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio\host-payload'))
$programData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
$programDataVentio = [IO.Path]::GetFullPath((Join-Path $programData 'Ventio'))
$databaseData = [IO.Path]::GetFullPath((Join-Path $programDataVentio 'PostgreSQL'))
$hostData = [IO.Path]::GetFullPath((Join-Path $programDataVentio 'Host'))
$installerData = [IO.Path]::GetFullPath((Join-Path $programDataVentio 'Installer'))
$backupData = [IO.Path]::GetFullPath((Join-Path $programDataVentio 'Backups'))
$sc = Join-Path $env:SystemRoot 'System32\sc.exe'

function Get-ValidatedService([string] $Name, [string] $Account, [string] $Executable, [string] $DataPath) {
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
  if ($null -eq $service) { return $null }
  if ($service.StartName -cne $Account -or $service.PathName -notmatch [regex]::Escape($Executable) -or
      ($DataPath -and $service.PathName -notmatch [regex]::Escape($DataPath))) {
    throw 'HOST_SERVICE_IDENTITY_CONFLICT'
  }
  return $service
}

function Assert-PrivateProductDirectory([string] $Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  $programPrefix = $programDataVentio.TrimEnd('\') + '\'
  if (-not $fullPath.StartsWith($programPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HOST_DATA_PATH_OUTSIDE_PRODUCT_ROOT'
  }

  $cursor = $fullPath
  while ($true) {
    $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'HOST_DATA_REPARSE_POINT'
    }
    if ($item -and -not $item.PSIsContainer) { throw 'HOST_DATA_PATH_TYPE_INVALID' }
    $parent = [IO.Directory]::GetParent($cursor)
    if ($null -eq $parent -or $parent.FullName -eq $cursor) { break }
    $cursor = $parent.FullName
  }

  if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) { return }
  $directories = [Collections.Generic.Stack[string]]::new()
  $directories.Push($fullPath)
  while ($directories.Count -gt 0) {
    $current = $directories.Pop()
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current)) {
      $child = Get-Item -LiteralPath $entry -Force
      if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'HOST_DATA_REPARSE_POINT'
      }
      if ($child.PSIsContainer) { $directories.Push($child.FullName) }
    }
  }
}
function Stop-ValidatedService([string] $Name) {
  $service = Get-Service -Name $Name -ErrorAction Stop
  if ($service.Status -eq 'Stopped') { return }
  Stop-Service -Name $Name -Force -ErrorAction Stop
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  while ((Get-Service -Name $Name).Status -ne 'Stopped') {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_SERVICE_STOP_TIMEOUT' }
    Start-Sleep -Milliseconds 500
  }
}

if (-not $payload.Equals($expectedPayload, [StringComparison]::OrdinalIgnoreCase)) { throw 'HOST_PAYLOAD_PATH_INVALID' }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'HOST_UNINSTALL_ADMIN_ELEVATION_REQUIRED' }
$postgres = Get-ValidatedService 'VentioPostgres' 'NT SERVICE\VentioPostgres' `
  (Join-Path $payload 'postgresql\bin\pg_ctl.exe') (Join-Path $databaseData 'data')
$hostService = Get-ValidatedService 'VentioHost' 'NT SERVICE\VentioHost' `
  (Join-Path $payload 'VentioHostService.exe') $null
if (($null -eq $postgres) -xor ($null -eq $hostService)) { throw 'HOST_PARTIAL_SERVICE_INSTALLATION' }
if ($RemoveData) {
  foreach ($path in @($databaseData, $hostData, $installerData, $backupData)) {
    Assert-PrivateProductDirectory $path
  }
}

if ($hostService) {
  Stop-ValidatedService 'VentioHost'
  Stop-ValidatedService 'VentioPostgres'
  foreach ($name in @('VentioHost', 'VentioPostgres')) {
    & $sc delete $name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'HOST_SERVICE_REMOVAL_FAILED' }
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while ($true) {
    $remaining = @(Get-CimInstance -ClassName Win32_Service | Where-Object { $_.Name -in @('VentioHost', 'VentioPostgres') })
    if ($remaining.Count -eq 0) { break }
    if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_SERVICE_REMOVAL_TIMEOUT' }
    Start-Sleep -Milliseconds 500
  }
}

if ($RemoveData) {
  foreach ($path in @($databaseData, $hostData, $installerData, $backupData)) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
  }
  if ((Test-Path -LiteralPath $programDataVentio) -and
      @(Get-ChildItem -LiteralPath $programDataVentio -Force).Count -eq 0) {
    Remove-Item -LiteralPath $programDataVentio -Force
  }
  Write-Output 'HOST_SERVICES_REMOVED_AND_DATA_DELETED'
} else {
  Write-Output 'HOST_SERVICES_REMOVED_DATA_RETAINED'
}
