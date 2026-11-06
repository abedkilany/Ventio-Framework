param(
  [string] $PayloadDirectory = (Join-Path $env:ProgramFiles 'Ventio\host-payload'),
  [switch] $AllowPostgresOnlyRecovery,
  [switch] $ResumePostgresOnly,
  [switch] $ResumeServices,
  [switch] $KeepHostRecoveryPolicySuppressed,
  [switch] $RestoreHostFailureActions,
  [string] $FailureCodePath
)

$ErrorActionPreference = 'Stop'
$payload = [IO.Path]::GetFullPath($PayloadDirectory)
$expectedPayload = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio\host-payload'))
$programData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
$dataDirectory = [IO.Path]::GetFullPath((Join-Path $programData 'Ventio\PostgreSQL\data'))
$installerStateDirectory = Join-Path $programData 'Ventio\Installer'
$hostConfigurationDirectory = Join-Path $programData 'Ventio\Host'
$script:VentioStopHostServicesStage = 'PREINSTALL_HELPER_INITIALIZATION'
$script:VentioStopHostServicesDiagnosticStage = $null

function Write-VentioPreinstallFailure([string] $Code, [string] $Stage) {
  if ([string]::IsNullOrWhiteSpace($FailureCodePath)) { return }
  if ($Code -notmatch '^HOST_[A-Z0-9_]{1,100}$') { $Code = 'HOST_PREINSTALL_UNEXPECTED_FAILURE' }
  if ($Stage -notmatch '^[A-Z0-9_]{1,100}$') { $Stage = 'PREINSTALL_HELPER' }
  try {
    $diagnosticLines = [string[]]::new(2)
    $diagnosticLines[0] = 'Code=' + $Code
    $diagnosticLines[1] = 'Stage=' + $Stage
    [IO.File]::WriteAllLines($FailureCodePath, $diagnosticLines, [Text.UTF8Encoding]::new($false))
  } catch { }
}

trap {
  $failureCode = 'HOST_PREINSTALL_UNEXPECTED_FAILURE'
  $message = [string]$_.Exception.Message
  if ($message -cmatch '^HOST_[A-Z0-9_]{1,100}$') { $failureCode = $message }
  $failureStage = [string]$script:VentioStopHostServicesStage
  if (-not [string]::IsNullOrWhiteSpace([string]$script:VentioStopHostServicesDiagnosticStage)) {
    $failureStage = [string]$script:VentioStopHostServicesDiagnosticStage
  } elseif ($failureStage -ceq 'SERVICE_RECOVERY_MAINTENANCE') {
    try {
      $moduleStage = [string](Get-VentioHostServiceRecoveryStage)
      if ($moduleStage -match '^[A-Z0-9_]{1,100}$') { $failureStage = $moduleStage }
    } catch { }
  }
  Write-VentioPreinstallFailure $failureCode $failureStage
  exit 1
}

$serviceRecoveryPolicyModule = Join-Path $PSScriptRoot 'HostServiceRecoveryPolicy.psm1'
$script:VentioStopHostServicesStage = 'HELPER_IMPORT_VALIDATION'
if (-not (Test-Path -LiteralPath $serviceRecoveryPolicyModule -PathType Leaf)) {
  throw 'HOST_SERVICE_RECOVERY_POLICY_HELPER_MISSING'
}
Import-Module $serviceRecoveryPolicyModule -Force
$script:VentioStopHostServicesStage = 'HELPER_READY'

if (($ResumeServices -and $ResumePostgresOnly) -or
    ($KeepHostRecoveryPolicySuppressed -and -not $ResumePostgresOnly) -or
    ($RestoreHostFailureActions -and $KeepHostRecoveryPolicySuppressed)) {
  throw 'HOST_SERVICE_RECOVERY_ARGUMENTS_INVALID'
}

function Test-ProtectedRecoveryRecordAcl([string] $Path) {
  try {
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $allowedSids = @('S-1-5-32-544', 'S-1-5-18', $ownerSid) | Select-Object -Unique
    $rules = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -lt 2) { return $false }
    foreach ($rule in $rules) {
      if ($rule.IdentityReference.Value -notin $allowedSids -or
          $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
          $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl) { return $false }
    }
    $ruleSids = @($rules | ForEach-Object { $_.IdentityReference.Value })
    return ('S-1-5-32-544' -in $ruleSids) -and ('S-1-5-18' -in $ruleSids)
  } catch {
    return $false
  }
}

