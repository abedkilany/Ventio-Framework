[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $PostgresRoot,
  [Parameter(Mandatory = $true)] [string] $DataDirectory,
  [Parameter(Mandatory = $true)] [PSCredential] $RuntimeCredential,
  [Parameter(Mandatory = $true)] [PSCredential] $IdentityApiCredential,
  [int] $Port = 54329
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$programData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
$programFiles = [IO.Path]::GetFullPath($env:ProgramFiles)
$postgresRoot = [IO.Path]::GetFullPath($PostgresRoot)
$dataDirectory = [IO.Path]::GetFullPath($DataDirectory)
$bin = Join-Path $postgresRoot 'bin'
$postgres = Join-Path $bin 'postgres.exe'
$pgCtl = Join-Path $bin 'pg_ctl.exe'
$pgIsReady = Join-Path $bin 'pg_isready.exe'
$psql = Join-Path $bin 'psql.exe'
$robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
$backupRoot = $null
$postgresService = $null
$postgresNeedsToRun = $false
$maintenanceProcess = $null
$runtimePassword = $null
$identityPassword = $null

function ConvertTo-HostRecoveryArgument([string] $Value) {
  $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $trailingSlashes = [regex]::Match($escaped, '\\+$').Length
  if ($trailingSlashes -gt 0) {
    $escaped = $escaped.Substring(0, $escaped.Length - $trailingSlashes) + ('\' * ($trailingSlashes * 2))
  }
  return '"' + $escaped + '"'
}

function Invoke-HostRecoveryProcess(
  [string] $Executable,
  [string[]] $Arguments,
  [string] $InputText,
  [hashtable] $Environment,
  [int] $TimeoutMilliseconds = 30000
) {
  $process = [Diagnostics.Process]::new()
  $started = $false
  try {
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $quoted = foreach ($argument in $Arguments) { ConvertTo-HostRecoveryArgument ([string]$argument) }
    $info.Arguments = [string]::Join(' ', [string[]]$quoted)
    if ($Environment) {
      foreach ($entry in $Environment.GetEnumerator()) {
        $info.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
      }
    }
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'HOST_DATABASE_RECOVERY_PROCESS_START_FAILED' }
    $started = $true
    if ($Environment) {
      foreach ($key in @($Environment.Keys)) { [void]$info.EnvironmentVariables.Remove([string]$key) }
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if ($null -ne $InputText) { $process.StandardInput.Write($InputText) }
    $process.StandardInput.Close()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
      try { $process.Kill() } catch { }
      throw 'HOST_DATABASE_RECOVERY_PROCESS_TIMEOUT'
    }
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      StandardOutput = $stdoutTask.GetAwaiter().GetResult()
      StandardError = $stderrTask.GetAwaiter().GetResult()
    }
  } finally {
    if ($started -and -not $process.HasExited) {
      try { $process.Kill(); $process.WaitForExit() } catch { }
    }
    $process.Dispose()
  }
}

function Get-HostCredentialPassword([PSCredential] $Credential, [string] $ExpectedUser) {
  if (-not $Credential -or $Credential.UserName -cne $ExpectedUser) { throw 'HOST_DATABASE_RECOVERY_CREDENTIAL_INVALID' }
  $password = $Credential.GetNetworkCredential().Password
  if ($password -notmatch '^[A-Za-z0-9_-]{48}$') { throw 'HOST_DATABASE_RECOVERY_CREDENTIAL_INVALID' }
  return $password
}

function Test-HostRecoveryBackupPathCollision([string] $PartialPath, [string] $BackupPath) {
  return (Test-Path -LiteralPath $PartialPath) -or (Test-Path -LiteralPath $BackupPath)
}

function Get-HostRecoveryRotationFailureClass(
  [int] $ExitCode,
  [string] $StandardOutput,
  [string] $StandardError
) {
  $output = [string]::Join("`n", @($StandardOutput, $StandardError))
  if ($output -match '(?i)role\s+"?ventio_runtime_app"?\s+does not exist') {
    return 'runtime_role_missing'
  }
  if ($output -match '(?i)role\s+"?ventio_identity_api_app"?\s+does not exist') {
    return 'identity_role_missing'
  }
  if ($output -match '(?i)(postmaster\.pid|lock file|already running)') {
    return 'postgres_already_running'
  }
  if ($output -match '(?i)(must be superuser|permission denied|not owner)') {
    return 'permission_denied'
  }
  if ($output -match '(?im)^\s*ERROR:') { return 'postgres_sql_error' }
  if ($ExitCode -ne 0) { return 'process_exit' }
  return 'process_output_error'
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
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'HOST_DATABASE_RECOVERY_REPARSE_POINT' }
      if ($item.PSIsContainer) {
        $directories.Push($item.FullName)
      } else {
        $fileCount++
        $bytes += [long]$item.Length
      }
    }
  }
  return [pscustomobject]@{ fileCount = $fileCount; bytes = $bytes }
}

