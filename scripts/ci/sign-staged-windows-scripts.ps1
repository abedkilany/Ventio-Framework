$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:COMPUTERNAME -in @('BAHAA','TEST-01','TEST-02')){throw 'SIGNING_HOSTED_RUNNER_REQUIRED'}
if($env:SIGNING_THUMBPRINT -cnotmatch '^[0-9A-F]{40}$' -or -not $env:SIGNING_PFX_BASE64 -or -not $env:SIGNING_PFX_PASSWORD){throw 'SIGNING_OWNER_IDENTITY_REQUIRED'}
$pfxPath=Join-Path $env:RUNNER_TEMP ('signing-'+[guid]::NewGuid().ToString('N')+'.pfx')
$certificate=$null
try {
  $stream=[IO.File]::Open($pfxPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$stream.Dispose()
  $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false)
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;$acl.SetOwner($sid)
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','Allow'));Set-Acl -LiteralPath $pfxPath -AclObject $acl
  [IO.File]::WriteAllBytes($pfxPath,[Convert]::FromBase64String($env:SIGNING_PFX_BASE64))
  $securePassword=ConvertTo-SecureString $env:SIGNING_PFX_PASSWORD -AsPlainText -Force
  $certificates=@(Import-PfxCertificate -FilePath $pfxPath -Password $securePassword -CertStoreLocation Cert:\CurrentUser\My)
  $certificate=@($certificates|Where-Object {$_.Thumbprint -ceq $env:SIGNING_THUMBPRINT -and $_.HasPrivateKey})
  if($certificate.Count -ne 1){throw 'SIGNING_PINNED_PRIVATE_IDENTITY_NOT_FOUND'}
  Import-Module (Join-Path $PSScriptRoot '../windows/SignHostScripts.psm1') -Force
  $root=Join-Path $env:RUNNER_TEMP 'ventio-staged-scripts'
  $evidence=Set-VentioStagedScriptSignatures -Root $root -CertificateThumbprint $env:SIGNING_THUMBPRINT -TimestampServer $env:SIGNING_TIMESTAMP
  $evidence|ConvertTo-Json -Depth 8|Set-Content (Join-Path $root 'script-signing-evidence.json')
  $sums=@(Get-ChildItem $root -File -Recurse|ForEach-Object {(Get-FileHash $_.FullName).Hash.ToLowerInvariant()+'  '+$_.FullName.Substring($root.Length+1).Replace('\','/')})
  [IO.File]::WriteAllText((Join-Path $root 'SIGNED-SHA256SUMS.txt'),($sums -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
} finally {
  if(Test-Path -LiteralPath $pfxPath){Remove-Item -LiteralPath $pfxPath}
  foreach($cert in @($certificate)){if($cert){Remove-Item -LiteralPath ('Cert:\CurrentUser\My\'+$cert.Thumbprint) -ErrorAction SilentlyContinue}}
  $env:SIGNING_PFX_BASE64=$null;$env:SIGNING_PFX_PASSWORD=$null;$securePassword=$null
}
