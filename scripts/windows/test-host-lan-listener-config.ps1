$ErrorActionPreference = 'Stop'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$directory = [IO.Path]::GetFullPath((Join-Path $tempRoot ('ventio-lan-config-test-' + [guid]::NewGuid().ToString('N'))))
if (-not $directory.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'LAN config test output must remain under the Windows temporary directory.'
}
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$listenerScriptPath = Join-Path $PSScriptRoot 'enable-host-lan-listener.ps1'
$listenerTokens = $null
$listenerParseErrors = $null
$listenerAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $listenerScriptPath, [ref]$listenerTokens, [ref]$listenerParseErrors)
if ($listenerParseErrors.Count -gt 0) { throw 'LAN listener script failed to parse during scope tests.' }
$remoteScopeFunction = $listenerAst.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Test-HostLanRemoteAddressScope'
}, $true)
if ($null -eq $remoteScopeFunction) { throw 'LAN remote-address scope validator was not found.' }
. ([scriptblock]::Create($remoteScopeFunction.Extent.Text))
foreach ($safeRemoteScope in @('LocalSubnet', 'LocalSubnet4', 'LocalSubnet6', 'LocalSubnet4, LocalSubnet6')) {
  if (-not (Test-HostLanRemoteAddressScope -RemoteAddress $safeRemoteScope)) {
    throw "A Windows LocalSubnet keyword representation was rejected: $safeRemoteScope"
  }
}
$dualLocalSubnetScope = [string[]]@('LocalSubnet4', 'LocalSubnet6')
if (-not (Test-HostLanRemoteAddressScope -RemoteAddress $dualLocalSubnetScope)) {
  throw 'A combined LocalSubnet4 and LocalSubnet6 scope was rejected.'
}
foreach ($unsafeRemoteScope in @('Any', 'LocalSubnet, 192.168.0.0/16', '10.0.0.0/8')) {
  if (Test-HostLanRemoteAddressScope -RemoteAddress $unsafeRemoteScope) {
    throw "A non-LocalSubnet remote address was accepted: $unsafeRemoteScope"
  }
}
if (Test-HostLanRemoteAddressScope -RemoteAddress $null) {
  throw 'An empty remote-address scope was accepted.'
}
$runtime = [PSCredential]::new('runtime_fixture', (ConvertTo-SecureString 'fixture-only-lan-secret-a' -AsPlainText -Force))
$identity = [PSCredential]::new('identity_fixture', (ConvertTo-SecureString 'fixture-only-lan-secret-b' -AsPlainText -Force))

function Remove-LanTestDirectory([string] $Path) {
  $resolved = [IO.Path]::GetFullPath($Path)
  if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
      (Split-Path -Leaf $resolved) -notmatch '^ventio-lan-config-test-[0-9a-f]{32}$') {
    throw 'Refusing to remove a path outside this temporary LAN config test.'
  }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

