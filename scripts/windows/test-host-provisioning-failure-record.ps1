$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$sourcePath = Join-Path $repoRoot 'scripts\windows\provision-host-installation.ps1'
$tokens = $null
$parseErrors = $null
$sourceAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Host provisioning script contains PowerShell syntax errors.' }

$functionAst = $sourceAst.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Write-HostProvisioningFailureRecord'
}, $true)
if ($null -eq $functionAst) { throw 'Protected provisioning diagnostic writer was not found.' }
. ([scriptblock]::Create($functionAst.Extent.Text))
$aclFunctionAst = $sourceAst.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Test-HostProtectedInstallerRecordAcl'
}, $true)
$stateFunctionAst = $sourceAst.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Test-HostInstallerStateForResume'
}, $true)
if ($null -eq $aclFunctionAst -or $null -eq $stateFunctionAst) {
  throw 'Safe Host installer-state validation functions were not found.'
}
. ([scriptblock]::Create($aclFunctionAst.Extent.Text))
. ([scriptblock]::Create($stateFunctionAst.Extent.Text))

$testRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ventio-host-provisioning-diagnostics-test-' + [guid]::NewGuid().ToString('N'))))
$diagnosticsDirectory = Join-Path $testRoot 'Installer\ProvisioningDiagnostics'
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ventio-host-provisioning-diagnostics-test-'

