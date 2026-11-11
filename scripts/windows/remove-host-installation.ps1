param(
  [string] $PayloadDirectory = (Join-Path $env:ProgramFiles 'Ventio\host-payload'),
  [switch] $RemoveData,
  [switch] $SystemWorker,
  [string] $StatusPath,
  [string] $FailureCodePath
)

$ErrorActionPreference = 'Stop'
$payload = [IO.Path]::GetFullPath($PayloadDirectory)
$removalScriptPath = [IO.Path]::GetFullPath($PSCommandPath)
$expectedPayload = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio\host-payload'))
$programData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
$programDataVentio = [IO.Path]::GetFullPath((Join-Path $programData 'Ventio'))
$databaseData = [IO.Path]::GetFullPath((Join-Path $programDataVentio 'PostgreSQL'))
$hostData = [IO.Path]::GetFullPath((Join-Path $programDataVentio 'Host'))
$installerData = [IO.Path]::GetFullPath((Join-Path $programDataVentio 'Installer'))
$backupData = [IO.Path]::GetFullPath((Join-Path $programDataVentio 'Backups'))
$recoveryEvidenceData = [IO.Path]::GetFullPath((Join-Path $programDataVentio 'RecoveryEvidence'))
$systemDirectory = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::System))
$systemPowerShell = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
$sc = Join-Path $systemDirectory 'sc.exe'
$takeown = Join-Path $systemDirectory 'takeown.exe'

function Get-ValidatedService([string] $Name, [string] $Account, [string] $Executable, [string] $DataPath) {
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
  if ($null -eq $service) { return $null }
  $expectedImagePath = [IO.Path]::GetFullPath($Executable)
  $rawImagePath = [string]$service.PathName
  $imageMatch = [regex]::Match($rawImagePath, '^\s*"([^"]+)"(?<arguments>\s.*)?$')
  $legacyUnquotedHostImage = $false
  if ($imageMatch.Success) {
    $imagePath = [IO.Path]::GetFullPath($imageMatch.Groups[1].Value)
    $serviceArguments = ([string]$imageMatch.Groups['arguments'].Value).Trim()
  } elseif (-not $DataPath -and
            [IO.Path]::GetFullPath($rawImagePath.Trim()).Equals($expectedImagePath, [StringComparison]::OrdinalIgnoreCase)) {
    # Older PowerShell 5.1 registration could strip the quotes while passing binPath= to sc.exe.
    # Accept only the exact Host executable path with no trailing service arguments.
    $imagePath = $expectedImagePath
    $serviceArguments = ''
    $legacyUnquotedHostImage = $true
  } else {
    $imagePath = ''
    $serviceArguments = ''
  }
  $dataPathPattern = if ($DataPath) {
    '(?i)(?:^|\s)-D\s+"' + [regex]::Escape([IO.Path]::GetFullPath($DataPath)) + '"(?:\s|$)'
  } else {
    $null
  }
  if ($service.StartName -cne $Account -or
      -not $imagePath.Equals($expectedImagePath, [StringComparison]::OrdinalIgnoreCase) -or
      (-not $DataPath -and $serviceArguments.Length -gt 0) -or
      ($DataPath -and $rawImagePath -notmatch $dataPathPattern)) {
    throw 'HOST_SERVICE_IDENTITY_CONFLICT'
  }
  if ($legacyUnquotedHostImage -and $service.State -cne 'Stopped') {
    $processId = [uint32]$service.ProcessId
    $serviceProcess = if ($processId -gt 0) {
      Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$processId" -ErrorAction SilentlyContinue
    } else {
      $null
    }
    if ($null -eq $serviceProcess -or
        -not [string]::Equals([string]$serviceProcess.ExecutablePath, $expectedImagePath, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'HOST_SERVICE_IDENTITY_CONFLICT'
    }
  }
  return $service
}

function Assert-PrivateProductRoot([string] $Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  $privateRoot = [IO.Path]::GetFullPath($programDataVentio).TrimEnd('\')
  $privateRootPrefix = $privateRoot + '\'
  if (-not $fullPath.Equals($privateRoot, [StringComparison]::OrdinalIgnoreCase) -and
      -not $fullPath.StartsWith($privateRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HOST_DATA_PATH_OUTSIDE_PRODUCT_ROOT'
  }

  $cursor = $fullPath
  while ($true) {
    try {
      $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
    } catch {
      if ($cursor.Equals($fullPath, [StringComparison]::OrdinalIgnoreCase) -and
          $_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
        return $false
      }
      throw 'HOST_DATA_ACCESS_CHECK_FAILED'
    }
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'HOST_DATA_REPARSE_POINT'
    }
    if ($item -and -not $item.PSIsContainer) { throw 'HOST_DATA_PATH_TYPE_INVALID' }
    $parent = [IO.Directory]::GetParent($cursor)
    if ($null -eq $parent -or $parent.FullName -eq $cursor) { break }
    $cursor = $parent.FullName
  }
  return $true
}

function Assert-PrivateProductDirectory([string] $Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (-not (Assert-PrivateProductRoot $fullPath)) { return }
  $directories = [Collections.Generic.Stack[string]]::new()
  $directories.Push($fullPath)
  while ($directories.Count -gt 0) {
    $current = $directories.Pop()
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current)) {
      $child = Get-Item -LiteralPath $entry -Force
      if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'HOST_DATA_REPARSE_POINT'
      }
      if ($child.PSIsContainer) { $directories.Push($child.FullName) }
    }
  }
}

