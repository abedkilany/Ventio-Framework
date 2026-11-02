param(
  [string] $PayloadDirectory = (Join-Path $env:ProgramFiles 'Ventio\host-payload'),
  [switch] $AllowPostgresOnlyRecovery,
  [switch] $ResumePostgresOnly,
  [switch] $ResumeServices
)

$ErrorActionPreference = 'Stop'
$payload = [IO.Path]::GetFullPath($PayloadDirectory)
$expectedPayload = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio\host-payload'))
$programData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
$dataDirectory = [IO.Path]::GetFullPath((Join-Path $programData 'Ventio\PostgreSQL\data'))
$installerStateDirectory = Join-Path $programData 'Ventio\Installer'
$hostConfigurationDirectory = Join-Path $programData 'Ventio\Host'

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
      -not (Test-Path -LiteralPath $migrationCredentialFile -PathType Leaf) -or
      -not (Test-ProtectedRecoveryRecordAcl $diagnosticsDirectory) -or
      -not (Test-ProtectedRecoveryRecordAcl $migrationCredentialFile)) {
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
  $credentialModule = Join-Path $PSScriptRoot 'HostMigrationCredential.psm1'
  if (-not (Test-Path -LiteralPath $credentialModule -PathType Leaf)) { throw 'HOST_RECOVERY_CREDENTIAL_MODULE_MISSING' }
  Import-Module $credentialModule -Force
  $credential = Read-HostMigrationCredential -OutputDirectory $installerStateDirectory
  if ($credential.Password) { $credential.Password.Dispose() }
  $credential = $null
}

function Get-ValidatedService([string] $Name, [string] $Account, [string] $Executable, [string] $DataPath) {
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
  if ($null -eq $service) { return $null }
  if ($service.StartName -cne $Account -or $service.PathName -notmatch [regex]::Escape($Executable) -or
      ($DataPath -and $service.PathName -notmatch [regex]::Escape($DataPath))) {
    throw 'HOST_SERVICE_IDENTITY_CONFLICT'
  }
  return $service
}

function Stop-ValidatedService([string] $Name) {
  $service = Get-Service -Name $Name -ErrorAction Stop
  if ($service.Status -eq 'Stopped') { return }
  Stop-Service -Name $Name -Force -ErrorAction Stop
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  while ((Get-Service -Name $Name).Status -ne 'Stopped') {
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

if (-not $payload.Equals($expectedPayload, [StringComparison]::OrdinalIgnoreCase)) { throw 'HOST_PAYLOAD_PATH_INVALID' }
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
  Start-ValidatedPostgresService
  Start-ValidatedHostService
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
  Start-ValidatedPostgresService
  Write-Output 'HOST_POSTGRES_RESUMED_AFTER_INCOMPLETE_INSTALL'
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
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'HOST_SERVICE_ADMIN_ELEVATION_REQUIRED' }

Stop-ValidatedService 'VentioHost'
Stop-ValidatedService 'VentioPostgres'
Write-Output 'HOST_SERVICES_STOPPED_FOR_UPGRADE'
