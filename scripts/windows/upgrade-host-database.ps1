param(
  [string] $PostgresRoot = (Join-Path $env:ProgramFiles 'Ventio\host-payload\postgresql'),
  [int] $Port = 54329,
  [switch] $Apply,
  [switch] $TestMode,
  [string] $TestDataDirectory,
  [switch] $TestBackupOnly,
  [ValidateSet('RobocopyExit8', 'InventoryMismatch', 'PostCopyAclRewrite', 'AclVerification')]
  [string] $TestBackupFailureAt,
  [string] $FailureCodePath
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
$script:hostBackupStage = 'INITIALIZATION'
$script:hostBackupFailureDetails = @()
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
$serviceRecoveryPolicyModule = Join-Path $payloadRoot 'setup\HostServiceRecoveryPolicy.psm1'
$hostServiceExe = Join-Path $payloadRoot 'VentioHostService.exe'
$trustedHostUpgradeExe = Join-Path $payloadRoot 'ventio_trusted_host_upgrade.exe'
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

function Get-HostBackupAllowedSids {
  $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
  if ($TestMode) {
    $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    return @($ownerSid, $systemSid)
  }
  return @(
    [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),
    $systemSid
  )
}

function Set-HostBackupAcl([string] $Path, [switch] $Directory, [string] $FailureCode = 'HOST_DATABASE_BACKUP_ACL_SET_FAILED') {
  try {
    $security = if ($Directory) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    $security.SetAccessRuleProtection($true, $false)
    $allowedSids = @(Get-HostBackupAllowedSids)
    $security.SetOwner($allowedSids[0])
    foreach ($sid in $allowedSids) {
      $inheritance = if ($Directory) {
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
      } else { [Security.AccessControl.InheritanceFlags]::None }
      $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
        [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $security -ErrorAction Stop
  } catch {
    if ($TestMode) { [Console]::Error.WriteLine('HOST_DATABASE_TEST_ACL_SET_HRESULT=' + $_.Exception.HResult.ToString('X8')) }
    throw $FailureCode
  }
}

function Assert-HostBackupAcl([string] $Path, [string] $FailureCode = 'HOST_DATABASE_BACKUP_ACL_VERIFICATION_FAILED') {
  try {
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if (-not $acl.AreAccessRulesProtected) { throw 'ACL_INHERITANCE_NOT_PROTECTED' }
    $allowed = @{}
    foreach ($sid in @(Get-HostBackupAllowedSids)) { $allowed[$sid.Value] = $true }
    $rules = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne $allowed.Count) { throw 'ACL_RULE_COUNT_INVALID' }
    foreach ($rule in $rules) {
      if (-not $allowed.ContainsKey($rule.IdentityReference.Value) -or
          $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
          $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl) {
        throw 'ACL_RULE_INVALID'
      }
    }
    $expectedOwner = (Get-HostBackupAllowedSids)[0].Value
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $expectedOwner) {
      throw 'ACL_OWNER_INVALID'
    }
  } catch {
    throw $FailureCode
  }
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

function Set-HostBackupStage([string] $Stage, [string] $FallbackCode = 'HOST_DATABASE_UPGRADE_FAILED') {
  $stageChanged = $script:hostBackupStage -cne $Stage
  $script:hostBackupStage = $Stage
  $script:hostBackupFallbackCode = $FallbackCode
  if ($stageChanged) { [Console]::Out.WriteLine('HOST_DATABASE_BACKUP_STAGE=' + $Stage) }
}

function Write-HostUpgradeFailureCode([string] $Code, [string] $Stage, [string] $Details = '') {
  if ($Code -notmatch '^HOST_[A-Z0-9_]{1,120}$') { $Code = 'HOST_DATABASE_UPGRADE_FAILED' }
  if ($FailureCodePath) {
    try {
      $full = [IO.Path]::GetFullPath($FailureCodePath)
      $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
      if ($full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $lines = @($Code, ('STAGE=' + [regex]::Replace($Stage, '[^A-Za-z0-9_]', '_')))
        if ($Details -match '^[A-Za-z0-9_=;,.-]{1,512}$') { $lines += $Details }
        [IO.File]::WriteAllLines($full, $lines, [Text.UTF8Encoding]::new($false))
      }
    } catch { }
  }
  [Console]::Error.WriteLine('HOST_DATABASE_UPGRADE_SAFE_FAILURE=' + $Code)
}

function Complete-HostPostgresBackup(
  [string] $SourceData,
  [pscustomobject] $StableInventory,
  [string] $PartialBackupRoot,
  [string] $BackupRoot,
  [string] $BackupName
) {
  $partialData = Join-Path $PartialBackupRoot 'data'
  Set-HostBackupStage 'BACKUP_ROBOCOPY' 'HOST_DATABASE_BACKUP_ROBOCOPY_FAILED'
  $robocopyExit = Copy-HostPostgresData $SourceData $partialData
  if ($TestMode -and $TestBackupFailureAt -eq 'RobocopyExit8') { $robocopyExit = 8 }
  [Console]::Out.WriteLine('HOST_DATABASE_BACKUP_ROBOCOPY_EXIT=' + $robocopyExit)
  if ($robocopyExit -ge 8) { throw ('HOST_DATABASE_BACKUP_ROBOCOPY_EXIT_' + $robocopyExit) }

  Set-HostBackupStage 'BACKUP_DESTINATION_INVENTORY' 'HOST_DATABASE_BACKUP_DESTINATION_INVENTORY_FAILED'
  $backupInventory = Get-HostDataInventory $partialData
  if ($TestMode -and $TestBackupFailureAt -eq 'InventoryMismatch') {
    $backupInventory = [pscustomobject]@{ fileCount = $backupInventory.fileCount + 1; bytes = $backupInventory.bytes }
  }
  if ($backupInventory.fileCount -ne $StableInventory.fileCount -or
      $backupInventory.bytes -ne $StableInventory.bytes) {
    $script:hostBackupFailureDetails = @(
      ('sourceFiles=' + $StableInventory.fileCount),
      ('sourceBytes=' + $StableInventory.bytes),
      ('backupFiles=' + $backupInventory.fileCount),
      ('backupBytes=' + $backupInventory.bytes)
    )
    throw 'HOST_DATABASE_BACKUP_INVENTORY_MISMATCH'
  }

  if ($TestMode -and $TestBackupFailureAt -eq 'PostCopyAclRewrite') {
    Set-HostBackupStage 'BACKUP_POSTCOPY_ACL_REWRITE' 'HOST_DATABASE_BACKUP_ACL_POSTCOPY_REWRITE_FAILED'
    try {
      Set-HostBackupAcl $partialData -Directory -FailureCode 'HOST_DATABASE_BACKUP_ACL_POSTCOPY_REWRITE_FAILED'
      $script:hostBackupFailureDetails = @('postcopyAclRewrite=completed')
    } catch {
      $script:hostBackupFailureDetails = @('postcopyAclRewrite=failed')
      throw
    }
  }
  Set-HostBackupStage 'BACKUP_ACL_VERIFICATION' 'HOST_DATABASE_BACKUP_ACL_VERIFICATION_FAILED'
  if ($TestMode -and $TestBackupFailureAt -eq 'AclVerification') {
    throw 'HOST_DATABASE_BACKUP_ACL_VERIFICATION_FAILED'
  }
  Assert-HostBackupAcl $partialData 'HOST_DATABASE_BACKUP_ACL_VERIFICATION_FAILED'

  Set-HostBackupStage 'BACKUP_MANIFEST_WRITE' 'HOST_DATABASE_BACKUP_MANIFEST_WRITE_FAILED'
  $manifest = [ordered]@{
    formatVersion = 1
    createdAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    postgresVersion = '16.15'
    dataDirectory = 'data'
    fileCount = $backupInventory.fileCount
    bytes = $backupInventory.bytes
  }
  $manifestPath = Join-Path $PartialBackupRoot 'backup-manifest.json'
  try {
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    Set-HostBackupAcl $manifestPath -FailureCode 'HOST_DATABASE_BACKUP_ACL_MANIFEST_FAILED'
    Assert-HostBackupAcl $manifestPath 'HOST_DATABASE_BACKUP_ACL_MANIFEST_VERIFICATION_FAILED'
  } catch {
    if ($_.Exception.Message -match '^HOST_[A-Z0-9_]{1,120}$') { throw }
    throw 'HOST_DATABASE_BACKUP_MANIFEST_WRITE_FAILED'
  }

  Set-HostBackupStage 'BACKUP_FINALIZE' 'HOST_DATABASE_BACKUP_FINALIZE_FAILED'
  try { [IO.Directory]::Move($PartialBackupRoot, $BackupRoot) }
  catch { throw 'HOST_DATABASE_BACKUP_FINALIZE_FAILED' }
  return $BackupRoot
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
    Set-HostBackupStage 'DATABASE_POSTGRES_RESTART_START' 'HOST_DATABASE_UPGRADE_POSTGRES_RESTART_FAILED'
    $testLog = Join-Path (Split-Path -Parent $dataDirectory) 'postgres-upgrade-test.log'
    & $pgCtl -D $dataDirectory -l $testLog -o "-h 127.0.0.1 -p $Port -c listen_addresses=127.0.0.1 -c max_prepared_transactions=1" -w start
    if ($LASTEXITCODE -ne 0) { throw 'HOST_DATABASE_UPGRADE_POSTGRES_RESTART_FAILED' }
  } else {
    Set-HostBackupStage 'DATABASE_POSTGRES_RESTART_START' 'HOST_DATABASE_UPGRADE_POSTGRES_RESTART_FAILED'
    Start-Service -Name $databaseServiceName -ErrorAction Stop
    Set-HostBackupStage 'DATABASE_POSTGRES_RESTART_WAIT' 'HOST_DATABASE_UPGRADE_POSTGRES_RESTART_TIMEOUT'
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while ((Get-Service -Name $databaseServiceName).Status -ne 'Running') {
      if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_DATABASE_UPGRADE_POSTGRES_RESTART_TIMEOUT' }
      Start-Sleep -Milliseconds 500
    }
  }
  $script:hostPostgresStoppedForBackup = $false
}

function Copy-HostPostgresData([string] $Source, [string] $Destination) {
  try { [void][IO.Directory]::CreateDirectory($Destination) }
  catch { throw 'HOST_DATABASE_BACKUP_DESTINATION_CREATE_FAILED' }
  # Apply and verify the restricted DACL while the destination is empty. Robocopy's
  # DAT flags deliberately exclude source security; descendants inherit this ACL.
  # Rewriting the populated directory ACL can fail while Windows propagates it.
  Set-HostBackupAcl $Destination -Directory -FailureCode 'HOST_DATABASE_BACKUP_ACL_DATA_ROOT_FAILED'
  Assert-HostBackupAcl $Destination 'HOST_DATABASE_BACKUP_ACL_DATA_ROOT_VERIFICATION_FAILED'
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
    if (-not $process.Start()) { throw 'HOST_DATABASE_BACKUP_ROBOCOPY_START_FAILED' }
    $started = $true
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(1800000)) {
      try { $process.Kill() } catch { }
      throw 'HOST_DATABASE_BACKUP_ROBOCOPY_TIMEOUT'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    return [int]$process.ExitCode
  } catch {
    if ($_.Exception.Message -match '^HOST_DATABASE_BACKUP_[A-Z0-9_]{1,120}$') { throw }
    throw 'HOST_DATABASE_BACKUP_ROBOCOPY_FAILED'
  } finally {
    if ($started -and -not $process.HasExited) { try { $process.Kill(); $process.WaitForExit() } catch { } }
    $process.Dispose()
    $stdout = $null
    $stderr = $null
  }
}

