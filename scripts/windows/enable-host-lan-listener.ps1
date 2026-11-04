[CmdletBinding()]
param(
  [string] $PayloadDirectory = (Join-Path $env:ProgramFiles 'Ventio\host-payload'),
  [switch] $RestartServices,
  [switch] $TestMode,
  [string] $TestDirectory,
  [string] $TestServiceSid,
  [string[]] $TestNetworkCategories = @('Private'),
  [string] $FailureCodePath
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
$firewallRuleModified = $false
$originalFirewallProfiles = @()
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

function Write-LanFailureCode([string] $FailureCode) {
  try {
    if ([string]::IsNullOrWhiteSpace($FailureCodePath) -or
        $FailureCode -notmatch '^HOST_LAN_[A-Z0-9_]{1,96}$') { return }
    $fullPath = [IO.Path]::GetFullPath($FailureCodePath)
    $temporaryPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($fullPath) -cne 'ventio-host-lan-failure.txt') { return }
    $bytes = [Text.Encoding]::ASCII.GetBytes($FailureCode)
    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
  } catch { }
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

function Resolve-HostLanFirewallProfiles([string[]] $NetworkCategories) {
  $profiles = [Collections.Generic.List[string]]::new()
  foreach ($category in $NetworkCategories) {
    switch ($category) {
      'Private' { if (-not $profiles.Contains('Private')) { $profiles.Add('Private') } }
      'DomainAuthenticated' { if (-not $profiles.Contains('Domain')) { $profiles.Add('Domain') } }
    }
  }
  $resolved = @($profiles.ToArray() | Sort-Object)
  if ($resolved.Count -eq 0) { throw 'HOST_LAN_TRUSTED_NETWORK_REQUIRED' }
  return ,$resolved
}

function Get-NormalizedFirewallProfiles([object] $Value) {
  $profiles = @(
    foreach ($entry in @($Value)) {
      foreach ($profile in ([string]$entry -split ',')) {
        $clean = $profile.Trim()
        if ($clean.Length -gt 0) { $clean }
      }
    }
  )
  return @($profiles | Sort-Object -Unique)
}

function Test-HostLanRemoteAddressScope([object] $RemoteAddress) {
  $addresses = @(
    foreach ($entry in @($RemoteAddress)) {
      foreach ($address in ([string]$entry -split ',')) {
        $clean = $address.Trim()
        if ($clean.Length -gt 0) { $clean }
      }
    }
  ) | Sort-Object -Unique
  $localSubnetKeywords = @('LocalSubnet', 'LocalSubnet4', 'LocalSubnet6')
  return $addresses.Count -gt 0 -and
    @($addresses | Where-Object { $_ -notin $localSubnetKeywords }).Count -eq 0
}

function Assert-HostLanFirewallProfile {
  $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
  if ($profiles.Count -lt 3 -or
      @($profiles | Where-Object { -not $_.Enabled -or $_.DefaultInboundAction -eq 'Allow' }).Count -gt 0) {
    throw 'HOST_LAN_FIREWALL_BASELINE_UNSAFE'
  }
  $networkCategories = @(
    Get-NetConnectionProfile -ErrorAction SilentlyContinue |
      ForEach-Object { [string]$_.NetworkCategory }
  )
  return Resolve-HostLanFirewallProfiles $networkCategories
}

function Assert-HostLanFirewallRule(
  [object] $Rule,
  [string] $Executable,
  [string[]] $FirewallProfiles,
  [string] $Context
) {
  $portFilter = $Rule | Get-NetFirewallPortFilter
  $addressFilter = $Rule | Get-NetFirewallAddressFilter
  $applicationFilter = $Rule | Get-NetFirewallApplicationFilter
  $actualProfiles = Get-NormalizedFirewallProfiles $Rule.Profile
  $expectedProfiles = @(Get-NormalizedFirewallProfiles $FirewallProfiles)
  $conflict = if ($Rule.Direction -ne 'Inbound') { 'DIRECTION' }
    elseif ($Rule.Action -ne 'Allow') { 'ACTION' }
    elseif ($Rule.Enabled -ne 'True') { 'ENABLED' }
    elseif ($portFilter.Protocol -ne 'TCP') { 'PROTOCOL' }
    elseif ($portFilter.LocalPort -ne [string]$port) { 'LOCAL_PORT' }
    elseif (-not (Test-HostLanRemoteAddressScope $addressFilter.RemoteAddress)) { 'REMOTE_ADDRESS' }
    elseif ($applicationFilter.Program -cne $Executable) { 'PROGRAM' }
    elseif ($Rule.EdgeTraversalPolicy -ne 'Block') { 'EDGE_TRAVERSAL' }
    elseif (($actualProfiles -join ',') -cne ($expectedProfiles -join ',')) { 'PROFILE' }
    else { $null }
  if ($null -ne $conflict) { throw "HOST_LAN_FIREWALL_RULE_CONFLICT_${Context}_$conflict" }
}

function Ensure-FirewallRule([string] $Executable, [string[]] $FirewallProfiles) {
  $existing = @(Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue)
  if ($existing.Count -gt 1) { throw 'HOST_LAN_FIREWALL_RULE_DUPLICATE' }
  if ($existing.Count -eq 1) {
    $rule = $existing[0]
    $actualProfiles = Get-NormalizedFirewallProfiles $rule.Profile
    $safeProfiles = @('Domain', 'Private')
    if ($actualProfiles.Count -eq 0 -or
        @($actualProfiles | Where-Object { $_ -notin $safeProfiles }).Count -gt 0) {
      throw 'HOST_LAN_FIREWALL_RULE_CONFLICT_EXISTING_PROFILE'
    }
    # A previous trusted-profile rule may need to follow this machine from a
    # Private network to an authenticated Domain network. Never widen to Public
    # or Any; validate every other rule boundary before updating its profile.
    $script:originalFirewallProfiles = $actualProfiles
    # Validate the exact LocalSubnet / executable / port boundary separately
    # because the existing trusted profile may differ from this installation.
    Assert-HostLanFirewallRule $rule $Executable $actualProfiles 'EXISTING'
    if (($actualProfiles -join ',') -cne (@(Get-NormalizedFirewallProfiles $FirewallProfiles) -join ',')) {
      Set-NetFirewallRule -Name $firewallRuleName -Profile ($FirewallProfiles -join ',') -ErrorAction Stop | Out-Null
      $script:firewallRuleModified = $true
    }
    $effective = @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $firewallRuleName -ErrorAction SilentlyContinue)
    if ($effective.Count -ne 1) { throw 'HOST_LAN_FIREWALL_RULE_NOT_EFFECTIVE' }
    Assert-HostLanFirewallRule $effective[0] $Executable $FirewallProfiles 'ACTIVE'
    return
  }
  New-NetFirewallRule -Name $firewallRuleName -DisplayName 'Ventio Host HTTPS LAN' `
    -Group 'Ventio Host' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port `
    -RemoteAddress LocalSubnet -Profile ($FirewallProfiles -join ',') -Program $Executable -EdgeTraversalPolicy Block `
    -Enabled True -ErrorAction Stop | Out-Null
  $script:createdFirewallRule = $true
  $effective = @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $firewallRuleName -ErrorAction SilentlyContinue)
  if ($effective.Count -ne 1) { throw 'HOST_LAN_FIREWALL_RULE_NOT_EFFECTIVE' }
  Assert-HostLanFirewallRule $effective[0] $Executable $FirewallProfiles 'ACTIVE'
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
    $lanFirewallProfiles = Assert-HostLanFirewallProfile
  }
  else {
    if (-not $TestDirectory -or -not $TestServiceSid) { throw 'HOST_LAN_TEST_ARGUMENTS_INVALID' }
    $hostDirectory = [IO.Path]::GetFullPath($TestDirectory)
    $configurationPath = Join-Path $hostDirectory 'service-config.dpapi'
    $configurationBackupPath = Join-Path $hostDirectory 'service-config.dpapi.pre-lan.bak'
    $lanFirewallProfiles = Resolve-HostLanFirewallProfiles $TestNetworkCategories
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
    }
    $lanFirewallProfiles = Assert-HostLanFirewallProfile
    $phase = 'firewall'
    Ensure-FirewallRule $engineExecutable $lanFirewallProfiles
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
    if (-not $values.Contains('VENTIO_HOST_LAN_BIND_ADDRESS')) {
      if (Test-Path -LiteralPath $configurationBackupPath) {
        $currentHash = (Get-FileHash -LiteralPath $configurationPath -Algorithm SHA256).Hash
        $backupHash = (Get-FileHash -LiteralPath $configurationBackupPath -Algorithm SHA256).Hash
        if ($currentHash -cne $backupHash) { throw 'HOST_LAN_CONFIGURATION_BACKUP_CONFLICT' }
      } else {
        [IO.File]::Copy($configurationPath, $configurationBackupPath, $false)
        Set-ConfigurationFileAcl $configurationBackupPath $serviceSid
      }
    }
    $values['VENTIO_HOST_LAN_BIND_ADDRESS'] = '0.0.0.0'
    $values['VENTIO_HOST_LAN_PORT'] = [string]$port
    $values['VENTIO_HOST_TLS_CERTIFICATE_FILE'] = Join-Path $hostDirectory 'host-lan-certificate.pem'
    $values['VENTIO_HOST_TLS_PRIVATE_KEY_FILE'] = Join-Path $hostDirectory 'host-lan-private-key.pem'
    Set-ProtectedConfiguration $values $configurationPath $serviceSid
    $configurationReplaced = $true
    Write-Output ('HOST_LAN_TEST_FIREWALL_PROFILES=' + ($lanFirewallProfiles -join ','))
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
  if (-not $TestMode -and $createdFirewallRule) {
    try {
      $rollbackRules = @(Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue)
      if ($rollbackRules.Count -gt 0) { $rollbackRules | Remove-NetFirewallRule -ErrorAction Stop }
    } catch { [Console]::Error.WriteLine('HOST_LAN_FIREWALL_ROLLBACK_FAILED') }
  } elseif (-not $TestMode -and $firewallRuleModified) {
    try {
      Set-NetFirewallRule -Name $firewallRuleName -Profile ($originalFirewallProfiles -join ',') -ErrorAction Stop | Out-Null
    } catch { [Console]::Error.WriteLine('HOST_LAN_FIREWALL_PROFILE_ROLLBACK_FAILED') }
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
  $normalizedPhase = [regex]::Replace($phase, '[^A-Za-z0-9_]', '_').ToUpperInvariant()
  $code = if ($_.Exception.Message -match '^HOST_LAN_[A-Z0-9_]+$') { $_.Exception.Message } else { "HOST_LAN_SETUP_FAILED_$normalizedPhase" }
  Write-LanFailureCode $code
  if ($TestMode) { throw $code }
  [Console]::Error.WriteLine($code)
  exit 1
}
