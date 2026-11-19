$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:COMPUTERNAME -in @('BAHAA','TEST-01','TEST-02')){throw 'HOSTED_OBSERVER_FIXTURE_ONLY'}
if((Get-Service VentioHost,VentioPostgres -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:ProgramData 'Ventio'))){throw 'NO_INSTALLED_PRODUCT_ALLOWED'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$out=Join-Path $repo 'test-results/recovery-admission';[void][IO.Directory]::CreateDirectory($out)
function Progress-State([string]$Stage){Write-Host ('OBS-FIXTURE '+$Stage);@{stage=$Stage;utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $out 'observer-progress.json')}
Progress-State 'stage-tool-layout'
Import-Module (Join-Path $repo 'scripts/windows/RecoveryLabObserver.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('ventio-pg-initdb-test-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$payload=Join-Path $root 'payload';[void][IO.Directory]::CreateDirectory($payload)
$pg=Join-Path $payload 'postgresql'
# CI-only layout link to the already hash-verified immutable tool distribution;
# do not recopy hundreds of MB through real-time scanning for each fixture.
[void](New-Item -ItemType Junction -Path $pg -Target (Split-Path -Parent $env:VENTIO_TEST_POSTGRES_BIN_DIR))
$bin=Join-Path $pg 'bin'
Copy-Item -LiteralPath (Join-Path $env:RUNNER_TEMP 'observer-migrate.exe') -Destination (Join-Path $payload 'ventio_migrate.exe')
Copy-Item -LiteralPath (Join-Path $repo 'migrations/postgres') -Destination (Join-Path $payload 'migrations') -Recurse
Copy-Item -LiteralPath (Join-Path $repo 'security/postgres') -Destination (Join-Path $payload 'security') -Recurse
$results=[Collections.Generic.List[object]]::new();$running=[Collections.Generic.List[object]]::new()
$password='Fixture-'+[guid]::NewGuid().ToString('N')+'!';$observerPassword='Observer-'+[guid]::NewGuid().ToString('N')+'!'
$out=Join-Path $repo 'test-results/recovery-admission';[void][IO.Directory]::CreateDirectory($out)
function Credential([string]$Name,[string]$Password){return [PSCredential]::new($Name,(ConvertTo-SecureString $Password -AsPlainText -Force))}
function Sql([int]$Port,[string]$User,[string]$Secret,[string]$Database,[string]$Text){
  $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $bin 'psql.exe'));$info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $info.Arguments='-X -q -w -h 127.0.0.1 -p '+$Port+' -U '+$User+' -d '+$Database+' -A -t -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate'
  $info.EnvironmentVariables['PGPASSWORD']=$Secret
  $process=[Diagnostics.Process]::Start($info)
  try{$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.StandardInput.Write($Text);$process.StandardInput.Close();if(-not $process.WaitForExit(60000)){$process.Kill();throw 'SQL_TIMEOUT'};return @{code=$process.ExitCode;value=$stdout.GetAwaiter().GetResult().Trim();error=$stderr.GetAwaiter().GetResult()}}finally{$process.Dispose()}
}
function Require([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function Case([string]$Id,[scriptblock]$Body){Progress-State $Id;try{& $Body;$results.Add(@{id=$Id;status='PASSED'});Write-Output "PASS $Id"}catch{$results.Add(@{id=$Id;status='FAILED';reason=$_.Exception.Message});Write-Output "FAIL $Id $($_.Exception.Message)"}finally{@{sourceCommit=$env:GITHUB_SHA;cases=@($results.ToArray())}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $out 'observer-partial.json')}}
function Free-Port {$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop();return $port}
function Start-Cluster([string]$Data,[int]$Port){
  Progress-State 'start-isolated-cluster'
  # A long-lived Windows server must not inherit a PowerShell pipeline's handles.
  $arguments='-D "'+$Data+'" -l "'+$Data+'.log" -o "-h 127.0.0.1 -p '+$Port+'" -w start'
  $control=Start-Process -FilePath (Join-Path $bin 'pg_ctl.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
  try{if(-not $control.WaitForExit(60000)){$control.Kill();throw 'CI_CLUSTER_START_TIMEOUT'};if($control.ExitCode){throw 'CI_CLUSTER_START_FAILED'}}finally{$control.Dispose()}
  $running.Add(@{data=$Data;port=$Port})
}
function New-Cluster([string]$Name,[bool]$Observer,[switch]$FailHba,[switch]$PreExistingObserver){
  Progress-State ('initialize-'+$Name)
  $data=Join-Path $root $Name;$port=Free-Port
  $pwFile=Join-Path $root ($Name+'-pw.txt')
  [IO.File]::WriteAllText($pwFile,$password,[Text.UTF8Encoding]::new($false))
  $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false)
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;$acl.SetOwner($sid)
  foreach($account in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($account,'FullControl','Allow'))}
  Set-Acl -LiteralPath $pwFile -AclObject $acl
  & (Join-Path $bin 'initdb.exe') -D $data --no-sync --locale=C --username=ventio_bootstrap --auth=scram-sha-256 "--pwfile=$pwFile"|Out-Null
  if($LASTEXITCODE){throw 'CI_INITDB_FAILED'}
  Progress-State ('initdb-completed-'+$Name)
  # Only a random fixture password file, never production data or credentials.
  Remove-Item -LiteralPath $pwFile
  Start-Cluster $data $port
  $seed=Sql $port 'ventio_bootstrap' $password 'postgres' "CREATE ROLE ventio_ci_seed LOGIN SUPERUSER PASSWORD '$password';"
  Require ($seed.code -eq 0) 'Independent CI seed administrator creation failed'
  if($PreExistingObserver){$q=Sql $port 'ventio_bootstrap' $password 'postgres' "CREATE ROLE ventio_w2_observer LOGIN PASSWORD '$observerPassword'";Require ($q.code -eq 0) 'Existing-role negative fixture failed'}
  if($FailHba){Add-Content (Join-Path $data 'pg_hba.conf') '# ventio_w2_observer pre-existing conflict'}
  $arguments=@{PostgresRoot=$pg;DataDirectory=$data;Port=$port;BootstrapCredential=(Credential 'ventio_bootstrap' $password);RuntimeCredential=(Credential 'ventio_runtime_app' $password);IdentityApiCredential=(Credential 'ventio_identity_api_app' $password);MigrationCredential=(Credential 'ventio_migrator_app' $password);Apply=$true;TestMode=$true}
  if($Observer){$arguments.DisposableObserverCredential=Credential 'ventio_w2_observer' $observerPassword;$arguments.ObserverValidUntilUtc=[DateTime]::UtcNow.AddHours(4)}
  $failed=$false
  $failureReason=''
  Progress-State ('production-initializer-'+$Name)
  try{& (Join-Path $repo 'scripts/windows/initialize-host-database.ps1') @arguments|Out-Null}catch{$failed=$true;$failureReason=$_.Exception.Message;if(-not ($FailHba -or $PreExistingObserver)){throw}}
  if($FailHba){Require $failed 'Expected initializer failure not observed'}
  if($PreExistingObserver){Require $failed 'Existing observer was accepted'}
  Progress-State ('initializer-completed-'+$Name)
  return @{data=$data;port=$port;failureReason=$failureReason}
}
try {
  $cluster=New-Cluster 'observer' $true;$port=$cluster.port
  Progress-State 'seed-real-records'
  $seedSql=@'
INSERT INTO public.ventio_records(tenant_id,company_id,branch_id,module_id,doc_type,record_id,revision,record_data) VALUES
 ('w2-physical-disposable','w2-company','w2-branch','com.example.wave2','Asset','W2-BACKUP-SENTINEL',1,'{"name":"before-backup"}'),
 ('other-tenant','w2-company','w2-branch','com.example.wave2','Asset','W2-BACKUP-SENTINEL',1,'{"name":"tenant-secret"}'),
 ('w2-physical-disposable','other-company','w2-branch','com.example.wave2','Asset','W2-BACKUP-SENTINEL',1,'{"name":"company-secret"}'),
 ('w2-physical-disposable','w2-company','other-branch','com.example.wave2','Asset','W2-BACKUP-SENTINEL',1,'{"name":"branch-secret"}'),
 ('w2-physical-disposable','w2-company','w2-branch','other.module','Asset','W2-BACKUP-SENTINEL',1,'{"name":"module-secret"}'),
 ('w2-physical-disposable','w2-company','w2-branch','com.example.wave2','Asset','OTHER-RECORD',1,'{"name":"record-secret"}');
INSERT INTO public.ventio_command_journal(tenant_id,command_id,company_id,branch_id,actor_id,device_id,fingerprint,receipt) VALUES
 ('w2-physical-disposable','11111111-1111-4111-8111-111111111111','w2-company','w2-branch','actor','device','fixture','{"status":"ACCEPTED"}'),
 ('other-tenant','22222222-2222-4222-8222-222222222222','w2-company','w2-branch','actor','device','fixture','{"status":"ACCEPTED"}');
'@
  $seed=Sql $port 'ventio_ci_seed' $password 'ventio_host' $seedSql;Require ($seed.code -eq 0) 'Real fixture seed failed'
  Case 'OBS01-fixed-sentinel-view' {$q=Sql $port 'ventio_w2_observer' $observerPassword 'ventio_host' 'SELECT observed_name FROM ventio_w2_fixture.sentinel';Require ($q.code -eq 0 -and $q.value -ceq 'before-backup') 'View scope/value mismatch'}
  Case 'OBS02-original-receipt-view' {$q=Sql $port 'ventio_w2_observer' $observerPassword 'ventio_host' "SELECT command_id||':'||status FROM ventio_w2_fixture.receipts";Require ($q.code -eq 0 -and $q.value -ceq '11111111-1111-4111-8111-111111111111:ACCEPTED') 'Receipt scope mismatch'}
  foreach($entry in @(
    @{id='OBS03-base-record-denied';sql='SELECT * FROM public.ventio_records'},
    @{id='OBS04-base-journal-denied';sql='SELECT * FROM public.ventio_command_journal'},
    @{id='OBS05-write-after-readwrite-denied';sql="BEGIN READ WRITE; UPDATE public.ventio_records SET record_data='{}'"},
    @{id='OBS06-view-write-denied';sql="BEGIN READ WRITE; DELETE FROM ventio_w2_fixture.receipts"},
    @{id='OBS07-set-owner-role-denied';sql='SET ROLE ventio_w2_observer_owner'},
    @{id='OBS08-private-recovery-schema-denied';sql='SELECT * FROM ventio_security.command_bindings'},
    @{id='OBS09-create-role-denied';sql='BEGIN READ WRITE; CREATE ROLE observer_escalation'},
    @{id='OBS10-create-object-denied';sql='BEGIN READ WRITE; CREATE TABLE ventio_w2_fixture.bad(id integer)'},
    @{id='OBS23-identity-admin-function-denied';sql="SELECT ventio_security.admin_change('{}'::jsonb)"},
    @{id='OBS24-temp-object-denied';sql='BEGIN READ WRITE; CREATE TEMP TABLE observer_temp(id integer)'}
  )){Case $entry.id {$q=Sql $port 'ventio_w2_observer' $observerPassword 'ventio_host' $entry.sql;Require ($q.code -ne 0 -and $q.error -match '42501') 'Expected SQL permission denial not observed'}}
  Case 'OBS11-wrong-database-hba-denied' {$q=Sql $port 'ventio_w2_observer' $observerPassword 'postgres' 'SELECT 1';Require ($q.code -ne 0 -and $q.error -match 'rejects connection') 'Observer reached another database'}
  Case 'OBS12-wrong-secret-denied' {$q=Sql $port 'ventio_w2_observer' 'wrong-secret' 'ventio_host' 'SELECT 1';Require ($q.code -ne 0) 'Bad secret authenticated'}
  Case 'OBS13-bootstrap-retired' {$q=Sql $port 'ventio_bootstrap' $password 'postgres' 'SELECT 1';Require ($q.code -ne 0) 'Bootstrap authenticated after retirement'}
  Case 'OBS14-unchanged-runtime-security-profile' {$q=Sql $port 'ventio_runtime_app' $password 'ventio_host' 'SELECT ventio_security.assert_runtime()';Require ($q.code -eq 0) 'Production runtime/RLS profile failed'}
  Case 'OBS15-role-membership-and-view-barriers' {
    $q=Sql $port 'ventio_ci_seed' $password 'ventio_host' "SELECT rolcanlogin::text||':'||rolsuper::text||':'||rolbypassrls::text FROM pg_roles WHERE rolname='ventio_w2_observer_owner';SELECT count(*) FROM pg_auth_members WHERE roleid IN(SELECT oid FROM pg_roles WHERE rolname IN('ventio_w2_observer_owner','ventio_w2_observer')) OR member IN(SELECT oid FROM pg_roles WHERE rolname='ventio_w2_observer');SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='ventio_w2_fixture' AND c.reloptions @> ARRAY['security_barrier=true'];"
    Require ($q.code -eq 0 -and ($q.value -replace '\r','') -ceq "false:false:true`n0`n2") 'Privilege/view profile differs'
  }
  Case 'OBS16-observer-survives-nondestructive-physical-copy' {
    Write-Host 'OBS-FIXTURE copying to fresh secondary directory; original remains live'
    $copy=Join-Path $root 'fresh-copy';$copyPort=Free-Port;$prior=$env:PGPASSWORD
    $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $bin 'pg_basebackup.exe'));$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.Arguments='-h 127.0.0.1 -p '+$port+' -U ventio_ci_seed -D "'+$copy+'" -X stream -c fast -w';$info.EnvironmentVariables['PGPASSWORD']=$password
    $process=[Diagnostics.Process]::Start($info)
    try{$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();if(-not $process.WaitForExit(180000)){$process.Kill();throw 'Physical copy timed out; fresh copy preserved'};[void]$stdout.GetAwaiter().GetResult();[void]$stderr.GetAwaiter().GetResult();Require ($process.ExitCode -eq 0) 'Physical copy failed'}finally{$process.Dispose();$env:PGPASSWORD=$prior}
    Start-Cluster $copy $copyPort
    $q=Sql $copyPort 'ventio_w2_observer' $observerPassword 'ventio_host' 'SELECT observed_name FROM ventio_w2_fixture.sentinel';Require ($q.code -eq 0 -and $q.value -ceq 'before-backup') 'Observer/physical data missing in fresh copy'
  }
  Case 'OBS17-expired-login-denied' {
    $q=Sql $port 'ventio_ci_seed' $password 'ventio_host' "ALTER ROLE ventio_w2_observer VALID UNTIL '2000-01-01'";Require ($q.code -eq 0) 'Expiry setup failed'
    $q=Sql $port 'ventio_w2_observer' $observerPassword 'ventio_host' 'SELECT 1';Require ($q.code -ne 0) 'Expired observer authenticated'
  }
  $normal=New-Cluster 'normal' $false
  Case 'OBS18-ordinary-setup-has-no-observer' {$q=Sql $normal.port 'ventio_ci_seed' $password 'ventio_host' "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'ventio_w2_observer%';SELECT count(*) FROM pg_namespace WHERE nspname='ventio_w2_fixture'";Require ($q.code -eq 0 -and ($q.value -replace '\r','') -ceq "0`n0") 'Ordinary installation gained fixture privileges'}
  Case 'OBS19-failed-profile-ddl-rolls-back' {
    $sql=New-RecoveryLabObserverSql -Credential (Credential 'ventio_w2_observer' $observerPassword) -ValidUntilUtc ([DateTime]::UtcNow.AddHours(4))
    $q=Sql $normal.port 'ventio_ci_seed' $password 'ventio_host' ($sql.Replace('FROM public.ventio_records','FROM public.absent_fixture_table'));Require ($q.code -ne 0) 'Invalid profile did not fail'
    $q=Sql $normal.port 'ventio_ci_seed' $password 'ventio_host' "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'ventio_w2_observer%'";Require ($q.value -ceq '0') 'Partial observer role survived failed transaction'
  }
  $failed=New-Cluster 'failed-hba' $true -FailHba
  Case 'OBS20-initializer-failure-retires-authority' {$q=Sql $failed.port 'ventio_ci_seed' $password 'ventio_host' "SELECT count(*) FROM pg_authid WHERE rolname IN('ventio_bootstrap','ventio_w2_observer') AND (rolcanlogin OR rolpassword IS NOT NULL)";Require ($q.code -eq 0 -and $q.value -ceq '0') 'Failed fixture retains login authority'}
  Case 'OBS21-expiry-boundaries' {
    foreach($date in @([DateTime]::UtcNow.AddMinutes(5),[DateTime]::UtcNow.AddHours(25),[DateTime]::Now.AddHours(4))){
      $blocked=$false;try{[void](New-RecoveryLabObserverSql -Credential (Credential 'ventio_w2_observer' $observerPassword) -ValidUntilUtc $date)}catch{$blocked=$true}
      Require $blocked 'Invalid expiry accepted'
    }
  }
  Case 'OBS22-weak-secret-and-wrong-user-denied' {
    foreach($credential in @((Credential 'ventio_w2_observer' 'short'),(Credential 'postgres' $observerPassword))){
      $blocked=$false;try{[void](New-RecoveryLabObserverSql -Credential $credential -ValidUntilUtc ([DateTime]::UtcNow.AddHours(4)))}catch{$blocked=$true}
      Require $blocked 'Unsafe observer credential accepted'
    }
  }
  Case 'OBS25-hba-preserves-original-and-acl' {
    $file=Join-Path $root 'hba-atomic-probe.conf';[IO.File]::WriteAllText($file,'# original rules')
    $beforeAcl=(Get-Acl $file).Sddl;Add-RecoveryLabObserverHba $file
    Require ((Get-Acl $file).Sddl -ceq $beforeAcl -and [IO.File]::ReadAllText($file).EndsWith('# original rules')) 'HBA contents/ACL changed unexpectedly'
    $hash=(Get-FileHash $file).Hash;$rejected=$false;try{Add-RecoveryLabObserverHba $file}catch{$rejected=$true}
    Require ($rejected -and (Get-FileHash $file).Hash -ceq $hash) 'Existing observer rules were overwritten'
  }
  Case 'OBS26-high-level-requires-new-host-only' {
    $blocked=$false;try{& (Join-Path $repo 'scripts/windows/provision-host-installation.ps1') -DisposableObserverCredential (Credential 'ventio_w2_observer' $observerPassword)|Out-Null}catch{$blocked=$_.Exception.Message -ceq 'RECOVERY_OBSERVER_FRESH_NEW_HOST_ONLY'}
    Require $blocked 'Observer provisioning did not reject non-fresh high-level mode'
  }
  $existing=New-Cluster 'preexisting-observer' $true -PreExistingObserver
  Case 'OBS27-existing-observer-is-not-modified' {
    Require ($existing.failureReason -ceq 'RECOVERY_OBSERVER_EXISTING_PROFILE') 'Existing role was not rejected before initialization'
    $q=Sql $existing.port 'ventio_ci_seed' $password 'postgres' "SELECT rolcanlogin FROM pg_roles WHERE rolname='ventio_w2_observer';SELECT count(*) FROM pg_database WHERE datname='ventio_host'"
    Require ($q.code -eq 0 -and ($q.value -replace '\r','') -ceq "t`n0") 'Existing role/database changed on rejection'
  }
} catch {
  $results.Add(@{id='OBS-FIXTURE-SETUP';status='FAILED';reason=$_.Exception.Message})
  throw
} finally {
  foreach($cluster in $running){
    $control=Start-Process -FilePath (Join-Path $bin 'pg_ctl.exe') -ArgumentList ('-D "'+$cluster.data+'" -m fast -w stop') -WindowStyle Hidden -PassThru
    try{if(-not $control.WaitForExit(60000)){$control.Kill();$results.Add(@{id='OBS-clean-shutdown';status='FAILED';reason='CI cluster shutdown timed out; directory preserved'})}elseif($control.ExitCode){$results.Add(@{id='OBS-clean-shutdown';status='FAILED';reason='CI cluster shutdown unconfirmed; directory preserved'})}}finally{$control.Dispose()}
  }
  $password=$null;$observerPassword=$null
  [ordered]@{sourceCommit=$env:GITHUB_SHA;runId=$env:GITHUB_RUN_ID;postgresVersion='16.16';cases=@($results.ToArray());installedRecoveryTestsExecuted=$false;physicalVmTouched=$false}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $out 'observer.json')
}
if(@($results|Where-Object status -eq 'FAILED').Count){throw 'Recovery observer security tests failed'}
