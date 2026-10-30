param(
  [string] $PayloadDirectory = (Join-Path $env:ProgramFiles 'Ventio\host-payload')
)

$ErrorActionPreference = 'Stop'
$payload = [IO.Path]::GetFullPath($PayloadDirectory)
$expectedPayload = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio\host-payload'))
$dataDirectory = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\PostgreSQL\data'))

function Get-ValidatedService([string] $Name, [string] $Account, [string] $Executable, [string] $DataPath) {
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
  if ($null -eq $service) { return $null }
  if ($service.StartName -cne $Account -or $service.PathName -notmatch [regex]::Escape($Executable) -or
      ($DataPath -and $service.PathName -notmatch [regex]::Escape($DataPath))) {
    throw 'HOST_SERVICE_IDENTITY_CONFLICT'
  }
  return $service
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
$postgres = Get-ValidatedService 'VentioPostgres' 'NT SERVICE\VentioPostgres' `
  (Join-Path $payload 'postgresql\bin\pg_ctl.exe') $dataDirectory
$hostService = Get-ValidatedService 'VentioHost' 'NT SERVICE\VentioHost' `
  (Join-Path $payload 'VentioHostService.exe') $null
if (($null -eq $postgres) -xor ($null -eq $hostService)) { throw 'HOST_PARTIAL_SERVICE_INSTALLATION' }
if (-not $postgres) {
  Write-Output 'HOST_SERVICES_NOT_INSTALLED'
  return
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'HOST_SERVICE_ADMIN_ELEVATION_REQUIRED' }

Stop-ValidatedService 'VentioHost'
Stop-ValidatedService 'VentioPostgres'
Write-Output 'HOST_SERVICES_STOPPED_FOR_UPGRADE'