function Assert-NoRecoveryReparseAncestors([string] $Path, [string] $Boundary) {
  $current = [IO.Path]::GetFullPath($Path)
  $boundaryPath = [IO.Path]::GetFullPath($Boundary).TrimEnd('\')
  while ($current.Equals($boundaryPath, [StringComparison]::OrdinalIgnoreCase) -or
      $current.StartsWith($boundaryPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'HOST_RECOVERY_REPARSE_POINT' }
    }
    if ($current.Equals($boundaryPath, [StringComparison]::OrdinalIgnoreCase)) { return }
    $parent = [IO.Directory]::GetParent($current)
    if ($null -eq $parent -or $parent.FullName -eq $current) { break }
    $current = $parent.FullName
  }
  throw 'HOST_RECOVERY_PATH_OUTSIDE_BOUNDARY'
}

function Assert-IncompleteHostRecoveryState {
  if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -PathType Leaf) -or
      (Get-Content -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -Raw).Trim() -ne '16') {
    throw 'HOST_RECOVERY_CLUSTER_VERSION_INVALID'
  }
  Assert-NoRecoveryReparseAncestors $dataDirectory $programData
  if (Test-Path -LiteralPath $hostConfigurationDirectory) {
    $configurationEntries = @(Get-ChildItem -LiteralPath $hostConfigurationDirectory -Force)
    if ($configurationEntries.Count -gt 0) { throw 'HOST_RECOVERY_CONFIGURATION_ALREADY_EXISTS' }
  }
  if (-not (Test-Path -LiteralPath $installerStateDirectory -PathType Container)) { throw 'HOST_RECOVERY_INSTALLER_STATE_MISSING' }
  $entries = @(Get-ChildItem -LiteralPath $installerStateDirectory -Force)
  if ($entries.Count -lt 1 -or $entries.Count -gt 2) { throw 'HOST_RECOVERY_INSTALLER_STATE_INVALID' }
  $diagnosticsDirectory = Join-Path $installerStateDirectory 'ProvisioningDiagnostics'
  $migrationCredentialFile = Join-Path $installerStateDirectory 'migration-credential.dpapi'
  if (-not (Test-Path -LiteralPath $diagnosticsDirectory -PathType Container) -or
      -not (Test-ProtectedRecoveryRecordAcl $diagnosticsDirectory)) {
    throw 'HOST_RECOVERY_INSTALLER_STATE_INVALID'
  }
  foreach ($entry in $entries) {
    if ($entry.Name -cne 'ProvisioningDiagnostics' -and $entry.Name -cne 'migration-credential.dpapi') {
      throw 'HOST_RECOVERY_INSTALLER_STATE_INVALID'
    }
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'HOST_RECOVERY_INSTALLER_STATE_INVALID' }
  }
  $diagnosticRecords = @(Get-ChildItem -LiteralPath $diagnosticsDirectory -Force)
  if ($diagnosticRecords.Count -lt 1 -or $diagnosticRecords.Count -gt 256) { throw 'HOST_RECOVERY_DIAGNOSTICS_INVALID' }
  foreach ($record in $diagnosticRecords) {
    if ($record.PSIsContainer -or $record.Name -notmatch '^host-provisioning-\d{8}T\d{9}Z-[0-9a-f]{32}\.json$' -or
        $record.Length -gt 8192 -or ($record.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not (Test-ProtectedRecoveryRecordAcl $record.FullName)) {
      throw 'HOST_RECOVERY_DIAGNOSTICS_INVALID'
    }
  }
  if (Test-Path -LiteralPath $migrationCredentialFile -PathType Leaf) {
    if ($entries.Count -ne 2 -or
        (Get-Item -LiteralPath $migrationCredentialFile -ErrorAction Stop).Length -gt 4096 -or
        -not (Test-ProtectedRecoveryRecordAcl $migrationCredentialFile)) {
      throw 'HOST_RECOVERY_INSTALLER_STATE_INVALID'
    }
    $credentialModule = Join-Path $PSScriptRoot 'HostMigrationCredential.psm1'
    if (-not (Test-Path -LiteralPath $credentialModule -PathType Leaf)) { throw 'HOST_RECOVERY_CREDENTIAL_MODULE_MISSING' }
    Import-Module $credentialModule -Force
    $credential = Read-HostMigrationCredential -OutputDirectory $installerStateDirectory
    if ($credential.Password) { $credential.Password.Dispose() }
    $credential = $null
    return
  }

  $recognizedLedgerFailure = $false
  foreach ($record in $diagnosticRecords) {
    $document = Get-Content -LiteralPath $record.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
    if ([string]$document.phase -ceq 'DATABASE_INITIALIZATION' -and
        [string]$document.failureCode -ceq 'HOST_DATABASE_MIGRATION_LEDGER_INVALID' -and
        [string]$document.scriptName -ceq 'initialize-host-database.ps1') {
      $recognizedLedgerFailure = $true
    }
  }
  if ($entries.Count -ne 1 -or -not $recognizedLedgerFailure) {
    throw 'HOST_RECOVERY_INSTALLER_STATE_INVALID'
  }
}