try {
  [void][IO.Directory]::CreateDirectory($testRoot)
  $expectedCode = 'POSTGRES_SERVICE_SID_CONFIGURATION_FAILED'
  $secretToken = 'A' * 48
  $detailText = "initdb: could not open password file $secretToken : Access denied. password=short-secret"
  $failure = [System.Management.Automation.ErrorRecord]::new(
    [InvalidOperationException]::new($expectedCode),
    $expectedCode,
    [Management.Automation.ErrorCategory]::InvalidOperation,
    $null)
  $recordPath = Write-HostProvisioningFailureRecord -DataRoot $testRoot `
    -DiagnosticsDirectory $diagnosticsDirectory -Phase 'POSTGRES_SERVICE_PROVISIONING' `
    -Failure $failure -Detail $detailText
  if (-not $recordPath -or -not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
    throw 'Protected provisioning diagnostic record was not created.'
  }

  $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
  if ($record.failureCode -ne $expectedCode -or $record.phase -ne 'POSTGRES_SERVICE_PROVISIONING') {
    throw 'Provisioning diagnostic record omitted the sanitized failure code or phase.'
  }
  $serialized = Get-Content -LiteralPath $recordPath -Raw
  if ($record.detail -notmatch 'could not open password file \[REDACTED_TOKEN\]' -or
      $record.detail -notmatch 'password=\[REDACTED\]' -or
      $serialized.Contains($secretToken) -or $serialized.Contains('short-secret')) {
    throw 'Provisioning diagnostic record did not redact sensitive error details.'
  }
  if (@($record.PSObject.Properties.Name | Where-Object { $_ -match '^(message|stackTrace|secret|password|token)$' }).Count -gt 0) {
    throw 'Provisioning diagnostic record contains a forbidden sensitive field.'
  }

  $migrationCredentialPath = Join-Path (Split-Path -Parent $diagnosticsDirectory) 'migration-credential.dpapi'
  [IO.File]::WriteAllBytes($migrationCredentialPath, [byte[]]@(1, 2, 3, 4))
  $migrationCredentialSecurity = [Security.AccessControl.FileSecurity]::new()
  $migrationCredentialSecurity.SetAccessRuleProtection($true, $false)
  $migrationOwner = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $migrationCredentialSecurity.SetOwner($migrationOwner)
  foreach ($sidValue in @('S-1-5-32-544', 'S-1-5-18', $migrationOwner.Value)) {
    $migrationCredentialSecurity.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      [Security.Principal.SecurityIdentifier]::new($sidValue),
      [Security.AccessControl.FileSystemRights]::FullControl,
      [Security.AccessControl.AccessControlType]::Allow))
  }
  Set-Acl -LiteralPath $migrationCredentialPath -AclObject $migrationCredentialSecurity

  $fallbackSecret = 'B' * 48
  $fallbackFailure = [System.Management.Automation.ErrorRecord]::new(
    [InvalidOperationException]::new("Configuration write failed; password=another-secret token=$fallbackSecret"),
    'CONFIG_WRITE_EXCEPTION',
    [Management.Automation.ErrorCategory]::WriteError,
    $null)
  $fallbackTestRoot = Join-Path $testRoot 'Fallback'
  $fallbackDiagnosticsDirectory = Join-Path $fallbackTestRoot 'Installer\ProvisioningDiagnostics'
  [void][IO.Directory]::CreateDirectory($fallbackTestRoot)
  $fallbackRecordPath = Write-HostProvisioningFailureRecord -DataRoot $fallbackTestRoot `
    -DiagnosticsDirectory $fallbackDiagnosticsDirectory -Phase 'HOST_CONFIGURATION_PROTECTION' `
    -Failure $fallbackFailure -Detail ''
  $fallbackRecord = Get-Content -LiteralPath $fallbackRecordPath -Raw | ConvertFrom-Json
  $fallbackSerialized = Get-Content -LiteralPath $fallbackRecordPath -Raw
  if ($fallbackRecord.detail -notmatch 'Configuration write failed' -or
      $fallbackRecord.detail -notmatch 'password=\[REDACTED\]' -or
      $fallbackSerialized.Contains($fallbackSecret) -or
      $fallbackSerialized.Contains('another-secret')) {
    throw 'Provisioning diagnostic fallback detail was missing or failed to redact secrets.'
  }

  $recoveryFailureCode = 'HOST_DATABASE_RECOVERY_MIGRATION_LEDGER_QUERY_FAILED'
  $recoveryFailure = [System.Management.Automation.ErrorRecord]::new(
    [InvalidOperationException]::new($recoveryFailureCode),
    $recoveryFailureCode,
    [Management.Automation.ErrorCategory]::InvalidOperation,
    $null)
  $recoveryTestRoot = Join-Path $testRoot 'RecoveryCode'
  $recoveryDiagnosticsDirectory = Join-Path $recoveryTestRoot 'Installer\ProvisioningDiagnostics'
  [void][IO.Directory]::CreateDirectory($recoveryTestRoot)
  $recoveryRecordPath = Write-HostProvisioningFailureRecord -DataRoot $recoveryTestRoot `
    -DiagnosticsDirectory $recoveryDiagnosticsDirectory -Phase 'DATABASE_ROLE_CREDENTIAL_RECOVERY' `
    -Failure $recoveryFailure -Detail ''
  $recoveryRecord = Get-Content -LiteralPath $recoveryRecordPath -Raw | ConvertFrom-Json
  if ($recoveryRecord.failureCode -cne $recoveryFailureCode -or
      $recoveryRecord.detail -cne $recoveryFailureCode) {
    throw 'Provisioning diagnostics redacted a safe classified failure code.'
  }

  $directoryAcl = Get-Acl -LiteralPath $diagnosticsDirectory
  $fileAcl = Get-Acl -LiteralPath $recordPath
  if (-not $directoryAcl.AreAccessRulesProtected -or -not $fileAcl.AreAccessRulesProtected) {
    throw 'Provisioning diagnostic storage inherited unprotected access rules.'
  }
  $allowedSids = @(
    'S-1-5-32-544',
    'S-1-5-18',
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  )
  foreach ($acl in @($directoryAcl, $fileAcl)) {
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
      if ($rule.IdentityReference.Value -notin $allowedSids -or
          $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
        throw 'Provisioning diagnostic storage contains an unexpected access rule.'
      }
    }
  }

  if (-not (Test-HostInstallerStateForResume -DataRoot $testRoot -InstallerStateDirectory (Join-Path $testRoot 'Installer'))) {
    throw 'Protected diagnostics and migration-credential installer state was rejected for safe resumption.'
  }

  $unexpectedState = Join-Path $testRoot 'Installer\unrelated-state.json'
  [IO.File]::WriteAllText($unexpectedState, '{}', [Text.UTF8Encoding]::new($false))
  if (Test-HostInstallerStateForResume -DataRoot $testRoot -InstallerStateDirectory (Join-Path $testRoot 'Installer')) {
    throw 'Host installer-state validation accepted unexpected state beside diagnostics.'
  }
  Remove-Item -LiteralPath $unexpectedState -Force

  $unexpectedRecord = Join-Path $diagnosticsDirectory 'unrecognized-diagnostic.txt'
  [IO.File]::WriteAllText($unexpectedRecord, 'preserve', [Text.UTF8Encoding]::new($false))
  if (Test-HostInstallerStateForResume -DataRoot $testRoot -InstallerStateDirectory (Join-Path $testRoot 'Installer')) {
    throw 'Host installer-state validation accepted an unrecognized diagnostics file.'
  }
  Remove-Item -LiteralPath $unexpectedRecord -Force

  $missingState = Join-Path $testRoot 'MissingInstaller'
  if (-not (Test-HostInstallerStateForResume -DataRoot $testRoot -InstallerStateDirectory $missingState)) {
    throw 'Host installer-state validation rejected an absent installer-state directory.'
  }

  $outsidePath = Join-Path ([IO.Path]::GetTempPath()) ('ventio-outside-' + [guid]::NewGuid().ToString('N'))
  $outsideRecord = Write-HostProvisioningFailureRecord -DataRoot $testRoot `
    -DiagnosticsDirectory $outsidePath -Phase 'TEST' -Failure $failure
  if ($outsideRecord -or (Test-Path -LiteralPath $outsidePath)) {
    throw 'Provisioning diagnostic writer accepted a path outside its approved data root.'
  }

  Write-Output 'Host provisioning diagnostics tests passed: redaction, protected ACLs, path boundary, and safe resume state.'
}
finally {
  if ($testRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $testRoot) -match '^ventio-host-provisioning-diagnostics-test-[0-9a-f]{32}$' -and
      (Test-Path -LiteralPath $testRoot)) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
}
