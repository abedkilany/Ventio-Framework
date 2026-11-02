param(
  [Parameter(Mandatory = $true)] [PSCredential] $RuntimeCredential,
  [Parameter(Mandatory = $true)] [PSCredential] $IdentityApiCredential,
  [string] $DatabaseName = 'ventio_host',
  [int] $DatabasePort = 54329,
  [string] $BindAddress = '127.0.0.1',
  [int] $HostPort = 8080,
  [string] $DiagnosticsFile,
  [string] $RecoveryAuthorityFile,
  [string] $RecoveryAuthorityOwnerSid,
  [string] $TlsCertificateFile,
  [string] $TlsPrivateKeyFile,
  [string] $OutputDirectory,
  [switch] $TestMode,
  [string] $TestServiceSid
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$phase = 'arguments'
$configName = 'service-config.dpapi'
$programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$productionDirectory = Join-Path $programData 'Ventio\Host'
if (-not $OutputDirectory) { $OutputDirectory = $productionDirectory }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

function ConvertTo-ConnectionUrl([PSCredential] $Credential, [string] $Database) {
  if ([string]::IsNullOrWhiteSpace($Credential.UserName) -or [string]::IsNullOrWhiteSpace($Database)) {
    throw 'Required credential field is missing.'
  }
  $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Credential.Password)
  $password = $null
  try {
    $password = [Runtime.InteropServices.Marshal]::PtrToStringUni($secretPointer)
    if ($null -eq $password) { throw 'Credential is empty.' }
    $usernamePart = [Uri]::EscapeDataString($Credential.UserName)
    $passwordPart = [Uri]::EscapeDataString($password)
    $databasePart = [Uri]::EscapeDataString($Database)
    return "postgresql://${usernamePart}:${passwordPart}@127.0.0.1:${DatabasePort}/${databasePart}?sslmode=disable"
  }
  finally {
    if ($secretPointer -ne [IntPtr]::Zero) {
      [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($secretPointer)
    }
    $password = $null
  }
}

function Assert-PrivateAncestors([string] $Path) {
  $cursor = [IO.Path]::GetFullPath($Path)
  while ($cursor -and (Test-Path -LiteralPath $cursor)) {
    $item = Get-Item -LiteralPath $cursor -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'A configuration ancestor is a reparse point.'
    }
    if ($cursor -eq $programData) { break }
    $parent = [IO.Directory]::GetParent($cursor)
    if ($null -eq $parent -or $parent.FullName -eq $cursor) { break }
    $cursor = $parent.FullName
  }
}

function Set-PrivateDirectoryAcl([string] $Path, [string] $ServiceSid, [string] $OwnerSid) {
  [void][IO.Directory]::CreateDirectory($Path)
  $security = [Security.AccessControl.DirectorySecurity]::new()
  $security.SetAccessRuleProtection($true, $false)
  $adminSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
  $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
  $serviceSecurityId = [Security.Principal.SecurityIdentifier]::new($ServiceSid)
  $security.SetOwner([Security.Principal.SecurityIdentifier]::new($OwnerSid))
  foreach ($sid in @($adminSid, $systemSid, $serviceSecurityId)) {
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      $sid, [Security.AccessControl.FileSystemRights]::FullControl,
      [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit,
      [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
  }
  Set-Acl -LiteralPath $Path -AclObject $security
}

function Set-PrivateConfigAcl([string] $Path, [string] $ServiceSid, [string] $OwnerSid) {
  $security = [Security.AccessControl.FileSecurity]::new()
  $security.SetAccessRuleProtection($true, $false)
  $adminSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
  $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
  $serviceSecurityId = [Security.Principal.SecurityIdentifier]::new($ServiceSid)
  $security.SetOwner([Security.Principal.SecurityIdentifier]::new($OwnerSid))
  foreach ($sid in @($adminSid, $systemSid)) {
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      $sid, [Security.AccessControl.FileSystemRights]::FullControl,
      [Security.AccessControl.AccessControlType]::Allow))
  }
  $serviceRights = if ($OwnerSid -eq $ServiceSid) {
    [Security.AccessControl.FileSystemRights]::FullControl
  } else {
    [Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::Synchronize
  }
  $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $serviceSecurityId, $serviceRights, [Security.AccessControl.AccessControlType]::Allow))
  Set-Acl -LiteralPath $Path -AclObject $security
}

