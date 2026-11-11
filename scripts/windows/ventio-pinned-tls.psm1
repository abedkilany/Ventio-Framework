Set-StrictMode -Version Latest

function Get-VentioPinnedCertificateSha256([byte[]] $Bytes) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
  }
  finally {
    $sha.Dispose()
  }
}

function Read-VentioDerLength([byte[]] $Bytes, [ref] $Offset) {
  if ($Offset.Value -ge $Bytes.Length) { throw 'Invalid subject alternative name.' }
  $first = [int] $Bytes[$Offset.Value]
  $Offset.Value++
  if (($first -band 0x80) -eq 0) { return $first }
  $count = $first -band 0x7f
  if ($count -eq 0 -or $count -gt 4 -or ($Offset.Value + $count) -gt $Bytes.Length) {
    throw 'Invalid subject alternative name length.'
  }
  $length = 0
  for ($i = 0; $i -lt $count; $i++) {
    $length = ($length * 256) + [int] $Bytes[$Offset.Value]
    $Offset.Value++
  }
  return $length
}

function Test-VentioPinnedCertificateEndpoint(
  [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
  [Uri] $Endpoint
) {
  try {
    $san = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
    if ($null -eq $san) { return $false }
    $bytes = $san.RawData
    $offset = 0
    if ($bytes.Length -lt 2 -or $bytes[$offset] -ne 0x30) { return $false }
    $offset++
    $sequenceLength = Read-VentioDerLength $bytes ([ref] $offset)
    $sequenceEnd = $offset + $sequenceLength
    if ($sequenceEnd -gt $bytes.Length) { return $false }

    $expectedAddress = $null
    if ($Endpoint.HostNameType -in @([UriHostNameType]::IPv4, [UriHostNameType]::IPv6)) {
      $host = $Endpoint.DnsSafeHost.Trim('[', ']')
      $expectedAddress = [System.Net.IPAddress]::Parse($host).GetAddressBytes()
    }

    while ($offset -lt $sequenceEnd) {
      $tag = [int] $bytes[$offset]
      $offset++
      $length = Read-VentioDerLength $bytes ([ref] $offset)
      $valueEnd = $offset + $length
      if ($valueEnd -gt $sequenceEnd) { return $false }

      if ($null -eq $expectedAddress -and $tag -eq 0x82) {
        $dnsName = [Text.Encoding]::ASCII.GetString($bytes, $offset, $length)
        if ([string]::Equals($dnsName, $Endpoint.DnsSafeHost, [StringComparison]::OrdinalIgnoreCase)) {
          return $true
        }
      }
      elseif ($null -ne $expectedAddress -and $tag -eq 0x87 -and $length -eq $expectedAddress.Length) {
        $matches = $true
        for ($i = 0; $i -lt $length; $i++) {
          if ($bytes[$offset + $i] -ne $expectedAddress[$i]) { $matches = $false; break }
        }
        if ($matches) { return $true }
      }
      $offset = $valueEnd
    }
    return $false
  }
  catch {
    return $false
  }
}

function Test-VentioPinnedServerCertificate(
  [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
  [Uri] $Endpoint,
  [string] $ExpectedSha256,
  [DateTime] $NowUtc = [DateTime]::UtcNow
) {
  try {
    $fingerprint = ($ExpectedSha256 -replace '[:\s]', '').ToLowerInvariant()
    if ($fingerprint -notmatch '^[0-9a-f]{64}$') { return $false }
    if ((Get-VentioPinnedCertificateSha256 $Certificate.RawData) -ne $fingerprint) { return $false }

    $now = $NowUtc.ToUniversalTime()
    if ($now -lt $Certificate.NotBefore.ToUniversalTime() -or $now -ge $Certificate.NotAfter.ToUniversalTime()) {
      return $false
    }
    if (-not (Test-VentioPinnedCertificateEndpoint $Certificate $Endpoint)) { return $false }

    $eku = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' } | Select-Object -First 1
    if ($null -eq $eku) { return $false }
    $serverAuth = ([System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] $eku).
      EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.1' }
    if ($null -eq $serverAuth) { return $false }

    $keyUsageExtension = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.15' } | Select-Object -First 1
    if ($null -ne $keyUsageExtension) {
      $keyUsage = ([System.Security.Cryptography.X509Certificates.X509KeyUsageExtension] $keyUsageExtension).KeyUsages
      $tlsKeyUsage = [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
        [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment
      if (($keyUsage -band $tlsKeyUsage) -eq 0) { return $false }
    }
    return $true
  }
  catch {
    return $false
  }
}

Export-ModuleMember -Function Get-VentioPinnedCertificateSha256, Test-VentioPinnedCertificateEndpoint, Test-VentioPinnedServerCertificate
