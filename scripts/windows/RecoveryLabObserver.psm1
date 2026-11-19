Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function New-RecoveryObserverScramVerifier([Security.SecureString]$Secret){
  $pointer=[Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Secret)
  $bytes=$null;$salted=$null;$client=$null;$server=$null;$stored=$null
  try {
    $text=[Runtime.InteropServices.Marshal]::PtrToStringUni($pointer)
    if($text.Length -lt 32 -or $text.Length -gt 256 -or $text -match '[^\x21-\x7e]'){throw 'RECOVERY_OBSERVER_SECRET_PROFILE_INVALID'}
    $bytes=[Text.Encoding]::UTF8.GetBytes($text)
    $salt=New-Object byte[] 16;$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try{$rng.GetBytes($salt)}finally{$rng.Dispose()}
    $derive=[Security.Cryptography.Rfc2898DeriveBytes]::new($bytes,$salt,4096,[Security.Cryptography.HashAlgorithmName]::SHA256)
    try{$salted=$derive.GetBytes(32)}finally{$derive.Dispose()}
    $hmac=[Security.Cryptography.HMACSHA256]::new($salted)
    try{$client=$hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes('Client Key'));$server=$hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes('Server Key'))}finally{$hmac.Dispose()}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$stored=$sha.ComputeHash($client)}finally{$sha.Dispose()}
    return 'SCRAM-SHA-256$4096:'+([Convert]::ToBase64String($salt))+'$'+([Convert]::ToBase64String($stored))+':'+([Convert]::ToBase64String($server))
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer)
    foreach($value in @($bytes,$salted,$client,$server,$stored)){if($null -ne $value){[Array]::Clear($value,0,$value.Length)}}
    $text=$null
  }
}
function New-RecoveryLabObserverSql {
  [CmdletBinding()]param([Parameter(Mandatory)][PSCredential]$Credential,[Parameter(Mandatory)][datetime]$ValidUntilUtc)
  if($Credential.UserName -cne 'ventio_w2_observer' -or $ValidUntilUtc.Kind -ne [DateTimeKind]::Utc -or
     $ValidUntilUtc -le [DateTime]::UtcNow.AddMinutes(30) -or $ValidUntilUtc -gt [DateTime]::UtcNow.AddHours(24)){throw 'RECOVERY_OBSERVER_PROFILE_INVALID'}
  $verifier=New-RecoveryObserverScramVerifier $Credential.Password
  $expiry=$ValidUntilUtc.ToString('yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)+'+00'
  # Fixed SQL, never a caller-supplied file/callback; no plaintext password in SQL.
  return @"
BEGIN;
DO `$guard`$ BEGIN
 IF current_database()<>'ventio_host' OR NOT EXISTS(SELECT FROM pg_roles WHERE rolname=current_user AND rolsuper) THEN RAISE EXCEPTION 'RECOVERY_OBSERVER_BOOTSTRAP_REQUIRED'; END IF;
 IF EXISTS(SELECT FROM pg_roles WHERE rolname IN ('ventio_w2_observer','ventio_w2_observer_owner')) OR to_regnamespace('ventio_w2_fixture') IS NOT NULL THEN RAISE EXCEPTION 'RECOVERY_OBSERVER_EXISTING_PROFILE'; END IF;
END `$guard`$;
CREATE ROLE ventio_w2_observer_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION BYPASSRLS NOINHERIT;
GRANT USAGE ON SCHEMA public TO ventio_w2_observer_owner;
GRANT SELECT(tenant_id,company_id,branch_id,module_id,doc_type,record_id,record_data) ON public.ventio_records TO ventio_w2_observer_owner;
GRANT SELECT(tenant_id,company_id,branch_id,command_id,receipt) ON public.ventio_command_journal TO ventio_w2_observer_owner;
CREATE SCHEMA ventio_w2_fixture AUTHORIZATION ventio_w2_observer_owner;
REVOKE ALL ON SCHEMA ventio_w2_fixture FROM PUBLIC;
CREATE VIEW ventio_w2_fixture.sentinel WITH(security_barrier=true) AS
 SELECT record_data->>'name' AS observed_name FROM public.ventio_records
 WHERE tenant_id='w2-physical-disposable' AND company_id='w2-company' AND branch_id='w2-branch'
 AND module_id='com.example.wave2' AND doc_type='Asset' AND record_id='W2-BACKUP-SENTINEL';
ALTER VIEW ventio_w2_fixture.sentinel OWNER TO ventio_w2_observer_owner;
CREATE VIEW ventio_w2_fixture.receipts WITH(security_barrier=true) AS
 SELECT command_id,receipt->>'status' AS status FROM public.ventio_command_journal
 WHERE tenant_id='w2-physical-disposable' AND company_id='w2-company' AND branch_id='w2-branch';
ALTER VIEW ventio_w2_fixture.receipts OWNER TO ventio_w2_observer_owner;
REVOKE ALL ON ALL TABLES IN SCHEMA ventio_w2_fixture FROM PUBLIC;
CREATE ROLE ventio_w2_observer LOGIN PASSWORD '$verifier' VALID UNTIL '$expiry' CONNECTION LIMIT 2
 NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
GRANT CONNECT ON DATABASE ventio_host TO ventio_w2_observer;
GRANT USAGE ON SCHEMA ventio_w2_fixture TO ventio_w2_observer;
GRANT SELECT ON ventio_w2_fixture.sentinel,ventio_w2_fixture.receipts TO ventio_w2_observer;
ALTER ROLE ventio_w2_observer SET default_transaction_read_only=on;
ALTER ROLE ventio_w2_observer SET statement_timeout='5s';
ALTER ROLE ventio_w2_observer SET idle_in_transaction_session_timeout='5s';
COMMIT;
"@
}
function Add-RecoveryLabObserverHba {
  [CmdletBinding()]param([Parameter(Mandatory)][string]$Path)
  $item=Get-Item -LiteralPath $Path
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'RECOVERY_OBSERVER_HBA_REPARSE_REFUSED'}
  $original=[IO.File]::ReadAllText($item.FullName)
  $originalAcl=Get-Acl -LiteralPath $item.FullName
  if($original -match 'ventio_w2_observer'){throw 'RECOVERY_OBSERVER_HBA_ALREADY_PRESENT'}
  $prefix="# Bounded disposable recovery observer; precedes generic rules.`r`nhost ventio_host ventio_w2_observer 127.0.0.1/32 scram-sha-256`r`nhost all ventio_w2_observer 0.0.0.0/0 reject`r`nhost all ventio_w2_observer ::/0 reject`r`n"
  # Atomic same-directory replacement preserves the destination security metadata;
  # caller is the fresh authorized provisioner only. Never leave a truncated HBA.
  $temporary=Join-Path $item.DirectoryName ('observer-hba-'+[guid]::NewGuid().ToString('N')+'.tmp')
  try {
    $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.Encoding]::UTF8.GetBytes($prefix+$original);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    # File.Replace alone can change inherited ACL metadata on Windows. Both the
    # staged file and final inode must retain the exact original descriptor.
    Set-Acl -LiteralPath $temporary -AclObject $originalAcl
    [IO.File]::Replace($temporary,$item.FullName,[System.Management.Automation.Language.NullString]::Value,$false)
    Set-Acl -LiteralPath $item.FullName -AclObject $originalAcl
    if((Get-Acl -LiteralPath $item.FullName).Sddl -cne $originalAcl.Sddl){throw 'RECOVERY_OBSERVER_HBA_ACL_PRESERVATION_FAILED'}
  } finally {if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
}
Export-ModuleMember -Function New-RecoveryLabObserverSql,Add-RecoveryLabObserverHba
