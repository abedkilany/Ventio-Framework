[CmdletBinding()]
param(
  [string] $PostgresRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PostgresRoot)) {
  $PostgresRoot = Join-Path $PSScriptRoot '..\..\packages\ventio_host_api\build\windows\host-payload\postgresql'
}
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$migrationDirectory = Join-Path $repoRoot 'migrations\postgres'
$bin = [IO.Path]::GetFullPath((Join-Path $PostgresRoot 'bin'))
$postgres = Join-Path $bin 'postgres.exe'
$initdb = Join-Path $bin 'initdb.exe'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testPrefix = $tempRoot + '\ventio-single-user-recovery-test-'
$testRoot = $testPrefix + [guid]::NewGuid().ToString('N')
$dataDirectory = Join-Path $testRoot 'data'
$passwordFile = Join-Path $testRoot 'bootstrap-password.tmp'
$migrationPassword = $null
$migrationCredential = $null
$testBootstrapCredential = $null

foreach ($file in @($postgres, $initdb)) {
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'POSTGRES_SINGLE_USER_TEST_PAYLOAD_INCOMPLETE' }
}
$version = (& $postgres --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $version -ne 'postgres (PostgreSQL) 16.15') {
  throw 'POSTGRES_SINGLE_USER_TEST_VERSION_INVALID'
}
if (Test-Path -LiteralPath $testRoot) { throw 'POSTGRES_SINGLE_USER_TEST_PATH_ALREADY_EXISTS' }

function ConvertTo-TestCommandLineArgument([string] $Value) {
  $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $trailingSlashes = [regex]::Match($escaped, '\\+$').Length
  if ($trailingSlashes -gt 0) {
    $escaped = $escaped.Substring(0, $escaped.Length - $trailingSlashes) + ('\' * ($trailingSlashes * 2))
  }
  return '"' + $escaped + '"'
}

function Invoke-TestProcess(
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
    $quoted = foreach ($argument in $Arguments) { ConvertTo-TestCommandLineArgument ([string]$argument) }
    $info.Arguments = [string]::Join(' ', [string[]]$quoted)
    if ($Environment) {
      foreach ($entry in $Environment.GetEnumerator()) {
        $info.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
      }
    }
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'POSTGRES_SINGLE_USER_TEST_PROCESS_START_FAILED' }
    $started = $true
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if ($null -ne $InputText) { $process.StandardInput.Write($InputText) }
    $process.StandardInput.Close()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
      try { $process.Kill() } catch { }
      throw 'POSTGRES_SINGLE_USER_TEST_PROCESS_TIMEOUT'
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

function New-TestSecret([int] $ByteCount = 32) {
  $bytes = [byte[]]::new($ByteCount)
  $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $generator.GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
  } finally {
    [Array]::Clear($bytes, 0, $bytes.Length)
    $generator.Dispose()
  }
}

function Set-TestPasswordFileAcl([string] $Path) {
  $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
  if ($null -eq $owner) { throw 'POSTGRES_SINGLE_USER_TEST_OWNER_MISSING' }
  $security = [Security.AccessControl.FileSecurity]::new()
  $security.SetAccessRuleProtection($true, $false)
  $security.SetOwner($owner)
  $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $owner, [Security.AccessControl.FileSystemRights]::FullControl,
    [Security.AccessControl.AccessControlType]::Allow))
  Set-Acl -LiteralPath $Path -AclObject $security
}

