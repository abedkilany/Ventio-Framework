param(
  [string] $PostgresRoot = (Join-Path $PSScriptRoot '..\..\packages\ventio_host_api\build\windows\host-payload\postgresql'),
  [int] $Port = 54329,
  [PSCredential] $BootstrapCredential,
  [switch] $Apply,
  [switch] $TestInitDbOnly,
  [switch] $TestMigrations
)

$ErrorActionPreference = 'Stop'
$serviceName = 'VentioPostgres'
$serviceAccount = 'NT SERVICE\VentioPostgres'
$commonData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
$ventioRoot = [IO.Path]::GetFullPath((Join-Path $commonData 'Ventio\PostgreSQL'))
$dataDirectory = Join-Path $ventioRoot 'data'
$pgRoot = [IO.Path]::GetFullPath($PostgresRoot)
$bin = Join-Path $pgRoot 'bin'
$pgCtl = Join-Path $bin 'pg_ctl.exe'
$initdb = Join-Path $bin 'initdb.exe'
$postgres = Join-Path $bin 'postgres.exe'
$pgIsReady = Join-Path $bin 'pg_isready.exe'
$sc = Join-Path $env:SystemRoot 'System32\sc.exe'

function Test-EmptyDirectory([string] $Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  return -not [bool](Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)
}

function Assert-NoReparseAncestors([string] $Path, [string] $Boundary) {
  $current = [IO.Path]::GetFullPath($Path)
  $boundaryPath = [IO.Path]::GetFullPath($Boundary).TrimEnd('\')
  while ($current.Equals($boundaryPath, [StringComparison]::OrdinalIgnoreCase) -or
    $current.StartsWith($boundaryPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'POSTGRES_INSTALL_PATH_REPARSE_POINT'
      }
    }
    if ($current.Equals($boundaryPath, [StringComparison]::OrdinalIgnoreCase)) { return }
    $parent = [IO.Directory]::GetParent($current)
    if ($null -eq $parent -or $parent.FullName -eq $current) { break }
    $current = $parent.FullName
  }
  throw 'POSTGRES_INSTALL_PATH_OUTSIDE_BOUNDARY'
}

function Set-PostgresDataAcl(
  [string] $Path,
  [string[]] $ServiceSids,
  [string] $OwnerSid = 'S-1-5-32-544'
) {
  $security = [Security.AccessControl.DirectorySecurity]::new()
  $security.SetAccessRuleProtection($true, $false)
  $owner = [Security.Principal.SecurityIdentifier]::new($OwnerSid)
  $security.SetOwner($owner)
  foreach ($sid in @('S-1-5-32-544', 'S-1-5-18') + $ServiceSids) {
    $sidObject = [Security.Principal.SecurityIdentifier]::new($sid)
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      $sidObject,
      [Security.AccessControl.FileSystemRights]::FullControl,
      [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit,
      [Security.AccessControl.PropagationFlags]::None,
      [Security.AccessControl.AccessControlType]::Allow))
  }
  Set-Acl -LiteralPath $Path -AclObject $security
}

function New-RandomBase64Secret([int] $ByteCount) {
  $bytes = [byte[]]::new($ByteCount)
  $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $generator.GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
  }
  finally {
    [Array]::Clear($bytes, 0, $bytes.Length)
    $generator.Dispose()
  }
}

