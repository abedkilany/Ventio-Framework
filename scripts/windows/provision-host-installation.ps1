param(
  [string] $PayloadDirectory = (Join-Path $env:ProgramFiles 'Ventio\host-payload'),
  [switch] $Apply,
  [switch] $NewHostOnly
)

$ErrorActionPreference = 'Stop'
$payload = [IO.Path]::GetFullPath($PayloadDirectory)
$expectedPayload = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio\host-payload'))
$programData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
$port = 54329
$hostPort = 8080
$databaseDirectory = Join-Path $programData 'Ventio\PostgreSQL\data'
$hostConfigurationDirectory = Join-Path $programData 'Ventio\Host'
$installerStateDirectory = Join-Path $programData 'Ventio\Installer'
$postgresServiceName = 'VentioPostgres'
$hostServiceName = 'VentioHost'
$setupDirectory = Join-Path $payload 'setup'
$postgresProvisioner = Join-Path $setupDirectory 'provision-postgres-service.ps1'
$databaseInitializer = Join-Path $setupDirectory 'initialize-host-database.ps1'
$hostServiceRegistrar = Join-Path $setupDirectory 'register-host-service.ps1'
$hostConfigWriter = Join-Path $setupDirectory 'write-host-service-config.ps1'
$hostLanListener = Join-Path $setupDirectory 'enable-host-lan-listener.ps1'
$migrationCredentialModule = Join-Path $setupDirectory 'HostMigrationCredential.psm1'
$productDataRootModule = Join-Path $setupDirectory 'HostProductDataRoot.psm1'
$databaseCredentialRecovery = Join-Path $setupDirectory 'recover-host-database-credentials.ps1'
$databaseUpgrade = Join-Path $setupDirectory 'upgrade-host-database.ps1'
$phase = 'PAYLOAD_VALIDATION'

function Test-ProductService([string] $Name, [string] $ExpectedAccount, [string] $ExpectedExecutable, [string] $ExpectedDataPath) {
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
  if ($null -eq $service) { return $null }
  if ($service.StartName -cne $ExpectedAccount -or
      $service.PathName -notmatch [regex]::Escape($ExpectedExecutable) -or
      ($ExpectedDataPath -and $service.PathName -notmatch [regex]::Escape($ExpectedDataPath))) {
    throw 'HOST_SERVICE_IDENTITY_CONFLICT'
  }
  return $service
}

function New-SetupCredential([string] $UserName, [int] $ByteCount) {
  $bytes = [byte[]]::new($ByteCount)
  $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $generator.GetBytes($bytes)
    $password = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    return [PSCredential]::new($UserName, $securePassword)
  } finally {
    [Array]::Clear($bytes, 0, $bytes.Length)
    $password = $null
    $generator.Dispose()
  }
}

function Wait-ProductService([string] $Name, [string] $ExpectedState) {
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  while ($true) {
    $service = Get-Service -Name $Name -ErrorAction Stop
    if ($service.Status.ToString() -eq $ExpectedState) { return }
    if ($ExpectedState -eq 'Running' -and $service.Status.ToString() -eq 'Stopped') {
      throw 'HOST_SERVICE_START_FAILED'
    }
    if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_SERVICE_READINESS_TIMEOUT' }
    Start-Sleep -Milliseconds 500
  }
}

