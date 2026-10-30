param(
  [Parameter(Mandatory = $true)] [string] $PayloadDirectory,
  [switch] $Start,
  [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'
$serviceName = 'VentioHost'
$databaseServiceName = 'VentioPostgres'
$payload = [IO.Path]::GetFullPath($PayloadDirectory)
$hostExe = Join-Path $payload 'ventio_host.exe'
$serviceExe = Join-Path $payload 'VentioHostService.exe'
$configFile = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\Host\service-config.dpapi'
$sc = Join-Path $env:SystemRoot 'System32\sc.exe'

if (-not (Test-Path -LiteralPath $hostExe -PathType Leaf) -or -not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
  throw 'The verified Host payload is incomplete.'
}
$manifestPath = Join-Path $payload 'payload-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Host payload manifest is missing.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.hostExecutable -ne 'ventio_host.exe' -or $manifest.serviceExecutable -ne 'VentioHostService.exe' -or
    $manifest.credentialsIncluded -ne $false -or $manifest.databaseIncluded -ne $false) {
  throw 'Host payload manifest failed its safe-content checks.'
}

$existingHost = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
$existingDatabase = Get-Service -Name $databaseServiceName -ErrorAction SilentlyContinue
if ($PlanOnly -and $existingHost) {
  Write-Output 'HOST_SERVICE_PLAN_BLOCKED_EXISTING_SERVICE'
  return
}
if ($PlanOnly -and -not $existingDatabase) {
  Write-Output 'HOST_SERVICE_PLAN_BLOCKED_POSTGRES_MISSING'
  return
}
if ($existingHost) { throw 'VentioHost service already exists; use the separately reviewed repair/upgrade workflow.' }
if (-not $existingDatabase) { throw 'Isolated VentioPostgres service must be installed before registering VentioHost.' }
if ($Start -and -not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
  if ($PlanOnly) { Write-Output 'HOST_SERVICE_PLAN_BLOCKED_CONFIG_MISSING'; return }
  throw 'Protected Host service configuration must be provisioned before startup.'
}

if ($PlanOnly) {
  Write-Output 'HOST_SERVICE_PLAN_VALID'
  Write-Output 'Service identity: NT SERVICE\VentioHost (virtual account, service SID enabled).'
  Write-Output 'Dependency: VentioPostgres.'
  Write-Output 'Failure recovery: restart after 5 seconds, 30 seconds, and 60 seconds.'
  Write-Output 'No service or system configuration was changed.'
  return
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Administrator elevation is required to register the Host Windows service.'
}

$created = $false
try {
  & $sc create $serviceName 'binPath=' "`"$serviceExe`"" 'start=' 'auto' 'obj=' 'NT SERVICE\VentioHost' 'depend=' $databaseServiceName 'DisplayName=' 'Ventio Host Engine'
  if ($LASTEXITCODE -ne 0) { throw 'SCM service creation failed.' }
  $created = $true
  & $sc sidtype $serviceName 'unrestricted'
  if ($LASTEXITCODE -ne 0) { throw 'Could not enable the dedicated Host service SID.' }
  & $sc failure $serviceName 'reset=' '86400' 'actions=' 'restart/5000/restart/30000/restart/60000'
  if ($LASTEXITCODE -ne 0) { throw 'Could not configure Host service recovery actions.' }
  & $sc config $serviceName 'failureflag=' '1'
  if ($LASTEXITCODE -ne 0) { throw 'Could not enable service failure recovery.' }
  if ($Start) {
    & $sc start $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Host service start failed; review protected local diagnostics.' }
  }
  Write-Output 'HOST_SERVICE_REGISTERED'
}
catch {
  if ($created) {
    & $sc stop $serviceName *> $null
    & $sc delete $serviceName *> $null
  }
  [Console]::Error.WriteLine('HOST_SERVICE_REGISTRATION_FAILED')
  exit 2
}
