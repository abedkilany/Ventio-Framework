param(
  [string] $PostgresRoot = (Join-Path $env:ProgramFiles 'Ventio\host-payload\postgresql'),
  [int] $Port = 54329,
  [switch] $Apply,
  [switch] $TestMode,
  [string] $TestDataDirectory
)

$ErrorActionPreference = 'Stop'
$payloadRoot = [IO.Path]::GetFullPath((Split-Path -Parent ([IO.Path]::GetFullPath($PostgresRoot))))
$pgRoot = [IO.Path]::GetFullPath($PostgresRoot)
$programData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
$dataDirectory = if ($TestMode) { [IO.Path]::GetFullPath($TestDataDirectory) } else { [IO.Path]::GetFullPath((Join-Path $programData 'Ventio\PostgreSQL\data')) }
$databaseServiceName = 'VentioPostgres'
$hostServiceName = 'VentioHost'
$migrationRole = 'ventio_migrator_app'
$databaseName = 'ventio_host'
$script:hostPostgresStoppedForBackup = $false
$bin = Join-Path $pgRoot 'bin'
$psql = Join-Path $bin 'psql.exe'
$pgCtl = Join-Path $bin 'pg_ctl.exe'
$robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
$migrationExe = Join-Path $payloadRoot 'ventio_migrate.exe'
$migrations = Join-Path $payloadRoot 'migrations'
$pairingContract = Join-Path $payloadRoot 'security\pairing.sql'
$credentialReissueContract = Join-Path $payloadRoot 'security\credential_reissues.sql'
$schemaProfileContract = Join-Path $payloadRoot 'security\schema_profile.sql'
$credentialModule = Join-Path $payloadRoot 'setup\HostMigrationCredential.psm1'
if ($TestMode -and -not (Test-Path -LiteralPath $credentialModule -PathType Leaf)) {
  $credentialModule = Join-Path $PSScriptRoot 'HostMigrationCredential.psm1'
}

function ConvertTo-WindowsCommandLineArgument([string] $Value) {
  $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $trailingSlashes = [regex]::Match($escaped, '\\+$').Length
  if ($trailingSlashes -gt 0) {
    $escaped = $escaped.Substring(0, $escaped.Length - $trailingSlashes) + ('\' * ($trailingSlashes * 2))
  }
  return '"' + $escaped + '"'
}

function Invoke-HostDatabaseTool([string] $Executable, [string[]] $Arguments, [hashtable] $Environment, [int] $TimeoutMs, [string] $FailureCode, [switch] $TestMode) {
  $process = [Diagnostics.Process]::new()
  $started = $false
  $stdout = $null
  $stderr = $null
  try {
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($Arguments.Count -gt 0) {
      $quoted = foreach ($argument in $Arguments) { ConvertTo-WindowsCommandLineArgument $argument }
      $info.Arguments = [string]::Join(' ', [string[]]$quoted)
    } else {
      $info.Arguments = ''
    }
    foreach ($entry in $Environment.GetEnumerator()) {
      $info.EnvironmentVariables[$entry.Key] = [string]$entry.Value
    }
    $process.StartInfo = $info
    if (-not $process.Start()) { throw $FailureCode }
    $started = $true
    foreach ($key in $Environment.Keys) { $info.EnvironmentVariables.Remove([string]$key) }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMs)) {
      try { $process.Kill() } catch { }
      throw $FailureCode
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
      if ($TestMode -and ($stderr -or $stdout)) {
        $safeError = ([string]$stderr + "`n" + [string]$stdout)
        foreach ($secret in $Environment.Values) {
          if ($secret) { $safeError = $safeError.Replace([string]$secret, '[redacted]') }
        }
        $lines = @($safeError -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 4)
        if ($lines.Count -gt 0) { [Console]::Error.WriteLine('HOST_DATABASE_TEST_TOOL_ERROR=' + ($lines -join ' | ')) }
      }
      throw $FailureCode
    }
    return $stdout.Trim()
  } catch {
    if ($TestMode) {
      $safeMessage = $_.Exception.Message
      foreach ($secret in $Environment.Values) {
        if ($secret) { $safeMessage = $safeMessage.Replace([string]$secret, '[redacted]') }
      }
      if ($safeMessage) { [Console]::Error.WriteLine('HOST_DATABASE_TEST_TOOL_EXCEPTION=' + $safeMessage) }
    }
    if ($_.FullyQualifiedErrorId -match '^HOST_[A-Z0-9_]+') { throw }
    throw $FailureCode
  } finally {
    if ($started -and -not $process.HasExited) {
      try { $process.Kill(); $process.WaitForExit() } catch { }
    }
    $process.Dispose()
    $stdout = $null
    $stderr = $null
  }
}