function Assert-HostRecoveryNoReparseAncestors([string] $Path, [string] $Boundary) {
  $current = [IO.Path]::GetFullPath($Path)
  $boundaryPath = [IO.Path]::GetFullPath($Boundary).TrimEnd('\')
  while ($current.Equals($boundaryPath, [StringComparison]::OrdinalIgnoreCase) -or
      $current.StartsWith($boundaryPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'HOST_DATABASE_RECOVERY_REPARSE_POINT' }
    }
    if ($current.Equals($boundaryPath, [StringComparison]::OrdinalIgnoreCase)) { return }
    $parent = [IO.Directory]::GetParent($current)
    if ($null -eq $parent -or $parent.FullName -eq $current) { break }
    $current = $parent.FullName
  }
  throw 'HOST_DATABASE_RECOVERY_PATH_OUTSIDE_BOUNDARY'
}

function Set-HostRecoveryBackupAcl([string] $Path, [switch] $Directory) {
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

function Copy-HostRecoveryData([string] $Source, [string] $Destination) {
  [void][IO.Directory]::CreateDirectory($Destination)
  Set-HostRecoveryBackupAcl $Destination -Directory
  $process = [Diagnostics.Process]::new()
  $started = $false
  try {
    $info = [Diagnostics.ProcessStartInfo]::new($robocopy)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $arguments = @($Source, $Destination, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    $quoted = foreach ($argument in $arguments) { ConvertTo-HostRecoveryArgument ([string]$argument) }
    $info.Arguments = [string]::Join(' ', [string[]]$quoted)
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'HOST_DATABASE_RECOVERY_BACKUP_START_FAILED' }
    $started = $true
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(900000)) {
      try { $process.Kill() } catch { }
      throw 'HOST_DATABASE_RECOVERY_BACKUP_TIMEOUT'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -gt 7) { throw 'HOST_DATABASE_RECOVERY_BACKUP_COPY_FAILED' }
  } finally {
    if ($started -and -not $process.HasExited) {
      try { $process.Kill(); $process.WaitForExit() } catch { }
    }
    $process.Dispose()
  }
}

function Wait-HostRecoveryService([string] $Name, [string] $ExpectedState) {
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  while ($true) {
    $service = Get-Service -Name $Name -ErrorAction Stop
    if ($service.Status.ToString() -eq $ExpectedState) { return }
    if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_DATABASE_RECOVERY_SERVICE_TIMEOUT' }
    Start-Sleep -Milliseconds 500
  }
}

function Test-HostRecoveryReadiness([int] $ExpectedPort) {
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  while ($true) {
    $result = Invoke-HostRecoveryProcess $pgIsReady @('-h', '127.0.0.1', '-p', [string]$ExpectedPort, '-t', '2') $null $null 5000
    if ($result.ExitCode -eq 0) { return }
    if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_DATABASE_RECOVERY_POSTGRES_NOT_READY' }
    Start-Sleep -Milliseconds 500
  }
}

function Assert-HostRoleLogin([string] $RoleName, [string] $Password, [int] $ExpectedPort) {
  $environment = @{ PGPASSWORD = $Password; PGCONNECT_TIMEOUT = '5' }
  $result = Invoke-HostRecoveryProcess $psql @(
    '-X', '-w', '-h', '127.0.0.1', '-p', [string]$ExpectedPort, '-U', $RoleName,
    '-d', 'ventio_host', '-Atc', 'SELECT current_user'
  ) $null $environment 15000
  if ($result.ExitCode -ne 0 -or $result.StandardOutput.Trim() -cne $RoleName) {
    throw 'HOST_DATABASE_RECOVERY_ROLE_AUTHENTICATION_FAILED'
  }
}

