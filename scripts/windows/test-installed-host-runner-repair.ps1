[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $InstallerPath,
  [Parameter(Mandatory = $true)] [ValidatePattern('^[0-9a-fA-F]{64}$')] [string] $InstallerSha256,
  [Parameter(Mandatory = $true)] [ValidatePattern('^[0-9]{1,20}$')] [string] $ExpectedClusterId
)

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'REPAIR_TEST_ADMIN_REQUIRED'
}

$installer = (Resolve-Path -LiteralPath $InstallerPath).ProviderPath
if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ine $InstallerSha256) {
  throw 'REPAIR_TEST_INSTALLER_HASH_MISMATCH'
}
$installRoot = Join-Path $env:ProgramFiles 'Ventio'
$payload = Join-Path $installRoot 'host-payload'
$productData = Join-Path $env:ProgramData 'Ventio'
$postgresRoot = Join-Path $productData 'PostgreSQL'
$data = Join-Path $postgresRoot 'data'
$runner = Join-Path $installRoot 'ventio_native_client.exe'
$control = Join-Path $payload 'postgresql\bin\pg_controldata.exe'
if (Get-Process -Name 'ventio_native_client' -ErrorAction SilentlyContinue) {
  throw 'REPAIR_TEST_CLOSE_VENTIO_FRAMEWORK_FIRST'
}

function Assert-OrdinaryPath([string] $Path) {
  $item = Get-Item -LiteralPath $Path -Force
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'REPAIR_TEST_REDIRECTED_PATH'
  }
}

function Assert-HostFixture {
  $services = @(Get-CimInstance Win32_Service |
    Where-Object { $_.Name -in 'VentioHost','VentioPostgres' })
  $hostService = $services | Where-Object Name -eq 'VentioHost'
  $postgresService = $services | Where-Object Name -eq 'VentioPostgres'
  if ($services.Count -ne 2 -or
      $hostService.StartName -cne 'NT SERVICE\VentioHost' -or
      $postgresService.StartName -cne 'NT SERVICE\VentioPostgres' -or
      $hostService.PathName -notlike "*$payload\VentioHostService.exe*" -or
      $postgresService.PathName -notlike "*$payload\postgresql\bin\pg_ctl.exe*" -or
      $postgresService.PathName -notlike "*$data*" -or
      $hostService.State -ne 'Running' -or $postgresService.State -ne 'Running' -or
      $hostService.StartMode -ne 'Auto' -or $postgresService.StartMode -ne 'Auto') {
    throw 'REPAIR_TEST_SERVICE_FIXTURE_MISMATCH'
  }

  $controlData = @(& $control $data)
  if ($LASTEXITCODE -ne 0 -or
      @($controlData | Select-String "^Database system identifier:\s*$ExpectedClusterId$").Count -ne 1) {
    throw 'REPAIR_TEST_CLUSTER_FIXTURE_MISMATCH'
  }
}

foreach ($path in @($installRoot, $payload, $runner, (Join-Path $payload 'postgresql'),
    (Join-Path $payload 'postgresql\bin'), $control, $productData, $postgresRoot, $data)) {
  Assert-OrdinaryPath $path
}
Assert-HostFixture

$holdParent = Join-Path $productData 'RecoveryEvidence'
if (-not (Test-Path -LiteralPath $holdParent -PathType Container)) {
  New-Item -ItemType Directory -Path $holdParent | Out-Null
}
Assert-OrdinaryPath $holdParent
$hold = Join-Path $holdParent ('wave1-runner-repair-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $hold | Out-Null
Assert-OrdinaryPath $hold
$heldRunner = Join-Path $hold 'ventio_native_client.exe'
$log = Join-Path $hold 'repair-install.log'
$runnerHash = (Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash
try {
  Move-Item -LiteralPath $runner -Destination $heldRunner
  if ((Get-FileHash -LiteralPath $heldRunner -Algorithm SHA256).Hash -cne $runnerHash) {
    throw 'REPAIR_TEST_HELD_RUNNER_HASH_MISMATCH'
  }
  $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LOG="' + $log + '"'
  $process = Start-Process -FilePath $installer -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
  if ($process.ExitCode -ne 0) { throw "REPAIR_TEST_INSTALLER_EXIT_$($process.ExitCode)" }
  if ((Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash -cne $runnerHash) {
    throw 'REPAIR_TEST_RESTORED_RUNNER_HASH_MISMATCH'
  }
  Assert-HostFixture
  Write-Output 'REPAIR_TEST_RUNNER_RESTORED'
} finally {
  if (-not (Test-Path -LiteralPath $runner) -and (Test-Path -LiteralPath $heldRunner -PathType Leaf) -and
      (Get-FileHash -LiteralPath $heldRunner -Algorithm SHA256).Hash -ceq $runnerHash) {
    Copy-Item -LiteralPath $heldRunner -Destination $runner
  }
  Write-Output "Repair evidence: $hold"
}