function Get-ValidatedService([string] $Name, [string] $Account, [string] $Executable, [string] $DataPath) {
  try { $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction Stop }
  catch { throw 'HOST_SERVICE_IDENTITY_QUERY_FAILED' }
  if ($null -eq $service) { return $null }
  if ($service.StartName -cne $Account -or $service.PathName -notmatch [regex]::Escape($Executable) -or
      ($DataPath -and $service.PathName -notmatch [regex]::Escape($DataPath))) {
    throw 'HOST_SERVICE_IDENTITY_CONFLICT'
  }
  return $service
}

function Stop-ValidatedService([string] $Name) {
  try { $service = Get-Service -Name $Name -ErrorAction Stop }
  catch { throw 'HOST_SERVICE_STATUS_QUERY_FAILED' }
  if ($service.Status -eq 'Stopped') { return }
  try { Stop-Service -Name $Name -Force -ErrorAction Stop }
  catch { throw 'HOST_SERVICE_STOP_FAILED' }
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  while ($true) {
    try { $status = (Get-Service -Name $Name -ErrorAction Stop).Status }
    catch { throw 'HOST_SERVICE_STATUS_QUERY_FAILED' }
    if ($status -eq 'Stopped') { break }
    if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_SERVICE_STOP_TIMEOUT' }
    Start-Sleep -Milliseconds 500
  }
}

