$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ventio-pinned-tls.psm1') -Force

function New-TestTlsCertificate(
  [string[]] $DnsNames,
  [string[]] $EkuOids,
  [DateTimeOffset] $NotBefore,
  [DateTimeOffset] $NotAfter
) {
  $key = [System.Security.Cryptography.RSA]::Create(2048)
  $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
    'CN=ventio-test.invalid', $key,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
  $request.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
  $request.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
      [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
      [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment, $true))
  $usage = [System.Security.Cryptography.OidCollection]::new()
  foreach ($oid in $EkuOids) { $usage.Add([System.Security.Cryptography.Oid]::new($oid)) | Out-Null }
  $request.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usage, $true))
  $names = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
  foreach ($name in $DnsNames) { $names.AddDnsName($name) }
  $names.AddIpAddress([System.Net.IPAddress]::Parse('192.168.1.102'))
  $request.CertificateExtensions.Add($names.Build())
  return $request.CreateSelfSigned($NotBefore, $NotAfter)
}

$now = [DateTimeOffset]::UtcNow
$serverAuthOid = '1.3.6.1.5.5.7.3.1'
$clientAuthOid = '1.3.6.1.5.5.7.3.2'
$valid = New-TestTlsCertificate @('host.test') @($serverAuthOid) $now.AddMinutes(-5) $now.AddDays(30)
$wrongLeaf = New-TestTlsCertificate @('host.test') @($serverAuthOid) $now.AddMinutes(-5) $now.AddDays(30)
$wrongName = New-TestTlsCertificate @('other.test') @($serverAuthOid) $now.AddMinutes(-5) $now.AddDays(30)
$wrongUsage = New-TestTlsCertificate @('host.test') @($clientAuthOid) $now.AddMinutes(-5) $now.AddDays(30)
$expired = New-TestTlsCertificate @('host.test') @($serverAuthOid) $now.AddDays(-30) $now.AddDays(-1)
try {
  $hostEndpoint = [Uri]::new('https://host.test:8443')
  $ipEndpoint = [Uri]::new('https://192.168.1.102:8443')
  $fingerprint = Get-VentioPinnedCertificateSha256 $valid.RawData
  if (-not (Test-VentioPinnedServerCertificate $valid $hostEndpoint $fingerprint $now.UtcDateTime)) {
    throw 'PINNED_TLS_VALID_DNS_ENDPOINT_FAILED'
  }
  Write-Output 'PINNED_TLS_VALID_DNS_ENDPOINT_PASS'
  if (-not (Test-VentioPinnedServerCertificate $valid $ipEndpoint $fingerprint $now.UtcDateTime)) {
    throw 'PINNED_TLS_VALID_IP_ENDPOINT_FAILED'
  }
  Write-Output 'PINNED_TLS_VALID_IP_ENDPOINT_PASS'
  if (Test-VentioPinnedServerCertificate $wrongLeaf $hostEndpoint $fingerprint $now.UtcDateTime) {
    throw 'PINNED_TLS_WRONG_LEAF_ACCEPTED'
  }
  Write-Output 'PINNED_TLS_WRONG_LEAF_REJECTED_PASS'
  if (Test-VentioPinnedServerCertificate $wrongName $hostEndpoint (Get-VentioPinnedCertificateSha256 $wrongName.RawData) $now.UtcDateTime) {
    throw 'PINNED_TLS_WRONG_SAN_ACCEPTED'
  }
  Write-Output 'PINNED_TLS_WRONG_SAN_REJECTED_PASS'
  if (Test-VentioPinnedServerCertificate $wrongUsage $hostEndpoint (Get-VentioPinnedCertificateSha256 $wrongUsage.RawData) $now.UtcDateTime) {
    throw 'PINNED_TLS_CLIENT_AUTH_CERT_ACCEPTED'
  }
  Write-Output 'PINNED_TLS_WRONG_EKU_REJECTED_PASS'
  if (Test-VentioPinnedServerCertificate $expired $hostEndpoint (Get-VentioPinnedCertificateSha256 $expired.RawData) $now.UtcDateTime) {
    throw 'PINNED_TLS_EXPIRED_CERT_ACCEPTED'
  }
  Write-Output 'PINNED_TLS_EXPIRED_CERT_REJECTED_PASS'
  if (Test-VentioPinnedServerCertificate $valid $hostEndpoint ('0' * 64) $now.UtcDateTime) {
    throw 'PINNED_TLS_WRONG_FINGERPRINT_ACCEPTED'
  }
  Write-Output 'PINNED_TLS_WRONG_FINGERPRINT_REJECTED_PASS'
}
finally {
  $valid.Dispose()
  $wrongLeaf.Dispose()
  $wrongName.Dispose()
  $wrongUsage.Dispose()
  $expired.Dispose()
}