function Get-HostServiceSid {
  return ([Security.Principal.NTAccount]::new('NT SERVICE\VentioHost')).Translate(
    [Security.Principal.SecurityIdentifier]).Value
}

function Set-HostSchemaUpgradeFileAcl([string] $Path) {
  $security = [Security.AccessControl.FileSecurity]::new()
  $security.SetAccessRuleProtection($true, $false)
  $adminSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
  $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
  $serviceSid = [Security.Principal.SecurityIdentifier]::new((Get-HostServiceSid))
  $security.SetOwner($adminSid)
  foreach ($sid in @($adminSid, $systemSid, $serviceSid)) {
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      $sid, [Security.AccessControl.FileSystemRights]::FullControl,
      [Security.AccessControl.AccessControlType]::Allow))
  }
  Set-Acl -LiteralPath $Path -AclObject $security
}

function New-HostSchemaUpgradeRequest([string] $DatabaseUrl, [string] $HostDirectory) {
  $requestPath = Join-Path $HostDirectory 'schema-upgrade.request.dpapi'
  $resultPath = Join-Path $HostDirectory 'schema-upgrade.result.json'
  foreach ($path in @($requestPath, $resultPath)) {
    if (Test-Path -LiteralPath $path) {
      $item = Get-Item -LiteralPath $path -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'HOST_SCHEMA_UPGRADE_REQUEST_PATH_INVALID'
      }
    }
  }
  if ((Test-Path -LiteralPath $requestPath) -and
      -not (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
    throw 'HOST_SCHEMA_UPGRADE_REQUEST_PATH_INVALID'
  }

  $operationId = 'upgrade_' + [guid]::NewGuid().ToString('N')
  $replaceExisting = Test-Path -LiteralPath $requestPath -PathType Leaf
  if ($replaceExisting) {
    $protected = [IO.File]::ReadAllBytes($requestPath)
    $plain = $null
    try {
      $plain = [Security.Cryptography.ProtectedData]::Unprotect(
        $protected, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
      $prior = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
      $priorProperties = @($prior.PSObject.Properties.Name | Sort-Object)
      $expectedProperties = @(@('createdAtUtc', 'databaseUrl', 'formatVersion', 'operationId') | Sort-Object)
      if ($prior.formatVersion -ne 1 -or
          (($expectedProperties -join '|') -cne ($priorProperties -join '|')) -or
          $prior.databaseUrl -cne $DatabaseUrl -or
          $prior.operationId -cnotmatch '^upgrade_[0-9a-f]{32}$') {
        throw 'HOST_SCHEMA_UPGRADE_REQUEST_PENDING'
      }
      $operationId = [string]$prior.operationId
    } catch {
      if ($_.FullyQualifiedErrorId -match '^HOST_SCHEMA_UPGRADE_REQUEST_') { throw }
      throw 'HOST_SCHEMA_UPGRADE_REQUEST_PENDING'
    } finally {
      if ($protected) { [Array]::Clear($protected, 0, $protected.Length) }
      if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
    }
  }

  $request = [ordered]@{
    formatVersion = 1
    operationId = $operationId
    databaseUrl = $DatabaseUrl
    createdAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
  }
  $jsonBytes = [Text.UTF8Encoding]::new($false).GetBytes(($request | ConvertTo-Json -Compress))
  $encrypted = $null
  $tempPath = $requestPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  try {
    $encrypted = [Security.Cryptography.ProtectedData]::Protect(
      $jsonBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    [IO.File]::WriteAllBytes($tempPath, $encrypted)
    Set-HostSchemaUpgradeFileAcl $tempPath
    if ($replaceExisting) {
      [IO.File]::Replace($tempPath, $requestPath, $null, $true)
    } else {
      [IO.File]::Move($tempPath, $requestPath)
    }
    if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force }
  } finally {
    if ($jsonBytes) { [Array]::Clear($jsonBytes, 0, $jsonBytes.Length) }
    if ($encrypted) { [Array]::Clear($encrypted, 0, $encrypted.Length) }
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
  }
  return [pscustomobject]@{ RequestPath = $requestPath; ResultPath = $resultPath; OperationId = $operationId }
}

function Invoke-HostSchemaUpgradeService([string] $DatabaseUrl, [string] $HostDirectory) {
  Set-HostBackupStage 'RECOVERY_AUTHORITY_SERVICE_PRECONDITION_QUERY' 'HOST_DATABASE_UPGRADE_HOST_SERVICE_IDENTITY_INVALID'
  $hostService = Get-CimInstance -ClassName Win32_Service -Filter "Name='$hostServiceName'" -ErrorAction Stop
  if ($null -eq $hostService -or $hostService.StartName -cne 'NT SERVICE\VentioHost' -or
      $hostService.PathName -notmatch [regex]::Escape($hostServiceExe)) {
    throw 'HOST_DATABASE_UPGRADE_HOST_SERVICE_IDENTITY_INVALID'
  }
  Set-HostBackupStage 'RECOVERY_AUTHORITY_SERVICE_PRECONDITION_STATE' 'HOST_DATABASE_UPGRADE_HOST_SERVICE_MUST_BE_STOPPED'
  Assert-VentioHostServiceMaintenance $hostService 'Stopped'
  Set-HostBackupStage 'RECOVERY_AUTHORITY_REQUEST_CREATE' 'HOST_SCHEMA_UPGRADE_REQUEST_CREATE_FAILED'
  $request = New-HostSchemaUpgradeRequest $DatabaseUrl $HostDirectory
  try {
    if (Test-Path -LiteralPath $request.ResultPath) {
      Remove-Item -LiteralPath $request.ResultPath -Force
    }
    Set-HostBackupStage 'RECOVERY_AUTHORITY_SERVICE_RECHECK_QUERY' 'HOST_DATABASE_UPGRADE_HOST_SERVICE_IDENTITY_INVALID'
    $hostService = Get-CimInstance -ClassName Win32_Service -Filter "Name='$hostServiceName'" -ErrorAction Stop
    if ($null -eq $hostService -or $hostService.StartName -cne 'NT SERVICE\VentioHost' -or
        $hostService.PathName -notmatch [regex]::Escape($hostServiceExe)) {
      throw 'HOST_DATABASE_UPGRADE_HOST_SERVICE_IDENTITY_INVALID'
    }
    Set-HostBackupStage 'RECOVERY_AUTHORITY_SERVICE_RECHECK_STATE' 'HOST_DATABASE_UPGRADE_HOST_SERVICE_MUST_BE_STOPPED'
    Assert-VentioHostServiceMaintenance $hostService 'Stopped'
    if ((Get-Service -Name $hostServiceName -ErrorAction Stop).Status -ne 'Stopped') {
      throw 'HOST_DATABASE_UPGRADE_HOST_SERVICE_MUST_BE_STOPPED'
    }
    Set-HostBackupStage 'RECOVERY_AUTHORITY_SERVICE_START' 'HOST_SCHEMA_UPGRADE_SERVICE_START_FAILED'
    Start-Service -Name $hostServiceName -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddMinutes(20)
    $completed = $false
    Set-HostBackupStage 'RECOVERY_AUTHORITY_RESULT_WAIT' 'HOST_SCHEMA_UPGRADE_SERVICE_TIMEOUT'
    while ([DateTime]::UtcNow -lt $deadline) {
      if (Test-Path -LiteralPath $request.ResultPath -PathType Leaf) {
        Set-HostBackupStage 'RECOVERY_AUTHORITY_RESULT_PARSE' 'HOST_SCHEMA_UPGRADE_RESULT_INVALID'
        $result = Get-Content -LiteralPath $request.ResultPath -Raw | ConvertFrom-Json
        if ($result.operationId -ceq $request.OperationId -and
            $result.status -in @('failed', 'unknown')) {
          $code = [string]$result.failureCode
          if ($code -notmatch '^[A-Z][A-Z0-9_]{0,63}$') {
            $code = if ($result.status -ceq 'unknown') { 'OUTCOME_UNKNOWN' } else { 'HOST_DATABASE_UPGRADE_FAILED' }
          }
          $failureStage = [string]$result.failureStage
          if ($failureStage -match '^[A-Z][A-Z0-9_]{0,63}$') {
            Set-HostBackupStage ('TRUSTED_HOST_UPGRADE_' + $failureStage) ('HOST_SCHEMA_UPGRADE_' + $code)
          } else {
            Set-HostBackupStage 'TRUSTED_HOST_UPGRADE_RESULT_UNCLASSIFIED' ('HOST_SCHEMA_UPGRADE_' + $code)
          }
          throw ('HOST_SCHEMA_UPGRADE_' + $code)
        }
        if ($result.operationId -ceq $request.OperationId -and $result.status -ceq 'complete' -and
            -not (Test-Path -LiteralPath $request.RequestPath)) { $completed = $true }
      }
      $serviceState = (Get-Service -Name $hostServiceName -ErrorAction Stop).Status
      Set-HostBackupStage 'RECOVERY_AUTHORITY_SERVICE_STATE_POLL' 'HOST_SCHEMA_UPGRADE_SERVICE_START_FAILED'
      if ($completed -and $serviceState -eq 'Running') { break }
      if ($serviceState -eq 'Stopped') {
        throw 'HOST_SCHEMA_UPGRADE_SERVICE_START_FAILED'
      }
      Start-Sleep -Milliseconds 500
    }
    if (-not $completed -or (Get-Service -Name $hostServiceName).Status -ne 'Running') {
      throw 'HOST_SCHEMA_UPGRADE_SERVICE_TIMEOUT'
    }
    if (Test-Path -LiteralPath $request.ResultPath) { Remove-Item -LiteralPath $request.ResultPath -Force }
  } catch {
    throw
  }
}

try {
if ($TestBackupOnly -and -not $TestMode) { throw 'HOST_DATABASE_TEST_BACKUP_MODE_REQUIRED' }
if ($TestBackupFailureAt -and -not $TestMode) { throw 'HOST_DATABASE_TEST_BACKUP_MODE_REQUIRED' }
if ($Port -lt 1 -or $Port -gt 65535) { throw 'HOST_DATABASE_PORT_INVALID' }
foreach ($file in @($psql, $pgCtl, $migrationExe, $migrations, $pairingContract,
    $credentialReissueContract, $schemaProfileContract, $credentialModule)) {
  if (-not (Test-Path -LiteralPath $file)) { throw 'HOST_DATABASE_UPGRADE_PAYLOAD_INCOMPLETE' }
}
if (-not $TestMode) {
  if (-not (Test-Path -LiteralPath $serviceRecoveryPolicyModule -PathType Leaf)) {
    throw 'HOST_SERVICE_RECOVERY_POLICY_HELPER_MISSING'
  }
  Import-Module $serviceRecoveryPolicyModule -Force
  foreach ($file in @($hostServiceExe, $trustedHostUpgradeExe)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
      throw 'HOST_DATABASE_UPGRADE_PAYLOAD_INCOMPLETE'
    }
  }
}
if (-not $TestMode -and -not (Test-Path -LiteralPath $robocopy -PathType Leaf)) { throw 'HOST_DATABASE_BACKUP_TOOL_MISSING' }
if ($TestMode) {
  $testPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ventio-pg-initdb-test-'
  if (-not $dataDirectory.StartsWith($testPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'HOST_DATABASE_TEST_PATH_INVALID' }
  if ($TestBackupOnly -and -not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -PathType Leaf)) {
    throw 'HOST_DATABASE_TEST_CLUSTER_MISSING'
  }
} else {
  $expectedData = [IO.Path]::GetFullPath((Join-Path $programData 'Ventio\PostgreSQL\data'))
  if (-not $dataDirectory.Equals($expectedData, [StringComparison]::OrdinalIgnoreCase) -or
      -not $pgRoot.StartsWith([IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio')).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HOST_DATABASE_UPGRADE_PATH_INVALID'
  }
}

if ($TestBackupOnly) {
  if (-not $Apply) { throw 'HOST_DATABASE_TEST_BACKUP_APPLY_REQUIRED' }
  try {
    $backupDirectory = Join-Path (Split-Path -Parent $dataDirectory) 'ventio-backups'
    Set-HostBackupStage 'BACKUP_DIRECTORY_CREATE' 'HOST_DATABASE_BACKUP_DIRECTORY_CREATE_FAILED'
    $backupDirectoryExists = Test-Path -LiteralPath $backupDirectory -PathType Container
    [void][IO.Directory]::CreateDirectory($backupDirectory)
    if (-not $backupDirectoryExists) {
      Set-HostBackupAcl $backupDirectory -Directory -FailureCode 'HOST_DATABASE_BACKUP_ACL_DIRECTORY_FAILED'
    }
    Assert-HostBackupAcl $backupDirectory 'HOST_DATABASE_BACKUP_ACL_DIRECTORY_VERIFICATION_FAILED'
    $backupName = "ventio-postgresql-before-upgrade-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture))-$([guid]::NewGuid().ToString('N'))"
    $partialRoot = Join-Path $backupDirectory ($backupName + '.partial')
    $backupRoot = Join-Path $backupDirectory $backupName
    Assert-HostBackupPath $partialRoot
    Set-HostBackupStage 'BACKUP_SOURCE_INVENTORY' 'HOST_DATABASE_BACKUP_SOURCE_INVENTORY_FAILED'
    $sourceInventory = Get-HostDataInventory $dataDirectory
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($backupDirectory))
    if ($drive.AvailableFreeSpace -lt ($sourceInventory.bytes + 67108864)) { throw 'HOST_DATABASE_BACKUP_DISK_SPACE_INSUFFICIENT' }
    Set-HostBackupStage 'BACKUP_PARTIAL_DIRECTORY_CREATE' 'HOST_DATABASE_BACKUP_PARTIAL_DIRECTORY_CREATE_FAILED'
    [void][IO.Directory]::CreateDirectory($partialRoot)
    Set-HostBackupAcl $partialRoot -Directory -FailureCode 'HOST_DATABASE_BACKUP_ACL_PARTIAL_ROOT_FAILED'
    Assert-HostBackupAcl $partialRoot 'HOST_DATABASE_BACKUP_ACL_PARTIAL_ROOT_VERIFICATION_FAILED'
    $backup = Complete-HostPostgresBackup $dataDirectory $sourceInventory $partialRoot $backupRoot $backupName
    Write-Output 'HOST_DATABASE_BACKUP_ISOLATED_WINDOWS_TEST_PASS'
    Write-Output ('Verified restricted temporary backup: ' + $backup)
    return
  } catch {
    $message = [string]$_.Exception.Message
    $code = if ($message -match '^HOST_[A-Z0-9_]{1,120}$') { $message } else { $script:hostBackupFallbackCode }
    if (-not $code) { $code = 'HOST_DATABASE_BACKUP_FAILED' }
    $details = $script:hostBackupFailureDetails -join ';'
    Write-HostUpgradeFailureCode $code $script:hostBackupStage $details
    throw $code
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
  Set-HostBackupStage 'PRE_DATABASE_UPGRADE_HOST_SERVICE_STATE' 'HOST_DATABASE_UPGRADE_HOST_SERVICE_MUST_BE_STOPPED'
  if ($null -eq $hostService -or $hostService.StartName -cne 'NT SERVICE\VentioHost' -or
      $hostService.PathName -notmatch [regex]::Escape((Join-Path $payloadRoot 'VentioHostService.exe'))) {
    throw 'HOST_DATABASE_UPGRADE_HOST_SERVICE_IDENTITY_INVALID'
  }
  if ($hostService.State -ne 'Stopped') {
    throw 'HOST_DATABASE_UPGRADE_HOST_SERVICE_MUST_BE_STOPPED'
  }
  Assert-VentioHostServiceMaintenance $hostService 'Stopped'
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
$script:hostBackupFallbackCode = 'HOST_DATABASE_BACKUP_FAILED'
$script:hostBackupStage = 'BACKUP_DIRECTORY_CREATE'
$backupDirectoryExists = Test-Path -LiteralPath $backupDirectory -PathType Container
[void][IO.Directory]::CreateDirectory($backupDirectory)
if (-not $backupDirectoryExists) {
  Set-HostBackupAcl $backupDirectory -Directory -FailureCode 'HOST_DATABASE_BACKUP_ACL_DIRECTORY_FAILED'
}
Assert-HostBackupAcl $backupDirectory 'HOST_DATABASE_BACKUP_ACL_DIRECTORY_VERIFICATION_FAILED'
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture)
$backupName = "ventio-postgresql-before-upgrade-$stamp-$([guid]::NewGuid().ToString('N'))"
$partialBackupRoot = Join-Path $backupDirectory ($backupName + '.partial')
$backupRoot = Join-Path $backupDirectory $backupName
Assert-HostBackupPath $partialBackupRoot
Import-Module $credentialModule -Force
$credential = Read-HostMigrationCredential -TestMode:$TestMode -OutputDirectory $(if ($TestMode) { Join-Path (Split-Path -Parent $dataDirectory) 'protected-migration-credential' } else { Join-Path $programData 'Ventio\Installer' })
$password = $credential.GetNetworkCredential().Password
$envVars = @{ PGPASSWORD = $password }
$migrationEnvironment = @{}
$databaseUrl = $null
try {
  Set-HostBackupStage 'BACKUP_POSTGRES_VERSION' 'HOST_DATABASE_UPGRADE_VERSION_UNSUPPORTED'
  $version = (& (Join-Path $bin 'postgres.exe') --version 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $version -ne 'postgres (PostgreSQL) 16.15') { throw 'HOST_DATABASE_UPGRADE_VERSION_UNSUPPORTED' }
  Set-HostBackupStage 'BACKUP_SOURCE_INVENTORY' 'HOST_DATABASE_BACKUP_SOURCE_INVENTORY_FAILED'
  $pgVersionFile = Join-Path $dataDirectory 'PG_VERSION'
  if ((Get-Content -LiteralPath $pgVersionFile -Raw).Trim() -ne '16') { throw 'HOST_DATABASE_UPGRADE_CLUSTER_VERSION_INVALID' }
  $initialInventory = Get-HostDataInventory $dataDirectory
  Set-HostBackupStage 'BACKUP_DISK_SPACE_CHECK' 'HOST_DATABASE_BACKUP_DISK_SPACE_CHECK_FAILED'
  $backupDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($backupDirectory))
  if ($backupDrive.AvailableFreeSpace -lt ($initialInventory.bytes + 67108864)) { throw 'HOST_DATABASE_BACKUP_DISK_SPACE_INSUFFICIENT' }
  Set-HostBackupStage 'BACKUP_PARTIAL_DIRECTORY_CREATE' 'HOST_DATABASE_BACKUP_PARTIAL_DIRECTORY_CREATE_FAILED'
  [void][IO.Directory]::CreateDirectory($partialBackupRoot)
  Set-HostBackupAcl $partialBackupRoot -Directory -FailureCode 'HOST_DATABASE_BACKUP_ACL_PARTIAL_ROOT_FAILED'
  Assert-HostBackupAcl $partialBackupRoot 'HOST_DATABASE_BACKUP_ACL_PARTIAL_ROOT_VERIFICATION_FAILED'
  Set-HostBackupStage 'BACKUP_POSTGRES_STOP' 'HOST_DATABASE_BACKUP_POSTGRES_STOP_FAILED'
  Stop-HostPostgresForBackup
  Set-HostBackupStage 'BACKUP_STABLE_INVENTORY' 'HOST_DATABASE_BACKUP_STABLE_INVENTORY_FAILED'
  $stableInventory = Get-HostDataInventory $dataDirectory
  Set-HostBackupStage 'BACKUP_DISK_SPACE_RECHECK' 'HOST_DATABASE_BACKUP_DISK_SPACE_CHECK_FAILED'
  if ($backupDrive.AvailableFreeSpace -lt ($stableInventory.bytes + 67108864)) { throw 'HOST_DATABASE_BACKUP_DISK_SPACE_INSUFFICIENT' }
  $backupRoot = Complete-HostPostgresBackup $dataDirectory $stableInventory $partialBackupRoot $backupRoot $backupName
  Set-HostBackupStage 'DATABASE_COORDINATED_MIGRATION' 'HOST_DATABASE_UPGRADE_FAILED'
  if (-not $TestMode) {
    Set-HostBackupStage 'DATABASE_POSTGRES_CONFIG_CHECK' 'HOST_DATABASE_POSTGRES_CONFIGURATION_MISSING'
    $postgresConfig = Join-Path $dataDirectory 'postgresql.conf'
    if (-not (Test-Path -LiteralPath $postgresConfig -PathType Leaf)) {
      throw 'HOST_DATABASE_POSTGRES_CONFIGURATION_MISSING'
    }
    Set-HostBackupStage 'DATABASE_POSTGRES_CONFIG_READ' 'HOST_DATABASE_POSTGRES_CONFIGURATION_READ_FAILED'
    $configuration = [IO.File]::ReadAllText($postgresConfig)
    if ($configuration -notmatch '(?m)^# Ventio Recovery Authority upgrade coordinator v1\s*$') {
      $temporaryConfig = $postgresConfig + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
      try {
        Set-HostBackupStage 'DATABASE_POSTGRES_CONFIG_WRITE' 'HOST_DATABASE_POSTGRES_CONFIGURATION_WRITE_FAILED'
        $configuration += "`n# Ventio Recovery Authority upgrade coordinator v1`nmax_prepared_transactions = 1`n"
        [IO.File]::WriteAllText($temporaryConfig, $configuration, [Text.UTF8Encoding]::new($false))
        Set-Acl -LiteralPath $temporaryConfig -AclObject (Get-Acl -LiteralPath $postgresConfig)
        Set-HostBackupStage 'DATABASE_POSTGRES_CONFIG_REPLACE' 'HOST_DATABASE_POSTGRES_CONFIGURATION_REPLACE_FAILED'
        [IO.File]::Replace($temporaryConfig, $postgresConfig, $null, $true)
      } finally {
        if (Test-Path -LiteralPath $temporaryConfig) { Remove-Item -LiteralPath $temporaryConfig -Force }
      }
    }
  }
  Set-HostBackupStage 'DATABASE_POSTGRES_RESTART' 'HOST_DATABASE_UPGRADE_POSTGRES_RESTART_FAILED'
  Start-HostPostgresAfterBackup
  Set-HostBackupStage 'DATABASE_PREPARED_TRANSACTIONS_PREFLIGHT' 'HOST_DATABASE_PREPARED_TRANSACTIONS_UNAVAILABLE'
  $preparedTransactions = Invoke-HostDatabaseTool $psql @(
    '-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$migrationRole,
    '-d',$databaseName,'-Atc','SHOW max_prepared_transactions'
  ) $envVars 30000 'HOST_DATABASE_PREPARED_TRANSACTIONS_UNAVAILABLE' -TestMode:$TestMode
  if ($preparedTransactions.Trim() -notmatch '^\d+$' -or [int]$preparedTransactions.Trim() -lt 1) {
    throw 'HOST_DATABASE_PREPARED_TRANSACTIONS_UNAVAILABLE'
  }
  Set-HostBackupStage 'DATABASE_MIGRATOR_PROFILE_PREFLIGHT' 'HOST_DATABASE_MIGRATOR_PROFILE_INVALID'
  $profile = Invoke-HostDatabaseTool $psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$migrationRole,'-d',$databaseName,'-Atc',"SELECT pg_has_role(session_user,'ventio_migrator','MEMBER')::text || ':' || rolsuper::text || ':' || rolcreatedb::text || ':' || rolcreaterole::text FROM pg_roles WHERE rolname=current_user") $envVars 30000 'HOST_DATABASE_MIGRATOR_AUTHENTICATION_FAILED' -TestMode:$TestMode
  if ($profile -ne 'true:false:false:false') { throw 'HOST_DATABASE_MIGRATOR_PROFILE_INVALID' }
  Set-HostBackupStage 'DATABASE_MIGRATION_PAYLOAD_INVENTORY' 'HOST_DATABASE_MIGRATION_FILES_MISSING'
  $migrationFiles = @(Get-ChildItem -LiteralPath $migrations -Filter '*.sql' -File -Recurse)
  if ($migrationFiles.Count -lt 1) { throw 'HOST_DATABASE_MIGRATION_FILES_MISSING' }
  Set-HostBackupStage 'DATABASE_CONNECTION_CONFIGURATION' 'HOST_DATABASE_MIGRATION_FAILED'
  $databaseUrl = 'postgresql://' + [Uri]::EscapeDataString($credential.UserName) + ':' + [Uri]::EscapeDataString($password) + "@127.0.0.1:${Port}/${databaseName}?sslmode=disable"
  $migrationEnvironment = @{
    VENTIO_DATABASE_URL = $databaseUrl
    VENTIO_MIGRATION_ROLE = 'ventio_owner'
    VENTIO_MIGRATIONS_DIR = $migrations
  }
  if ($TestMode) {
    # The isolated backup-contract fixture has no Host service identity or
    # Recovery Authority witness. Production upgrades always go through the
    # service-identity Recovery Authority transition below.
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
  } else {
    Set-HostBackupStage 'DATABASE_TRUSTED_HOST_SCHEMA_UPGRADE' 'HOST_DATABASE_UPGRADE_FAILED'
    Invoke-HostSchemaUpgradeService $databaseUrl (Join-Path $programData 'Ventio\Host')
  }
  Set-HostBackupStage 'DATABASE_PAIRING_CONTRACT_VERIFICATION' 'HOST_PAIRING_CONTRACT_VERIFICATION_FAILED'
  $pairingContractReady = Invoke-HostDatabaseTool $psql @(
    '-X', '-w', '-h', '127.0.0.1', '-p', [string]$Port, '-U', $migrationRole,
    '-d', $databaseName, '-Atc', "SET ROLE ventio_owner; SELECT position('Pairing request was already accepted' IN pg_get_functiondef('ventio_security.scoped_pairing_create(text,text,text,text,text,text)'::regprocedure)) > 0 AND position('TRUSTED_PAIRING_CREATED' IN pg_get_functiondef('ventio_security.trusted_windows_pairing_create(text,text,text,text,text,text,text,text,text[],text)'::regprocedure)) > 0 AND position('CREDENTIAL_CEILING_DENIED' IN pg_get_functiondef('ventio_security.permission_denial_reason(text,text,text,text,text)'::regprocedure)) > 0 AND has_function_privilege('ventio_identity_api','ventio_security.trusted_windows_pairing_create(text,text,text,text,text,text,text,text,text[],text)','EXECUTE') AND NOT has_function_privilege('ventio_runtime','ventio_security.trusted_windows_pairing_create(text,text,text,text,text,text,text,text,text[],text)','EXECUTE') AND has_function_privilege('ventio_identity_api','ventio_security.permission_denial_reason(text,text,text,text,text)','EXECUTE') AND NOT has_function_privilege('ventio_runtime','ventio_security.permission_denial_reason(text,text,text,text,text)','EXECUTE')"
  ) $envVars 30000 'HOST_PAIRING_CONTRACT_VERIFICATION_FAILED' -TestMode:$TestMode
  $pairingContractMatch = [regex]::Match($pairingContractReady.Trim(), '(?:^|\s)(t|f)$')
  if (-not $pairingContractMatch.Success -or $pairingContractMatch.Groups[1].Value -cne 't') {
    throw 'HOST_PAIRING_CONTRACT_VERIFICATION_FAILED'
  }
  Set-HostBackupStage 'DATABASE_CREDENTIAL_REISSUE_CONTRACT_VERIFICATION' 'HOST_CREDENTIAL_REISSUE_CONTRACT_VERIFICATION_FAILED'
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
  Set-HostBackupStage 'DATABASE_MIGRATION_LEDGER_VERIFICATION' 'HOST_DATABASE_MIGRATION_LEDGER_INVALID'
  $ledger = Invoke-HostDatabaseTool $psql @('-X','-w','-h','127.0.0.1','-p',[string]$Port,'-U',$migrationRole,'-d',$databaseName,'-Atc','SET ROLE ventio_owner; SELECT count(*) FROM public.ventio_schema_migrations') $envVars 30000 'HOST_DATABASE_MIGRATION_LEDGER_INVALID' -TestMode:$TestMode
  $ledgerCounts = @($ledger -split "`r?`n" | Where-Object { $_ -match '^\d+$' })
  if ($ledgerCounts.Count -ne 1 -or [int]$ledgerCounts[0] -ne $migrationFiles.Count) {
    throw 'HOST_DATABASE_MIGRATION_LEDGER_INVALID'
  }
  Write-Output 'HOST_DATABASE_UPGRADE_PASS'
  Write-Output ("Verified restricted PostgreSQL data backup: " + $backupRoot)
} finally {
  try {
    $reportedStage = $script:hostBackupStage
    $reportedFallbackCode = $script:hostBackupFallbackCode
    Start-HostPostgresAfterBackup
    # A successful cleanup restart must not replace the operation stage that
    # caused the upgrade to fail. If cleanup itself fails, retain its stage so
    # the operator can see why PostgreSQL could not be restored to service.
    $script:hostBackupStage = $reportedStage
    $script:hostBackupFallbackCode = $reportedFallbackCode
  } finally {
    $password = $null
    $databaseUrl = $null
    $credential = $null
    $envVars.Clear()
    $migrationEnvironment.Clear()
  }
}
} catch {
  $message = [string]$_.Exception.Message
  $code = if ($message -match '^HOST_[A-Z0-9_]{1,120}$') {
    $message
  } elseif ($script:hostBackupFallbackCode -match '^HOST_[A-Z0-9_]{1,120}$') {
    $script:hostBackupFallbackCode
  } else {
    'HOST_DATABASE_UPGRADE_FAILED'
  }
  $details = $script:hostBackupFailureDetails -join ';'
  Write-HostUpgradeFailureCode $code $script:hostBackupStage $details
  throw $code
}
