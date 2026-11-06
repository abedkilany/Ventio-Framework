param(
  [string] $PostgresRoot = (Join-Path $PSScriptRoot '..\..\packages\ventio_host_api\build\windows\host-payload\postgresql'),
  [string] $DataDirectory = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\PostgreSQL\data'),
  [int] $Port = 54329,
  [PSCredential] $BootstrapCredential,
  [PSCredential] $RuntimeCredential,
  [PSCredential] $IdentityApiCredential,
  [PSCredential] $MigrationCredential,
  [switch] $Apply,
  [switch] $TestMode
)

$ErrorActionPreference = 'Stop'
$pgRoot = [IO.Path]::GetFullPath($PostgresRoot)
$payloadRoot = Split-Path -Parent $pgRoot
$bin = Join-Path $pgRoot 'bin'
$psql = Join-Path $bin 'psql.exe'
$createdb = Join-Path $bin 'createdb.exe'
$postgres = Join-Path $bin 'postgres.exe'
$migrationExe = Join-Path $payloadRoot 'ventio_migrate.exe'
$migrations = Join-Path $payloadRoot 'migrations'
$securityRoot = Join-Path $payloadRoot 'security'
$bootstrapSql = Join-Path $securityRoot 'bootstrap.sql'
$serviceName = 'VentioPostgres'
$databaseName = 'ventio_host'
$bootstrapRole = 'ventio_bootstrap'

function Get-SecureText([Security.SecureString] $Secret) {
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Secret)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringUni($pointer) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer) }
}

function ConvertTo-WindowsCommandLineArgument([string] $Value) {
  $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $trailingSlashes = [regex]::Match($escaped, '\\+$').Length
  if ($trailingSlashes -gt 0) {
    $escaped = $escaped.Substring(0, $escaped.Length - $trailingSlashes) + ('\' * ($trailingSlashes * 2))
  }
  return '"' + $escaped + '"'
}

function Assert-ApplicationCredential([PSCredential] $Credential, [string] $ExpectedName) {
  if (-not $Credential -or $Credential.UserName -cne $ExpectedName -or $Credential.Password.Length -lt 24) {
    throw 'HOST_DATABASE_CREDENTIAL_INVALID'
  }
  $secret = Get-SecureText $Credential.Password
  try {
    if ($secret -match '[\x00-\x1f\x7f]') { throw 'HOST_DATABASE_CREDENTIAL_INVALID' }
  }
  finally { $secret = $null }
}

function Invoke-Psql([string[]] $Arguments, [string] $SqlInput = $null, [int] $TimeoutMs = 120000) {
  $info = [Diagnostics.ProcessStartInfo]::new($psql)
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.RedirectStandardInput = ($null -ne $SqlInput)
  $quotedArguments = foreach ($argument in $Arguments) {
    ConvertTo-WindowsCommandLineArgument $argument
  }
  $info.Arguments = [string]::Join(' ', [string[]]$quotedArguments)
  $process = [Diagnostics.Process]::new()
  $started = $false
  try {
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'HOST_DATABASE_CLIENT_START_FAILED' }
    $started = $true
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if ($null -ne $SqlInput) {
      $process.StandardInput.Write($SqlInput)
      $process.StandardInput.Close()
    }
    if (-not $process.WaitForExit($TimeoutMs)) { throw 'HOST_DATABASE_CLIENT_TIMEOUT' }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw 'HOST_DATABASE_SQL_FAILED' }
    return $stdout.Trim()
  }
  finally {
    if ($started -and -not $process.HasExited) {
      try { $process.Kill(); $process.WaitForExit() } catch { }
    }
    $process.Dispose()
    $stdout = $null
    $stderr = $null
  }
}