function Set-HostBackupAcl([string] $Path, [switch] $Directory) {
  $security = if ($Directory) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
  $security.SetAccessRuleProtection($true, $false)
  $adminSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
  $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
  $security.SetOwner($adminSid)
  foreach ($sid in @($adminSid, $systemSid)) {
    $inheritance = if ($Directory) {
      [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else { [Security.AccessControl.InheritanceFlags]::None }
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      $sid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
      [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
  }
  Set-Acl -LiteralPath $Path -AclObject $security
}

function Assert-HostBackupPath([string] $Path) {
  if ($TestMode) {
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ventio-pg-initdb-test-'
    if (-not $Path.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'HOST_DATABASE_TEST_BACKUP_PATH_INVALID' }
  } else {
    $expectedPrefix = Join-Path $programData 'Ventio\Backups'
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith([IO.Path]::GetFullPath($expectedPrefix).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
      throw 'HOST_DATABASE_BACKUP_PATH_INVALID'
    }
  }
}

function Get-HostDataInventory([string] $Path) {
  $directories = [Collections.Generic.Stack[string]]::new()
  $directories.Push([IO.Path]::GetFullPath($Path))
  $fileCount = 0
  [long]$bytes = 0
  while ($directories.Count -gt 0) {
    $current = $directories.Pop()
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current)) {
      $item = Get-Item -LiteralPath $entry -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'HOST_DATABASE_BACKUP_REPARSE_POINT' }
      if ($item.PSIsContainer) {
        $directories.Push($item.FullName)
      } else {
        $fileCount++
        $bytes += [long]$item.Length
      }
    }
  }
  return [pscustomobject]@{
    fileCount = $fileCount
    bytes = $bytes
  }
}

function Stop-HostPostgresForBackup {
  if ($TestMode) {
    & $pgCtl -D $dataDirectory -m fast -w stop
    if ($LASTEXITCODE -ne 0) { throw 'HOST_DATABASE_BACKUP_POSTGRES_STOP_FAILED' }
  } else {
    Stop-Service -Name $databaseServiceName -Force -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while ((Get-Service -Name $databaseServiceName).Status -ne 'Stopped') {
      if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_DATABASE_BACKUP_POSTGRES_STOP_TIMEOUT' }
      Start-Sleep -Milliseconds 500
    }
  }
  $script:hostPostgresStoppedForBackup = $true
}

function Start-HostPostgresAfterBackup {
  if (-not $script:hostPostgresStoppedForBackup) { return }
  if ($TestMode) {
    $testLog = Join-Path (Split-Path -Parent $dataDirectory) 'postgres-upgrade-test.log'
    & $pgCtl -D $dataDirectory -l $testLog -o "-h 127.0.0.1 -p $Port -c listen_addresses=127.0.0.1" -w start
    if ($LASTEXITCODE -ne 0) { throw 'HOST_DATABASE_UPGRADE_POSTGRES_RESTART_FAILED' }
  } else {
    Start-Service -Name $databaseServiceName -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while ((Get-Service -Name $databaseServiceName).Status -ne 'Running') {
      if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_DATABASE_UPGRADE_POSTGRES_RESTART_TIMEOUT' }
      Start-Sleep -Milliseconds 500
    }
  }
  $script:hostPostgresStoppedForBackup = $false
}

