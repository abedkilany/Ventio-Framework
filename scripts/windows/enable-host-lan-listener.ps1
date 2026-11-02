[CmdletBinding()]
param(
  [string] $PayloadDirectory = (Join-Path $env:ProgramFiles 'Ventio\host-payload'),
  [switch] $RestartServices,
  [switch] $TestMode,
  [string] $TestDirectory,
  [string] $TestServiceSid
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$expectedPayload = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio\host-payload'))
$payload = [IO.Path]::GetFullPath($PayloadDirectory)
$programData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
$hostDirectory = Join-Path $programData 'Ventio\Host'
$configurationPath = Join-Path $hostDirectory 'service-config.dpapi'
$configurationBackupPath = Join-Path $hostDirectory 'service-config.dpapi.pre-lan.bak'
$firewallRuleName = 'Ventio Host HTTPS LAN'
$port = 8443
$createdFirewallRule = $false
$removeFirewallOnRollback = $false
$originalProtectedConfiguration = $null
$configurationReplaced = $false
$phase = 'preflight'

function Assert-Administrator {
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'HOST_LAN_ADMIN_ELEVATION_REQUIRED'
  }
}

function Assert-NoReparseAncestors([string] $Path, [string] $Boundary) {
  $current = [IO.Path]::GetFullPath($Path)
  $boundaryPath = [IO.Path]::GetFullPath($Boundary).TrimEnd('\')
  if (-not $current.StartsWith($boundaryPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HOST_LAN_PATH_OUTSIDE_PRODUCT_DATA'
  }
  while ($current.StartsWith($boundaryPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'HOST_LAN_REPARSE_POINT_REJECTED' }
    }
    $parent = [IO.Directory]::GetParent($current)
    if ($null -eq $parent -or $parent.FullName -eq $current) { break }
    $current = $parent.FullName
  }
}

function Get-ExpectedServiceSid {
  if ($TestMode) {
    if (-not $TestServiceSid) { throw 'HOST_LAN_TEST_SERVICE_SID_REQUIRED' }
    return $TestServiceSid
  }
  return ([Security.Principal.NTAccount]::new('NT SERVICE', 'VentioHost')).Translate(
    [Security.Principal.SecurityIdentifier]).Value
}

function Read-Configuration([string] $Path) {
  $encrypted = [IO.File]::ReadAllBytes($Path)
  $plain = $null
  try {
    $plain = [Security.Cryptography.ProtectedData]::Unprotect(
      $encrypted, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($plain)
    $values = [ordered]@{}
    foreach ($line in ($text -split "`n")) {
      if ([string]::IsNullOrEmpty($line)) { continue }
      $clean = $line.TrimEnd("`r")
      $separator = $clean.IndexOf('=')
      if ($separator -le 0) { throw 'HOST_LAN_CONFIGURATION_INVALID' }
      $name = $clean.Substring(0, $separator)
      $value = $clean.Substring($separator + 1)
      if ($values.Contains($name) -or $value.Contains("`r") -or $value.Contains("`n")) {
        throw 'HOST_LAN_CONFIGURATION_INVALID'
      }
      $values[$name] = $value
    }
    $allowed = @(
      'VENTIO_HOST_DATABASE_URL', 'VENTIO_HOST_IDENTITY_API_DATABASE_URL',
      'VENTIO_RECOVERY_AUTHORITY_FILE', 'VENTIO_RECOVERY_AUTHORITY_HOST_WRITES',
      'VENTIO_RECOVERY_AUTHORITY_OWNER_SID', 'VENTIO_RECOVERY_AUTHORITY_READER_SID',
      'VENTIO_HOST_DIAGNOSTICS_FILE', 'VENTIO_HOST_BIND_ADDRESS', 'VENTIO_HOST_PORT',
      'VENTIO_HOST_TLS_CERTIFICATE_FILE', 'VENTIO_HOST_TLS_PRIVATE_KEY_FILE',
      'VENTIO_HOST_LAN_BIND_ADDRESS', 'VENTIO_HOST_LAN_PORT'
    )
    if (@($values.Keys | Where-Object { $_ -notin $allowed }).Count -ne 0 -or
        -not $values.Contains('VENTIO_HOST_DATABASE_URL') -or
        -not $values.Contains('VENTIO_HOST_IDENTITY_API_DATABASE_URL') -or
        $values['VENTIO_RECOVERY_AUTHORITY_HOST_WRITES'] -cne 'yes' -or
        $values['VENTIO_HOST_BIND_ADDRESS'] -cne '127.0.0.1' -or
        $values['VENTIO_HOST_PORT'] -cne '8080') {
      throw 'HOST_LAN_CONFIGURATION_INVALID'
    }
    return $values
  }
  finally {
    [Array]::Clear($encrypted, 0, $encrypted.Length)
    if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
    $text = $null
  }
}

function Set-ProtectedConfiguration([System.Collections.IDictionary] $Values, [string] $Path, [string] $ServiceSid) {
  $text = ($Values.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"
  $plain = [Text.UTF8Encoding]::new($false).GetBytes($text)
  $encrypted = $null
  $temp = Join-Path (Split-Path -Parent $Path) ('.service-config-' + [guid]::NewGuid().ToString('N') + '.tmp')
  $replacementBackup = $Path + '.' + [guid]::NewGuid().ToString('N') + '.bak'
  try {
    $encrypted = [Security.Cryptography.ProtectedData]::Protect(
      $plain, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    [IO.File]::WriteAllBytes($temp, $encrypted)
    Set-ConfigurationFileAcl $temp $ServiceSid
    [IO.File]::Replace($temp, $Path, $replacementBackup, $true)
    if (Test-Path -LiteralPath $replacementBackup) { [IO.File]::Delete($replacementBackup) }
  }
  finally {
    [Array]::Clear($plain, 0, $plain.Length)
    if ($encrypted) { [Array]::Clear($encrypted, 0, $encrypted.Length) }
    $text = $null
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    if (Test-Path -LiteralPath $replacementBackup) { [IO.File]::Delete($replacementBackup) }
  }
}

function Set-ConfigurationFileAcl([string] $Path, [string] $ServiceSid) {
  $security = [Security.AccessControl.FileSecurity]::new()
  $security.SetAccessRuleProtection($true, $false)
  $admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
  $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
  $service = [Security.Principal.SecurityIdentifier]::new($ServiceSid)
  $owner = if ($TestMode) { [Security.Principal.SecurityIdentifier]::new($ServiceSid) } else { $admins }
  $security.SetOwner($owner)
  foreach ($sid in @($admins, $system)) {
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      $sid, [Security.AccessControl.FileSystemRights]::FullControl,
      [Security.AccessControl.AccessControlType]::Allow))
  }
  $serviceRights = if ($TestMode) {
    [Security.AccessControl.FileSystemRights]::FullControl
  } else {
    [Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::Synchronize
  }
  $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $service, $serviceRights, [Security.AccessControl.AccessControlType]::Allow))
  Set-Acl -LiteralPath $Path -AclObject $security
}

function Assert-PrivateConfigurationAcl([string] $Path, [string] $ServiceSid) {
  $acl = Get-Acl -LiteralPath $Path
  if (-not $acl.AreAccessRulesProtected) { throw 'HOST_LAN_CONFIGURATION_ACL_INVALID' }
  $allowed = @('S-1-5-18', 'S-1-5-32-544', $ServiceSid)
  $rules = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
  if ($rules.Count -ne 3) { throw 'HOST_LAN_CONFIGURATION_ACL_INVALID' }
  foreach ($rule in $rules) {
    if ($rule.IdentityReference.Value -notin $allowed -or
        $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
      throw 'HOST_LAN_CONFIGURATION_ACL_INVALID'
    }
  }
}

function Assert-PrivateHostDirectoryAcl([string] $Path, [string] $ServiceSid) {
  $acl = Get-Acl -LiteralPath $Path
  if (-not $acl.AreAccessRulesProtected -or
      $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $ServiceSid) {
    throw 'HOST_LAN_HOST_DIRECTORY_ACL_INVALID'
  }
  $allowed = @('S-1-5-18', 'S-1-5-32-544', $ServiceSid)
  $rules = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
  if ($rules.Count -ne 3) { throw 'HOST_LAN_HOST_DIRECTORY_ACL_INVALID' }
  foreach ($rule in $rules) {
    if ($rule.IdentityReference.Value -notin $allowed -or
        $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
        $rule.InheritanceFlags -ne ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit)) {
      throw 'HOST_LAN_HOST_DIRECTORY_ACL_INVALID'
    }
  }
}