function Invoke-MigrationRunner([string] $DatabaseUrl) {
  $oldUrl = $env:VENTIO_DATABASE_URL
  $oldMigrations = $env:VENTIO_MIGRATIONS_DIR
  $oldRole = $env:VENTIO_MIGRATION_ROLE
  $env:VENTIO_DATABASE_URL = $DatabaseUrl
  $env:VENTIO_MIGRATIONS_DIR = $migrations
  Remove-Item Env:VENTIO_MIGRATION_ROLE -ErrorAction SilentlyContinue
  $process = [Diagnostics.Process]::new()
  $started = $false
  try {
    $info = [Diagnostics.ProcessStartInfo]::new($migrationExe)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'HOST_MIGRATION_RUNNER_START_FAILED' }
    $started = $true
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) { throw 'HOST_MIGRATION_RUNNER_TIMEOUT' }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
      $sqlState = [regex]::Match(($stdout + "`n" + $stderr), '(?:SQLSTATE|code)\s*[:= ]\s*([0-9A-Z]{5})', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
      if (-not $sqlState.Success) { $sqlState = [regex]::Match(($stdout + "`n" + $stderr), '\b([0-9][0-9A-Z]{4})\b') }
      if ($sqlState.Success) { Write-Output ('HOST_MIGRATION_SQLSTATE_' + $sqlState.Groups[1].Value.ToUpperInvariant()) }
      throw 'HOST_MIGRATION_RUNNER_FAILED'
    }
  }
  finally {
    if ($started -and -not $process.HasExited) {
      try { $process.Kill(); $process.WaitForExit() } catch { }
    }
    $process.Dispose()
    $stdout = $null
    $stderr = $null
    if ($null -eq $oldUrl) { Remove-Item Env:VENTIO_DATABASE_URL -ErrorAction SilentlyContinue } else { $env:VENTIO_DATABASE_URL = $oldUrl }
    if ($null -eq $oldMigrations) { Remove-Item Env:VENTIO_MIGRATIONS_DIR -ErrorAction SilentlyContinue } else { $env:VENTIO_MIGRATIONS_DIR = $oldMigrations }
    if ($null -eq $oldRole) { Remove-Item Env:VENTIO_MIGRATION_ROLE -ErrorAction SilentlyContinue } else { $env:VENTIO_MIGRATION_ROLE = $oldRole }
  }
}

if ($Port -lt 1 -or $Port -gt 65535) { throw 'HOST_DATABASE_PORT_INVALID' }
foreach ($path in @($psql, $createdb, $postgres, $migrationExe, $migrations, $bootstrapSql)) {
  if (-not (Test-Path -LiteralPath $path)) { throw 'HOST_DATABASE_PAYLOAD_INCOMPLETE' }
}
$version = (& $postgres --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $version -ne 'postgres (PostgreSQL) 16.15') { throw 'HOST_DATABASE_VERSION_UNSUPPORTED' }
$data = [IO.Path]::GetFullPath($DataDirectory)
if ($TestMode) {
  $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ventio-pg-initdb-test-'
  if (-not $data.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HOST_DATABASE_TEST_PATH_INVALID'
  }
} else {
  $expectedData = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\PostgreSQL\data'))
  if (-not $data.Equals($expectedData, [StringComparison]::OrdinalIgnoreCase)) { throw 'HOST_DATABASE_PATH_NOT_PRODUCT_OWNED' }
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
  if ($null -eq $service -or $service.State -ne 'Running' -or $service.StartName -cne 'NT SERVICE\VentioPostgres' -or
      $service.PathName -notmatch [regex]::Escape($pgRoot) -or $service.PathName -notmatch [regex]::Escape($data)) {
    throw 'HOST_DATABASE_SERVICE_IDENTITY_MISMATCH'
  }
}

if (-not $Apply) {
  if (-not $BootstrapCredential -or $BootstrapCredential.UserName -cne $bootstrapRole) { throw 'HOST_DATABASE_CREDENTIAL_INVALID' }
  $oldPassword = $env:PGPASSWORD
  try {
    $env:PGPASSWORD = Get-SecureText $BootstrapCredential.Password
    $target = Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$bootstrapRole,'-d','postgres','-Atc',"SELECT current_setting('data_directory')")
    if (-not [IO.Path]::GetFullPath($target).Equals($data, [StringComparison]::OrdinalIgnoreCase)) { throw 'HOST_DATABASE_DATA_DIRECTORY_MISMATCH' }
    $databaseExists = Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$bootstrapRole,'-d','postgres','-Atc',"SELECT count(*) FROM pg_database WHERE datname='$databaseName'")
    if ($databaseExists -ne '0') { throw 'HOST_DATABASE_ALREADY_INITIALIZED' }
    Write-Output 'HOST_DATABASE_PLAN_VALID'
    Write-Output 'Plan only; no database, role, service, or file was changed.'
  }
  finally {
    if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
    $BootstrapCredential = $null
  }
  return
}

