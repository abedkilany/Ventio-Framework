param([switch] $Apply)

# Targeted installed-service regression for the pinned development fix.
$ErrorActionPreference = 'Stop'
$executable = 'C:\Program Files\Ventio\host-payload\VentioHostService.exe'
$expectedHash = '129E4F4AB295FA161C32BE35C09F488107206250B9FAB6701D930A9F7B3113C3'
$statusFile = 'C:\Program Files\Ventio\SetupStatus\maintenance-fixed-stop-test-20261031.json'
$sc = Join-Path $env:SystemRoot 'System32\sc.exe'
$phase = 'PREFLIGHT'

function Publish([string] $State, [string] $Code) {
  if ($Apply) {
    $record = @{ formatVersion=1; operation='installed-bootstrap-service-stop-test'; state=$State; phase=$phase; code=$Code; timestamp=[DateTime]::UtcNow.ToString('o') }
    [IO.File]::WriteAllText($statusFile,($record | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  }
}

function Wait-State([string] $State, [int] $Seconds) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ((Get-Service -Name VentioHost).Status.ToString() -ne $State) {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'VENTIO_STOP_TEST_TIMEOUT' }
    Start-Sleep -Milliseconds 200
  }
}

try {
  $service = Get-CimInstance Win32_Service -Filter "Name='VentioHost'"
  $database = Get-CimInstance Win32_Service -Filter "Name='VentioPostgres'"
  $processes = @(Get-CimInstance Win32_Process)
  if ($service.State -cne 'Running' -or $service.StartMode -cne 'Auto' -or $service.StartName -cne 'NT SERVICE\VentioHost' -or
      -not $service.PathName.Trim('"').Equals($executable,[StringComparison]::OrdinalIgnoreCase) -or
      (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -ne $expectedHash -or
      $database.State -cne 'Running' -or $database.StartName -cne 'NT SERVICE\VentioPostgres' -or
      @($processes | Where-Object ParentProcessId -eq $service.ProcessId).Count -ne 0 -or
      @($processes | Where-Object { $_.Name -in @('ventio_native_client.exe','ventio_identity_bootstrap.exe','ventio_host.exe') -or $_.Name -like 'Ventio-Setup-*' }).Count -ne 0) {
    throw 'VENTIO_STOP_TEST_PREFLIGHT_FAILED'
  }
  if (-not $Apply) { Write-Output 'VENTIO_STOP_TEST_PREFLIGHT_PASS'; exit 0 }
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'VENTIO_STOP_TEST_ELEVATION_REQUIRED' }
  $phase = 'STOP'
  Publish 'running' 'VENTIO_STOP_TEST_STOPPING'
  $timer = [Diagnostics.Stopwatch]::StartNew()
  & $sc stop VentioHost | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'VENTIO_STOP_TEST_CONTROL_FAILED' }
  Wait-State 'Stopped' 20
  $elapsed = $timer.ElapsedMilliseconds
  $phase = 'START'
  Publish 'running' 'VENTIO_STOP_TEST_STARTING'
  & $sc start VentioHost | Out-Null
  if ($LASTEXITCODE -notin @(0,1056)) { throw 'VENTIO_STOP_TEST_START_FAILED' }
  Wait-State 'Running' 30
  if ((Get-Service -Name VentioPostgres).Status -ne 'Running') { throw 'VENTIO_STOP_TEST_POSTGRES_NOT_RUNNING' }
  $phase = 'COMPLETE'
  Publish 'complete' ('VENTIO_STOP_TEST_PASS_' + $elapsed + '_MS')
  Write-Output ('VENTIO_STOP_TEST_PASS: normal SCM stop completed in ' + $elapsed + 'ms; Host restarted; PostgreSQL remained running.')
}
catch {
  $code = [string]$_.Exception.Message
  if ($code -notmatch '^VENTIO_STOP_TEST_[A-Z_]+$') { $code = 'VENTIO_STOP_TEST_FAILED' }
  try { Publish 'failed' $code } catch { }
  if ($Apply -and (Get-Service VentioHost -ErrorAction SilentlyContinue).Status -eq 'Stopped') { & $sc start VentioHost | Out-Null }
  [Console]::Error.WriteLine($code)
  exit 1
}