try {
  & (Join-Path $PSScriptRoot 'write-host-service-config.ps1') `
    -RuntimeCredential $runtime -IdentityApiCredential $identity `
    -OutputDirectory $directory -TestMode -TestServiceSid $sid | Out-Null
  $recoveryAuthorityPath = Join-Path $directory 'recovery.witness'
  $recoveryAuthoritySentinel = [Text.Encoding]::UTF8.GetBytes('fixture-recovery-authority-sentinel')
  [IO.File]::WriteAllBytes($recoveryAuthorityPath, $recoveryAuthoritySentinel)
  $recoveryAuthorityHash = (Get-FileHash -LiteralPath $recoveryAuthorityPath -Algorithm SHA256).Hash
  [Array]::Clear($recoveryAuthoritySentinel, 0, $recoveryAuthoritySentinel.Length)
  $lanListenerScript = $listenerScriptPath
  $domainOutput = @(& $lanListenerScript -TestMode -TestDirectory $directory `
    -TestServiceSid $sid -TestNetworkCategories @('DomainAuthenticated'))
  if ($domainOutput -notcontains 'HOST_LAN_TEST_FIREWALL_PROFILES=Domain') {
    throw 'Domain-authenticated Windows networks did not select the Domain firewall profile.'
  }

  $configPath = Join-Path $directory 'service-config.dpapi'
  $encrypted = [IO.File]::ReadAllBytes($configPath)
  $plain = $null
  try {
    $encryptedText = [Text.Encoding]::UTF8.GetString($encrypted)
    if ($encryptedText.IndexOf('fixture-only-lan-secret-a', [StringComparison]::Ordinal) -ge 0 -or
        $encryptedText.IndexOf('fixture-only-lan-secret-b', [StringComparison]::Ordinal) -ge 0) {
      throw 'Plaintext database credentials appeared in the protected file.'
    }
    $plain = [Security.Cryptography.ProtectedData]::Unprotect(
      $encrypted, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($plain)
    foreach ($required in @(
      'VENTIO_HOST_LAN_BIND_ADDRESS=0.0.0.0',
      'VENTIO_HOST_LAN_PORT=8443',
      "VENTIO_HOST_TLS_CERTIFICATE_FILE=$directory\host-lan-certificate.pem",
      "VENTIO_HOST_TLS_PRIVATE_KEY_FILE=$directory\host-lan-private-key.pem",
      "VENTIO_RECOVERY_AUTHORITY_FILE=$recoveryAuthorityPath",
      'VENTIO_RECOVERY_AUTHORITY_HOST_WRITES=yes',
      "VENTIO_RECOVERY_AUTHORITY_OWNER_SID=$sid",
      "VENTIO_RECOVERY_AUTHORITY_READER_SID=$sid",
      "VENTIO_HOST_DIAGNOSTICS_FILE=$directory\host-diagnostics.jsonl",
      'VENTIO_HOST_BIND_ADDRESS=127.0.0.1',
      'VENTIO_HOST_PORT=8080'
    )) {
      if ($text.IndexOf($required, [StringComparison]::Ordinal) -lt 0) { throw 'Protected LAN settings were not written.' }
    }
    if ($text.IndexOf('runtime_fixture', [StringComparison]::Ordinal) -lt 0 -or
        $text.IndexOf('identity_fixture', [StringComparison]::Ordinal) -lt 0) {
      throw 'The pre-existing database credential settings were not preserved.'
    }
  }
  finally {
    [Array]::Clear($encrypted, 0, $encrypted.Length)
    if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
    $text = $null
  }

  $backupPath = Join-Path $directory 'service-config.dpapi.pre-lan.bak'
  if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
    throw 'The original protected Host configuration was not preserved for in-place upgrade.'
  }
  $backupEncrypted = [IO.File]::ReadAllBytes($backupPath)
  $backupPlain = $null
  try {
    $backupPlain = [Security.Cryptography.ProtectedData]::Unprotect(
      $backupEncrypted, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    $backupText = [Text.UTF8Encoding]::new($false, $true).GetString($backupPlain)
    foreach ($required in @(
      'runtime_fixture', 'identity_fixture',
      "VENTIO_RECOVERY_AUTHORITY_FILE=$recoveryAuthorityPath",
      'VENTIO_RECOVERY_AUTHORITY_HOST_WRITES=yes',
      "VENTIO_RECOVERY_AUTHORITY_OWNER_SID=$sid",
      "VENTIO_RECOVERY_AUTHORITY_READER_SID=$sid",
      "VENTIO_HOST_DIAGNOSTICS_FILE=$directory\host-diagnostics.jsonl",
      'VENTIO_HOST_BIND_ADDRESS=127.0.0.1',
      'VENTIO_HOST_PORT=8080'
    )) {
      if ($backupText.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
        throw 'The pre-upgrade configuration backup lost an existing Host, diagnostics, or Recovery Authority setting.'
      }
    }
    if ($backupText.Contains('VENTIO_HOST_LAN_BIND_ADDRESS=')) {
      throw 'The preserved pre-upgrade configuration unexpectedly contains LAN settings.'
    }
  }
  finally {
    [Array]::Clear($backupEncrypted, 0, $backupEncrypted.Length)
    if ($backupPlain) { [Array]::Clear($backupPlain, 0, $backupPlain.Length) }
    $backupText = $null
  }

  $combinedOutput = @(& $lanListenerScript -TestMode -TestDirectory $directory `
    -TestServiceSid $sid -TestNetworkCategories @('Private', 'DomainAuthenticated'))
  if ($combinedOutput -notcontains 'HOST_LAN_TEST_FIREWALL_PROFILES=Domain,Private') {
    throw 'Trusted Private and Domain networks did not map to the exact safe firewall profiles.'
  }
  if ((Get-FileHash -LiteralPath $recoveryAuthorityPath -Algorithm SHA256).Hash -cne $recoveryAuthorityHash) {
    throw 'LAN configuration changed the existing Recovery Authority witness fixture.'
  }

  $publicNetworkRejected = $false
  $publicFailureCodePath = Join-Path $directory 'ventio-host-lan-failure.txt'
  try {
    $null = & $lanListenerScript -TestMode -TestDirectory $directory `
      -TestServiceSid $sid -TestNetworkCategories @('Public') `
      -FailureCodePath $publicFailureCodePath
  }
  catch {
    $publicNetworkRejected = $_.Exception.Message -eq 'HOST_LAN_TRUSTED_NETWORK_REQUIRED'
  }
  if (-not $publicNetworkRejected) {
    throw 'A Public-only network was not rejected before enabling the LAN listener.'
  }
  if (-not (Test-Path -LiteralPath $publicFailureCodePath -PathType Leaf) -or
      (Get-Content -LiteralPath $publicFailureCodePath -Raw) -cne 'HOST_LAN_TRUSTED_NETWORK_REQUIRED') {
    throw 'A safe classified LAN failure code was not persisted for the installer.'
  }
  Write-Output 'HOST_LAN_DPAPI_CONFIGURATION_TEST_PASS'
  Write-Output 'HOST_LAN_DOMAIN_FIREWALL_PROFILE_TEST_PASS'
  Write-Output 'HOST_LAN_PUBLIC_PROFILE_REJECTION_TEST_PASS'
  Write-Output 'HOST_LAN_REMOTE_ADDRESS_SCOPE_NORMALIZATION_TEST_PASS'
  Write-Output 'HOST_LAN_UPGRADE_CONFIG_PRESERVATION_TEST_PASS'
  Write-Output 'HOST_LAN_RECOVERY_AUTHORITY_PRESERVATION_TEST_PASS'
}
finally {
  $runtime = $null
  $identity = $null
  Remove-LanTestDirectory $directory
}
