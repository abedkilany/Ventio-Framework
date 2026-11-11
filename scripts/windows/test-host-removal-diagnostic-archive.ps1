$ErrorActionPreference = 'Stop'

$sourcePath = Join-Path $PSScriptRoot 'remove-host-installation.ps1'
$tokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $sourcePath,
  [ref]$tokens,
  [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) { throw 'HOST_REMOVAL_SCRIPT_PARSE_FAILED' }

$testOwner = [Security.Principal.WindowsIdentity]::GetCurrent().User
if ($null -eq $testOwner) { throw 'HOST_REMOVAL_TEST_OWNER_MISSING' }

$functionNames = @(
  'Assert-PrivateProductRoot',
  'Assert-PrivateProductDirectory',
  'Test-ProtectedRecoveryRecordAcl',
  'Save-ProtectedProvisioningDiagnostics',
  'Assert-PostgresOnlyFailedInstallation'
)
$functionAsts = @($scriptAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in $functionNames
}, $true))
if ($functionAsts.Count -ne $functionNames.Count) { throw 'HOST_REMOVAL_TEST_FUNCTIONS_MISSING' }

foreach ($functionAst in $functionAsts) {
  $functionSource = $functionAst.Extent.Text
  Invoke-Expression $functionSource
}

function Set-ProtectedRecoveryEvidenceAcl([string] $Path, [bool] $IsDirectory) {
  if ($IsDirectory) {
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
      [Security.AccessControl.InheritanceFlags]::ObjectInherit
  } else {
    $acl = [Security.AccessControl.FileSecurity]::new()
    $inheritance = [Security.AccessControl.InheritanceFlags]::None
  }
  $acl.SetAccessRuleProtection($true, $false)
  $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
  $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
  $acl.SetOwner($testOwner)
  foreach ($sid in @($administrators, $system, $testOwner)) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
      $sid,
      [Security.AccessControl.FileSystemRights]::FullControl,
      $inheritance,
      [Security.AccessControl.PropagationFlags]::None,
      [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
  }
  Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

$userProfilePrefix = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)).TrimEnd('\') + '\'
$testPrefix = $userProfilePrefix + 'VentioRemovalTest-'
$testRoot = [IO.Path]::GetFullPath(($testPrefix + [guid]::NewGuid().ToString('N')))
if (-not $testRoot.StartsWith($testPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'HOST_REMOVAL_TEST_PATH_INVALID'
}

try {
  $programDataVentio = Join-Path $testRoot 'Ventio'
  $databaseData = Join-Path $programDataVentio 'PostgreSQL'
  $hostData = Join-Path $programDataVentio 'Host'
  $installerData = Join-Path $programDataVentio 'Installer'
  $backupData = Join-Path $programDataVentio 'Backups'
  $recoveryEvidenceData = Join-Path $programDataVentio 'RecoveryEvidence'
  $dataDirectory = Join-Path $databaseData 'data'
  $diagnosticsDirectory = Join-Path $installerData 'ProvisioningDiagnostics'
  [void][IO.Directory]::CreateDirectory($dataDirectory)
  [void][IO.Directory]::CreateDirectory($diagnosticsDirectory)
  if (-not (Assert-PrivateProductRoot $dataDirectory)) {
    throw 'HOST_REMOVAL_REJECTED_PRODUCT_DATA_DESCENDANT'
  }
  $outsideProductPathRejected = $false
  try {
    [void](Assert-PrivateProductRoot (Join-Path $testRoot 'VentioSibling'))
  } catch {
    $outsideProductPathRejected =
      $_.Exception.Message -ceq 'HOST_DATA_PATH_OUTSIDE_PRODUCT_ROOT'
  }
  if (-not $outsideProductPathRejected) {
    throw 'HOST_REMOVAL_ACCEPTED_PATH_OUTSIDE_PRODUCT_ROOT'
  }
  Set-ProtectedRecoveryEvidenceAcl $installerData $true
  Set-ProtectedRecoveryEvidenceAcl $diagnosticsDirectory $true

  $pgVersionPath = Join-Path $dataDirectory 'PG_VERSION'
  [IO.File]::WriteAllText($pgVersionPath, '16', [Text.UTF8Encoding]::new($false))
  $migrationCredential = Join-Path $installerData 'migration-credential.dpapi'
  [IO.File]::WriteAllBytes($migrationCredential, [byte[]]@(1, 2, 3, 4))
  Set-ProtectedRecoveryEvidenceAcl $migrationCredential $false

  $recordName = 'host-provisioning-20261031T010203004Z-00112233445566778899aabbccddeeff.json'
  $recordPath = Join-Path $diagnosticsDirectory $recordName
  $recordContents = '{"failureCode":"HOST_DATABASE_RECOVERY_ROLE_ROTATION_FAILED","phase":"DATABASE_RECOVERY"}'
  [IO.File]::WriteAllText($recordPath, $recordContents, [Text.UTF8Encoding]::new($false))
  Set-ProtectedRecoveryEvidenceAcl $recordPath $false

  Assert-PostgresOnlyFailedInstallation
  $archiveOutput = Save-ProtectedProvisioningDiagnostics
  $archiveLine = @($archiveOutput | Where-Object { $_ -like 'HOST_RECOVERY_DIAGNOSTICS_ARCHIVED=*' })
  if ($archiveLine.Count -ne 1) { throw 'HOST_RECOVERY_DIAGNOSTIC_ARCHIVE_PATH_MISSING' }
  $archiveDirectory = $archiveLine[0].Substring('HOST_RECOVERY_DIAGNOSTICS_ARCHIVED='.Length)
  if (-not $archiveDirectory.StartsWith($recoveryEvidenceData, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HOST_RECOVERY_DIAGNOSTIC_ARCHIVE_OUTSIDE_PRODUCT_EVIDENCE'
  }

  $archivedRecord = Join-Path (Join-Path $archiveDirectory 'ProvisioningDiagnostics') $recordName
  if (-not (Test-Path -LiteralPath $archivedRecord -PathType Leaf) -or
      (Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).Hash -cne
        (Get-FileHash -LiteralPath $archivedRecord -Algorithm SHA256).Hash -or
      -not (Test-ProtectedRecoveryRecordAcl $archivedRecord)) {
    throw 'HOST_RECOVERY_DIAGNOSTIC_ARCHIVE_CONTENT_OR_ACL_INVALID'
  }
  $manifest = Get-Content -LiteralPath (Join-Path $archiveDirectory 'manifest.json') -Raw | ConvertFrom-Json
  if ($manifest.formatVersion -ne 1 -or $manifest.files.Count -ne 1 -or
      $manifest.files[0].name -cne $recordName) {
    throw 'HOST_RECOVERY_DIAGNOSTIC_ARCHIVE_MANIFEST_INVALID'
  }
  Write-Output 'HOST_PARTIAL_INSTALLATION_STATE_TEST_PASS'
  Write-Output 'HOST_DIAGNOSTIC_ARCHIVE_TEST_PASS'

  [IO.File]::WriteAllText(
    $recordPath,
    '{"failureCode":"HOST_UNRECOGNIZED_FAILURE"}',
    [Text.UTF8Encoding]::new($false)
  )
  try {
    Assert-PostgresOnlyFailedInstallation
    throw 'HOST_REMOVAL_ACCEPTED_UNRECOGNIZED_PARTIAL_INSTALLATION'
  } catch {
    if ($_.Exception.Message -notmatch '^HOST_PARTIAL_INSTALLATION_FAILURE_NOT_RECOGNIZED$') { throw }
  }
  Write-Output 'HOST_UNRECOGNIZED_PARTIAL_INSTALLATION_REJECTED_PASS'
} finally {
  $resolvedTempRoot = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)).TrimEnd('\') + '\'
  $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
  if (-not $resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetFileName($resolvedTestRoot) -notmatch '^VentioRemovalTest-[0-9a-f]{32}$') {
    throw 'HOST_REMOVAL_TEST_CLEANUP_PATH_INVALID'
  }
  if (Test-Path -LiteralPath $resolvedTestRoot) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}