function ConvertTo-WindowsCommandLineArgument([string] $Value) {
  $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $trailingSlashes = [regex]::Match($escaped, '\\+$').Length
  if ($trailingSlashes -gt 0) {
    $escaped = $escaped.Substring(0, $escaped.Length - $trailingSlashes) + ('\' * ($trailingSlashes * 2))
  }
  return '"' + $escaped + '"'
}

function Initialize-PostgresCluster([string] $Executable, [string] $DataDirectory, [Security.SecureString] $Secret) {
  $pipeName = 'ventio-pg-bootstrap-' + [guid]::NewGuid().ToString('N')
  $pipePath = "\\.\pipe\$pipeName"
  $pipe = [IO.Pipes.NamedPipeServerStream]::new(
    $pipeName, [IO.Pipes.PipeDirection]::Out, 1,
    [IO.Pipes.PipeTransmissionMode]::Byte,
    [IO.Pipes.PipeOptions]::Asynchronous -bor [IO.Pipes.PipeOptions]::CurrentUserOnly)
  $processInfo = [Diagnostics.ProcessStartInfo]::new($Executable)
  $processInfo.UseShellExecute = $false
  $processInfo.CreateNoWindow = $true
  $processInfo.RedirectStandardOutput = $true
  $processInfo.RedirectStandardError = $true
  $arguments = [System.Collections.Generic.List[string]]::new()
  foreach ($argument in @('-D', $DataDirectory, '-U', 'ventio_bootstrap', '-W',
    '--auth-local=scram-sha-256', '--auth-host=scram-sha-256', '--encoding=UTF8', '--no-locale')) {
    if ($argument -eq '-W') { $argument = "--pwfile=$pipePath" }
    $arguments.Add((ConvertTo-WindowsCommandLineArgument $argument))
  }
  $processInfo.Arguments = [string]::Join(' ', $arguments)

  $pointer = [IntPtr]::Zero
  $characters = $null
  $passwordBytes = $null
  $process = [Diagnostics.Process]::new()
  $processStarted = $false
  try {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Secret)
    $characters = [char[]]::new($Secret.Length)
    [Runtime.InteropServices.Marshal]::Copy($pointer, $characters, 0, $characters.Length)
    $invalidCharacter = $false
    foreach ($character in $characters) {
      if ([int]$character -gt 127 -or [char]::IsControl($character)) { $invalidCharacter = $true; break }
    }
    if ($characters.Length -lt 24 -or $invalidCharacter) {
      throw 'POSTGRES_BOOTSTRAP_CREDENTIAL_INVALID'
    }
    $passwordBytes = [Text.Encoding]::ASCII.GetBytes($characters)
    $process.StartInfo = $processInfo
    if (-not $process.Start()) { throw 'POSTGRES_INITIALIZER_UNAVAILABLE' }
    $processStarted = $true
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $connectTask = $pipe.WaitForConnectionAsync()
    if (-not $connectTask.Wait(30000)) { throw 'POSTGRES_PASSWORD_PIPE_TIMEOUT' }
    $pipe.Write($passwordBytes, 0, $passwordBytes.Length)
    $pipe.WriteByte(10)
    $pipe.Flush()
    $pipe.Dispose()
    if (-not $process.WaitForExit(90000)) { throw 'POSTGRES_INITIALIZER_TIMEOUT' }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
      $global:VentioProvisioningFailureDetail = [string]$stderr
      throw 'POSTGRES_CLUSTER_INITIALIZATION_FAILED'
    }
  }
  finally {
    if ($passwordBytes) { [Array]::Clear($passwordBytes, 0, $passwordBytes.Length) }
    if ($characters) { [Array]::Clear($characters, 0, $characters.Length) }
    if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer) }
    if ($processStarted -and -not $process.HasExited) {
      try { $process.Kill(); $process.WaitForExit() } catch { }
    }
    $pipe.Dispose()
    if ($process) { $process.Dispose() }
    $stdout = $null
    $stderr = $null
  }
}