function Write-HostProvisioningFailureRecord(
  [string] $DataRoot,
  [string] $DiagnosticsDirectory,
  [string] $Phase,
  [System.Management.Automation.ErrorRecord] $Failure,
  [string] $Detail
) {
  try {
    $boundary = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
    $directory = [IO.Path]::GetFullPath($DiagnosticsDirectory)
    if (-not $directory.StartsWith($boundary + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $current = $directory
    while ($true) {
      if (Test-Path -LiteralPath $current) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
      }
      if ($current.Equals($boundary, [StringComparison]::OrdinalIgnoreCase)) { break }
      $parent = [IO.Directory]::GetParent($current)
      if ($null -eq $parent) { return $null }
      $current = $parent.FullName
    }

    [void][IO.Directory]::CreateDirectory($directory)
    $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $ownerSid) { return $null }
    $allowedSids = @('S-1-5-32-544', 'S-1-5-18', $ownerSid.Value) | Select-Object -Unique
    $directorySecurity = [Security.AccessControl.DirectorySecurity]::new()
    $directorySecurity.SetAccessRuleProtection($true, $false)
    $directorySecurity.SetOwner($ownerSid)
    foreach ($sidValue in $allowedSids) {
      $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
      $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $sid,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow)
      $directorySecurity.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $directory -AclObject $directorySecurity

    $safePhase = if ($Phase -match '^[A-Z0-9_]{1,64}$') { $Phase } else { 'UNKNOWN' }
    $errorCode = 'UNCLASSIFIED_ERROR'
    $candidateCode = [string]$Failure.Exception.Message
    if ($candidateCode -match '^(HOST|POSTGRES)_[A-Z0-9_]{1,96}$') { $errorCode = $candidateCode }
    $detailSource = [string]$Detail
    if ([string]::IsNullOrWhiteSpace($detailSource)) { $detailSource = [string]$Failure.Exception.Message }
    $safeDetail = [regex]::Replace($detailSource, '[\x00-\x1f\x7f]+', ' ')
    $safeDetail = [regex]::Replace($safeDetail, '(?i)\b(password|token|credential)\s*[:=]\s*[^ ,;]+', '$1=[REDACTED]')
    if ($safeDetail -notmatch '^(HOST|POSTGRES)_[A-Z0-9_]{1,96}$') {
      $safeDetail = [regex]::Replace($safeDetail, '(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{24,}(?![A-Za-z0-9_-])', '[REDACTED_TOKEN]')
    }
    $safeDetail = [regex]::Replace($safeDetail, '\s{2,}', ' ').Trim()
    if ($safeDetail.Length -gt 1024) { $safeDetail = $safeDetail.Substring($safeDetail.Length - 1024) }
    $exceptionType = $Failure.Exception.GetType().Name
    if ($exceptionType -notmatch '^[A-Za-z][A-Za-z0-9]{0,63}$') { $exceptionType = 'Unknown' }
    $scriptName = [IO.Path]::GetFileName([string]$Failure.InvocationInfo.ScriptName)
    if ($scriptName -notmatch '^[A-Za-z0-9_.-]{1,100}$') { $scriptName = 'Unknown' }
    $lineNumber = [Math]::Max(0, [int]$Failure.InvocationInfo.ScriptLineNumber)
    $record = [ordered]@{
      timestampUtc = [DateTime]::UtcNow.ToString('o')
      phase = $safePhase
      failureCode = $errorCode
      detail = $safeDetail
      exceptionType = $exceptionType
      scriptName = $scriptName
      lineNumber = $lineNumber
    }
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture)
    $recordPath = Join-Path $directory ('host-provisioning-' + $timestamp + '-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json -Depth 3 -Compress), [Text.UTF8Encoding]::new($false))

    $fileSecurity = [Security.AccessControl.FileSecurity]::new()
    $fileSecurity.SetAccessRuleProtection($true, $false)
    $fileSecurity.SetOwner($ownerSid)
    foreach ($sidValue in $allowedSids) {
      $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
      $fileSecurity.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $recordPath -AclObject $fileSecurity
    return $recordPath
  } catch {
    return $null
  }
}

function Test-HostProtectedInstallerRecordAcl([string] $Path) {
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
          $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl) {
        return $false
      }
    }
    $ruleSids = @($rules | ForEach-Object { $_.IdentityReference.Value })
    return ('S-1-5-32-544' -in $ruleSids) -and ('S-1-5-18' -in $ruleSids)
  } catch {
    return $false
  }
}

