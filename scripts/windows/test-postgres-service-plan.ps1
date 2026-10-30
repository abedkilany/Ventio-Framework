$ErrorActionPreference = 'Stop'
$provisioner = Join-Path $PSScriptRoot 'provision-postgres-service.ps1'
$payload = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\packages\ventio_host_api\build\windows\host-payload\postgresql'))
$data = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\PostgreSQL\data'

if (Get-Service -Name VentioPostgres -ErrorAction SilentlyContinue) {
  throw 'Refusing to run the non-mutation plan test when a VentioPostgres service already exists.'
}
if ((Test-Path -LiteralPath $data -PathType Container) -and
    -not (Get-ChildItem -LiteralPath $data -Force | Select-Object -First 1)) {
  throw 'Refusing to run the clean-machine plan test when a Ventio data directory already exists.'
}

$beforeServices = @(Get-CimInstance -ClassName Win32_Service |
  Where-Object { $_.Name -in @('VentioPostgres', 'VentioHost') } |
  Select-Object Name, State, StartMode, PathName | Sort-Object Name | ConvertTo-Json -Compress)
$beforeDataExists = Test-Path -LiteralPath $data
try {
  $output = @(& $provisioner -PostgresRoot $payload 2>&1 | ForEach-Object { $_.ToString() })
  $invokeSucceeded = $?
} catch {
  $output = @($_.ToString())
  $invokeSucceeded = $false
}
if (-not $invokeSucceeded -or $output -notcontains 'POSTGRES_SERVICE_PLAN_VALID') {
  throw "PostgreSQL service plan did not pass: $($output -join ' ')"
}
if ($output -notcontains 'Plan only; no files, services, accounts, firewall rules, or registry values were changed.') {
  throw 'PostgreSQL plan did not state its no-change guarantee.'
}

$afterServices = @(Get-CimInstance -ClassName Win32_Service |
  Where-Object { $_.Name -in @('VentioPostgres', 'VentioHost') } |
  Select-Object Name, State, StartMode, PathName | Sort-Object Name | ConvertTo-Json -Compress)
if (($beforeServices -join '') -ne ($afterServices -join '')) {
  throw 'PostgreSQL plan changed Ventio Windows service state.'
}
if ((Test-Path -LiteralPath $data) -ne $beforeDataExists) {
  throw 'PostgreSQL plan created or removed the Ventio data directory.'
}
Write-Output 'POSTGRES_SERVICE_PLAN_TEST_PASS'