function Start-ValidatedPostgresService {
  if ((Get-Service -Name 'VentioPostgres' -ErrorAction Stop).Status -ne 'Running') {
    Start-Service -Name 'VentioPostgres' -ErrorAction Stop
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  while ((Get-Service -Name 'VentioPostgres' -ErrorAction Stop).Status -ne 'Running') {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_POSTGRES_RESTART_TIMEOUT' }
    Start-Sleep -Milliseconds 500
  }
}

function Start-ValidatedHostService {
  if ((Get-Service -Name 'VentioHost' -ErrorAction Stop).Status -ne 'Running') {
    Start-Service -Name 'VentioHost' -ErrorAction Stop
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  while ((Get-Service -Name 'VentioHost' -ErrorAction Stop).Status -ne 'Running') {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_SERVICE_RESTART_TIMEOUT' }
    Start-Sleep -Milliseconds 500
  }
}

$script:VentioStopHostServicesStage = 'PAYLOAD_PATH_VALIDATION'
if (-not $payload.Equals($expectedPayload, [StringComparison]::OrdinalIgnoreCase)) { throw 'HOST_PAYLOAD_PATH_INVALID' }
$script:VentioStopHostServicesStage = 'SERVICE_IDENTITY_VALIDATION'
$postgres = Get-ValidatedService 'VentioPostgres' 'NT SERVICE\VentioPostgres' `
  (Join-Path $payload 'postgresql\bin\pg_ctl.exe') $dataDirectory
$hostService = Get-ValidatedService 'VentioHost' 'NT SERVICE\VentioHost' `
  (Join-Path $payload 'VentioHostService.exe') $null
if ($ResumeServices) {
  if (-not $postgres -or -not $hostService) { throw 'HOST_SERVICE_PAIR_REQUIRED_FOR_RESUME' }
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'HOST_SERVICE_ADMIN_ELEVATION_REQUIRED' }
  if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -PathType Leaf) -or
      (Get-Content -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -Raw).Trim() -ne '16' -or
      -not (Test-Path -LiteralPath (Join-Path $hostConfigurationDirectory 'service-config.dpapi') -PathType Leaf)) {
    throw 'HOST_SERVICE_RESUME_STATE_INVALID'
  }
  Assert-NoRecoveryReparseAncestors $dataDirectory $programData
  try {
    Start-ValidatedPostgresService
    Start-ValidatedHostService
  } finally {
    Restore-VentioHostServiceFailureActions $hostService
  }
  Write-Output 'HOST_SERVICES_RESUMED_AFTER_INSTALL'
  return
}
if ($ResumePostgresOnly) {
  if (-not $postgres) { Write-Output 'HOST_POSTGRES_NOT_INSTALLED'; return }
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'HOST_SERVICE_ADMIN_ELEVATION_REQUIRED' }
  if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -PathType Leaf) -or
      (Get-Content -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -Raw).Trim() -ne '16') {
    throw 'HOST_POSTGRES_RESTART_CLUSTER_INVALID'
  }
  Assert-NoRecoveryReparseAncestors $dataDirectory $programData
  if ($hostService) { Stop-ValidatedService 'VentioHost' }
  if (-not $KeepHostRecoveryPolicySuppressed) {
    if ($hostService) { Restore-VentioHostServiceFailureActions $hostService }
  }
  Start-ValidatedPostgresService
  Write-Output 'HOST_POSTGRES_RESUMED_AFTER_INCOMPLETE_INSTALL'
  return
}
if ($RestoreHostFailureActions) {
  if (-not $hostService) { throw 'HOST_SERVICE_RECOVERY_HOST_SERVICE_MISSING' }
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'HOST_SERVICE_ADMIN_ELEVATION_REQUIRED' }
  Restore-VentioHostServiceFailureActions $hostService
  Write-Output 'HOST_SERVICE_RECOVERY_POLICY_RESTORED'
  return
}
if (($null -eq $postgres) -xor ($null -eq $hostService)) {
  if (-not $AllowPostgresOnlyRecovery -or $null -eq $postgres -or $null -ne $hostService) {
    throw 'HOST_PARTIAL_SERVICE_INSTALLATION'
  }
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'HOST_SERVICE_ADMIN_ELEVATION_REQUIRED' }
  Assert-IncompleteHostRecoveryState
  Stop-ValidatedService 'VentioPostgres'
  Write-Output 'HOST_POSTGRES_STOPPED_FOR_INCOMPLETE_INSTALL_RECOVERY'
  return
}
if (-not $postgres) {
  Write-Output 'HOST_SERVICES_NOT_INSTALLED'
  return
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$script:VentioStopHostServicesStage = 'ADMINISTRATOR_TOKEN_VALIDATION'
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'HOST_SERVICE_ADMIN_ELEVATION_REQUIRED' }

try {
  $script:VentioStopHostServicesStage = 'SERVICE_RECOVERY_MAINTENANCE'
  [void](Start-VentioHostServiceMaintenance $hostService $installerStateDirectory)
  $script:VentioStopHostServicesStage = 'POSTGRES_SERVICE_STOP'
  Stop-ValidatedService 'VentioPostgres'
} catch {
  if ($script:VentioStopHostServicesStage -ceq 'SERVICE_RECOVERY_MAINTENANCE') {
    try { $script:VentioStopHostServicesDiagnosticStage = [string](Get-VentioHostServiceRecoveryStage) }
    catch { $script:VentioStopHostServicesDiagnosticStage = 'SERVICE_RECOVERY_MAINTENANCE' }
  }
  $script:VentioStopHostServicesStage = 'SERVICE_RECOVERY_ROLLBACK'
  try {
    Restore-VentioHostServiceFailureActions $hostService
  } catch {
    $script:VentioStopHostServicesDiagnosticStage = 'SERVICE_RECOVERY_POLICY_ROLLBACK'
    throw 'HOST_SERVICE_RECOVERY_POLICY_ROLLBACK_FAILED'
  }
  throw
}
Write-Output 'HOST_SERVICES_STOPPED_FOR_UPGRADE'