if ($Port -lt 1 -or $Port -gt 65535) { throw 'POSTGRES_PORT_INVALID' }
foreach ($name in @('postgres.exe', 'initdb.exe', 'pg_ctl.exe', 'pg_isready.exe')) {
  if (-not (Test-Path -LiteralPath (Join-Path $bin $name) -PathType Leaf)) {
    throw "POSTGRES_PAYLOAD_MISSING_$($name.Replace('.exe','').ToUpperInvariant())"
  }
}
$version = (& $postgres --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $version -ne 'postgres (PostgreSQL) 16.15') {
  throw 'POSTGRES_VERSION_UNSUPPORTED'
}
if ($TestInitDbOnly) {
  if ($Apply) { throw 'POSTGRES_TEST_MODE_CANNOT_APPLY' }
  if ($TestMigrations) {
    $payloadRoot = Split-Path -Parent $pgRoot
    $migrationExecutable = Join-Path $payloadRoot 'ventio_migrate.exe'
    $migrationFiles = Join-Path $payloadRoot 'migrations'
    $bootstrapFile = Join-Path $payloadRoot 'security\bootstrap.sql'
    foreach ($file in @($migrationExecutable, $migrationFiles, $bootstrapFile)) {
      if (-not (Test-Path -LiteralPath $file)) { throw 'POSTGRES_TEST_HOST_MIGRATION_PAYLOAD_MISSING' }
    }
  }
  $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ventio-pg-initdb-test-' + [guid]::NewGuid().ToString('N'))
  $testData = Join-Path $testRoot 'data'
  $testLog = Join-Path $testRoot 'postgres.log'
  $testListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $testListener.Start()
  $testPort = ([Net.IPEndPoint]$testListener.LocalEndpoint).Port
  $testListener.Stop()
  $testPassword = New-RandomBase64Secret 36
  $testSecret = ConvertTo-SecureString $testPassword -AsPlainText -Force
  $testStarted = $false
  $oldPassword = $env:PGPASSWORD
  $oldDatabaseUrl = $env:VENTIO_DATABASE_URL
  $oldMigrationDirectory = $env:VENTIO_MIGRATIONS_DIR
  $oldMigrationRole = $env:VENTIO_MIGRATION_ROLE
  try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    [void][IO.Directory]::CreateDirectory($testData)
    $testUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Set-PostgresDataAcl $testData @($testUserSid) $testUserSid
    Initialize-PostgresCluster $initdb $testData $testSecret
    & $pgCtl -D $testData -l $testLog -o "-h 127.0.0.1 -p $testPort -c listen_addresses=127.0.0.1" -w start
    if ($LASTEXITCODE -ne 0) { throw 'POSTGRES_TEST_SERVER_START_FAILED' }
    $testStarted = $true
    $testReady = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
      & $pgIsReady -h 127.0.0.1 -p $testPort -t 1 | Out-Null
      if ($LASTEXITCODE -eq 0) { $testReady = $true; break }
      Start-Sleep -Milliseconds 250
    }
    if (-not $testReady) { throw 'POSTGRES_TEST_READINESS_FAILED' }
    $env:PGPASSWORD = $testPassword
    $result = & (Join-Path $bin 'psql.exe') -h 127.0.0.1 -p $testPort -U ventio_bootstrap -d postgres `
      -v ON_ERROR_STOP=1 -Atc "select current_user || ':' || current_setting('server_version')"
    if ($LASTEXITCODE -ne 0 -or $result -ne 'ventio_bootstrap:16.15') { throw 'POSTGRES_TEST_AUTHENTICATED_QUERY_FAILED' }
    if ($TestMigrations) {
      $databaseInitializer = Join-Path $PSScriptRoot 'initialize-host-database.ps1'
      if (-not (Test-Path -LiteralPath $databaseInitializer)) { throw 'POSTGRES_TEST_DATABASE_INITIALIZER_MISSING' }
      $runtimePassword = New-RandomBase64Secret 36
      $identityPassword = New-RandomBase64Secret 36
      $migrationPassword = New-RandomBase64Secret 32
      $bootstrapCredential = [PSCredential]::new('ventio_bootstrap', $testSecret)
      $runtimeCredential = [PSCredential]::new('ventio_runtime_app', (ConvertTo-SecureString $runtimePassword -AsPlainText -Force))
      $identityCredential = [PSCredential]::new('ventio_identity_api_app', (ConvertTo-SecureString $identityPassword -AsPlainText -Force))
      $migrationCredential = [PSCredential]::new('ventio_migrator_app', (ConvertTo-SecureString $migrationPassword -AsPlainText -Force))
      try {
        $databaseInitOutput = @(& $databaseInitializer -PostgresRoot $pgRoot -DataDirectory $testData -Port $testPort `
          -BootstrapCredential $bootstrapCredential -RuntimeCredential $runtimeCredential `
          -IdentityApiCredential $identityCredential -MigrationCredential $migrationCredential -Apply -TestMode 2>&1)
        $databaseInitSucceeded = $?
      } catch {
        $databaseInitOutput = @($_.ToString())
        $databaseInitSucceeded = $false
        Write-Output ('POSTGRES_TEST_DATABASE_INIT_EXCEPTION=' + $_.Exception.GetType().Name)
        if ($_.FullyQualifiedErrorId -match '^[A-Z0-9_]+$') {
          Write-Output ('POSTGRES_TEST_DATABASE_INIT_ERROR_ID=' + $_.FullyQualifiedErrorId)
        }
      }
      if (-not $databaseInitSucceeded -or $databaseInitOutput -notcontains 'HOST_DATABASE_INITIALIZED' -or
          $databaseInitOutput -notcontains 'HOST_BOOTSTRAP_LOGIN_RETIRED') {
        $safeStageSignals = @([regex]::Matches(($databaseInitOutput | ForEach-Object { [string]$_ }) -join "`n",
          '\b(?:HOST|VENTIO)_[A-Z0-9_]+\b') | ForEach-Object { $_.Value } | Select-Object -Unique)
        if ($safeStageSignals.Count -gt 0) {
          Write-Output ('POSTGRES_TEST_DATABASE_INIT_SIGNALS=' + ($safeStageSignals -join ','))
        }
        throw 'POSTGRES_TEST_HOST_DATABASE_INITIALIZATION_FAILED'
      }
      $env:VENTIO_DATABASE_URL = "postgresql://ventio_migrator_app:${migrationPassword}@127.0.0.1:${testPort}/ventio_host?sslmode=disable"
      $env:VENTIO_MIGRATIONS_DIR = $migrationFiles
      $env:VENTIO_MIGRATION_ROLE = 'ventio_owner'
      $migrationProcess = [Diagnostics.Process]::new()
      $migrationProcess.StartInfo = [Diagnostics.ProcessStartInfo]::new($migrationExecutable)
      $migrationProcess.StartInfo.UseShellExecute = $false
      $migrationProcess.StartInfo.CreateNoWindow = $true
      $migrationProcess.StartInfo.RedirectStandardOutput = $true
      $migrationProcess.StartInfo.RedirectStandardError = $true
      $migrationProcess.StartInfo.EnvironmentVariables['VENTIO_DATABASE_URL'] = $env:VENTIO_DATABASE_URL
      $migrationProcess.StartInfo.EnvironmentVariables['VENTIO_MIGRATIONS_DIR'] = $migrationFiles
      $migrationProcess.StartInfo.EnvironmentVariables['VENTIO_MIGRATION_ROLE'] = 'ventio_owner'
      $migrationProcess.StartInfo.EnvironmentVariables['PGPASSWORD'] = $migrationPassword
      if (-not $migrationProcess.Start()) { throw 'POSTGRES_TEST_MIGRATOR_PROCESS_START_FAILED' }
      $migrationStdoutTask = $migrationProcess.StandardOutput.ReadToEndAsync()
      $migrationStderrTask = $migrationProcess.StandardError.ReadToEndAsync()
      $migrationProcess.WaitForExit()
      $migrationRunText = $migrationStdoutTask.GetAwaiter().GetResult()
      $migrationErrorText = $migrationStderrTask.GetAwaiter().GetResult().Replace($migrationPassword, '[redacted]')
      $migrationExitCode = $migrationProcess.ExitCode
      $migrationProcess.Dispose()
      if ($migrationExitCode -ne 0 -or $migrationRunText -notmatch 'Applied 0 migration\(s\)') {
        if ($migrationErrorText) {
          $safeErrors = @($migrationErrorText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 6)
          if ($safeErrors.Count -gt 0) { Write-Output ('POSTGRES_TEST_MIGRATOR_ERROR=' + ($safeErrors -join ' | ')) }
        }
        throw 'POSTGRES_TEST_MIGRATOR_UPGRADE_FAILED'
      }
      Write-Output 'POSTGRES_MIGRATOR_UPGRADE_TEST_PASS'
      $migrationCredentialModule = Join-Path $PSScriptRoot 'HostMigrationCredential.psm1'
      if (-not (Test-Path -LiteralPath $migrationCredentialModule -PathType Leaf)) {
        throw 'POSTGRES_TEST_MIGRATION_CREDENTIAL_MODULE_MISSING'
      }
      Import-Module $migrationCredentialModule -Force
      $migrationCredentialDirectory = Join-Path $testRoot 'protected-migration-credential'
      Write-HostMigrationCredential -Credential $migrationCredential -OutputDirectory $migrationCredentialDirectory -TestMode
      $restoredMigrationCredential = Read-HostMigrationCredential -OutputDirectory $migrationCredentialDirectory -TestMode
      if ($restoredMigrationCredential.UserName -cne 'ventio_migrator_app' -or
          $restoredMigrationCredential.GetNetworkCredential().Password -cne $migrationPassword) {
        throw 'POSTGRES_TEST_MIGRATION_CREDENTIAL_ROUNDTRIP_FAILED'
      }
      $databaseUpgrade = Join-Path $PSScriptRoot 'upgrade-host-database.ps1'
      if (-not (Test-Path -LiteralPath $databaseUpgrade -PathType Leaf)) { throw 'POSTGRES_TEST_DATABASE_UPGRADE_SCRIPT_MISSING' }
      & $databaseUpgrade -PostgresRoot $pgRoot -Port $testPort -Apply -TestMode -TestDataDirectory $testData
      if (-not $?) {
        throw 'POSTGRES_TEST_DATABASE_UPGRADE_FAILED'
      }
      $testBackupRoot = Join-Path $testRoot 'ventio-backups'
      $testBackups = @(Get-ChildItem -LiteralPath $testBackupRoot -Directory -Filter 'ventio-postgresql-before-upgrade-*' -ErrorAction SilentlyContinue)
      if ($testBackups.Count -ne 1 -or
          -not (Test-Path -LiteralPath (Join-Path $testBackups[0].FullName 'backup-manifest.json') -PathType Leaf) -or
          -not (Test-Path -LiteralPath (Join-Path (Join-Path $testBackups[0].FullName 'data') 'PG_VERSION') -PathType Leaf)) {
        throw 'POSTGRES_TEST_DATABASE_BACKUP_VERIFICATION_FAILED'
      }
      $protectedMigrationCredential = Join-Path $migrationCredentialDirectory 'migration-credential.dpapi'
      $migrationBytes = [IO.File]::ReadAllBytes($protectedMigrationCredential)
      try {
        if ([Text.Encoding]::UTF8.GetString($migrationBytes).Contains($migrationPassword)) {
          throw 'POSTGRES_TEST_MIGRATION_CREDENTIAL_PLAINTEXT_SECRET'
        }
      }
      finally { [Array]::Clear($migrationBytes, 0, $migrationBytes.Length) }
      $configWriter = Join-Path $PSScriptRoot 'write-host-service-config.ps1'
      if (-not (Test-Path -LiteralPath $configWriter)) { throw 'POSTGRES_TEST_CONFIG_WRITER_MISSING' }
      $serviceTests = Join-Path $PSScriptRoot '..\..\installer\windows\host-service.tests\HostService.Tests.csproj'
      $testServiceSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
      $testConfigDirectory = Join-Path $testRoot 'protected-host-config'
      & $configWriter -RuntimeCredential $runtimeCredential -IdentityApiCredential $identityCredential `
        -DatabasePort $testPort -OutputDirectory $testConfigDirectory -TestMode -TestServiceSid $testServiceSid
      if (-not $?) { throw 'POSTGRES_TEST_CONFIG_WRITE_FAILED' }
      $protectedConfig = Join-Path $testConfigDirectory 'service-config.dpapi'
      if (-not (Test-Path -LiteralPath $protectedConfig -PathType Leaf)) { throw 'POSTGRES_TEST_CONFIG_MISSING' }
      & dotnet run --project $serviceTests -c Release --no-restore -- --validate-file $protectedConfig
      if ($LASTEXITCODE -ne 0) { throw 'POSTGRES_TEST_CONFIG_VALIDATION_FAILED' }
      $configBytes = [IO.File]::ReadAllBytes($protectedConfig)
      try {
        $configText = [Text.Encoding]::UTF8.GetString($configBytes)
        if ($configText.Contains($runtimePassword) -or $configText.Contains($identityPassword) -or
            $configText.Contains($migrationPassword)) {
          throw 'POSTGRES_TEST_CONFIG_PLAINTEXT_SECRET'
        }
      }
      finally { [Array]::Clear($configBytes, 0, $configBytes.Length) }
      $runtimeCredential = $null
      $identityCredential = $null
      $migrationCredential = $null
      $restoredMigrationCredential = $null
      $bootstrapCredential = $null
      $runtimePassword = $null
      $identityPassword = $null
      $migrationPassword = $null
      Write-Output 'POSTGRES_MIGRATION_LEAST_PRIVILEGE_BOOTSTRAP_TEST_PASS'
    } else {
      Write-Output 'POSTGRES_INITDB_SECRET_PIPE_TEST_PASS'
    }
  }
  finally {
    if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
    if ($null -eq $oldDatabaseUrl) { Remove-Item Env:VENTIO_DATABASE_URL -ErrorAction SilentlyContinue } else { $env:VENTIO_DATABASE_URL = $oldDatabaseUrl }
    if ($null -eq $oldMigrationDirectory) { Remove-Item Env:VENTIO_MIGRATIONS_DIR -ErrorAction SilentlyContinue } else { $env:VENTIO_MIGRATIONS_DIR = $oldMigrationDirectory }
    if ($null -eq $oldMigrationRole) { Remove-Item Env:VENTIO_MIGRATION_ROLE -ErrorAction SilentlyContinue } else { $env:VENTIO_MIGRATION_ROLE = $oldMigrationRole }
    $testSecret.Dispose()
    $testPassword = $null
    if ($testStarted) { & $pgCtl -D $testData -m fast -w stop *> $null }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ventio-pg-initdb-test-'
    if ($resolvedTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot) -match '^ventio-pg-initdb-test-[0-9a-f]{32}$' -and
        (Test-Path -LiteralPath $resolvedTestRoot)) {
      Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
  }
  return
}
if ($Apply -and -not $pgRoot.StartsWith((Join-Path $env:ProgramFiles 'Ventio\'), [StringComparison]::OrdinalIgnoreCase)) {
  throw 'POSTGRES_PAYLOAD_PATH_NOT_INSTALLER_OWNED'
}
Assert-NoReparseAncestors $ventioRoot $commonData
if ($Apply) { Assert-NoReparseAncestors $pgRoot (Join-Path $env:ProgramFiles 'Ventio') }
foreach ($path in @($pgRoot, $bin, $postgres)) {
  $item = Get-Item -LiteralPath $path -Force
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'POSTGRES_PAYLOAD_REPARSE_POINT'
  }
}

$existing = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
if ($existing) {
  $expectedDataArg = [regex]::Escape($dataDirectory)
  if ($existing.PathName -match [regex]::Escape($pgCtl) -and $existing.PathName -match $expectedDataArg) {
    Write-Output 'POSTGRES_SERVICE_ALREADY_PRESENT'
    return
  }
  throw 'POSTGRES_SERVICE_NAME_CONFLICT'
}
if (Test-Path -LiteralPath $dataDirectory) {
  if (-not (Test-EmptyDirectory $dataDirectory)) { throw 'POSTGRES_DATA_DIRECTORY_NOT_EMPTY' }
}
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
try { $listener.Start() } catch { throw 'POSTGRES_PORT_IN_USE' } finally { $listener.Stop() }

if (-not $Apply) {
  Write-Output 'POSTGRES_SERVICE_PLAN_VALID'
  Write-Output "Pinned version: 16.15; service: $serviceName; account: $serviceAccount; start: automatic; listener: 127.0.0.1:$Port."
  Write-Output "Data directory: $dataDirectory. Existing PostgreSQL services and non-empty data directories are never changed."
  Write-Output 'Plan only; no files, services, accounts, firewall rules, or registry values were changed.'
  return
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'POSTGRES_ADMIN_ELEVATION_REQUIRED'
}
if (-not $BootstrapCredential -or $BootstrapCredential.UserName -ne 'ventio_bootstrap' -or
    $BootstrapCredential.Password.Length -lt 24) {
  throw 'POSTGRES_BOOTSTRAP_CREDENTIAL_INVALID'
}
if (Test-Path -LiteralPath $dataDirectory -PathType Container) {
  if (-not (Test-EmptyDirectory $dataDirectory)) { throw 'POSTGRES_DATA_DIRECTORY_NOT_EMPTY' }
} elseif (Test-Path -LiteralPath $dataDirectory) {
  throw 'POSTGRES_DATA_DIRECTORY_INVALID'
}

$createdDirectory = $false
$serviceRegistered = $false
$secretPointer = [IntPtr]::Zero
$password = $null
try {
  Import-Module (Join-Path $PSScriptRoot 'HostProductDataRoot.psm1') -Force
  Protect-HostProductDataRoot
  [void][IO.Directory]::CreateDirectory($ventioRoot)
  Set-PostgresDataAcl $ventioRoot @()
  if (-not (Test-Path -LiteralPath $dataDirectory)) {
    [void][IO.Directory]::CreateDirectory($dataDirectory)
    $createdDirectory = $true
  }
  Set-PostgresDataAcl $dataDirectory @()

  & $pgCtl register -D $dataDirectory -N $serviceName -U $serviceAccount -S auto
  if ($LASTEXITCODE -ne 0) { throw 'POSTGRES_SERVICE_REGISTRATION_FAILED' }
  $serviceRegistered = $true
  & $sc sidtype $serviceName unrestricted | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'POSTGRES_SERVICE_SID_CONFIGURATION_FAILED' }
  $serviceSid = ([Security.Principal.NTAccount]::new('NT SERVICE', $serviceName)).Translate(
    [Security.Principal.SecurityIdentifier]).Value
  Protect-HostProductDataRoot
  Set-PostgresDataAcl $ventioRoot @($serviceSid)
  $installerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  Set-PostgresDataAcl $dataDirectory @($serviceSid, $installerSid)
  try {
    Initialize-PostgresCluster $initdb $dataDirectory $BootstrapCredential.Password
  }
  finally {
    Set-PostgresDataAcl $dataDirectory @($serviceSid)
  }

  $configPath = Join-Path $dataDirectory 'postgresql.conf'
  [IO.File]::AppendAllText($configPath, "`n# Ventio-managed local-only settings`nlisten_addresses = '127.0.0.1'`nport = $Port`npassword_encryption = 'scram-sha-256'`n# One bounded Recovery Authority schema-upgrade transaction at a time.`nmax_prepared_transactions = 1`n", [Text.UTF8Encoding]::new($false))

  & $sc failure $serviceName reset= 86400 actions= restart/5000/restart/30000/restart/60000 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'POSTGRES_SERVICE_RECOVERY_CONFIGURATION_FAILED' }
  & $sc failureflag $serviceName 1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'POSTGRES_SERVICE_RECOVERY_CONFIGURATION_FAILED' }
  & $sc start $serviceName | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'POSTGRES_SERVICE_START_FAILED' }

  $ready = $false
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    & $pgIsReady -h 127.0.0.1 -p $Port -U ventio_bootstrap -d postgres -t 1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $ready) { throw 'POSTGRES_READINESS_FAILED' }
  Write-Output 'POSTGRES_SERVICE_PROVISIONED'
  Write-Output "PostgreSQL 16.15 is ready on 127.0.0.1:$Port; service recovery is configured."
  Write-Output 'POSTGRES_DATA_PRESERVED_FOR_REPAIR'
  Write-Output 'Host database migrations, application role provisioning, and Host service startup are separate next steps.'
}
catch {
  if ($serviceRegistered) {
    & $sc stop $serviceName *> $null
    & $sc delete $serviceName *> $null
  }
  if ($createdDirectory) { [Console]::Error.WriteLine('POSTGRES_DATA_PRESERVED_FOR_REPAIR') }
  throw
}
finally {
  $BootstrapCredential = $null
  # Keep an initialized cluster for repair/resume; never delete data during rollback.
}
