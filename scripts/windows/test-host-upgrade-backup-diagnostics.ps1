[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $PostgresRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$upgradeScript = Join-Path $PSScriptRoot 'upgrade-host-database.ps1'
$pgRoot = [IO.Path]::GetFullPath($PostgresRoot)
$payloadRoot = [IO.Path]::GetFullPath((Split-Path -Parent $pgRoot))
$testRoot = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) ('ventio-pg-initdb-test-backup-' + [guid]::NewGuid().ToString('N'))
$dataDirectory = Join-Path $testRoot 'database-data'
$failuresDirectory = Join-Path $testRoot 'failure-codes'
$currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$robocopyPath = Join-Path $env:SystemRoot 'System32\robocopy.exe'

function Assert-BackupTest([bool] $Condition, [string] $Name) {
  if (-not $Condition) { throw ('HOST_UPGRADE_BACKUP_TEST_FAILED_' + $Name) }
  Write-Output ('PASS: ' + $Name)
}

function ConvertTo-CommandLineArgument([string] $Value) {
  $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $trailingSlashes = [regex]::Match($escaped, '\\+$').Length
  if ($trailingSlashes -gt 0) {
    $escaped = $escaped.Substring(0, $escaped.Length - $trailingSlashes) + ('\' * ($trailingSlashes * 2))
  }
  return '"' + $escaped + '"'
}

function Invoke-BackupOnlyUpgrade([string] $FailureAt, [string] $FailureCodePath) {
  $process = [Diagnostics.Process]::new()
  try {
    $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $arguments = @(
      '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', $upgradeScript,
      '-PostgresRoot', $pgRoot,
      '-Port', '55439',
      '-Apply', '-TestMode', '-TestBackupOnly',
      '-TestDataDirectory', $dataDirectory,
      '-FailureCodePath', $FailureCodePath
    )
    if ($FailureAt) { $arguments += @('-TestBackupFailureAt', $FailureAt) }
    $quoted = foreach ($argument in $arguments) { ConvertTo-CommandLineArgument $argument }
    $info.Arguments = [string]::Join(' ', [string[]]$quoted)
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'HOST_UPGRADE_BACKUP_TEST_PROCESS_START_FAILED' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) {
      $process.Kill()
      throw 'HOST_UPGRADE_BACKUP_TEST_TIMEOUT'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
  } finally { $process.Dispose() }
}

function Get-Inventory([string] $Path) {
  $count = 0
  [long]$bytes = 0
  foreach ($file in Get-ChildItem -LiteralPath $Path -File -Force -Recurse) {
    $count++
    $bytes += [long]$file.Length
  }
  return [pscustomobject]@{ fileCount = $count; bytes = $bytes }
}

function Assert-PartialFailure([string] $FailureAt, [string] $ExpectedCode, [string] $ExpectedStage, [string] $ExpectedHresult = '') {
  $failureFile = Join-Path $failuresDirectory ($FailureAt + '.txt')
  $result = Invoke-BackupOnlyUpgrade $FailureAt $failureFile
  if ($result.Stderr) { Write-Output ($FailureAt + '_STDERR=' + (@($result.Stderr -split "`r?`n" | Select-Object -First 12) -join '|')) }
  if ($ExpectedHresult) {
    Assert-BackupTest ($result.Stderr.Contains('HOST_DATABASE_TEST_ACL_SET_HRESULT=' + $ExpectedHresult)) ($FailureAt + '_expected_ntfs_error_reproduced')
  }
  Assert-BackupTest ($result.ExitCode -ne 0) ($FailureAt + '_returns_failure')
  $lines = @(Get-Content -LiteralPath $failureFile)
  Write-Output ($FailureAt + '_OBSERVED=' + ($lines -join '|'))
  Assert-BackupTest ($lines.Count -ge 2 -and $lines[0] -ceq $ExpectedCode) ($FailureAt + '_safe_failure_code')
  Assert-BackupTest ($lines[1] -ceq ('STAGE=' + $ExpectedStage)) ($FailureAt + '_stage_reported')
  $partial = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'ventio-backups') -Directory -Filter '*.partial') |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  Assert-BackupTest ($null -ne $partial) ($FailureAt + '_partial_preserved')
  Assert-BackupTest ((Test-Path -LiteralPath (Join-Path $partial.FullName 'data\PG_VERSION') -PathType Leaf) -and
    -not (Test-Path -LiteralPath (Join-Path $partial.FullName 'backup-manifest.json'))) ($FailureAt + '_manifest_not_written_on_failure')
  $inventory = Get-Inventory (Join-Path $partial.FullName 'data')
  Assert-BackupTest ($inventory.fileCount -eq 1375 -and $inventory.bytes -eq 50810225) ($FailureAt + '_complete_copy_retained_for_diagnosis')
}