function Test-FullyQualifiedWindowsPath([string] $Path) {
  return [IO.Path]::IsPathRooted($Path) -and $Path -match '^(?:[A-Za-z]:\\|\\\\)'
}

try {
  $phase = 'service-identity'
  if ($TestMode) {
    if (-not $TestServiceSid -or -not $OutputDirectory.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
      throw 'Test mode requires a temporary output directory and a test SID.'
    }
    $serviceSid = $TestServiceSid
    $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  }
  else {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
      throw 'Administrator elevation is required to write Host service configuration.'
    }
    if ($OutputDirectory -ne $productionDirectory) { throw 'Production configuration path is fixed.' }
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='VentioHost'"
    if ($null -eq $service -or $service.StartName -ne 'NT SERVICE\VentioHost') {
      throw 'VentioHost must use its dedicated virtual service identity before configuration.'
    }
    $serviceSid = ([Security.Principal.NTAccount]::new('NT SERVICE', 'VentioHost')).Translate(
      [Security.Principal.SecurityIdentifier]).Value
    if ($serviceSid -notmatch '^S-1-5-80-(?:\d+-){4}\d+$') { throw 'VentioHost service SID is invalid.' }
    $ownerSid = 'S-1-5-32-544'
  }

  $phase = 'listener-settings'
  if ($DatabasePort -lt 1 -or $DatabasePort -gt 65535 -or $HostPort -lt 1 -or $HostPort -gt 65535) {
    throw 'A configured port is outside the valid range.'
  }
  $bind = [Net.IPAddress]::Parse($BindAddress)
  if (-not [Net.IPAddress]::IsLoopback($bind) -and (-not $TlsCertificateFile -or -not $TlsPrivateKeyFile)) {
    throw 'External Host listeners require both TLS files.'
  }
  if (($null -ne $TlsCertificateFile) -xor ($null -ne $TlsPrivateKeyFile)) {
    throw 'TLS certificate and private key must be provided together.'
  }
  foreach ($tlsPath in @($TlsCertificateFile, $TlsPrivateKeyFile)) {
    if ($tlsPath -and (-not (Test-FullyQualifiedWindowsPath $tlsPath) -or -not (Test-Path -LiteralPath $tlsPath -PathType Leaf))) {
      throw 'TLS files must exist at absolute local paths.'
    }
  }
  if (-not $RecoveryAuthorityOwnerSid) { $RecoveryAuthorityOwnerSid = $serviceSid }
  foreach ($sid in @($RecoveryAuthorityOwnerSid, $serviceSid)) {
    if ($sid -notmatch '^S-1-\d+(?:-\d+)+$') { throw 'A configured Windows security identifier is invalid.' }
    [void][Security.Principal.SecurityIdentifier]::new($sid)
  }
  if ($RecoveryAuthorityOwnerSid -ne $serviceSid) {
    throw 'Recovery Authority must be owned by the dedicated Host service identity.'
  }

  if (-not $DiagnosticsFile) { $DiagnosticsFile = Join-Path $OutputDirectory 'host-diagnostics.jsonl' }
  if (-not $RecoveryAuthorityFile) { $RecoveryAuthorityFile = Join-Path $OutputDirectory 'recovery.witness' }
  foreach ($path in @($DiagnosticsFile, $RecoveryAuthorityFile)) {
    if (-not (Test-FullyQualifiedWindowsPath $path)) { throw 'Host diagnostics and Recovery Authority paths must be absolute.' }
  }

  $phase = 'connection-urls'
  $settings = [ordered]@{
    VENTIO_HOST_DATABASE_URL = ConvertTo-ConnectionUrl $RuntimeCredential $DatabaseName
    VENTIO_HOST_IDENTITY_API_DATABASE_URL = ConvertTo-ConnectionUrl $IdentityApiCredential $DatabaseName
    VENTIO_RECOVERY_AUTHORITY_FILE = [IO.Path]::GetFullPath($RecoveryAuthorityFile)
    VENTIO_RECOVERY_AUTHORITY_HOST_WRITES = 'yes'
    VENTIO_RECOVERY_AUTHORITY_OWNER_SID = $RecoveryAuthorityOwnerSid
    VENTIO_RECOVERY_AUTHORITY_READER_SID = $serviceSid
    VENTIO_HOST_DIAGNOSTICS_FILE = [IO.Path]::GetFullPath($DiagnosticsFile)
    VENTIO_HOST_BIND_ADDRESS = $BindAddress
    VENTIO_HOST_PORT = [string]$HostPort
  }
  if ($TlsCertificateFile) {
    $settings.VENTIO_HOST_TLS_CERTIFICATE_FILE = [IO.Path]::GetFullPath($TlsCertificateFile)
    $settings.VENTIO_HOST_TLS_PRIVATE_KEY_FILE = [IO.Path]::GetFullPath($TlsPrivateKeyFile)
  }

  $plainText = $null
  $plainBytes = $null
  $protectedBytes = $null
  $tempPath = $null
  try {
    $phase = 'dpapi-protect'
    $plainText = ($settings.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
    $plainBytes = [Text.UTF8Encoding]::new($false).GetBytes($plainText)
    $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
      $plainBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    if (-not $TestMode) { Assert-PrivateAncestors (Split-Path -Parent $OutputDirectory) }
    $phase = 'directory-acl'
    if (-not $TestMode) {
      Import-Module (Join-Path $PSScriptRoot 'HostProductDataRoot.psm1') -Force
      Protect-HostProductDataRoot
    }
    Set-PrivateDirectoryAcl $OutputDirectory $serviceSid $serviceSid
    $targetPath = Join-Path $OutputDirectory $configName
    $tempPath = Join-Path $OutputDirectory ('.service-config-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $phase = 'write-protected-file'
    [IO.File]::WriteAllBytes($tempPath, $protectedBytes)
    Set-PrivateConfigAcl $tempPath $serviceSid $ownerSid
    if (Test-Path -LiteralPath $targetPath) {
      [IO.File]::Replace($tempPath, $targetPath, $null, $true)
    }
    else {
      [IO.File]::Move($tempPath, $targetPath)
    }
    $tempPath = $null
  }
  finally {
    if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
    if ($protectedBytes) { [Array]::Clear($protectedBytes, 0, $protectedBytes.Length) }
    $plainText = $null
    $settings = $null
    if ($tempPath -and (Test-Path -LiteralPath $tempPath)) { Remove-Item -LiteralPath $tempPath -Force }
  }
  Write-Output 'HOST_CONFIG_PROTECTED'
}
catch {
  $safeFailureType = if ($_.Exception.InnerException) { $_.Exception.InnerException.GetType().Name } else { $_.Exception.GetType().Name }
  if ($safeFailureType -notmatch '^[A-Za-z][A-Za-z0-9]{0,63}$') { $safeFailureType = 'Unknown' }
  $line = [int]$_.InvocationInfo.ScriptLineNumber
  $failureCode = "HOST_CONFIG_WRITE_FAILED_${phase}_${safeFailureType}_LINE_$line"
  [Console]::Error.WriteLine($failureCode)
  throw $failureCode
}
finally {
  $RuntimeCredential = $null
  $IdentityApiCredential = $null
}