if (-not $TestMode) {
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'HOST_DATABASE_ADMIN_ELEVATION_REQUIRED' }
}
if (-not $BootstrapCredential -or $BootstrapCredential.UserName -cne $bootstrapRole) { throw 'HOST_DATABASE_BOOTSTRAP_CREDENTIAL_INVALID' }
Assert-ApplicationCredential $RuntimeCredential 'ventio_runtime_app'
Assert-ApplicationCredential $IdentityApiCredential 'ventio_identity_api_app'
Assert-ApplicationCredential $MigrationCredential 'ventio_migrator_app'
$runtimeSecret = Get-SecureText $RuntimeCredential.Password
$identitySecret = Get-SecureText $IdentityApiCredential.Password
$migrationSecret = Get-SecureText $MigrationCredential.Password
$bootstrapSecret = Get-SecureText $BootstrapCredential.Password
$oldPassword = $env:PGPASSWORD
try {
  $env:PGPASSWORD = $bootstrapSecret
  $target = Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$bootstrapRole,'-d','postgres','-Atc',"SELECT current_setting('data_directory')")
  if (-not [IO.Path]::GetFullPath($target).Equals($data, [StringComparison]::OrdinalIgnoreCase)) { throw 'HOST_DATABASE_DATA_DIRECTORY_MISMATCH' }
  $databaseExists = Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$bootstrapRole,'-d','postgres','-Atc',"SELECT count(*) FROM pg_database WHERE datname='$databaseName'")
  $reservedRoles = Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$bootstrapRole,'-d','postgres','-Atc',"SELECT count(*) FROM pg_roles WHERE rolname IN ('ventio_owner','ventio_runtime','ventio_identity_admin','ventio_identity_api','ventio_migrator','ventio_runtime_app','ventio_identity_api_app','ventio_migrator_app')")
  if ($databaseExists -ne '0' -or $reservedRoles -ne '0') { throw 'HOST_DATABASE_OR_ROLE_CONFLICT' }

  $baseRolesSql = @'
CREATE ROLE ventio_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
CREATE ROLE ventio_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
CREATE ROLE ventio_identity_admin NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
CREATE ROLE ventio_identity_api NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
CREATE ROLE ventio_migrator NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
'@
  [void](Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$bootstrapRole,'-d','postgres','-v','ON_ERROR_STOP=1') $baseRolesSql)
  & $createdb -h 127.0.0.1 -p $Port -U $bootstrapRole -O ventio_owner -E UTF8 -T template0 $databaseName
  if ($LASTEXITCODE -ne 0) { throw 'HOST_DATABASE_CREATE_FAILED' }

  $encodedBootstrap = [Uri]::EscapeDataString($bootstrapSecret)
  $databaseUrl = "postgresql://${bootstrapRole}:${encodedBootstrap}@127.0.0.1:${Port}/${databaseName}?sslmode=disable"
  Invoke-MigrationRunner $databaseUrl
  [void](Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$bootstrapRole,'-d',$databaseName,'-v','ON_ERROR_STOP=1','-v',"expected_database=$databaseName",'-f',$bootstrapSql))

  $escapedRuntime = $runtimeSecret.Replace("'", "''")
  $escapedIdentity = $identitySecret.Replace("'", "''")
  $loginSql = @"
