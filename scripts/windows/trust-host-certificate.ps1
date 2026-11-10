[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $Endpoint,

  [Parameter(Mandatory = $true)]
  [string] $CertificatePath,

  [Parameter(Mandatory = $true)]
  [string] $ExpectedSha256,

  [switch] $Remove
)

$ErrorActionPreference = 'Stop'
$null = Import-Module (Join-Path $PSScriptRoot 'ventio-pinned-tls.psm1') -Force

$normalizedFingerprint = ($ExpectedSha256 -replace '[:\s]', '').ToLowerInvariant()
if ($normalizedFingerprint -notmatch '^[0-9a-f]{64}$') {
  throw 'ExpectedSha256 must be a 64-character SHA-256 fingerprint.'
}

$uri = [Uri]::new($Endpoint)
if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or
    -not [string]::IsNullOrEmpty($uri.UserInfo) -or
    $uri.AbsolutePath -ne '/' -or
    -not [string]::IsNullOrEmpty($uri.Query) -or
    -not [string]::IsNullOrEmpty($uri.Fragment)) {
  throw 'Endpoint must be an HTTPS origin without credentials, query, or fragment.'
}

$certBytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $CertificatePath).Path)
$certText = [System.Text.Encoding]::ASCII.GetString($certBytes)
if ($certText.Contains('-----BEGIN CERTIFICATE-----')) {
  $base64 = $certText -replace '-----BEGIN CERTIFICATE-----', ''
  $base64 = $base64 -replace '-----END CERTIFICATE-----', ''
  $base64 = $base64 -replace '\s', ''
  $certBytes = [Convert]::FromBase64String($base64)
}
$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
if ($certificate.HasPrivateKey) {
  $certificate.Dispose()
  throw 'The trust file must contain only the public Host certificate.'
}
if ((Get-VentioPinnedCertificateSha256 $certificate.RawData) -ne $normalizedFingerprint) {
  $certificate.Dispose()
  throw 'Host certificate fingerprint does not match the fingerprint confirmed out of band.'
}
if (-not $Remove -and -not (Test-VentioPinnedServerCertificate $certificate $uri $normalizedFingerprint)) {
  $certificate.Dispose()
  throw 'Host certificate pin, SAN, validity, or TLS Server Authentication check failed.'
}

$store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
  [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPeople,
  [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
$addedByThisRun = $false
try {
  $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
  $matches = @($store.Certificates | Where-Object {
    (Get-VentioPinnedCertificateSha256 $_.RawData) -eq $normalizedFingerprint
  })
  if ($Remove) {
    foreach ($match in $matches) { $store.Remove($match) }
    [pscustomobject]@{ Endpoint = $uri.GetLeftPart([UriPartial]::Authority); Fingerprint = $normalizedFingerprint; State = 'REMOVED' }
    return
  }
  if ($matches.Count -eq 0) {
    $store.Add($certificate)
    $addedByThisRun = $true
  }
  $healthUri = [Uri]::new($uri.GetLeftPart([UriPartial]::Authority).TrimEnd('/') + '/healthz')
  $curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
  if (-not (Test-Path -LiteralPath $curlExe -PathType Leaf)) {
    throw 'Windows curl.exe is required for the pinned self-signed Host TLS check.'
  }
  $curlCertificatePath = (Resolve-Path -LiteralPath $CertificatePath).Path
  $temporaryCertificatePath = $null
  if (-not $certText.Contains('-----BEGIN CERTIFICATE-----')) {
    $temporaryCertificatePath = Join-Path $env:TEMP ('ventio-host-certificate-' + [Guid]::NewGuid().ToString('N') + '.pem')
    $pem = "-----BEGIN CERTIFICATE-----`r`n$([Convert]::ToBase64String($certificate.RawData, [Base64FormattingOptions]::InsertLineBreaks))`r`n-----END CERTIFICATE-----`r`n"
    [System.IO.File]::WriteAllText($temporaryCertificatePath, $pem, [System.Text.Encoding]::ASCII)
    $curlCertificatePath = $temporaryCertificatePath
  }
  try {
    # Windows' Invoke-WebRequest does not treat the explicitly imported
    # self-signed leaf in TrustedPeople as a chain anchor. curl verifies TLS
    # against the fingerprint-confirmed certificate and checks the HTTPS name,
    # certificate dates, and server-auth usage; it follows no redirects.
    $probe = @(& $curlExe --silent --show-error --fail --proto '=https' --noproxy '*' --max-time 15 --cacert $curlCertificatePath --write-out "`nVENTIO_HTTP_STATUS:%{http_code}" $healthUri 2>$null)
    $curlExitCode = $LASTEXITCODE
    if ($curlExitCode -ne 0) {
      throw "Pinned HTTPS health request failed (curl exit $curlExitCode)."
    }
    $probeText = $probe -join "`n"
    $statusMarker = "`nVENTIO_HTTP_STATUS:"
    $statusOffset = $probeText.LastIndexOf($statusMarker, [StringComparison]::Ordinal)
    if ($statusOffset -lt 0) { throw 'Pinned HTTPS health response omitted the HTTP status.' }
    $body = $probeText.Substring(0, $statusOffset).Trim()
    $statusText = $probeText.Substring($statusOffset + $statusMarker.Length).Trim()
    $health = $body | ConvertFrom-Json
    if ($statusText -ne '200' -or $health.apiVersion -ne 1 -or $health.status -ne 'alive') {
      throw 'Pinned HTTPS health response did not match the Host liveness contract.'
    }
  }
  catch {
    if ($addedByThisRun) { $store.Remove($certificate) }
    throw "Pinned HTTPS validation failed for $($uri.Authority): $($_.Exception.Message)"
  }
  finally {
    if ($null -ne $temporaryCertificatePath -and (Test-Path -LiteralPath $temporaryCertificatePath)) {
      Remove-Item -LiteralPath $temporaryCertificatePath -Force
    }
  }
  [pscustomobject]@{ Endpoint = $uri.GetLeftPart([UriPartial]::Authority); Fingerprint = $normalizedFingerprint; State = 'TRUSTED_AND_VALIDATED' }
}
finally {
  $store.Close()
  $certificate.Dispose()
}
