Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

function Get-HostMigrationCredentialPath([string] $OutputDirectory, [switch] $TestMode) {
  $fullPath = [IO.Path]::GetFullPath($OutputDirectory)
  if ($TestMode) {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $safePattern = '^' + [regex]::Escape($tempRoot + '\ventio-pg-initdb-test-')
    if ($fullPath -notmatch $safePattern) { throw 'HOST_MIGRATION_CREDENTIAL_TEST_PATH_INVALID' }
  } else {
    $expected = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\Installer'))
    if (-not $fullPath.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'HOST_MIGRATION_CREDENTIAL_PATH_INVALID'
    }
  }
  return Join-Path $fullPath 'migration-credential.dpapi'
}

function Assert-HostMigrationCredentialAdministrator([switch] $TestMode) {
  if ($TestMode) { return }
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'HOST_MIGRATION_CREDENTIAL_ADMIN_ELEVATION_REQUIRED'
  }
}

function Assert-HostMigrationCredentialAncestors([string] $Path) {
  $programData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)).TrimEnd('\')
  $current = [IO.Path]::GetFullPath($Path)
  while ($current.StartsWith($programData + '\', [StringComparison]::OrdinalIgnoreCase)) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'HOST_MIGRATION_CREDENTIAL_REPARSE_POINT'
      }
    }
    if ($current.Equals($programData, [StringComparison]::OrdinalIgnoreCase)) { return }
    $parent = [IO.Directory]::GetParent($current)
    if ($null -eq $parent -or $parent.FullName -eq $current) { break }
    $current = $parent.FullName
  }
  if (-not $current.Equals($programData, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HOST_MIGRATION_CREDENTIAL_OUTSIDE_PROGRAM_DATA'
  }
}

function Set-HostMigrationCredentialAcl([string] $Path, [switch] $Directory, [switch] $TestMode) {
  if ($Directory) {
    $security = [Security.AccessControl.DirectorySecurity]::new()
  } else {
    $security = [Security.AccessControl.FileSecurity]::new()
  }
  $security.SetAccessRuleProtection($true, $false)
  if ($TestMode) {
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $identities = @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
  } else {
    $owner = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $identities = @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
  }
  $security.SetOwner($owner)
  foreach ($identity in $identities) {
    $rights = [Security.AccessControl.FileSystemRights]::FullControl
    $inheritance = if ($Directory) {
      [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
      [Security.AccessControl.InheritanceFlags]::None
    }
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      $identity, $rights, $inheritance, [Security.AccessControl.PropagationFlags]::None,
      [Security.AccessControl.AccessControlType]::Allow))
  }
  Set-Acl -LiteralPath $Path -AclObject $security
}

function Assert-HostMigrationCredentialAcl([string] $Path, [switch] $Directory, [switch] $TestMode) {
  $security = Get-Acl -LiteralPath $Path
  if (-not $security.AreAccessRulesProtected) { throw 'HOST_MIGRATION_CREDENTIAL_ACL_INHERITANCE_ENABLED' }
  $expected = if ($TestMode) {
    @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
  } else {
    @('S-1-5-32-544', 'S-1-5-18')
  }
  $rules = @($security.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
  if ($rules.Count -ne $expected.Count) { throw 'HOST_MIGRATION_CREDENTIAL_ACL_INVALID' }
  foreach ($rule in $rules) {
    if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
        $rule.IdentityReference.Value -notin $expected) {
      throw 'HOST_MIGRATION_CREDENTIAL_ACL_INVALID'
    }
  }
  $ownerSid = if ($TestMode) { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } else { 'S-1-5-32-544' }
  $owner = $security.GetOwner([Security.Principal.SecurityIdentifier]).Value
  if ($owner -ne $ownerSid) { throw 'HOST_MIGRATION_CREDENTIAL_OWNER_INVALID' }
}