function Start-HostCredentialMaintenance {
  $helper = Join-Path (Split-Path -Parent $postgresRoot) 'VentioHostService.exe'
  if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw 'HOST_DATABASE_RECOVERY_MAINTENANCE_HELPER_MISSING' }
  $process = [Diagnostics.Process]::new()
  $info = [Diagnostics.ProcessStartInfo]::new($helper, '--recover-postgres-credentials')
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardInput = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $process.StartInfo = $info
  try {
    if (-not $process.Start()) { throw 'HOST_DATABASE_RECOVERY_MAINTENANCE_START_FAILED' }
    $ready = $process.StandardOutput.ReadLineAsync()
    if (-not $ready.Wait(45000) -or $ready.GetAwaiter().GetResult() -cne 'HOST_POSTGRES_MAINTENANCE_READY') {
      throw 'HOST_DATABASE_RECOVERY_MAINTENANCE_NOT_READY'
    }
    return $process
  } catch {
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(10000) | Out-Null }
    $process.Dispose()
    throw
  }
}

function Invoke-HostSingleUserCredentialRotation {
  param([Diagnostics.Process] $Maintenance, [string] $RuntimeSecret, [string] $IdentitySecret)
  # Credentials travel only over inherited stdin and the authenticated local pipe.
  # The helper has retained the exact service token before Stop-Service; only its
  # non-administrator worker opens the stopped cluster. ACLs/HBA are unchanged.
  $request = @{ runtime = $RuntimeSecret; identity = $IdentitySecret } | ConvertTo-Json -Compress
  try {
    $Maintenance.StandardInput.WriteLine($request)
    $Maintenance.StandardInput.Close()
    $output = $Maintenance.StandardOutput.ReadToEndAsync()
    $errorOutput = $Maintenance.StandardError.ReadToEndAsync()
    if (-not $Maintenance.WaitForExit(60000)) { throw 'HOST_DATABASE_RECOVERY_MAINTENANCE_TIMEOUT' }
    if ($Maintenance.ExitCode -ne 0 -or $output.GetAwaiter().GetResult().Trim() -cne 'HOST_POSTGRES_MAINTENANCE_PASS') {
      $safeCode = $errorOutput.GetAwaiter().GetResult().Trim()
      if ($safeCode -match '^HOST_POSTGRES_MAINTENANCE_[A-Z0-9_]+$') { $global:VentioProvisioningFailureDetail = $safeCode }
      throw 'HOST_DATABASE_RECOVERY_ROLE_ROTATION_FAILED'
    }
  } finally { $request = $null }
}

function Invoke-HostRecoveryMigrationValidation(
  [int] $ExpectedPort,
  [PSCredential] $CredentialOverride = $null,
  [string] $MigrationDirectoryOverride = $null
) {
  $credential = $CredentialOverride
  $password = $null
  $ownsCredential = $false
  try {
    if ($null -eq $credential) {
      $modulePath = Join-Path $PSScriptRoot 'HostMigrationCredential.psm1'
      if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw 'HOST_DATABASE_RECOVERY_MIGRATION_MODULE_MISSING' }
      Import-Module $modulePath -Force
      $credential = Read-HostMigrationCredential -OutputDirectory (Join-Path $programData 'Ventio\Installer')
      $ownsCredential = $true
    }
    $password = $credential.GetNetworkCredential().Password
    if ($credential.UserName -cne 'ventio_migrator_app' -or $password -notmatch '^[A-Za-z0-9_-]{43}$') {
      throw 'HOST_DATABASE_RECOVERY_MIGRATION_CREDENTIAL_INVALID'
    }
    $profile = Invoke-HostRecoveryProcess $psql @(
      '-X', '-w', '-h', '127.0.0.1', '-p', [string]$ExpectedPort, '-U', 'ventio_migrator_app',
      '-d', 'ventio_host', '-Atc', "SELECT current_user || ':' || rolsuper::text || ':' || rolcreatedb::text || ':' || rolcreaterole::text || ':' || rolreplication::text || ':' || rolbypassrls::text || ':' || pg_has_role(session_user,'ventio_migrator','MEMBER')::text || ':' || pg_has_role(session_user,'ventio_owner','MEMBER')::text FROM pg_roles WHERE rolname=current_user"
    ) $null @{ PGPASSWORD = $password; PGCONNECT_TIMEOUT = '5' } 15000
    if ($profile.ExitCode -ne 0 -or $profile.StandardOutput.Trim() -cne 'ventio_migrator_app:false:false:false:false:false:true:true') {
      throw 'HOST_DATABASE_RECOVERY_MIGRATOR_PROFILE_INVALID'
    }
    $migrationDirectory = if ($MigrationDirectoryOverride) {
      [IO.Path]::GetFullPath($MigrationDirectoryOverride)
    } else {
      Join-Path (Split-Path -Parent $postgresRoot) 'migrations'
    }
    if (-not (Test-Path -LiteralPath $migrationDirectory -PathType Container)) {
      throw 'HOST_DATABASE_RECOVERY_MIGRATION_DIRECTORY_INVALID'
    }
    $expectedCount = @(Get-ChildItem -LiteralPath $migrationDirectory -Filter '*.sql' -File -Recurse).Count
    if ($expectedCount -lt 1) { throw 'HOST_DATABASE_RECOVERY_MIGRATION_DIRECTORY_EMPTY' }
    $migrationCount = Invoke-HostRecoveryProcess $psql @(
      '-X', '-w', '-h', '127.0.0.1', '-p', [string]$ExpectedPort, '-U', 'ventio_migrator_app',
      '-d', 'ventio_host', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c',
      'SET ROLE ventio_owner; SELECT count(*) FROM public.ventio_schema_migrations'
    ) $null @{ PGPASSWORD = $password; PGCONNECT_TIMEOUT = '5' } 15000
    if ($migrationCount.ExitCode -ne 0) {
      $failureClass = if ($migrationCount.StandardError -match '(?i)permission denied|must be member') {
        'permission_denied'
      } elseif ($migrationCount.StandardError -match '(?i)does not exist|undefined table') {
        'migration_table_missing'
      } elseif ($migrationCount.StandardError -match '(?i)password authentication failed') {
        'authentication_failed'
      } else {
        'query_failed'
      }
      $global:VentioProvisioningFailureDetail = 'migration_ledger_query_exit_code=' + $migrationCount.ExitCode + '; failure_class=' + $failureClass
      throw 'HOST_DATABASE_RECOVERY_MIGRATION_LEDGER_QUERY_FAILED'
    }
    $actualCount = $migrationCount.StandardOutput.Trim()
    if ($actualCount -notmatch '^[0-9]+$') {
      $global:VentioProvisioningFailureDetail = 'migration_ledger_result_format_invalid'
      throw 'HOST_DATABASE_RECOVERY_MIGRATION_LEDGER_RESULT_INVALID'
    }
    if ($actualCount -cne [string]$expectedCount) {
      $global:VentioProvisioningFailureDetail = "expected_migration_count=$expectedCount actual_migration_count=$actualCount"
      throw 'HOST_DATABASE_RECOVERY_MIGRATION_LEDGER_COUNT_MISMATCH'
    }
  } finally {
    $password = $null
    if ($ownsCredential -and $credential -and $credential.Password) { $credential.Password.Dispose() }
    $credential = $null
  }
}

