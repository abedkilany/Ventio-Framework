$ErrorActionPreference = 'Stop'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$directory = [IO.Path]::GetFullPath((Join-Path $tempRoot ('ventio-lan-config-test-' + [guid]::NewGuid().ToString('N'))))
if (-not $directory.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'LAN config test output must remain under the Windows temporary directory.'
}
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
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
  & (Join-Path $PSScriptRoot 'enable-host-lan-listener.ps1') `
    -TestMode -TestDirectory $directory -TestServiceSid $sid | Out-Null

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
      "VENTIO_HOST_TLS_PRIVATE_KEY_FILE=$directory\host-lan-private-key.pem"
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
  Write-Output 'HOST_LAN_DPAPI_CONFIGURATION_TEST_PASS'
}
finally {
  $runtime = $null
  $identity = $null
  Remove-LanTestDirectory $directory
}