function Write-HostMigrationCredential {
  param(
    [Parameter(Mandatory = $true)] [PSCredential] $Credential,
    [string] $OutputDirectory = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\Installer'),
    [switch] $TestMode
  )
  Assert-HostMigrationCredentialAdministrator -TestMode:$TestMode
  if ($Credential.UserName -cne 'ventio_migrator_app') { throw 'HOST_MIGRATION_CREDENTIAL_INVALID' }
  $password = $Credential.GetNetworkCredential().Password
  if ($password -notmatch '^[A-Za-z0-9_-]{43}$') { throw 'HOST_MIGRATION_CREDENTIAL_INVALID' }
  $path = Get-HostMigrationCredentialPath -OutputDirectory $OutputDirectory -TestMode:$TestMode
  if (-not $TestMode) { Assert-HostMigrationCredentialAncestors ([IO.Path]::GetDirectoryName($path)) }
  $directory = [IO.Path]::GetDirectoryName($path)
  [void][IO.Directory]::CreateDirectory($directory)
  if (-not $TestMode) { Assert-HostMigrationCredentialAncestors $directory }
  Set-HostMigrationCredentialAcl $directory -Directory -TestMode:$TestMode
  $tempPath = Join-Path $directory ('.migration-credential-' + [guid]::NewGuid().ToString('N') + '.tmp')
  $replacementBackup = $path + '.' + [guid]::NewGuid().ToString('N') + '.replace-backup'
  $plaintext = $null
  $plainBytes = $null
  $protectedBytes = $null
  try {
    $plaintext = [ordered]@{ formatVersion = 1; username = $Credential.UserName; password = $password } | ConvertTo-Json -Compress
    $plainBytes = [Text.UTF8Encoding]::new($false).GetBytes($plaintext)
    $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
      $plainBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    [IO.File]::WriteAllBytes($tempPath, $protectedBytes)
    Set-HostMigrationCredentialAcl $tempPath -TestMode:$TestMode
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      [IO.File]::Replace($tempPath, $path, $replacementBackup, $true)
    } else {
      [IO.File]::Move($tempPath, $path)
    }
    Assert-HostMigrationCredentialAcl $directory -Directory -TestMode:$TestMode
    Assert-HostMigrationCredentialAcl $path -TestMode:$TestMode
  } finally {
    if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
    if ($protectedBytes) { [Array]::Clear($protectedBytes, 0, $protectedBytes.Length) }
    $plaintext = $null
    $password = $null
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    if (Test-Path -LiteralPath $replacementBackup) { Remove-Item -LiteralPath $replacementBackup -Force -ErrorAction SilentlyContinue }
  }
}

function Read-HostMigrationCredential {
  param(
    [string] $OutputDirectory = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\Installer'),
    [switch] $TestMode
  )
  Assert-HostMigrationCredentialAdministrator -TestMode:$TestMode
  $path = Get-HostMigrationCredentialPath -OutputDirectory $OutputDirectory -TestMode:$TestMode
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'HOST_MIGRATION_CREDENTIAL_MISSING' }
  Assert-HostMigrationCredentialAcl ([IO.Path]::GetDirectoryName($path)) -Directory -TestMode:$TestMode
  Assert-HostMigrationCredentialAcl $path -TestMode:$TestMode
  $protectedBytes = [IO.File]::ReadAllBytes($path)
  $plainBytes = $null
  $plaintext = $null
  try {
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
      $protectedBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    $plaintext = [Text.UTF8Encoding]::new($false, $true).GetString($plainBytes)
    $document = $plaintext | ConvertFrom-Json
    $properties = @($document.PSObject.Properties.Name | Sort-Object)
    if ($properties -join ',' -cne 'formatVersion,password,username' -or
        $document.formatVersion -ne 1 -or $document.username -cne 'ventio_migrator_app' -or
        $document.password -notmatch '^[A-Za-z0-9_-]{43}$') {
      throw 'HOST_MIGRATION_CREDENTIAL_INVALID'
    }
    $securePassword = ConvertTo-SecureString $document.password -AsPlainText -Force
    return [PSCredential]::new('ventio_migrator_app', $securePassword)
  } catch {
    if ($_.FullyQualifiedErrorId -match '^HOST_MIGRATION_CREDENTIAL_[A-Z0-9_]+') { throw }
    throw 'HOST_MIGRATION_CREDENTIAL_INVALID'
  } finally {
    if ($protectedBytes) { [Array]::Clear($protectedBytes, 0, $protectedBytes.Length) }
    if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
    $plaintext = $null
  }
}

Export-ModuleMember -Function Write-HostMigrationCredential, Read-HostMigrationCredential