function Assert-PrivateFirewallProfile {
  $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
  if ($profiles.Count -lt 3 -or
      @($profiles | Where-Object { -not $_.Enabled -or $_.DefaultInboundAction -eq 'Allow' }).Count -gt 0) {
    throw 'HOST_LAN_FIREWALL_BASELINE_UNSAFE'
  }
  $privateProfile = @($profiles | Where-Object { $_.Name -eq 'Private' })
  if ($privateProfile.Count -ne 1) { throw 'HOST_LAN_PRIVATE_FIREWALL_DISABLED' }
  $privateNetwork = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
    Where-Object { $_.NetworkCategory -eq 'Private' })
  if ($privateNetwork.Count -eq 0) { throw 'HOST_LAN_PRIVATE_NETWORK_REQUIRED' }
}

function Ensure-FirewallRule([string] $Executable) {
  $existing = @(Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue)
  if ($existing.Count -gt 1) { throw 'HOST_LAN_FIREWALL_RULE_CONFLICT' }
  if ($existing.Count -eq 1) {
    $rule = $existing[0]
    $portFilter = $rule | Get-NetFirewallPortFilter
    $addressFilter = $rule | Get-NetFirewallAddressFilter
    $applicationFilter = $rule | Get-NetFirewallApplicationFilter
    if ($rule.Direction -ne 'Inbound' -or $rule.Action -ne 'Allow' -or
        $rule.Enabled -ne 'True' -or $rule.Profile -ne 'Private' -or
        $portFilter.Protocol -ne 'TCP' -or $portFilter.LocalPort -ne [string]$port -or
        $addressFilter.RemoteAddress -notcontains 'LocalSubnet' -or
        $applicationFilter.Program -cne $Executable) {
      throw 'HOST_LAN_FIREWALL_RULE_CONFLICT'
    }
    return
  }
  New-NetFirewallRule -Name $firewallRuleName -DisplayName 'Ventio Host HTTPS LAN' `
    -Group 'Ventio Host' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port `
    -RemoteAddress LocalSubnet -Profile Private -Program $Executable -EdgeTraversalPolicy Block `
    -Enabled True -ErrorAction Stop | Out-Null
  $script:createdFirewallRule = $true
}

function Start-ValidatedService([string] $Name) {
  if ((Get-Service -Name $Name -ErrorAction Stop).Status -ne 'Running') {
    Start-Service -Name $Name -ErrorAction Stop
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  while ((Get-Service -Name $Name -ErrorAction Stop).Status -ne 'Running') {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_LAN_SERVICE_START_TIMEOUT' }
    Start-Sleep -Milliseconds 500
  }
}

function Stop-ValidatedService([string] $Name) {
  $service = Get-Service -Name $Name -ErrorAction Stop
  if ($service.Status -ne 'Stopped') {
    Stop-Service -Name $Name -ErrorAction Stop
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  while ((Get-Service -Name $Name -ErrorAction Stop).Status -ne 'Stopped') {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_LAN_SERVICE_STOP_TIMEOUT' }
    Start-Sleep -Milliseconds 500
  }
}

function Read-HostLanCertificate([string] $Path) {
  $file = Get-Item -LiteralPath $Path -ErrorAction Stop
  if ($file.Length -le 0 -or $file.Length -gt 65536) { throw 'HOST_LAN_CERTIFICATE_PEM_INVALID' }
  $pem = [IO.File]::ReadAllText($Path, [Text.Encoding]::ASCII)
  $match = [regex]::Match($pem,
    '\A\s*-----BEGIN CERTIFICATE-----\s*(?<body>[A-Za-z0-9+/=\r\n]+?)\s*-----END CERTIFICATE-----\s*\z')
  if (-not $match.Success) { throw 'HOST_LAN_CERTIFICATE_PEM_INVALID' }

  $der = $null
  try {
    $body = $match.Groups['body'].Value -replace '\s', ''
    $der = [Convert]::FromBase64String($body)
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($der)
    if ($certificate.HasPrivateKey) {
      $certificate.Dispose()
      throw 'HOST_LAN_PUBLIC_CERTIFICATE_CONTAINS_PRIVATE_KEY'
    }
    return $certificate
  }
  catch [FormatException] {
    throw 'HOST_LAN_CERTIFICATE_PEM_INVALID'
  }
  finally {
    if ($der) { [Array]::Clear($der, 0, $der.Length) }
    $pem = $null
  }
}

function Get-HostLanCertificateSha256([Security.Cryptography.X509Certificates.X509Certificate2] $Certificate) {
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha256.ComputeHash($Certificate.RawData)
    try { return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant() }
    finally { [Array]::Clear($hash, 0, $hash.Length) }
  }
  finally { $sha256.Dispose() }
}

function Test-ListenerTls([string] $HostName, [string] $CertificatePath) {
  # This callback pins only the local post-install self-test to the exact
  # provisioned certificate. Client TLS validation remains unchanged.
  $certificate = Read-HostLanCertificate $CertificatePath
  $expectedFingerprint = Get-HostLanCertificateSha256 $certificate
  $tcp = [Net.Sockets.TcpClient]::new()
  try {
    $tcp.Connect('127.0.0.1', $port)
    $stream = [Net.Security.SslStream]::new($tcp.GetStream(), $false, {
      param($sender, $remoteCertificate, $chain, $errors)
      if ($null -eq $remoteCertificate) { return $false }
      $presented = [Security.Cryptography.X509Certificates.X509Certificate2]::new($remoteCertificate)
      try {
        return (Get-HostLanCertificateSha256 $presented) -ceq $expectedFingerprint
      } finally { $presented.Dispose() }
    })
    try { $stream.AuthenticateAsClient($HostName) }
    finally { $stream.Dispose() }
  }
  finally { $tcp.Dispose(); $certificate.Dispose() }
}

try {
  if (-not $TestMode) {
    Assert-Administrator
    if (-not $payload.Equals($expectedPayload, [StringComparison]::OrdinalIgnoreCase)) { throw 'HOST_LAN_PAYLOAD_PATH_INVALID' }
    $hostExecutable = Join-Path $payload 'VentioHostService.exe'
    $engineExecutable = Join-Path $payload 'ventio_host.exe'
    if (-not (Test-Path -LiteralPath $hostExecutable -PathType Leaf) -or
        -not (Test-Path -LiteralPath $engineExecutable -PathType Leaf)) { throw 'HOST_LAN_PAYLOAD_INCOMPLETE' }
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='VentioHost'" -ErrorAction Stop
    if ($null -eq $service -or $service.StartName -cne 'NT SERVICE\VentioHost' -or
        $service.PathName -notmatch [regex]::Escape($hostExecutable)) { throw 'HOST_LAN_SERVICE_IDENTITY_INVALID' }
    if ((Get-Service -Name 'VentioHost' -ErrorAction Stop).Status -ne 'Stopped') { throw 'HOST_LAN_HOST_SERVICE_MUST_BE_STOPPED' }
    $postgres = Get-CimInstance -ClassName Win32_Service -Filter "Name='VentioPostgres'" -ErrorAction Stop
    $postgresExecutable = Join-Path $payload 'postgresql\bin\pg_ctl.exe'
    $dataDirectory = Join-Path $programData 'Ventio\PostgreSQL\data'
    if ($null -eq $postgres -or $postgres.StartName -cne 'NT SERVICE\VentioPostgres' -or
        $postgres.PathName -notmatch [regex]::Escape($postgresExecutable) -or
        $postgres.PathName -notmatch [regex]::Escape($dataDirectory)) { throw 'HOST_LAN_POSTGRES_IDENTITY_INVALID' }
    Assert-NoReparseAncestors $hostDirectory $programData
    Assert-PrivateFirewallProfile
  }
  else {
    if (-not $TestDirectory -or -not $TestServiceSid) { throw 'HOST_LAN_TEST_ARGUMENTS_INVALID' }
    $hostDirectory = [IO.Path]::GetFullPath($TestDirectory)
    $configurationPath = Join-Path $hostDirectory 'service-config.dpapi'
    $configurationBackupPath = Join-Path $hostDirectory 'service-config.dpapi.pre-lan.bak'
  }

  $phase = 'configuration-validation'
  if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) { throw 'HOST_LAN_CONFIGURATION_MISSING' }
  $serviceSid = Get-ExpectedServiceSid
  if (-not $TestMode) {
    Assert-PrivateHostDirectoryAcl $hostDirectory $serviceSid
    Assert-PrivateConfigurationAcl $configurationPath $serviceSid
  }
  $values = Read-Configuration $configurationPath
  if ($values.Contains('VENTIO_HOST_LAN_BIND_ADDRESS') -or $values.Contains('VENTIO_HOST_LAN_PORT')) {
    if ($values['VENTIO_HOST_LAN_BIND_ADDRESS'] -cne '0.0.0.0' -or
        $values['VENTIO_HOST_LAN_PORT'] -cne [string]$port -or
        $values['VENTIO_HOST_TLS_CERTIFICATE_FILE'] -cne (Join-Path $hostDirectory 'host-lan-certificate.pem') -or
        $values['VENTIO_HOST_TLS_PRIVATE_KEY_FILE'] -cne (Join-Path $hostDirectory 'host-lan-private-key.pem')) {
      throw 'HOST_LAN_EXISTING_CONFIGURATION_CONFLICT'
    }
  }
  if (-not $TestMode) {
    $phase = 'certificate'
    $certificatePath = Join-Path $hostDirectory 'host-lan-certificate.pem'
    $privateKeyPath = Join-Path $hostDirectory 'host-lan-private-key.pem'
    $infoPath = Join-Path $hostDirectory 'host-lan-info.json'
    & $hostExecutable '--provision-lan-certificate'
    if ($LASTEXITCODE -ne 0) { throw 'HOST_LAN_CERTIFICATE_PROVISIONING_FAILED' }
    if (-not (Test-Path -LiteralPath $certificatePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $privateKeyPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $infoPath -PathType Leaf)) { throw 'HOST_LAN_CERTIFICATE_FILES_MISSING' }
    if ($RestartServices -and (Test-Path -LiteralPath $configurationBackupPath -PathType Leaf)) {
      $originalProtectedConfiguration = [IO.File]::ReadAllBytes($configurationBackupPath)
      $configurationReplaced = $true
      $removeFirewallOnRollback = $true
    }
    Assert-PrivateFirewallProfile
    $phase = 'firewall'
    Ensure-FirewallRule $engineExecutable
    $phase = 'configuration-write'
    if (-not $values.Contains('VENTIO_HOST_LAN_BIND_ADDRESS')) {
      if (Test-Path -LiteralPath $configurationBackupPath) {
        $currentHash = (Get-FileHash -LiteralPath $configurationPath -Algorithm SHA256).Hash
        $backupHash = (Get-FileHash -LiteralPath $configurationBackupPath -Algorithm SHA256).Hash
        if ($currentHash -cne $backupHash) { throw 'HOST_LAN_CONFIGURATION_BACKUP_CONFLICT' }
      } else {
        [IO.File]::Copy($configurationPath, $configurationBackupPath, $false)
        Set-ConfigurationFileAcl $configurationBackupPath $serviceSid
      }
      if (-not $originalProtectedConfiguration) {
        $originalProtectedConfiguration = [IO.File]::ReadAllBytes($configurationBackupPath)
      }
      $values['VENTIO_HOST_LAN_BIND_ADDRESS'] = '0.0.0.0'
      $values['VENTIO_HOST_LAN_PORT'] = [string]$port
      $values['VENTIO_HOST_TLS_CERTIFICATE_FILE'] = $certificatePath
      $values['VENTIO_HOST_TLS_PRIVATE_KEY_FILE'] = $privateKeyPath
      Set-ProtectedConfiguration $values $configurationPath $serviceSid
      $configurationReplaced = $true
      $removeFirewallOnRollback = $true
    }
    if ($RestartServices) {
      $phase = 'service-start'
      Start-ValidatedService 'VentioPostgres'
      Start-ValidatedService 'VentioHost'
      $phase = 'https-readiness'
      $hostName = (Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json).hostname
      Test-ListenerTls $hostName $certificatePath
      & $hostExecutable '--set-lan-listener-status' 'enabled'
      if ($LASTEXITCODE -ne 0) { throw 'HOST_LAN_STATUS_UPDATE_FAILED' }
    }
  }
  else {
    $values['VENTIO_HOST_LAN_BIND_ADDRESS'] = '0.0.0.0'
    $values['VENTIO_HOST_LAN_PORT'] = [string]$port
    $values['VENTIO_HOST_TLS_CERTIFICATE_FILE'] = Join-Path $hostDirectory 'host-lan-certificate.pem'
    $values['VENTIO_HOST_TLS_PRIVATE_KEY_FILE'] = Join-Path $hostDirectory 'host-lan-private-key.pem'
    Set-ProtectedConfiguration $values $configurationPath $serviceSid
    $configurationReplaced = $true
  }

  if ($originalProtectedConfiguration) { [Array]::Clear($originalProtectedConfiguration, 0, $originalProtectedConfiguration.Length) }
  Write-Output 'HOST_LAN_HTTPS_CONFIGURATION_READY'
}
catch {
  if (-not $TestMode -and $RestartServices -and (Test-Path -LiteralPath (Join-Path $hostDirectory 'host-lan-info.json'))) {
    try {
      & (Join-Path $payload 'VentioHostService.exe') '--set-lan-listener-status' 'disabled'
      if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('HOST_LAN_STATUS_ROLLBACK_FAILED') }
    } catch { [Console]::Error.WriteLine('HOST_LAN_STATUS_ROLLBACK_FAILED') }
  }
  $hostStoppedForRollback = $false
  if (-not $TestMode -and $RestartServices) {
    try {
      Stop-ValidatedService 'VentioHost'
      $hostStoppedForRollback = $true
    } catch { [Console]::Error.WriteLine('HOST_LAN_HOST_STOP_FOR_ROLLBACK_FAILED') }
  }
  if ($TestMode) { [Console]::Error.WriteLine("HOST_LAN_TEST_FAILURE $($_.Exception.GetType().Name) $($_.Exception.Message)") }
  if (-not $TestMode -and $configurationReplaced -and $originalProtectedConfiguration) {
    try {
      $restore = Join-Path $hostDirectory ('.service-config-restore-' + [guid]::NewGuid().ToString('N') + '.tmp')
      [IO.File]::WriteAllBytes($restore, $originalProtectedConfiguration)
      Set-ConfigurationFileAcl $restore $serviceSid
      $restoreBackup = $configurationPath + '.' + [guid]::NewGuid().ToString('N') + '.rollback'
      [IO.File]::Replace($restore, $configurationPath, $restoreBackup, $true)
      if (Test-Path -LiteralPath $restoreBackup) { [IO.File]::Delete($restoreBackup) }
      if (Test-Path -LiteralPath $restore) { [IO.File]::Delete($restore) }
    } catch { [Console]::Error.WriteLine('HOST_LAN_CONFIGURATION_ROLLBACK_FAILED') }
  }
  if (-not $TestMode -and ($createdFirewallRule -or $removeFirewallOnRollback)) {
    try {
      $rollbackRules = @(Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue)
      if ($rollbackRules.Count -gt 0) { $rollbackRules | Remove-NetFirewallRule -ErrorAction Stop }
    } catch { [Console]::Error.WriteLine('HOST_LAN_FIREWALL_ROLLBACK_FAILED') }
  }
  if (-not $TestMode -and $RestartServices) {
    try {
      Start-ValidatedService 'VentioPostgres'
      Start-ValidatedService 'VentioHost'
      $listenerDeadline = [DateTime]::UtcNow.AddSeconds(15)
      while (@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).Count -gt 0) {
        if ([DateTime]::UtcNow -ge $listenerDeadline) { throw 'HOST_LAN_ROLLBACK_LISTENER_STILL_BOUND' }
        Start-Sleep -Milliseconds 500
      }
      if (-not $hostStoppedForRollback) { throw 'HOST_LAN_HOST_STOP_FOR_ROLLBACK_FAILED' }
    } catch { [Console]::Error.WriteLine('HOST_LAN_LOCAL_SERVICE_RESTORE_FAILED') }
  }
  if ($originalProtectedConfiguration) { [Array]::Clear($originalProtectedConfiguration, 0, $originalProtectedConfiguration.Length) }
  $code = if ($_.Exception.Message -match '^HOST_LAN_[A-Z0-9_]+$') { $_.Exception.Message } else { "HOST_LAN_SETUP_FAILED_$phase" }
  [Console]::Error.WriteLine($code)
  exit 1
}
