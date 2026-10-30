param(
  [string] $PayloadDirectory = (Join-Path $env:ProgramFiles 'Ventio\host-payload'),
  [switch] $Apply
)

$ErrorActionPreference = 'Stop'
$payload = [IO.Path]::GetFullPath($PayloadDirectory)
$expectedPayload = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio\host-payload'))
$programData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
$port = 54329
$hostPort = 8080
$databaseDirectory = Join-Path $programData 'Ventio\PostgreSQL\data'
$hostConfigurationDirectory = Join-Path $programData 'Ventio\Host'
$installerStateDirectory = Join-Path $programData 'Ventio\Installer'
$postgresServiceName = 'VentioPostgres'
$hostServiceName = 'VentioHost'
$setupDirectory = Join-Path $payload 'setup'
$postgresProvisioner = Join-Path $setupDirectory 'provision-postgres-service.ps1'
$databaseInitializer = Join-Path $setupDirectory 'initialize-host-database.ps1'
$hostServiceRegistrar = Join-Path $setupDirectory 'register-host-service.ps1'
$hostConfigWriter = Join-Path $setupDirectory 'write-host-service-config.ps1'
$migrationCredentialModule = Join-Path $setupDirectory 'HostMigrationCredential.psm1'
$databaseUpgrade = Join-Path $setupDirectory 'upgrade-host-database.ps1'

function Test-ProductService([string] $Name, [string] $ExpectedAccount, [string] $ExpectedExecutable, [string] $ExpectedDataPath) {
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
  if ($null -eq $service) { return $null }
  if ($service.StartName -cne $ExpectedAccount -or
      $service.PathName -notmatch [regex]::Escape($ExpectedExecutable) -or
      ($ExpectedDataPath -and $service.PathName -notmatch [regex]::Escape($ExpectedDataPath))) {
    throw 'HOST_SERVICE_IDENTITY_CONFLICT'
  }
  return $service
}

function New-SetupCredential([string] $UserName, [int] $ByteCount) {
  $bytes = [byte[]]::new($ByteCount)
  $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $generator.GetBytes($bytes)
    $password = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    return [PSCredential]::new($UserName, $securePassword)
  } finally {
    [Array]::Clear($bytes, 0, $bytes.Length)
    $password = $null
    $generator.Dispose()
  }
}

function Wait-ProductService([string] $Name, [string] $ExpectedState) {
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  while ($true) {
    $service = Get-Service -Name $Name -ErrorAction Stop
    if ($service.Status.ToString() -eq $ExpectedState) { return }
    if ($ExpectedState -eq 'Running' -and $service.Status.ToString() -eq 'Stopped') {
      throw 'HOST_SERVICE_START_FAILED'
    }
    if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_SERVICE_READINESS_TIMEOUT' }
    Start-Sleep -Milliseconds 500
  }
}