try {
  [void][IO.Directory]::CreateDirectory($testRoot)

  $recoveryScript = Join-Path $PSScriptRoot 'recover-host-database-credentials.ps1'
  $recoveryTokens = $null
  $recoveryParseErrors = $null
  $recoveryAst = [Management.Automation.Language.Parser]::ParseFile(
    $recoveryScript, [ref]$recoveryTokens, [ref]$recoveryParseErrors)
  if ($recoveryParseErrors.Count -gt 0) { throw 'POSTGRES_SINGLE_USER_TEST_RECOVERY_SCRIPT_PARSE_FAILED' }
  $collisionFunction = $recoveryAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq 'Test-HostRecoveryBackupPathCollision'
  }, $true)
  if (-not $collisionFunction) { throw 'POSTGRES_SINGLE_USER_TEST_BACKUP_COLLISION_FUNCTION_MISSING' }
  . ([scriptblock]::Create($collisionFunction.Extent.Text))
  $partialCollisionPath = Join-Path $testRoot 'backup-collision.partial'
  $finalCollisionPath = Join-Path $testRoot 'backup-collision'
  if (Test-HostRecoveryBackupPathCollision $partialCollisionPath $finalCollisionPath) {
    throw 'POSTGRES_SINGLE_USER_TEST_BACKUP_COLLISION_FALSE_POSITIVE'
  }
  [void][IO.Directory]::CreateDirectory($partialCollisionPath)
  if (-not (Test-HostRecoveryBackupPathCollision $partialCollisionPath $finalCollisionPath)) {
    throw 'POSTGRES_SINGLE_USER_TEST_PARTIAL_BACKUP_COLLISION_MISSED'
  }
  [IO.Directory]::Delete($partialCollisionPath)
  [void][IO.Directory]::CreateDirectory($finalCollisionPath)
  if (-not (Test-HostRecoveryBackupPathCollision $partialCollisionPath $finalCollisionPath)) {
    throw 'POSTGRES_SINGLE_USER_TEST_FINAL_BACKUP_COLLISION_MISSED'
  }
  [IO.Directory]::Delete($finalCollisionPath)
  Write-Output 'POSTGRES_SINGLE_USER_BACKUP_COLLISION_TEST_PASS'

  $rotationClassifier = $recoveryAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq 'Get-HostRecoveryRotationFailureClass'
  }, $true)
  if (-not $rotationClassifier) { throw 'POSTGRES_SINGLE_USER_TEST_ROTATION_CLASSIFIER_MISSING' }
  . ([scriptblock]::Create($rotationClassifier.Extent.Text))
  $rotationFailureCases = @(
    @{ ExitCode = 1; StandardOutput = ''; StandardError = 'ERROR: role "ventio_runtime_app" does not exist'; Expected = 'runtime_role_missing' },
    @{ ExitCode = 1; StandardOutput = ''; StandardError = 'ERROR: role "ventio_identity_api_app" does not exist'; Expected = 'identity_role_missing' },
    @{ ExitCode = 1; StandardOutput = ''; StandardError = 'lock file "postmaster.pid" already exists'; Expected = 'postgres_already_running' },
    @{ ExitCode = 1; StandardOutput = ''; StandardError = 'ERROR: permission denied'; Expected = 'permission_denied' },
    @{ ExitCode = 1; StandardOutput = ''; StandardError = 'ERROR: unclassified fixture'; Expected = 'postgres_sql_error' },
    @{ ExitCode = 3; StandardOutput = ''; StandardError = ''; Expected = 'process_exit' }
  )
  foreach ($case in $rotationFailureCases) {
    $actual = Get-HostRecoveryRotationFailureClass $case.ExitCode $case.StandardOutput $case.StandardError
    if ($actual -cne $case.Expected) { throw 'POSTGRES_SINGLE_USER_TEST_ROTATION_FAILURE_CLASSIFICATION_FAILED' }
  }
  Write-Output 'POSTGRES_SINGLE_USER_ROTATION_FAILURE_CLASSIFICATION_TEST_PASS'

  $bootstrapPassword = New-TestSecret
  $runtimePassword = New-TestSecret
  $identityPassword = New-TestSecret
  $migrationPassword = New-TestSecret
  [IO.File]::WriteAllText($passwordFile, $bootstrapPassword, [Text.UTF8Encoding]::new($false))
  Set-TestPasswordFileAcl $passwordFile
  $initResult = Invoke-TestProcess $initdb @(
    '--no-sync', '--locale=C', '--username=ventio_bootstrap',
    '--auth-local=trust', '--auth-host=scram-sha-256', "--pwfile=$passwordFile", '-D', $dataDirectory
  ) $null $null 60000
  if ($initResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -PathType Leaf)) {
    throw 'POSTGRES_SINGLE_USER_TEST_INITDB_FAILED'
  }
  Remove-Item -LiteralPath $passwordFile -Force
  $passwordFile = $null

  $databaseResult = Invoke-TestProcess $postgres @('--single', '-D', $dataDirectory, 'postgres') `
    "CREATE DATABASE ventio_host;`n" $null 30000
  if ($databaseResult.ExitCode -ne 0 -or $databaseResult.StandardOutput -match '(?m)^ERROR:' -or
      $databaseResult.StandardError -match '(?m)^ERROR:') {
    throw 'POSTGRES_SINGLE_USER_TEST_DATABASE_CREATION_FAILED'
  }

  $createSql = @"