CREATE ROLE ventio_runtime_app LOGIN PASSWORD '$escapedRuntime' INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT ventio_runtime TO ventio_runtime_app;
CREATE ROLE ventio_identity_api_app LOGIN PASSWORD '$escapedIdentity' INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT ventio_identity_api TO ventio_identity_api_app;
CREATE ROLE ventio_migrator_app LOGIN PASSWORD '$($migrationSecret.Replace("'", "''"))' INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT ventio_migrator TO ventio_migrator_app;
"@
  [void](Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$bootstrapRole,'-d',$databaseName,'-v','ON_ERROR_STOP=1') $loginSql)

  $env:PGPASSWORD = $runtimeSecret
  $runtimeCheck = Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U','ventio_runtime_app','-d',$databaseName,'-Atc',"SELECT current_user || ':' || (SELECT rolsuper::text FROM pg_roles WHERE rolname=current_user) || ':' || pg_has_role(current_user,'ventio_runtime','MEMBER')::text")
  if ($runtimeCheck -ne 'ventio_runtime_app:false:true') { throw 'HOST_DATABASE_RUNTIME_PROFILE_INVALID' }
  $env:PGPASSWORD = $identitySecret
  $identityCheck = Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U','ventio_identity_api_app','-d',$databaseName,'-Atc',"SELECT current_user || ':' || (SELECT rolsuper::text FROM pg_roles WHERE rolname=current_user) || ':' || pg_has_role(current_user,'ventio_identity_api','MEMBER')::text")
  if ($identityCheck -ne 'ventio_identity_api_app:false:true') { throw 'HOST_DATABASE_IDENTITY_PROFILE_INVALID' }

  $env:PGPASSWORD = $migrationSecret
  $migrationCheck = Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U','ventio_migrator_app','-d',$databaseName,'-Atc',"SELECT current_user || ':' || rolsuper::text || ':' || rolcreatedb::text || ':' || rolcreaterole::text || ':' || rolreplication::text || ':' || rolbypassrls::text || ':' || pg_has_role(session_user,'ventio_migrator','MEMBER')::text || ':' || pg_has_role(session_user,'ventio_owner','MEMBER')::text FROM pg_roles WHERE rolname=current_user")
  if ($migrationCheck -ne 'ventio_migrator_app:false:false:false:false:false:true:true') { throw 'HOST_DATABASE_MIGRATION_PROFILE_INVALID' }

  $env:PGPASSWORD = $bootstrapSecret
  $migrationCount = Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$bootstrapRole,'-d',$databaseName,'-Atc','SELECT count(*) FROM public.ventio_schema_migrations')
  $expectedMigrationCount = @(Get-ChildItem -LiteralPath $migrations -File -Filter '*.sql').Count
  if ($expectedMigrationCount -lt 1 -or $migrationCount -ne [string]$expectedMigrationCount) {
    throw 'HOST_DATABASE_MIGRATION_LEDGER_INVALID'
  }
  $bootstrapProfile = Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$bootstrapRole,'-d','postgres','-Atc',"SELECT rolcanlogin::text || ':' || rolsuper::text FROM pg_roles WHERE rolname='$bootstrapRole'")
  if ($bootstrapProfile -ne 'true:true') { throw 'HOST_DATABASE_BOOTSTRAP_PROFILE_INVALID' }
  [void](Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$bootstrapRole,'-d','postgres','-v','ON_ERROR_STOP=1','-c','ALTER ROLE ventio_bootstrap NOLOGIN PASSWORD NULL'))
  $bootstrapLoginRejected = $false
  try {
    [void](Invoke-Psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$bootstrapRole,'-d','postgres','-Atc','SELECT 1'))
  }
  catch {
    if ($_.Exception.Message -ne 'HOST_DATABASE_SQL_FAILED') { throw 'HOST_DATABASE_BOOTSTRAP_RETIREMENT_VERIFY_FAILED' }
    $bootstrapLoginRejected = $true
  }
  if (-not $bootstrapLoginRejected) { throw 'HOST_DATABASE_BOOTSTRAP_LOGIN_STILL_ALLOWED' }
  Write-Output 'HOST_DATABASE_INITIALIZED'
  Write-Output 'HOST_BOOTSTRAP_LOGIN_RETIRED'
  Write-Output 'Migrations, security bootstrap, least-privilege runtime and identity API logins passed verification; temporary cluster bootstrap login is NOLOGIN with no password verifier.'
}
finally {
  if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
  $runtimeSecret = $null
  $identitySecret = $null
  $migrationSecret = $null
  $bootstrapSecret = $null
  $RuntimeCredential = $null
  $IdentityApiCredential = $null
  $BootstrapCredential = $null
}