function Set-RemovalDataAcl([string] $Path) {
  if (-not (Test-Path -LiteralPath $takeown -PathType Leaf)) {
    throw 'HOST_DATA_OWNERSHIP_TOOL_MISSING'
  }

  $takeownArguments = '/F ' + (ConvertTo-WindowsCommandLineArgument $Path) + ' /A'
  $takeownProcess = Start-Process -FilePath $takeown -ArgumentList $takeownArguments `
    -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
  if ($takeownProcess.ExitCode -ne 0) { throw 'HOST_DATA_OWNERSHIP_REPAIR_FAILED' }

  $acl = [Security.AccessControl.DirectorySecurity]::new()
  $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
    [Security.AccessControl.InheritanceFlags]::ObjectInherit
  $acl.SetAccessRuleProtection($true, $false)
  $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
  $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
  $acl.SetOwner($administrators)
  foreach ($sid in @($administrators, $system)) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
      $sid,
      [Security.AccessControl.FileSystemRights]::FullControl,
      $inheritance,
      [Security.AccessControl.PropagationFlags]::None,
      [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
  }
  try {
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
  } catch {
    throw 'HOST_DATA_ACL_REPAIR_FAILED'
  }
}

function Repair-PrivateProductDirectoryForRemoval([string] $Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (-not (Assert-PrivateProductRoot $fullPath)) { return }

  # Repair only one object at a time. Inspect every child for reparse points
  # before changing its ACL or descending into it.
  Set-RemovalDataAcl $fullPath
  $directories = [Collections.Generic.Stack[string]]::new()
  $directories.Push($fullPath)
  while ($directories.Count -gt 0) {
    $current = $directories.Pop()
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current)) {
      $attributes = [IO.File]::GetAttributes($entry)
      if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'HOST_DATA_REPARSE_POINT'
      }
      if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
        Set-RemovalDataAcl $entry
        $directories.Push($entry)
      }
    }
  }
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

function Test-TrustedInstallerStateDirectoryAcl([string] $Path) {
  try {
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $trustedSids = @('S-1-5-32-544', 'S-1-5-18')
    $writeAccess = [Security.AccessControl.FileSystemRights]::WriteData -bor
      [Security.AccessControl.FileSystemRights]::AppendData -bor
      [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
      [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
      [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
      [Security.AccessControl.FileSystemRights]::Delete -bor
      [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
      [Security.AccessControl.FileSystemRights]::TakeOwnership
    $genericWrite = 0x40000000
    $genericAll = 0x10000000
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
      if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
          $rule.IdentityReference.Value -notin $trustedSids) {
        $rights = [int]$rule.FileSystemRights
        if (($rights -band ($genericWrite -bor $genericAll)) -ne 0 -or
            ($rights -band [int]$writeAccess) -ne 0) {
          return $false
        }
      }
    }
    return $true
  } catch {
    return $false
  }
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
  $acl.SetOwner($administrators)
  foreach ($sid in @($administrators, $system)) {
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

function Save-ProtectedProvisioningDiagnostics([switch] $AllowMissing) {
  $sourceDirectory = Join-Path $installerData 'ProvisioningDiagnostics'
  if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
    if ($AllowMissing) { return }
    throw 'HOST_RECOVERY_DIAGNOSTICS_MISSING'
  }
  Assert-PrivateProductDirectory $sourceDirectory
  if (-not (Test-ProtectedRecoveryRecordAcl $sourceDirectory)) {
    throw 'HOST_RECOVERY_DIAGNOSTICS_ACL_INVALID'
  }

  $records = @(Get-ChildItem -LiteralPath $sourceDirectory -Force -ErrorAction Stop)
  if ($records.Count -eq 0 -and $AllowMissing) { return }
  if ($records.Count -lt 1 -or $records.Count -gt 256) { throw 'HOST_RECOVERY_DIAGNOSTICS_INVALID' }
  foreach ($record in $records) {
    if ($record.PSIsContainer -or
        $record.Name -notmatch '^host-provisioning-\d{8}T\d{9}Z-[0-9a-f]{32}\.json$' -or
        $record.Length -gt 8192 -or
        ($record.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not (Test-ProtectedRecoveryRecordAcl $record.FullName)) {
      throw 'HOST_RECOVERY_DIAGNOSTICS_INVALID'
    }
  }

  Assert-PrivateProductDirectory $recoveryEvidenceData
  if (-not (Test-Path -LiteralPath $recoveryEvidenceData -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($recoveryEvidenceData)
    Set-ProtectedRecoveryEvidenceAcl $recoveryEvidenceData $true
  } elseif (-not (Test-ProtectedRecoveryRecordAcl $recoveryEvidenceData)) {
    throw 'HOST_RECOVERY_EVIDENCE_DIRECTORY_ACL_INVALID'
  }

  $archiveName = 'partial-host-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
  $archiveDirectory = Join-Path $recoveryEvidenceData $archiveName
  [void][IO.Directory]::CreateDirectory($archiveDirectory)
  Set-ProtectedRecoveryEvidenceAcl $archiveDirectory $true
  $archiveDiagnostics = Join-Path $archiveDirectory 'ProvisioningDiagnostics'
  [void][IO.Directory]::CreateDirectory($archiveDiagnostics)
  Set-ProtectedRecoveryEvidenceAcl $archiveDiagnostics $true

  $archivedRecords = [Collections.Generic.List[object]]::new()
  foreach ($record in $records) {
    $destination = Join-Path $archiveDiagnostics $record.Name
    [IO.File]::Copy($record.FullName, $destination, $false)
    Set-ProtectedRecoveryEvidenceAcl $destination $false
    $sourceHash = (Get-FileHash -LiteralPath $record.FullName -Algorithm SHA256).Hash
    $archiveHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($sourceHash -cne $archiveHash -or -not (Test-ProtectedRecoveryRecordAcl $destination)) {
      throw 'HOST_RECOVERY_DIAGNOSTICS_ARCHIVE_VERIFICATION_FAILED'
    }
    $archivedRecords.Add([ordered]@{
      name = $record.Name
      length = [long]$record.Length
      sha256 = $archiveHash.ToLowerInvariant()
    })
  }

  $manifest = [ordered]@{
    formatVersion = 1
    archivedUtc = [DateTime]::UtcNow.ToString('o')
    source = 'ProgramData\Ventio\Installer\ProvisioningDiagnostics'
    files = @($archivedRecords)
  }
  $manifestPath = Join-Path $archiveDirectory 'manifest.json'
  [IO.File]::WriteAllText(
    $manifestPath,
    (ConvertTo-Json -InputObject $manifest -Depth 5),
    [Text.UTF8Encoding]::new($false)
  )
  Set-ProtectedRecoveryEvidenceAcl $manifestPath $false
  if (-not (Test-ProtectedRecoveryRecordAcl $manifestPath)) {
    throw 'HOST_RECOVERY_EVIDENCE_MANIFEST_ACL_INVALID'
  }
  Write-Output ('HOST_RECOVERY_DIAGNOSTICS_ARCHIVED=' + $archiveDirectory)
}

function Assert-PostgresOnlyFailedInstallation {
  $dataVersion = Join-Path (Join-Path $databaseData 'data') 'PG_VERSION'
  if (-not (Test-Path -LiteralPath $dataVersion -PathType Leaf) -or
      (Get-Content -LiteralPath $dataVersion -Raw -ErrorAction Stop).Trim() -ne '16') {
    throw 'HOST_PARTIAL_INSTALLATION_CLUSTER_INVALID'
  }
  Assert-PrivateProductDirectory $databaseData
  Assert-PrivateProductDirectory $hostData
  Assert-PrivateProductDirectory $installerData
  Assert-PrivateProductDirectory $backupData

  if (Test-Path -LiteralPath $hostData -PathType Container) {
    if (@(Get-ChildItem -LiteralPath $hostData -Force -ErrorAction Stop).Count -gt 0) {
      throw 'HOST_PARTIAL_INSTALLATION_HOST_CONFIGURATION_PRESENT'
    }
  }

  $stateEntries = @(Get-ChildItem -LiteralPath $installerData -Force -ErrorAction Stop)
  $diagnosticsDirectory = Join-Path $installerData 'ProvisioningDiagnostics'
  $migrationCredential = Join-Path $installerData 'migration-credential.dpapi'
  $hasMigrationCredential = Test-Path -LiteralPath $migrationCredential -PathType Leaf
  $installerStateAclValid = if ($hasMigrationCredential) {
    Test-ProtectedRecoveryRecordAcl $installerData
  } else {
    Test-TrustedInstallerStateDirectoryAcl $installerData
  }
  if (-not (Test-Path -LiteralPath $diagnosticsDirectory -PathType Container) -or
      -not $installerStateAclValid -or
      -not (Test-ProtectedRecoveryRecordAcl $diagnosticsDirectory)) {
    throw 'HOST_PARTIAL_INSTALLATION_STATE_INVALID'
  }
  foreach ($entry in $stateEntries) {
    if ($entry.Name -cne 'ProvisioningDiagnostics' -and $entry.Name -cne 'migration-credential.dpapi') {
      throw 'HOST_PARTIAL_INSTALLATION_STATE_INVALID'
    }
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'HOST_PARTIAL_INSTALLATION_STATE_INVALID'
    }
  }
  if ($hasMigrationCredential -and
      ($stateEntries.Count -ne 2 -or
       (Get-Item -LiteralPath $migrationCredential -ErrorAction Stop).Length -gt 4096 -or
       -not (Test-ProtectedRecoveryRecordAcl $migrationCredential))) {
    throw 'HOST_PARTIAL_INSTALLATION_STATE_INVALID'
  }
  if (-not $hasMigrationCredential -and $stateEntries.Count -ne 1) {
    throw 'HOST_PARTIAL_INSTALLATION_STATE_INVALID'
  }

  $records = @(Get-ChildItem -LiteralPath $diagnosticsDirectory -Force -ErrorAction Stop)
  if ($records.Count -lt 1 -or $records.Count -gt 256) {
    throw 'HOST_PARTIAL_INSTALLATION_DIAGNOSTICS_INVALID'
  }
  $hasConfirmedFailure = $false
  $hasInitialLedgerFailure = $false
  foreach ($record in $records) {
    if ($record.PSIsContainer -or
        $record.Name -notmatch '^host-provisioning-\d{8}T\d{9}Z-[0-9a-f]{32}\.json$' -or
        $record.Length -gt 8192 -or
        ($record.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not (Test-ProtectedRecoveryRecordAcl $record.FullName)) {
      throw 'HOST_PARTIAL_INSTALLATION_DIAGNOSTICS_INVALID'
    }
    $document = Get-Content -LiteralPath $record.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
    if ([string]$document.failureCode -ceq 'HOST_DATABASE_RECOVERY_ROLE_ROTATION_FAILED') {
      $hasConfirmedFailure = $true
    }
    if ([string]$document.phase -ceq 'DATABASE_INITIALIZATION' -and
        [string]$document.failureCode -ceq 'HOST_DATABASE_MIGRATION_LEDGER_INVALID' -and
        [string]$document.scriptName -ceq 'initialize-host-database.ps1') {
      $hasInitialLedgerFailure = $true
    }
  }
  if ($hasMigrationCredential) {
    if (-not $hasConfirmedFailure) { throw 'HOST_PARTIAL_INSTALLATION_FAILURE_NOT_RECOGNIZED' }
  } elseif (-not $hasInitialLedgerFailure) {
    throw 'HOST_PARTIAL_INSTALLATION_FAILURE_NOT_RECOGNIZED'
  }
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

function Remove-ValidatedLanFirewallRule([string] $Executable) {
  $rules = @(Get-NetFirewallRule -Name 'Ventio Host HTTPS LAN' -ErrorAction SilentlyContinue)
  if ($rules.Count -eq 0) { return }
  if ($rules.Count -ne 1) { throw 'HOST_LAN_FIREWALL_RULE_CONFLICT' }
  $rule = $rules[0]
  $portFilter = $rule | Get-NetFirewallPortFilter
  $addressFilter = $rule | Get-NetFirewallAddressFilter
  $applicationFilter = $rule | Get-NetFirewallApplicationFilter
  if ($rule.Direction -ne 'Inbound' -or $rule.Action -ne 'Allow' -or
      $rule.Enabled -ne 'True' -or $rule.Profile -ne 'Private' -or
      $portFilter.Protocol -ne 'TCP' -or $portFilter.LocalPort -ne '8443' -or
      $addressFilter.RemoteAddress -notcontains 'LocalSubnet' -or
      $applicationFilter.Program -cne $Executable) {
    throw 'HOST_LAN_FIREWALL_RULE_CONFLICT'
  }
  Remove-NetFirewallRule -Name 'Ventio Host HTTPS LAN' -ErrorAction Stop
}

function ConvertTo-WindowsCommandLineArgument([string] $Value) {
  $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $trailingSlashes = [regex]::Match($escaped, '\\+$').Length
  if ($trailingSlashes -gt 0) {
    $escaped = $escaped.Substring(0, $escaped.Length - $trailingSlashes) + ('\' * ($trailingSlashes * 2))
  }
  return '"' + $escaped + '"'
}

function Assert-NoReparseWithinBoundary([string] $Path, [string] $Boundary) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  $boundaryPath = [IO.Path]::GetFullPath($Boundary).TrimEnd('\')
  if (-not $fullPath.Equals($boundaryPath, [StringComparison]::OrdinalIgnoreCase) -and
      -not $fullPath.StartsWith($boundaryPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HOST_REMOVAL_TRUSTED_PATH_INVALID'
  }
  $current = $fullPath
  while ($true) {
    $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'HOST_REMOVAL_TRUSTED_PATH_REPARSE_POINT'
    }
    if ($current.Equals($boundaryPath, [StringComparison]::OrdinalIgnoreCase)) { return }
    $parent = [IO.Directory]::GetParent($current)
    if ($null -eq $parent) { throw 'HOST_REMOVAL_TRUSTED_PATH_INVALID' }
    $current = $parent.FullName
  }
}

function Assert-TrustedRemovalScript {
  $programFilesRoot = [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')
  $productRoot = [IO.Path]::GetFullPath((Join-Path $programFilesRoot 'Ventio'))
  $setupDirectory = [IO.Path]::GetFullPath((Join-Path $payload 'setup'))
  $expectedScript = [IO.Path]::GetFullPath((Join-Path $setupDirectory 'remove-host-installation.ps1'))
  $currentScript = $removalScriptPath
  if (-not $currentScript.Equals($expectedScript, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HOST_REMOVAL_SCRIPT_PATH_INVALID'
  }
  if (-not (Test-Path -LiteralPath $systemPowerShell -PathType Leaf) -or
      -not (Test-Path -LiteralPath $sc -PathType Leaf)) {
    throw 'HOST_REMOVAL_SYSTEM_TOOLS_MISSING'
  }
  Assert-NoReparseWithinBoundary $expectedScript $programFilesRoot
  Assert-NoReparseWithinBoundary $systemPowerShell $systemDirectory
  Assert-NoReparseWithinBoundary $sc $systemDirectory

  $untrustedSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')
  $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  if ($currentUserSid -and $currentUserSid.Value -cne 'S-1-5-18') {
    $untrustedSids += $currentUserSid.Value
  }
  $writeRights = [Security.AccessControl.FileSystemRights]::WriteData -bor
    [Security.AccessControl.FileSystemRights]::AppendData -bor
    [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
    [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
    [Security.AccessControl.FileSystemRights]::Delete -bor
    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [Security.AccessControl.FileSystemRights]::TakeOwnership
  foreach ($path in @(
    $programFilesRoot, $productRoot, $payload, $setupDirectory, $expectedScript,
    $systemDirectory, (Join-Path $systemDirectory 'WindowsPowerShell'),
    (Split-Path -Parent $systemPowerShell), $systemPowerShell, $sc
  )) {
    $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
      if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
          $rule.IdentityReference.Value -in $untrustedSids -and
          ($rule.FileSystemRights -band $writeRights) -ne 0) {
        throw 'HOST_REMOVAL_SCRIPT_WRITE_ACCESS_INVALID'
      }
    }
  }
}

function Write-SystemWorkerStatus([string] $State, [string] $FailureCode) {
  $statusDirectory = [IO.Path]::GetFullPath((Join-Path $payload 'setup'))
  $fullStatusPath = [IO.Path]::GetFullPath($StatusPath)
  $prefix = $statusDirectory.TrimEnd('\') + '\'
  if (-not $SystemWorker -or
      -not $fullStatusPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetFileName($fullStatusPath) -notmatch '^remove-status-[0-9a-f]{32}\.json$') {
    throw 'HOST_REMOVAL_STATUS_PATH_INVALID'
  }
  $status = [ordered]@{
    formatVersion = 1
    state = $State
    failureCode = $FailureCode
  }
  $temporaryPath = $fullStatusPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  try {
    [IO.File]::WriteAllText($temporaryPath, (ConvertTo-Json -InputObject $status -Compress), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporaryPath, $fullStatusPath)
  } finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
      Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Write-RemovalFailureCode([string] $FailureCode) {
  try {
    if ([string]::IsNullOrWhiteSpace($FailureCodePath) -or
        $FailureCode -notmatch '^(HOST|POSTGRES)_[A-Z0-9_]{1,96}$') { return }
    $fullPath = [IO.Path]::GetFullPath($FailureCodePath)
    $temporaryPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($fullPath) -cne 'ventio-host-removal-failure.txt') { return }
    $bytes = [Text.Encoding]::ASCII.GetBytes($FailureCode)
    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
  } catch { }
}

function Assert-SystemWorkerRequest {
  $statusDirectory = [IO.Path]::GetFullPath((Join-Path $payload 'setup'))
  $fullStatusPath = [IO.Path]::GetFullPath($StatusPath)
  $prefix = $statusDirectory.TrimEnd('\') + '\'
  if (-not $SystemWorker -or -not $RemoveData -or
      [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne 'S-1-5-18' -or
      -not $fullStatusPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetFileName($fullStatusPath) -notmatch '^remove-status-[0-9a-f]{32}\.json$' -or
      (Test-Path -LiteralPath $fullStatusPath)) {
    throw 'HOST_REMOVAL_SYSTEM_WORKER_REQUEST_INVALID'
  }
  Assert-TrustedRemovalScript
}

function Invoke-SystemRemovalWorker {
  Assert-TrustedRemovalScript
  $statusDirectory = [IO.Path]::GetFullPath((Join-Path $payload 'setup'))
  $statusPath = Join-Path $statusDirectory ('remove-status-' + [guid]::NewGuid().ToString('N') + '.json')
  $taskName = 'Ventio.HostRemoval.' + [guid]::NewGuid().ToString('N')
  if (-not (Test-Path -LiteralPath $systemPowerShell -PathType Leaf)) { throw 'HOST_REMOVAL_SYSTEM_WORKER_UNAVAILABLE' }

  $arguments = @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', (ConvertTo-WindowsCommandLineArgument $removalScriptPath),
    '-PayloadDirectory', (ConvertTo-WindowsCommandLineArgument $payload),
    '-RemoveData', '-SystemWorker', '-StatusPath', (ConvertTo-WindowsCommandLineArgument $statusPath)
  ) -join ' '
  $action = New-ScheduledTaskAction -Execute $systemPowerShell -Argument $arguments -WorkingDirectory $payload
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  $registered = $false
  $startedAt = [DateTime]::Now
  try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    $registered = $true
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddHours(1)
    while ([DateTime]::UtcNow -lt $deadline) {
      if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        $result = Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($result.formatVersion -ne 1 -or $result.state -notin @('complete', 'failed')) {
          throw 'HOST_REMOVAL_SYSTEM_WORKER_RESULT_INVALID'
        }
        if ($result.state -ne 'complete') {
          if ([string]$result.failureCode -match '^(HOST|POSTGRES)_[A-Z0-9_]{1,96}$') {
            throw [string]$result.failureCode
          }
          throw 'HOST_REMOVAL_SYSTEM_WORKER_FAILED'
        }
        return
      }
      $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
      if ($task -and $task.State -eq 'Ready' -and [DateTime]::Now -ge $startedAt.AddSeconds(10)) {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        if ($taskInfo -and $taskInfo.LastRunTime -ge $startedAt) {
          throw 'HOST_REMOVAL_SYSTEM_WORKER_RESULT_MISSING'
        }
      }
      Start-Sleep -Milliseconds 500
    }
    throw 'HOST_REMOVAL_SYSTEM_WORKER_TIMEOUT'
  }
  finally {
    try {
      if ($registered) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task -and $task.State -ne 'Ready') {
          try { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch { }
          $stopDeadline = [DateTime]::UtcNow.AddSeconds(10)
          while ([DateTime]::UtcNow -lt $stopDeadline) {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if (-not $task -or $task.State -eq 'Ready') { break }
            Start-Sleep -Milliseconds 250
          }
        }
        try {
          Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        } catch {
          throw 'HOST_REMOVAL_SYSTEM_TASK_CLEANUP_FAILED'
        }
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
          throw 'HOST_REMOVAL_SYSTEM_TASK_CLEANUP_FAILED'
        }
      }
    } finally {
      if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Invoke-HostRemoval {
  if (-not $payload.Equals($expectedPayload, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HOST_PAYLOAD_PATH_INVALID'
  }
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'HOST_UNINSTALL_ADMIN_ELEVATION_REQUIRED'
  }

  $postgres = Get-ValidatedService 'VentioPostgres' 'NT SERVICE\VentioPostgres' `
    (Join-Path $payload 'postgresql\bin\pg_ctl.exe') (Join-Path $databaseData 'data')
  $hostService = Get-ValidatedService 'VentioHost' 'NT SERVICE\VentioHost' `
    (Join-Path $payload 'VentioHostService.exe') $null
  if ($null -eq $postgres -and $null -ne $hostService) { throw 'HOST_PARTIAL_SERVICE_INSTALLATION' }
  if ($postgres -and -not $hostService) { Assert-PostgresOnlyFailedInstallation }

  if ($RemoveData) {
    [void](Assert-PrivateProductRoot $programDataVentio)
  }

  Remove-ValidatedLanFirewallRule (Join-Path $payload 'ventio_host.exe')
  if ($hostService) { Stop-ValidatedService 'VentioHost' }
  if ($postgres) { Stop-ValidatedService 'VentioPostgres' }
  $servicesToRemove = @()
  if ($hostService) { $servicesToRemove += 'VentioHost' }
  if ($postgres) { $servicesToRemove += 'VentioPostgres' }
  foreach ($name in $servicesToRemove) {
    & $sc delete $name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'HOST_SERVICE_REMOVAL_FAILED' }
  }
  if ($servicesToRemove.Count -gt 0) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($true) {
      $remaining = @(Get-CimInstance -ClassName Win32_Service | Where-Object { $_.Name -in @('VentioHost', 'VentioPostgres') })
      if ($remaining.Count -eq 0) { break }
      if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_SERVICE_REMOVAL_TIMEOUT' }
      Start-Sleep -Milliseconds 500
    }
  }

  if ($RemoveData) {
    Repair-PrivateProductDirectoryForRemoval $programDataVentio
    Assert-PrivateProductDirectory $programDataVentio
    if (Assert-PrivateProductRoot $programDataVentio) {
      Remove-Item -LiteralPath $programDataVentio -Recurse -Force -ErrorAction Stop
    }
    Write-Output 'HOST_SERVICES_REMOVED_AND_DATA_DELETED'
  } else {
    Write-Output 'HOST_SERVICES_REMOVED_DATA_RETAINED'
  }
}

try {
  if ($SystemWorker) {
    try {
      Assert-SystemWorkerRequest
      Invoke-HostRemoval
      Write-SystemWorkerStatus 'complete' $null
      exit 0
    } catch {
      $failureCode = [string]$_.Exception.Message
      if ($failureCode -notmatch '^(HOST|POSTGRES)_[A-Z0-9_]{1,96}$') {
        $failureCode = 'HOST_REMOVAL_SYSTEM_WORKER_FAILED'
      }
      try { Write-SystemWorkerStatus 'failed' $failureCode } catch { }
      exit 1
    }
  }

  if ($RemoveData) {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
      throw 'HOST_UNINSTALL_ADMIN_ELEVATION_REQUIRED'
    }
    Invoke-SystemRemovalWorker
    exit 0
  }

  Invoke-HostRemoval
  exit 0
} catch {
  $failureCode = [string]$_.Exception.Message
  if ($failureCode -notmatch '^(HOST|POSTGRES)_[A-Z0-9_]{1,96}$') {
    $failureCode = 'HOST_REMOVAL_FAILED'
  }
  Write-RemovalFailureCode $failureCode
  Write-Error $failureCode
  exit 1
}