foreach ($file in @($postgres, $pgCtl, $pgIsReady, $psql)) {
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'HOST_DATABASE_RECOVERY_PAYLOAD_INCOMPLETE' }
}
if ($Port -lt 1 -or $Port -gt 65535) { throw 'HOST_DATABASE_RECOVERY_PORT_INVALID' }
$version = (& $postgres --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $version -ne 'postgres (PostgreSQL) 16.16') { throw 'HOST_DATABASE_RECOVERY_VERSION_INVALID' }
$runtimePassword = Get-HostCredentialPassword $RuntimeCredential 'ventio_runtime_app'
$identityPassword = Get-HostCredentialPassword $IdentityApiCredential 'ventio_identity_api_app'


$expectedPostgres = [IO.Path]::GetFullPath((Join-Path $programFiles 'Ventio\host-payload\postgresql'))
$expectedData = [IO.Path]::GetFullPath((Join-Path $programData 'Ventio\PostgreSQL\data'))
if (-not $postgresRoot.Equals($expectedPostgres, [StringComparison]::OrdinalIgnoreCase) -or
    -not $dataDirectory.Equals($expectedData, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'HOST_DATABASE_RECOVERY_PRODUCT_PATH_INVALID'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'HOST_DATABASE_RECOVERY_ADMIN_ELEVATION_REQUIRED'
}
$service = Get-CimInstance -ClassName Win32_Service -Filter "Name='VentioPostgres'" -ErrorAction SilentlyContinue
if ($null -eq $service -or $service.StartName -cne 'NT SERVICE\VentioPostgres' -or
    $service.PathName -notmatch [regex]::Escape((Join-Path $postgresRoot 'bin\pg_ctl.exe')) -or
    $service.PathName -notmatch [regex]::Escape($dataDirectory)) {
  throw 'HOST_DATABASE_RECOVERY_SERVICE_IDENTITY_INVALID'
}
if (Get-Service -Name 'VentioHost' -ErrorAction SilentlyContinue) { throw 'HOST_DATABASE_RECOVERY_HOST_SERVICE_ALREADY_EXISTS' }
$postgresService = Get-Service -Name 'VentioPostgres' -ErrorAction Stop
$postgresNeedsToRun = $true
Assert-HostRecoveryNoReparseAncestors $dataDirectory $programData

if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -PathType Leaf) -or
    (Get-Content -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -Raw).Trim() -ne '16') {
  throw 'HOST_DATABASE_RECOVERY_CLUSTER_VERSION_INVALID'
}