try {
  if (-not (Test-Path -LiteralPath $robocopyPath -PathType Leaf)) { throw 'HOST_UPGRADE_BACKUP_TEST_ROBOCOPY_MISSING' }
  foreach ($path in @((Join-Path $payloadRoot 'ventio_migrate.exe'), (Join-Path $payloadRoot 'migrations'),
      (Join-Path $payloadRoot 'security\pairing.sql'), (Join-Path $payloadRoot 'security\credential_reissues.sql'),
      (Join-Path $payloadRoot 'security\schema_profile.sql'))) {
    if (-not (Test-Path -LiteralPath $path)) { throw 'HOST_UPGRADE_BACKUP_TEST_PAYLOAD_INCOMPLETE' }
  }
  [void][IO.Directory]::CreateDirectory((Join-Path $dataDirectory 'base\1'))
  [void][IO.Directory]::CreateDirectory((Join-Path $dataDirectory 'global'))
  [IO.File]::WriteAllText((Join-Path $dataDirectory 'PG_VERSION'), '16', [Text.Encoding]::ASCII)
  $block = [byte[]]::new(37000)
  for ($index = 0; $index -lt 1373; $index++) {
    $directory = if (($index % 2) -eq 0) { Join-Path $dataDirectory 'base\1' } else { Join-Path $dataDirectory 'global' }
    [IO.File]::WriteAllBytes((Join-Path $directory ('fixture-' + $index.ToString('D4') + '.dat')), $block)
  }
  [IO.File]::WriteAllBytes((Join-Path $dataDirectory 'global\fixture-final.dat'), [byte[]]::new(9223))
  [Array]::Clear($block, 0, $block.Length)
  [void][IO.Directory]::CreateDirectory($failuresDirectory)

  $sourceInventory = Get-Inventory $dataDirectory
  Assert-BackupTest ($sourceInventory.fileCount -eq 1375 -and $sourceInventory.bytes -eq 50810225) 'field-sized-database-fixture_created'

  $successResult = Invoke-BackupOnlyUpgrade '' (Join-Path $failuresDirectory 'unexpected.txt')
  Assert-BackupTest ($successResult.ExitCode -eq 0 -and $successResult.Stdout.Contains('HOST_DATABASE_BACKUP_ISOLATED_WINDOWS_TEST_PASS')) 'robocopy-and-restricted-ntfs-backup_pass'
  Assert-BackupTest ($successResult.Stdout -match 'HOST_DATABASE_BACKUP_ROBOCOPY_EXIT=[0-7]') 'robocopy_exit_0_to_7_accepted'
  $completeBackup = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'ventio-backups') -Directory -Filter 'ventio-postgresql-before-upgrade-*' |
    Where-Object { $_.Name -notmatch '\.partial$' }) | Select-Object -First 1
  $manifestPath = Join-Path $completeBackup.FullName 'backup-manifest.json'
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  Assert-BackupTest ($manifest.fileCount -eq 1375 -and $manifest.bytes -eq 50810225) 'manifest_matches_robocopy_inventory'
  $backupAcl = Get-Acl -LiteralPath (Join-Path $completeBackup.FullName 'data')
  $backupRules = @($backupAcl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
  Assert-BackupTest ($backupAcl.AreAccessRulesProtected -and $backupRules.Count -eq 2 -and
    @($backupRules | Where-Object { $_.IdentityReference.Value -eq $currentUserSid }).Count -eq 1 -and
    @($backupRules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-18' }).Count -eq 1) 'backup_acl_restricted_to_test_owner_and_system'
  $sampleAcl = Get-Acl -LiteralPath (Join-Path $completeBackup.FullName 'data\base\1\fixture-0000.dat')
  $sampleRules = @($sampleAcl.GetAccessRules($false, $true, [Security.Principal.SecurityIdentifier]))
  Assert-BackupTest ($sampleRules.Count -eq 2 -and
    @($sampleRules | Where-Object { $_.IdentityReference.Value -eq $currentUserSid }).Count -eq 1 -and
    @($sampleRules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-18' }).Count -eq 1) 'robocopy_descendants_inherit_only_restricted_destination_acl'
  $completeManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash

  Assert-PartialFailure 'RobocopyExit8' 'HOST_DATABASE_BACKUP_ROBOCOPY_EXIT_8' 'BACKUP_ROBOCOPY'
  Assert-PartialFailure 'InventoryMismatch' 'HOST_DATABASE_BACKUP_INVENTORY_MISMATCH' 'BACKUP_DESTINATION_INVENTORY'
  Assert-PartialFailure 'PostCopyAclRewrite' 'HOST_DATABASE_BACKUP_ACL_POSTCOPY_REWRITE_FAILED' 'BACKUP_POSTCOPY_ACL_REWRITE' '80070005'
  Assert-PartialFailure 'AclVerification' 'HOST_DATABASE_BACKUP_ACL_VERIFICATION_FAILED' 'BACKUP_ACL_VERIFICATION'
  Assert-BackupTest ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ceq $completeManifestHash) 'existing_verified_backup_preserved_across_retries'
  Write-Output 'HOST_UPGRADE_BACKUP_DIAGNOSTICS_TEST_PASS'
} finally {
  $fullTestRoot = [IO.Path]::GetFullPath($testRoot)
  $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  if ($fullTestRoot.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $fullTestRoot) -match '^ventio-pg-initdb-test-backup-[0-9a-f]{32}$' -and
      (Test-Path -LiteralPath $fullTestRoot)) {
    Remove-Item -LiteralPath $fullTestRoot -Recurse -Force
  }
}
