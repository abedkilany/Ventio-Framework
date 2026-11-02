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
$migrationExe = Join-Path $payload 'ventio_migrate.exe'
$identityBootstrapExe = Join-Path $payload 'ventio_identity_bootstrap.exe'
$serviceExe = Join-Path $payload 'VentioHostService.exe'
$expectedPayload = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio\host-payload'))
$configFile = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\Host\service-config.dpapi'
$sc = Join-Path $env:SystemRoot 'System32\sc.exe'

function ConvertTo-WindowsCommandLineArgument([string] $Value) {
  $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $trailingSlashes = [regex]::Match($escaped, '\\+$').Length
  if ($trailingSlashes -gt 0) {
    $escaped = $escaped.Substring(0, $escaped.Length - $trailingSlashes) + ('\' * ($trailingSlashes * 2))
  }
  return '"' + $escaped + '"'
}

function Invoke-ServiceControl([string[]] $CommandArguments) {
  if ($CommandArguments.Count -lt 1) { throw 'HOST_SERVICE_CONTROL_ARGUMENTS_INVALID' }
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $sc
  $startInfo.Arguments = (($CommandArguments | ForEach-Object {
    ConvertTo-WindowsCommandLineArgument ([string]$_)
  }) -join ' ')
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $process = [Diagnostics.Process]::Start($startInfo)
  if ($null -eq $process) { throw 'HOST_SERVICE_CONTROL_START_FAILED' }
  try {
    $process.WaitForExit()
    return [int]$process.ExitCode
  } finally {
    $process.Dispose()
  }
}

if (-not $payload.Equals($expectedPayload, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Host service payload must be the verified machine-wide Ventio installation directory.'
}

if (-not (Test-Path -LiteralPath $hostExe -PathType Leaf) -or
    -not (Test-Path -LiteralPath $migrationExe -PathType Leaf) -or
    -not (Test-Path -LiteralPath $identityBootstrapExe -PathType Leaf) -or
    -not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
  throw 'The verified Host payload is incomplete.'
}
$manifestPath = Join-Path $payload 'payload-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Host payload manifest is missing.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.hostExecutable -ne 'ventio_host.exe' -or $manifest.migrationExecutable -ne 'ventio_migrate.exe' -or
    $manifest.identityBootstrapExecutable -ne 'ventio_identity_bootstrap.exe' -or
    $manifest.serviceExecutable -ne 'VentioHostService.exe' -or
    $manifest.credentialsIncluded -ne $false -or $manifest.databaseIncluded -ne $false) {
  throw 'Host payload manifest failed its safe-content checks.'
}

foreach ($relative in @('ventio_host.exe', 'ventio_migrate.exe', 'ventio_identity_bootstrap.exe', 'VentioHostService.exe')) {
  $entry = @($manifest.verifiedFiles | Where-Object { $_.path -ceq $relative })
  $file = Join-Path $payload $relative
  if ($entry.Count -ne 1 -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
    throw 'Host payload manifest is missing a required executable hash.'
  }
  $item = Get-Item -LiteralPath $file
  if ($item.Length -ne [long]$entry[0].length -or
      (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry[0].sha256) {
    throw 'A required Host executable differs from its payload manifest.'
  }
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
  $createArguments = @(
    'create', $serviceName, 'binPath=', ('"' + $serviceExe + '"'),
    'start=', 'auto', 'obj=', 'NT SERVICE\VentioHost',
    'depend=', $databaseServiceName, 'DisplayName=', 'Ventio Host Engine'
  )
  if ((Invoke-ServiceControl $createArguments) -ne 0) { throw 'SCM service creation failed.' }
  $created = $true
  $serviceReadbackDeadline = [DateTime]::UtcNow.AddSeconds(15)
  $registeredService = $null
  while ($null -eq $registeredService -and [DateTime]::UtcNow -lt $serviceReadbackDeadline) {
    $registeredService = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
    if ($null -eq $registeredService) { Start-Sleep -Milliseconds 200 }
  }
  $expectedImagePath = '"' + $serviceExe + '"'
  if ($null -eq $registeredService -or
      $registeredService.StartName -cne 'NT SERVICE\VentioHost' -or
      $registeredService.PathName -cne $expectedImagePath) {
    throw 'HOST_SERVICE_IMAGE_PATH_VERIFICATION_FAILED'
  }
  if ((Invoke-ServiceControl @('sidtype', $serviceName, 'unrestricted')) -ne 0) {
    throw 'Could not enable the dedicated Host service SID.'
  }
  if ((Invoke-ServiceControl @('failure', $serviceName, 'reset=', '86400', 'actions=', 'restart/5000/restart/30000/restart/60000')) -ne 0) {
    throw 'Could not configure Host service recovery actions.'
  }
  if ((Invoke-ServiceControl @('failureflag', $serviceName, '1')) -ne 0) {
    throw 'Could not enable service failure recovery.'
  }
  if ($Start) {
    if ((Invoke-ServiceControl @('start', $serviceName)) -ne 0) {
      throw 'Host service start failed; review protected local diagnostics.'
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while ($true) {
      $registeredService = Get-Service -Name $serviceName -ErrorAction Stop
      if ($registeredService.Status.ToString() -eq 'Running') { break }
      if ($registeredService.Status.ToString() -eq 'Stopped') {
        throw 'Host service stopped before its readiness checks completed.'
      }
      if ([DateTime]::UtcNow -ge $deadline) { throw 'Host service readiness timed out.' }
      Start-Sleep -Seconds 1
    }
  }
  Write-Output 'HOST_SERVICE_REGISTERED'
}
catch {
  if ($created) {
    try { [void](Invoke-ServiceControl @('stop', $serviceName)) } catch { }
    try { [void](Invoke-ServiceControl @('delete', $serviceName)) } catch { }
  }
  [Console]::Error.WriteLine('HOST_SERVICE_REGISTRATION_FAILED')
  throw 'HOST_SERVICE_REGISTRATION_FAILED'
}
