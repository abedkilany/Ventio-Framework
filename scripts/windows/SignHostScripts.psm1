Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Set-VentioStagedScriptSignatures {
  [CmdletBinding()]param([Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{40}$')][string]$CertificateThumbprint,
    [string]$TimestampServer,[switch]$FixtureCertificate)
  if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:COMPUTERNAME -in @('BAHAA','TEST-01','TEST-02')){throw 'SIGNING_CLEAN_HOSTED_RUNNER_REQUIRED'}
  $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\')
  $checkout=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
  # Never append signature blocks to checked-out source or accept reparse traversal.
  if($rootPath -eq $checkout -or $rootPath.StartsWith($checkout+'\',[StringComparison]::OrdinalIgnoreCase)){
    $allowed=Join-Path $checkout 'packages\ventio_host_api\build\'
    if(-not $rootPath.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'SIGNING_SOURCE_TREE_REFUSED'}
  }
  $cursor=Get-Item -LiteralPath $rootPath
  while($cursor){if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'SIGNING_REPARSE_PATH_REFUSED'};$cursor=$cursor.Parent}
  if(@(Get-ChildItem -LiteralPath $rootPath -Force -Recurse | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'SIGNING_REPARSE_MEMBER_REFUSED'}
  $certificate=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$CertificateThumbprint)
  if(-not $certificate.HasPrivateKey -or $certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow -or
     $certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
     '1.3.6.1.5.5.7.3.3' -notin @($certificate.EnhancedKeyUsageList | ForEach-Object {$_.ObjectId.Value})){throw 'SIGNING_CERTIFICATE_PROFILE_INVALID'}
  if(-not $FixtureCertificate -and ($TimestampServer -notmatch '^https://[^\s]+$')){throw 'SIGNING_RELEASE_TIMESTAMP_REQUIRED'}
  $files=@(Get-ChildItem -LiteralPath $rootPath -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.psm1','.psd1','.ps1xml')})
  if(-not $files.Count){throw 'SIGNING_EMPTY_SCRIPT_CLOSURE'}
  $records=@()
  foreach($file in $files){
    $sourceHash=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    $arguments=@{FilePath=$file.FullName;Certificate=$certificate;HashAlgorithm='SHA256';ErrorAction='Stop'}
    if($TimestampServer){$arguments.TimestampServer=$TimestampServer}
    $signature=Set-AuthenticodeSignature @arguments
    $verified=Get-AuthenticodeSignature -LiteralPath $file.FullName
    if($signature.Status -ne 'Valid' -or $verified.Status -ne 'Valid' -or $verified.SignerCertificate.Thumbprint -cne $CertificateThumbprint -or
       (-not $FixtureCertificate -and $null -eq $verified.TimeStamperCertificate)){throw 'SIGNING_SIGNATURE_VERIFICATION_FAILED'}
    $records+=[ordered]@{path=$file.FullName.Substring($rootPath.Length+1).Replace('\','/');sourceSha256=$sourceHash;signedSha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant();publisherThumbprint=$CertificateThumbprint;timestamped=($null -ne $verified.TimeStamperCertificate)}
  }
  [ordered]@{schemaVersion=1;fixtureCertificate=[bool]$FixtureCertificate;sourceCommit=$env:GITHUB_SHA;runId=$env:GITHUB_RUN_ID;publisherThumbprint=$CertificateThumbprint;files=$records}
}
Export-ModuleMember -Function Set-VentioStagedScriptSignatures