CREATE ROLE ventio_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
CREATE ROLE ventio_migrator NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
GRANT ventio_owner TO ventio_migrator WITH INHERIT FALSE, SET TRUE;
CREATE ROLE ventio_migrator_app LOGIN PASSWORD '$migrationPassword' INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT ventio_migrator TO ventio_migrator_app;
CREATE ROLE ventio_runtime_app WITH LOGIN PASSWORD '$runtimePassword';
CREATE ROLE ventio_identity_api_app WITH LOGIN PASSWORD '$identityPassword';

"@
  $createResult = Invoke-TestProcess $postgres @('--single', '-D', $dataDirectory, '-j', 'postgres') $createSql $null 30000
  if ($createResult.ExitCode -ne 0 -or $createResult.StandardOutput -match '(?m)^ERROR:') {
    throw 'POSTGRES_SINGLE_USER_TEST_ROLE_CREATION_FAILED'
  }

  $rotatedRuntimePassword = New-TestSecret 36
  $rotatedIdentityPassword = New-TestSecret 36
  $runtimeCredential = [PSCredential]::new(
    'ventio_runtime_app', (ConvertTo-SecureString $rotatedRuntimePassword -AsPlainText -Force))
  $identityCredential = [PSCredential]::new(
    'ventio_identity_api_app', (ConvertTo-SecureString $rotatedIdentityPassword -AsPlainText -Force))
  $migrationCredential = [PSCredential]::new(
    'ventio_migrator_app', (ConvertTo-SecureString $migrationPassword -AsPlainText -Force))
  $testBootstrapCredential = [PSCredential]::new(
    'ventio_bootstrap', (ConvertTo-SecureString $bootstrapPassword -AsPlainText -Force))
  $global:VentioProvisioningFailureDetail = $null
  try {
    $recoveryOutput = & $recoveryScript -PostgresRoot (Split-Path -Parent $bin) `
      -DataDirectory $dataDirectory -RuntimeCredential $runtimeCredential `
      -IdentityApiCredential $identityCredential -TestMode `
      -TestBootstrapCredential $testBootstrapCredential `
      -TestMigrationCredential $migrationCredential -TestMigrationDirectory $migrationDirectory
  } catch {
    if ($global:VentioProvisioningFailureDetail) {
      Write-Output ('POSTGRES_RECOVERY_TEST_DIAGNOSTIC=' + $global:VentioProvisioningFailureDetail)
    }
    throw
  }
  if ($recoveryOutput -notcontains 'HOST_DATABASE_CREDENTIAL_RECOVERY_TEST_PASS' -or
      $recoveryOutput -notcontains 'HOST_DATABASE_RECOVERY_MIGRATION_LEDGER_TEST_PASS') {
    throw 'POSTGRES_SINGLE_USER_TEST_RECOVERY_HELPER_FAILED'
  }
  Write-Output 'POSTGRES_SINGLE_USER_RECOVERY_PASS'
} finally {
  $safeToRemove = $true
  $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
  $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot).TrimEnd('\') + '\'
  $matchingProcesses = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'postgres.exe' -and ($_.CommandLine -replace '/', '\') -match [regex]::Escape($resolvedRoot)
  })
  if ($matchingProcesses.Count -gt 0) { $safeToRemove = $false }
  if ($safeToRemove -and $resolvedRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $resolvedRoot) -match '^ventio-single-user-recovery-test-[0-9a-f]{32}$' -and
      (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    $unsafeEntry = Get-ChildItem -LiteralPath $resolvedRoot -Force -Recurse | Where-Object {
      ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    } | Select-Object -First 1
    if ($unsafeEntry) { throw 'POSTGRES_SINGLE_USER_TEST_CLEANUP_REPARSE_POINT' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
  } elseif (Test-Path -LiteralPath $resolvedRoot) {
    throw 'POSTGRES_SINGLE_USER_TEST_DATA_PRESERVED_AFTER_INCOMPLETE_SHUTDOWN'
  }
  $bootstrapPassword = $null
  $runtimePassword = $null
  $identityPassword = $null
  $migrationPassword = $null
  $rotatedRuntimePassword = $null
  $rotatedIdentityPassword = $null
  if ($migrationCredential -and $migrationCredential.Password) { $migrationCredential.Password.Dispose() }
  if ($testBootstrapCredential -and $testBootstrapCredential.Password) { $testBootstrapCredential.Password.Dispose() }
}