function Copy-HostPostgresData([string] $Source, [string] $Destination) {
  [void][IO.Directory]::CreateDirectory($Destination)
  if (-not $TestMode) { Set-HostBackupAcl $Destination -Directory }
  $process = [Diagnostics.Process]::new()
  $started = $false
  try {
    $info = [Diagnostics.ProcessStartInfo]::new($robocopy)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $arguments = @($Source, $Destination, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:2', '/XJ', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    $quoted = foreach ($argument in $arguments) { ConvertTo-WindowsCommandLineArgument $argument }
    $info.Arguments = [string]::Join(' ', [string[]]$quoted)
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'HOST_DATABASE_BACKUP_COPY_FAILED' }
    $started = $true
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(1800000)) {
      try { $process.Kill() } catch { }
      throw 'HOST_DATABASE_BACKUP_COPY_TIMEOUT'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ge 8) { throw 'HOST_DATABASE_BACKUP_COPY_FAILED' }
  } finally {
    if ($started -and -not $process.HasExited) { try { $process.Kill(); $process.WaitForExit() } catch { } }
    $process.Dispose()
    $stdout = $null
    $stderr = $null
  }
}

if ($Port -lt 1 -or $Port -gt 65535) { throw 'HOST_DATABASE_PORT_INVALID' }
foreach ($file in @($psql, $pgCtl, $migrationExe, $migrations, $pairingContract,
    $credentialReissueContract, $schemaProfileContract, $credentialModule)) {
  if (-not (Test-Path -LiteralPath $file)) { throw 'HOST_DATABASE_UPGRADE_PAYLOAD_INCOMPLETE' }
}
if (-not $TestMode -and -not (Test-Path -LiteralPath $robocopy -PathType Leaf)) { throw 'HOST_DATABASE_BACKUP_TOOL_MISSING' }
if ($TestMode) {
  $testPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ventio-pg-initdb-test-'
  if (-not $dataDirectory.StartsWith($testPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'HOST_DATABASE_TEST_PATH_INVALID' }
} else {
  $expectedData = [IO.Path]::GetFullPath((Join-Path $programData 'Ventio\PostgreSQL\data'))
  if (-not $dataDirectory.Equals($expectedData, [StringComparison]::OrdinalIgnoreCase) -or
      -not $pgRoot.StartsWith([IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio')).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HOST_DATABASE_UPGRADE_PATH_INVALID'
  }
}

if (-not $Apply) {
  Write-Output 'HOST_DATABASE_UPGRADE_PLAN_VALID'
  Write-Output 'Plan only; Host must be stopped, PostgreSQL must use the Ventio service identity, a protected migrator credential must exist, and a restricted backup will be created before migrations.'
  return
}
if (-not $TestMode) {
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'HOST_DATABASE_UPGRADE_ADMIN_ELEVATION_REQUIRED' }
  $databaseService = Get-CimInstance -ClassName Win32_Service -Filter "Name='$databaseServiceName'" -ErrorAction SilentlyContinue
  $hostService = Get-CimInstance -ClassName Win32_Service -Filter "Name='$hostServiceName'" -ErrorAction SilentlyContinue
  if ($null -eq $databaseService -or $databaseService.StartName -cne 'NT SERVICE\VentioPostgres' -or
      $databaseService.State -ne 'Running' -or $databaseService.PathName -notmatch [regex]::Escape((Join-Path $pgRoot 'bin\pg_ctl.exe')) -or
      $databaseService.PathName -notmatch [regex]::Escape($dataDirectory)) { throw 'HOST_DATABASE_UPGRADE_POSTGRES_SERVICE_INVALID' }
  if ($null -eq $hostService -or $hostService.StartName -cne 'NT SERVICE\VentioHost' -or
      $hostService.State -ne 'Stopped' -or $hostService.PathName -notmatch [regex]::Escape((Join-Path $payloadRoot 'VentioHostService.exe'))) {
    throw 'HOST_DATABASE_UPGRADE_HOST_SERVICE_MUST_BE_STOPPED'
  }
} elseif (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -PathType Leaf)) {
  throw 'HOST_DATABASE_TEST_CLUSTER_MISSING'
}

$backupDirectory = if ($TestMode) { Join-Path (Split-Path -Parent $dataDirectory) 'ventio-backups' } else { Join-Path $programData 'Ventio\Backups' }
if (-not $TestMode) {
  $programDataRoot = $programData.TrimEnd('\')
  $cursor = [IO.Path]::GetFullPath($backupDirectory)
  while ($cursor.StartsWith($programDataRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    if (Test-Path -LiteralPath $cursor) {
      $item = Get-Item -LiteralPath $cursor -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'HOST_DATABASE_BACKUP_REPARSE_POINT' }
    }
    if ($cursor -eq $programDataRoot) { break }
    $parent = [IO.Directory]::GetParent($cursor)
    if ($null -eq $parent -or $parent.FullName -eq $cursor) { break }
    $cursor = $parent.FullName
  }
}
[void][IO.Directory]::CreateDirectory($backupDirectory)
if (-not $TestMode) { Set-HostBackupAcl $backupDirectory -Directory }
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture)
$backupName = "ventio-postgresql-before-upgrade-$stamp-$([guid]::NewGuid().ToString('N'))"
$partialBackupRoot = Join-Path $backupDirectory ($backupName + '.partial')
$backupRoot = Join-Path $backupDirectory $backupName
$partialBackupData = Join-Path $partialBackupRoot 'data'
Assert-HostBackupPath $partialBackupRoot
Import-Module $credentialModule -Force
$credential = Read-HostMigrationCredential -TestMode:$TestMode -OutputDirectory $(if ($TestMode) { Join-Path (Split-Path -Parent $dataDirectory) 'protected-migration-credential' } else { Join-Path $programData 'Ventio\Installer' })
$password = $credential.GetNetworkCredential().Password
$envVars = @{ PGPASSWORD = $password }
$migrationEnvironment = @{}
$databaseUrl = $null
try {
  $version = (& (Join-Path $bin 'postgres.exe') --version 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $version -ne 'postgres (PostgreSQL) 16.15') { throw 'HOST_DATABASE_UPGRADE_VERSION_UNSUPPORTED' }
  $pgVersionFile = Join-Path $dataDirectory 'PG_VERSION'
  if ((Get-Content -LiteralPath $pgVersionFile -Raw).Trim() -ne '16') { throw 'HOST_DATABASE_UPGRADE_CLUSTER_VERSION_INVALID' }
  $initialInventory = Get-HostDataInventory $dataDirectory
  $backupDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($backupDirectory))
  if ($backupDrive.AvailableFreeSpace -lt ($initialInventory.bytes + 67108864)) { throw 'HOST_DATABASE_BACKUP_DISK_SPACE_INSUFFICIENT' }
  [void][IO.Directory]::CreateDirectory($partialBackupRoot)
  if (-not $TestMode) { Set-HostBackupAcl $partialBackupRoot -Directory }
  Stop-HostPostgresForBackup
  $stableInventory = Get-HostDataInventory $dataDirectory
  if ($backupDrive.AvailableFreeSpace -lt ($stableInventory.bytes + 67108864)) { throw 'HOST_DATABASE_BACKUP_DISK_SPACE_INSUFFICIENT' }
  Copy-HostPostgresData $dataDirectory $partialBackupData
  $backupInventory = Get-HostDataInventory $partialBackupData
  if ($backupInventory.fileCount -ne $stableInventory.fileCount -or $backupInventory.bytes -ne $stableInventory.bytes) {
    throw 'HOST_DATABASE_BACKUP_VERIFICATION_FAILED'
  }
  if (-not $TestMode) { Set-HostBackupAcl $partialBackupData -Directory }
  $manifest = [ordered]@{
    formatVersion = 1
    createdAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    postgresVersion = '16.15'
    dataDirectory = 'data'
    fileCount = $backupInventory.fileCount
    bytes = $backupInventory.bytes
  }
  $manifestPath = Join-Path $partialBackupRoot 'backup-manifest.json'
  [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
  if (-not $TestMode) { Set-HostBackupAcl $manifestPath }
  [IO.Directory]::Move($partialBackupRoot, $backupRoot)
  Start-HostPostgresAfterBackup
  $profile = Invoke-HostDatabaseTool $psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$migrationRole,'-d',$databaseName,'-Atc',"SELECT pg_has_role(session_user,'ventio_migrator','MEMBER')::text || ':' || rolsuper::text || ':' || rolcreatedb::text || ':' || rolcreaterole::text FROM pg_roles WHERE rolname=current_user") $envVars 30000 'HOST_DATABASE_MIGRATOR_AUTHENTICATION_FAILED' -TestMode:$TestMode
  if ($profile -ne 'true:false:false:false') { throw 'HOST_DATABASE_MIGRATOR_PROFILE_INVALID' }
  $migrationFiles = @(Get-ChildItem -LiteralPath $migrations -Filter '*.sql' -File -Recurse)
  if ($migrationFiles.Count -lt 1) { throw 'HOST_DATABASE_MIGRATION_FILES_MISSING' }
  $databaseUrl = 'postgresql://' + [Uri]::EscapeDataString($credential.UserName) + ':' + [Uri]::EscapeDataString($password) + "@127.0.0.1:${Port}/${databaseName}?sslmode=disable"
  $migrationEnvironment = @{
    VENTIO_DATABASE_URL = $databaseUrl
    VENTIO_MIGRATION_ROLE = 'ventio_owner'
    VENTIO_MIGRATIONS_DIR = $migrations
  }
  $migrationOutput = Invoke-HostDatabaseTool $migrationExe @() $migrationEnvironment 300000 'HOST_DATABASE_MIGRATION_FAILED' -TestMode:$TestMode
  if ($migrationOutput -notmatch 'Applied \d+ migration\(s\):') { throw 'HOST_DATABASE_MIGRATION_RESULT_INVALID' }
  [void](Invoke-HostDatabaseTool $psql @(
    '-X', '-w', '-h', '127.0.0.1', '-p', [string]$Port, '-U', $migrationRole,
    '-d', $databaseName, '-v', 'ON_ERROR_STOP=1', '-c', 'SET ROLE ventio_owner',
    '-f', $pairingContract
  ) $envVars 60000 'HOST_PAIRING_CONTRACT_UPDATE_FAILED' -TestMode:$TestMode)
  [void](Invoke-HostDatabaseTool $psql @(
    '-X', '-w', '-h', '127.0.0.1', '-p', [string]$Port, '-U', $migrationRole,
    '-d', $databaseName, '-v', 'ON_ERROR_STOP=1', '-c', 'SET ROLE ventio_owner',
    '-f', $credentialReissueContract
  ) $envVars 60000 'HOST_CREDENTIAL_REISSUE_CONTRACT_UPDATE_FAILED' -TestMode:$TestMode)
  [void](Invoke-HostDatabaseTool $psql @(
    '-X', '-w', '-h', '127.0.0.1', '-p', [string]$Port, '-U', $migrationRole,
    '-d', $databaseName, '-v', 'ON_ERROR_STOP=1', '-c', 'SET ROLE ventio_owner',
    '-f', $schemaProfileContract
  ) $envVars 60000 'HOST_SCHEMA_PROFILE_UPDATE_FAILED' -TestMode:$TestMode)
  $pairingContractReady = Invoke-HostDatabaseTool $psql @(
    '-X', '-w', '-h', '127.0.0.1', '-p', [string]$Port, '-U', $migrationRole,
    '-d', $databaseName, '-Atc', "SET ROLE ventio_owner; SELECT position('Pairing request was already accepted' IN pg_get_functiondef('ventio_security.scoped_pairing_create(text,text,text,text,text,text)'::regprocedure)) > 0 AND position('TRUSTED_PAIRING_CREATED' IN pg_get_functiondef('ventio_security.trusted_windows_pairing_create(text,text,text,text,text,text,text,text,text[],text)'::regprocedure)) > 0 AND position('CREDENTIAL_CEILING_DENIED' IN pg_get_functiondef('ventio_security.permission_denial_reason(text,text,text,text,text)'::regprocedure)) > 0 AND has_function_privilege('ventio_identity_api','ventio_security.trusted_windows_pairing_create(text,text,text,text,text,text,text,text,text[],text)','EXECUTE') AND NOT has_function_privilege('ventio_runtime','ventio_security.trusted_windows_pairing_create(text,text,text,text,text,text,text,text,text[],text)','EXECUTE') AND has_function_privilege('ventio_identity_api','ventio_security.permission_denial_reason(text,text,text,text,text)','EXECUTE') AND NOT has_function_privilege('ventio_runtime','ventio_security.permission_denial_reason(text,text,text,text,text)','EXECUTE')"
  ) $envVars 30000 'HOST_PAIRING_CONTRACT_VERIFICATION_FAILED' -TestMode:$TestMode
  $pairingContractMatch = [regex]::Match($pairingContractReady.Trim(), '(?:^|\s)(t|f)$')
  if (-not $pairingContractMatch.Success -or $pairingContractMatch.Groups[1].Value -cne 't') {
    throw 'HOST_PAIRING_CONTRACT_VERIFICATION_FAILED'
  }
  $credentialReissueVerificationSql = @'
SET ROLE ventio_owner;
SELECT ventio_security.assert_schema();
SELECT jsonb_build_array(
  has_function_privilege('ventio_identity_api','ventio_security.trusted_windows_credential_reissue_prepare(text,text,text,text,text,text,text,text,text,text,text,bytea,text[],text[],text)','EXECUTE'),
  NOT has_function_privilege('ventio_runtime','ventio_security.trusted_windows_credential_reissue_prepare(text,text,text,text,text,text,text,text,text,text,text,bytea,text[],text[],text)','EXECUTE'),
  has_function_privilege('ventio_identity_api','ventio_security.credential_reissue_claim(text,text)','EXECUTE'),
  has_function_privilege('ventio_identity_api','ventio_security.credential_reissue_pending_claim(text)','EXECUTE'),
  has_function_privilege('ventio_identity_api','ventio_security.credential_reissue_finalize(text,text)','EXECUTE'),
  has_function_privilege('ventio_identity_api','ventio_security.assert_schema()','EXECUTE'),
  (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid='public.ventio_identity_credential_reissues'::regclass),
  (SELECT count(*)=2 FROM pg_trigger WHERE tgrelid='public.ventio_identity_credential_reissues'::regclass AND NOT tgisinternal AND tgname IN ('ventio_recovery_lock','ventio_recovery_mark')))::text
'@
  $credentialReissueContractReady = Invoke-HostDatabaseTool $psql @(
    '-X', '-w', '-h', '127.0.0.1', '-p', [string]$Port, '-U', $migrationRole,
    '-d', $databaseName, '-Atc', $credentialReissueVerificationSql
  ) $envVars 30000 'HOST_CREDENTIAL_REISSUE_CONTRACT_VERIFICATION_FAILED' -TestMode:$TestMode
  $credentialReissueFlags = @($credentialReissueContractReady -split "`r?`n" |
    Where-Object { $_.Trim() } | Select-Object -Last 1)
  if ($credentialReissueFlags.Count -ne 1 -or
      $credentialReissueFlags[0].Trim() -cne '[true, true, true, true, true, true, true, true]') {
    if ($credentialReissueFlags.Count -eq 1) {
      Write-Output ('HOST_CREDENTIAL_REISSUE_CONTRACT_FLAGS=' + $credentialReissueFlags[0].Trim())
    }
    throw 'HOST_CREDENTIAL_REISSUE_CONTRACT_VERIFICATION_FAILED'
  }
  $ledger = Invoke-HostDatabaseTool $psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$migrationRole,'-d',$databaseName,'-Atc','SET ROLE ventio_owner; SELECT count(*) FROM public.ventio_schema_migrations') $envVars 30000 'HOST_DATABASE_MIGRATION_LEDGER_INVALID' -TestMode:$TestMode
  $ledgerCounts = @($ledger -split "`r?`n" | Where-Object { $_ -match '^\d+$' })
  if ($ledgerCounts.Count -ne 1 -or [int]$ledgerCounts[0] -ne $migrationFiles.Count) {
    throw 'HOST_DATABASE_MIGRATION_LEDGER_INVALID'
  }
  Write-Output 'HOST_DATABASE_UPGRADE_PASS'
  Write-Output ("Verified restricted PostgreSQL data backup: " + $backupRoot)
} finally {
  try {
    Start-HostPostgresAfterBackup
  } finally {
    $password = $null
    $databaseUrl = $null
    $credential = $null
    $envVars.Clear()
    $migrationEnvironment.Clear()
  }
}