if (-not $payload.Equals($expectedPayload, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'HOST_PAYLOAD_PATH_INVALID'
}
foreach ($file in @(
  (Join-Path $payload 'payload-manifest.json'),
  (Join-Path $payload 'ventio_host.exe'),
  (Join-Path $payload 'ventio_migrate.exe'),
  (Join-Path $payload 'ventio_identity_bootstrap.exe'),
  (Join-Path $payload 'VentioHostService.exe'),
  (Join-Path $payload 'postgresql\bin\postgres.exe'),
  (Join-Path $payload 'postgresql\bin\initdb.exe'),
  $postgresProvisioner, $databaseInitializer, $hostServiceRegistrar, $hostConfigWriter,
  $migrationCredentialModule, $databaseUpgrade
)) {
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'HOST_PAYLOAD_INCOMPLETE' }
}
$manifest = Get-Content -LiteralPath (Join-Path $payload 'payload-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.formatVersion -ne 1 -or $manifest.postgresVersion -ne '16.15' -or
    $manifest.credentialsIncluded -ne $false -or $manifest.databaseIncluded -ne $false) {
  throw 'HOST_PAYLOAD_MANIFEST_INVALID'
}
$setupScriptNames = @(
  'provision-host-installation.ps1', 'provision-postgres-service.ps1',
  'initialize-host-database.ps1', 'register-host-service.ps1',
  'write-host-service-config.ps1', 'HostMigrationCredential.psm1',
  'upgrade-host-database.ps1', 'stop-host-services.ps1',
  'remove-host-installation.ps1'
)
foreach ($scriptName in $setupScriptNames) {
  $relative = 'setup/' + $scriptName
  $entry = @($manifest.verifiedFiles | Where-Object { $_.path -ceq $relative })
  $file = Join-Path $setupDirectory $scriptName
  if ($entry.Count -ne 1 -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
    throw 'HOST_SETUP_SCRIPT_MANIFEST_ENTRY_MISSING'
  }
  $item = Get-Item -LiteralPath $file
  if ($item.Length -ne [long]$entry[0].length -or
      (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry[0].sha256) {
    throw 'HOST_SETUP_SCRIPT_HASH_INVALID'
  }
}

$postgres = Test-ProductService $postgresServiceName 'NT SERVICE\VentioPostgres' `
  (Join-Path $payload 'postgresql\bin\pg_ctl.exe') $databaseDirectory
$hostService = Test-ProductService $hostServiceName 'NT SERVICE\VentioHost' `
  (Join-Path $payload 'VentioHostService.exe') $null
if (($null -eq $postgres) -xor ($null -eq $hostService)) { throw 'HOST_PARTIAL_SERVICE_INSTALLATION' }

if (-not $Apply) {
  if ($postgres -and $hostService) {
    Write-Output 'HOST_UPGRADE_PLAN_VALID'
    Write-Output 'The existing Ventio services match the installed product paths. PostgreSQL data and configuration will be backed up before applying migrations.'
  } else {
    if (Test-Path -LiteralPath $databaseDirectory) {
      $entries = @(Get-ChildItem -LiteralPath $databaseDirectory -Force)
      if ($entries.Count -gt 0) { throw 'HOST_DATA_DIRECTORY_REQUIRES_REPAIR' }
    }
    Write-Output 'HOST_INSTALL_PLAN_VALID'
    Write-Output 'The bundled PostgreSQL runtime, migrations, Host service, and protected configuration are present. No service, database, or file was changed.'
  }
  return
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'HOST_INSTALL_ADMIN_ELEVATION_REQUIRED'
}

if ($postgres -and $hostService) {
  if ($hostService.State -ne 'Stopped') { throw 'HOST_UPGRADE_HOST_SERVICE_MUST_BE_STOPPED' }
  if ($postgres.State -ne 'Running') {
    Start-Service -Name $postgresServiceName -ErrorAction Stop
    Wait-ProductService $postgresServiceName 'Running'
  }
  & $databaseUpgrade -PostgresRoot (Join-Path $payload 'postgresql') -Port $port -Apply
  Start-Service -Name $hostServiceName -ErrorAction Stop
  Wait-ProductService $hostServiceName 'Running'
  Write-Output 'HOST_UPGRADE_SERVICES_READY'
  return
}

foreach ($directory in @($databaseDirectory, $hostConfigurationDirectory, $installerStateDirectory)) {
  if (Test-Path -LiteralPath $directory) {
    $entries = @(Get-ChildItem -LiteralPath $directory -Force)
    if ($entries.Count -gt 0) { throw 'HOST_EXISTING_DATA_REQUIRES_REPAIR' }
  }
}

$bootstrapCredential = New-SetupCredential 'ventio_bootstrap' 36
$runtimeCredential = New-SetupCredential 'ventio_runtime_app' 36
$identityCredential = New-SetupCredential 'ventio_identity_api_app' 36
$migrationCredential = New-SetupCredential 'ventio_migrator_app' 32
$failed = $false
try {
  & $postgresProvisioner -PostgresRoot (Join-Path $payload 'postgresql') -Port $port `
    -BootstrapCredential $bootstrapCredential -Apply
  & $databaseInitializer -PostgresRoot (Join-Path $payload 'postgresql') `
    -DataDirectory $databaseDirectory -Port $port -BootstrapCredential $bootstrapCredential `
    -RuntimeCredential $runtimeCredential -IdentityApiCredential $identityCredential `
    -MigrationCredential $migrationCredential -Apply

  Import-Module $migrationCredentialModule -Force
  Write-HostMigrationCredential -Credential $migrationCredential

  & $hostServiceRegistrar -PayloadDirectory $payload
  & $hostConfigWriter -RuntimeCredential $runtimeCredential -IdentityApiCredential $identityCredential `
    -DatabasePort $port -HostPort $hostPort
  Start-Service -Name $hostServiceName -ErrorAction Stop
  Wait-ProductService $hostServiceName 'Running'
  Write-Output 'HOST_INSTALL_SERVICES_READY_FOR_FIRST_ADMIN'
} catch {
  $failed = $true
  [Console]::Error.WriteLine('HOST_INSTALL_FAILED_DATA_PRESERVED')
  throw 'HOST_INSTALL_PROVISIONING_FAILED'
} finally {
  foreach ($credential in @($bootstrapCredential, $runtimeCredential, $identityCredential, $migrationCredential)) {
    if ($credential -and $credential.Password) { $credential.Password.Dispose() }
  }
  $bootstrapCredential = $null
  $runtimeCredential = $null
  $identityCredential = $null
  $migrationCredential = $null
}