function Test-HostInstallerStateForResume([string] $DataRoot, [string] $InstallerStateDirectory) {
  try {
    $boundary = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
    $directory = [IO.Path]::GetFullPath($InstallerStateDirectory).TrimEnd('\')
    if (-not $directory.StartsWith($boundary + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not (Test-Path -LiteralPath $directory)) { return $true }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return $false }

    $current = $directory
    while ($true) {
      if (Test-Path -LiteralPath $current) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
      }
      if ($current.Equals($boundary, [StringComparison]::OrdinalIgnoreCase)) { break }
      $parent = [IO.Directory]::GetParent($current)
      if ($null -eq $parent) { return $false }
      $current = $parent.FullName
    }

    $stateEntries = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
    if ($stateEntries.Count -eq 0) { return $true }
    if ($stateEntries.Count -gt 2) { return $false }
    foreach ($entry in $stateEntries) {
      if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
      if ($entry.Name -ceq 'ProvisioningDiagnostics' -and $entry.PSIsContainer) {
        if (-not (Test-HostProtectedInstallerRecordAcl $entry.FullName)) { return $false }
        $records = @(Get-ChildItem -LiteralPath $entry.FullName -Force -ErrorAction Stop)
        if ($records.Count -gt 256) { return $false }
        foreach ($record in $records) {
          if ($record.PSIsContainer -or
              (($record.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
              $record.Name -notmatch '^host-provisioning-\d{8}T\d{9}Z-[0-9a-f]{32}\.json$' -or
              $record.Length -gt 8192 -or
              -not (Test-HostProtectedInstallerRecordAcl $record.FullName)) {
            return $false
          }
        }
      } elseif ($entry.Name -ceq 'migration-credential.dpapi' -and -not $entry.PSIsContainer) {
        if ($entry.Length -gt 4096 -or -not (Test-HostProtectedInstallerRecordAcl $entry.FullName)) { return $false }
      } else {
        return $false
      }
    }
    return $true
  } catch {
    return $false
  }
}

function Test-HostDataPathHasNoReparsePoints([string] $DataRoot, [string] $ProductDataRoot, [string] $Path) {
  try {
    $dataBoundary = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
    $productBoundary = [IO.Path]::GetFullPath($ProductDataRoot).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $productBoundary.StartsWith($dataBoundary + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not $candidate.StartsWith($productBoundary + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }

    $current = $candidate
    while ($true) {
      if (Test-Path -LiteralPath $current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
      }
      if ($current.Equals($dataBoundary, [StringComparison]::OrdinalIgnoreCase)) { break }
      $parent = [IO.Directory]::GetParent($current)
      if ($null -eq $parent) { return $false }
      $current = $parent.FullName
    }
    return $true
  } catch {
    return $false
  }
}

function Assert-HostNewInstallationState(
  [object] $PostgresService,
  [object] $HostService,
  [string] $DataRoot,
  [string] $ProductDataRoot,
  [string[]] $ExistingDataDirectories,
  [string] $InstallerStateDirectory
) {
  if ($PostgresService -or $HostService) { throw 'HOST_EXISTING_SERVICES_REQUIRE_RECOVERY' }
  foreach ($directory in @($ExistingDataDirectories) + @($InstallerStateDirectory)) {
    if (-not (Test-HostDataPathHasNoReparsePoints -DataRoot $DataRoot -ProductDataRoot $ProductDataRoot -Path $directory)) {
      throw 'HOST_EXISTING_DATA_REQUIRES_REPAIR'
    }
    if (Test-Path -LiteralPath $directory) { throw 'HOST_EXISTING_DATA_REQUIRES_REPAIR' }
  }
}

if (-not $payload.Equals($expectedPayload, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'HOST_PAYLOAD_PATH_INVALID'
}
foreach ($file in @(
  (Join-Path $payload 'payload-manifest.json'),
  (Join-Path $payload 'ventio_host.exe'),
  (Join-Path $payload 'ventio_migrate.exe'),
  (Join-Path $payload 'ventio_identity_bootstrap.exe'),
  (Join-Path $payload 'ventio_trusted_pairing.exe'),
  (Join-Path $payload 'ventio_trusted_credential_reissue.exe'),
  (Join-Path $payload 'VentioHostService.exe'),
  (Join-Path $payload 'VentioSetupBroker.exe'),
  (Join-Path $payload 'postgresql\bin\postgres.exe'),
  (Join-Path $payload 'postgresql\bin\initdb.exe'),
  $postgresProvisioner, $databaseInitializer, $hostServiceRegistrar, $hostConfigWriter, $databaseCredentialRecovery,
  $migrationCredentialModule, $productDataRootModule, $databaseUpgrade, $hostLanListener
)) {
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'HOST_PAYLOAD_INCOMPLETE' }
}
$manifest = Get-Content -LiteralPath (Join-Path $payload 'payload-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.formatVersion -ne 1 -or $manifest.postgresVersion -ne '16.15' -or
    $manifest.setupBrokerExecutable -ne 'VentioSetupBroker.exe' -or
    $manifest.trustedPairingExecutable -ne 'ventio_trusted_pairing.exe' -or
    $manifest.trustedCredentialReissueExecutable -ne 'ventio_trusted_credential_reissue.exe' -or
    $manifest.credentialsIncluded -ne $false -or $manifest.databaseIncluded -ne $false) {
  throw 'HOST_PAYLOAD_MANIFEST_INVALID'
}
$brokerEntry = @($manifest.verifiedFiles | Where-Object { $_.path -ceq 'VentioSetupBroker.exe' })
$brokerPath = Join-Path $payload 'VentioSetupBroker.exe'
if ($brokerEntry.Count -ne 1 -or
    (Get-Item -LiteralPath $brokerPath).Length -ne [long]$brokerEntry[0].length -or
    (Get-FileHash -LiteralPath $brokerPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$brokerEntry[0].sha256) {
  throw 'HOST_SETUP_BROKER_MANIFEST_ENTRY_INVALID'
}
$trustedPairingEntry = @($manifest.verifiedFiles | Where-Object { $_.path -ceq 'ventio_trusted_pairing.exe' })
$trustedPairingPath = Join-Path $payload 'ventio_trusted_pairing.exe'
if ($trustedPairingEntry.Count -ne 1 -or
    (Get-Item -LiteralPath $trustedPairingPath).Length -ne [long]$trustedPairingEntry[0].length -or
    (Get-FileHash -LiteralPath $trustedPairingPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$trustedPairingEntry[0].sha256) {
  throw 'HOST_TRUSTED_PAIRING_MANIFEST_ENTRY_INVALID'
}
$trustedReissueEntry = @($manifest.verifiedFiles | Where-Object { $_.path -ceq 'ventio_trusted_credential_reissue.exe' })
$trustedReissuePath = Join-Path $payload 'ventio_trusted_credential_reissue.exe'
if ($trustedReissueEntry.Count -ne 1 -or
    (Get-Item -LiteralPath $trustedReissuePath).Length -ne [long]$trustedReissueEntry[0].length -or
    (Get-FileHash -LiteralPath $trustedReissuePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$trustedReissueEntry[0].sha256) {
  throw 'HOST_TRUSTED_CREDENTIAL_REISSUE_MANIFEST_ENTRY_INVALID'
}
$setupScriptNames = @(
  'provision-host-installation.ps1', 'provision-postgres-service.ps1',
  'initialize-host-database.ps1', 'register-host-service.ps1',
  'write-host-service-config.ps1', 'HostMigrationCredential.psm1', 'HostProductDataRoot.psm1', 'recover-host-database-credentials.ps1',
  'upgrade-host-database.ps1', 'stop-host-services.ps1', 'enable-host-lan-listener.ps1',
  'remove-host-installation.ps1'
)
foreach ($scriptName in $setupScriptNames) {
  $relative = 'setup/' + $scriptName
  $entry = @($manifest.verifiedFiles | Where-Object { $_.path -ceq $relative })
  $file = Join-Path $setupDirectory $scriptName
  if ($entry.Count -ne 1 -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
    throw 'HOST_SETUP_SCRIPT_MANIFEST_ENTRY_MISSING'
  }
  $item = Get-Item -LiteralPath $file
  if ($item.Length -ne [long]$entry[0].length -or
      (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry[0].sha256) {
    throw 'HOST_SETUP_SCRIPT_HASH_INVALID'
  }
}

$postgres = Test-ProductService $postgresServiceName 'NT SERVICE\VentioPostgres' `
  (Join-Path $payload 'postgresql\bin\pg_ctl.exe') $databaseDirectory
$hostService = Test-ProductService $hostServiceName 'NT SERVICE\VentioHost' `
  (Join-Path $payload 'VentioHostService.exe') $null
$partialHostRecovery = ($null -ne $postgres -and $null -eq $hostService)
if ($null -eq $postgres -and $null -ne $hostService) { throw 'HOST_PARTIAL_SERVICE_INSTALLATION' }

if ($NewHostOnly) {
  Assert-HostNewInstallationState -PostgresService $postgres -HostService $hostService `
    -DataRoot $programData -ProductDataRoot (Join-Path $programData 'Ventio') `
    -ExistingDataDirectories @(
      $databaseDirectory,
      $hostConfigurationDirectory,
      (Join-Path $programData 'Ventio\Backups')
    ) -InstallerStateDirectory $installerStateDirectory
}

if (-not $Apply) {
  if ($postgres -and $hostService) {
    Write-Output 'HOST_UPGRADE_PLAN_VALID'
    Write-Output 'The existing Ventio services match the installed product paths. PostgreSQL data and configuration will be backed up before applying migrations.'
  } elseif ($partialHostRecovery) {
    if (-not (Test-Path -LiteralPath $databaseDirectory -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $databaseDirectory 'PG_VERSION') -PathType Leaf) -or
        (Get-Content -LiteralPath (Join-Path $databaseDirectory 'PG_VERSION') -Raw).Trim() -ne '16' -or
        -not (Test-HostInstallerStateForResume -DataRoot $programData -InstallerStateDirectory $installerStateDirectory) -or
        -not (Test-Path -LiteralPath (Join-Path $installerStateDirectory 'migration-credential.dpapi') -PathType Leaf)) {
      throw 'HOST_EXISTING_DATA_REQUIRES_REPAIR'
    }
    if (Test-Path -LiteralPath $hostConfigurationDirectory) {
      $configEntries = @(Get-ChildItem -LiteralPath $hostConfigurationDirectory -Force)
      if ($configEntries.Count -gt 0) { throw 'HOST_EXISTING_DATA_REQUIRES_REPAIR' }
    }
    Write-Output 'HOST_INSTALL_RECOVERY_PLAN_VALID'
    Write-Output 'The existing PostgreSQL cluster will be backed up and its two restricted application-role credentials will be recovered before Host service registration.'
  } else {
    if (Test-Path -LiteralPath $databaseDirectory) {
      $entries = @(Get-ChildItem -LiteralPath $databaseDirectory -Force)
      if ($entries.Count -gt 0) { throw 'HOST_DATA_DIRECTORY_REQUIRES_REPAIR' }
    }
    Write-Output 'HOST_INSTALL_PLAN_VALID'
    Write-Output 'The bundled PostgreSQL runtime, migrations, Host service, and protected configuration are present. No service, database, or file was changed.'
  }
  return
}

Write-Output 'HOST_SETUP_PHASE:PAYLOAD_VALIDATION'

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'HOST_INSTALL_ADMIN_ELEVATION_REQUIRED'
}
Import-Module $productDataRootModule -Force
Protect-HostProductDataRoot

if ($postgres -and $hostService) {
  if ($hostService.State -ne 'Stopped') { throw 'HOST_UPGRADE_HOST_SERVICE_MUST_BE_STOPPED' }
  if ($postgres.State -ne 'Running') {
    Start-Service -Name $postgresServiceName -ErrorAction Stop
    Wait-ProductService $postgresServiceName 'Running'
  }
  & $databaseUpgrade -PostgresRoot (Join-Path $payload 'postgresql') -Port $port -Apply
  Start-Service -Name $hostServiceName -ErrorAction Stop
  Wait-ProductService $hostServiceName 'Running'
  Write-Output 'HOST_UPGRADE_SERVICES_READY'
  return
}

if (-not $partialHostRecovery) {
  foreach ($directory in @($databaseDirectory, $hostConfigurationDirectory)) {
    if (Test-Path -LiteralPath $directory) {
      $entries = @(Get-ChildItem -LiteralPath $directory -Force)
      if ($entries.Count -gt 0) { throw 'HOST_EXISTING_DATA_REQUIRES_REPAIR' }
    }
  }
  if (-not (Test-HostInstallerStateForResume -DataRoot $programData -InstallerStateDirectory $installerStateDirectory)) {
    throw 'HOST_EXISTING_DATA_REQUIRES_REPAIR'
  }
} else {
  if (-not (Test-Path -LiteralPath $databaseDirectory -PathType Container) -or
      (Get-Content -LiteralPath (Join-Path $databaseDirectory 'PG_VERSION') -Raw).Trim() -ne '16' -or
      -not (Test-Path -LiteralPath (Join-Path $installerStateDirectory 'migration-credential.dpapi') -PathType Leaf) -or
      -not (Test-HostInstallerStateForResume -DataRoot $programData -InstallerStateDirectory $installerStateDirectory)) {
    throw 'HOST_EXISTING_DATA_REQUIRES_REPAIR'
  }
  if (Test-Path -LiteralPath $hostConfigurationDirectory) {
    $configEntries = @(Get-ChildItem -LiteralPath $hostConfigurationDirectory -Force)
    if ($configEntries.Count -gt 0) { throw 'HOST_EXISTING_DATA_REQUIRES_REPAIR' }
  }
}

$runtimeCredential = New-SetupCredential 'ventio_runtime_app' 36
$identityCredential = New-SetupCredential 'ventio_identity_api_app' 36
$bootstrapCredential = if ($partialHostRecovery) { $null } else { New-SetupCredential 'ventio_bootstrap' 36 }
$migrationCredential = if ($partialHostRecovery) { $null } else { New-SetupCredential 'ventio_migrator_app' 32 }
$failed = $false
try {
  $global:VentioProvisioningFailureDetail = $null
  if ($partialHostRecovery) {
    $phase = 'DATABASE_ROLE_CREDENTIAL_RECOVERY'
    & $databaseCredentialRecovery -PostgresRoot (Join-Path $payload 'postgresql') `
      -DataDirectory $databaseDirectory -Port $port -RuntimeCredential $runtimeCredential `
      -IdentityApiCredential $identityCredential
  } else {
    $phase = 'POSTGRES_SERVICE_PROVISIONING'
    Write-Output "HOST_SETUP_PHASE:$phase"
    & $postgresProvisioner -PostgresRoot (Join-Path $payload 'postgresql') -Port $port `
      -BootstrapCredential $bootstrapCredential -Apply
    $phase = 'DATABASE_INITIALIZATION'
    Write-Output "HOST_SETUP_PHASE:$phase"
    & $databaseInitializer -PostgresRoot (Join-Path $payload 'postgresql') `
      -DataDirectory $databaseDirectory -Port $port -BootstrapCredential $bootstrapCredential `
      -RuntimeCredential $runtimeCredential -IdentityApiCredential $identityCredential `
      -MigrationCredential $migrationCredential -Apply

    $phase = 'MIGRATION_CREDENTIAL_PROTECTION'
    Write-Output "HOST_SETUP_PHASE:$phase"
    Import-Module $migrationCredentialModule -Force
    Write-HostMigrationCredential -Credential $migrationCredential
  }

  $phase = 'HOST_SERVICE_REGISTRATION'
  Write-Output "HOST_SETUP_PHASE:$phase"
  & $hostServiceRegistrar -PayloadDirectory $payload
  $phase = 'HOST_CONFIGURATION_PROTECTION'
  Write-Output "HOST_SETUP_PHASE:$phase"
  & $hostConfigWriter -RuntimeCredential $runtimeCredential -IdentityApiCredential $identityCredential `
    -OutputDirectory $hostConfigurationDirectory
  $phase = 'HOST_LAN_CONFIGURATION'
  Write-Output "HOST_SETUP_PHASE:$phase"
  & $hostLanListener -PayloadDirectory $payload -RestartServices
  $phase = 'HOST_SERVICE_STARTUP'
  Write-Output "HOST_SETUP_PHASE:$phase"
  Start-Service -Name $hostServiceName -ErrorAction Stop
  Wait-ProductService $hostServiceName 'Running'
  $phase = 'HOST_READINESS'
  Write-Output "HOST_SETUP_PHASE:$phase"
  Write-Output 'HOST_INSTALL_SERVICES_READY_FOR_FIRST_ADMIN'
} catch {
  $failed = $true
  $failure = $_
  $failureCode = [string]$failure.Exception.Message
  if ($failureCode -notmatch '^(HOST|POSTGRES)_[A-Z0-9_]{1,96}$') {
    $failureCode = 'HOST_INSTALL_PROVISIONING_FAILED'
  }
  $diagnosticsDirectory = Join-Path $installerStateDirectory 'ProvisioningDiagnostics'
  $failureRecord = Write-HostProvisioningFailureRecord -DataRoot $programData `
    -DiagnosticsDirectory $diagnosticsDirectory -Phase $phase -Failure $failure `
    -Detail ([string]$global:VentioProvisioningFailureDetail)
  $global:VentioProvisioningFailureDetail = $null
  [Console]::Error.WriteLine('HOST_SETUP_SAFE_FAILURE=' + $failureCode)
  [Console]::Error.WriteLine('HOST_INSTALL_FAILED_DATA_PRESERVED')
  if ($failureRecord) { [Console]::Error.WriteLine('HOST_INSTALL_DIAGNOSTIC_RECORD_AVAILABLE') }
  throw 'HOST_INSTALL_PROVISIONING_FAILED'
} finally {
  foreach ($credential in @($bootstrapCredential, $runtimeCredential, $identityCredential, $migrationCredential)) {
    if ($credential -and $credential.Password) { $credential.Password.Dispose() }
  }
  $bootstrapCredential = $null
  $runtimeCredential = $null
  $identityCredential = $null
  $migrationCredential = $null
}