try {
  if ($postgresService.Status -eq 'Stopped') {
    Start-Service -Name 'VentioPostgres' -ErrorAction Stop
    Wait-HostRecoveryService 'VentioPostgres' 'Running'
  } elseif ($postgresService.Status -ne 'Running') {
    throw 'HOST_DATABASE_RECOVERY_SERVICE_STATE_INVALID'
  }
  Test-HostRecoveryReadiness $Port
  Invoke-HostRecoveryMigrationValidation $Port

  $maintenanceProcess = Start-HostCredentialMaintenance
  Stop-Service -Name 'VentioPostgres' -Force -ErrorAction Stop
  Wait-HostRecoveryService 'VentioPostgres' 'Stopped'
  $inventory = Get-HostDataInventory $dataDirectory
  $backupDirectory = Join-Path $programData 'Ventio\Backups'
  Assert-HostRecoveryNoReparseAncestors $backupDirectory $programData
  [void][IO.Directory]::CreateDirectory($backupDirectory)
  $backupDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($backupDirectory))
  if ($backupDrive.AvailableFreeSpace -lt ($inventory.bytes + 67108864)) { throw 'HOST_DATABASE_RECOVERY_BACKUP_SPACE_INSUFFICIENT' }
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture)
  $backupName = 'ventio-postgresql-before-host-recovery-' + $stamp + '-' + [guid]::NewGuid().ToString('N')
  $partialRoot = Join-Path $backupDirectory ($backupName + '.partial')
  $backupRoot = Join-Path $backupDirectory $backupName
  if (Test-HostRecoveryBackupPathCollision $partialRoot $backupRoot) { throw 'HOST_DATABASE_RECOVERY_BACKUP_PATH_EXISTS' }
  [void][IO.Directory]::CreateDirectory($partialRoot)
  Set-HostRecoveryBackupAcl $partialRoot -Directory
  $partialData = Join-Path $partialRoot 'data'
  Copy-HostRecoveryData $dataDirectory $partialData
  $backupInventory = Get-HostDataInventory $partialData
  if ($backupInventory.fileCount -ne $inventory.fileCount -or $backupInventory.bytes -ne $inventory.bytes) {
    throw 'HOST_DATABASE_RECOVERY_BACKUP_VERIFICATION_FAILED'
  }
  $manifest = [ordered]@{
    formatVersion = 1
    createdAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    postgresVersion = '16.16'
    dataDirectory = 'data'
    fileCount = $backupInventory.fileCount
    bytes = $backupInventory.bytes
  }
  $manifestPath = Join-Path $partialRoot 'backup-manifest.json'
  [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
  Set-HostRecoveryBackupAcl $manifestPath
  [IO.Directory]::Move($partialRoot, $backupRoot)

  Invoke-HostSingleUserCredentialRotation $maintenanceProcess $runtimePassword $identityPassword
  Start-Service -Name 'VentioPostgres' -ErrorAction Stop
  Wait-HostRecoveryService 'VentioPostgres' 'Running'
  Test-HostRecoveryReadiness $Port
  Assert-HostRoleLogin 'ventio_runtime_app' $runtimePassword $Port
  Assert-HostRoleLogin 'ventio_identity_api_app' $identityPassword $Port
  Write-Output 'HOST_DATABASE_CREDENTIAL_RECOVERY_PASS'
  Write-Output "Verified PostgreSQL backup: $backupRoot"
} finally {
  if ($null -ne $maintenanceProcess) {
    try {
      if (-not $maintenanceProcess.HasExited) {
        $maintenanceProcess.StandardInput.Close()
        if (-not $maintenanceProcess.WaitForExit(15000)) { $maintenanceProcess.Kill(); $maintenanceProcess.WaitForExit(10000) | Out-Null }
      }
    } finally { $maintenanceProcess.Dispose() }
  }
  if ($postgresNeedsToRun) {
    $currentService = Get-Service -Name 'VentioPostgres' -ErrorAction SilentlyContinue
    if ($currentService -and $currentService.Status -ne 'Running') {
      Start-Service -Name 'VentioPostgres' -ErrorAction Stop
      Wait-HostRecoveryService 'VentioPostgres' 'Running'
    }
  }
  $runtimePassword = $null
  $identityPassword = $null
}
