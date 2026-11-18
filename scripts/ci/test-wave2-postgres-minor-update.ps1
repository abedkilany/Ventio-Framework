$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:COMPUTERNAME -in @('BAHAA','TEST-01','TEST-02')){throw 'Disposable hosted minor-update fixture only'}
$newBin=$env:VENTIO_TEST_POSTGRES_BIN_DIR
if((& (Join-Path $newBin 'postgres.exe') --version) -cne 'postgres (PostgreSQL) 16.16'){throw 'Pinned new PostgreSQL required'}
$root=Join-Path $env:RUNNER_TEMP ('ventio-minor-update-'+[guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $root){throw 'Fresh fixture required'}
[void][IO.Directory]::CreateDirectory($root)
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($sid)
foreach($allowed in @($sid.Value,'S-1-5-18','S-1-5-32-544') | Select-Object -Unique){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($allowed),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
Set-Acl -LiteralPath $root -AclObject $acl
$archive=Join-Path $root 'legacy-upstream.zip'
$oldBin=Join-Path $root 'legacy/pgsql/bin'
$data=Join-Path $root 'data'
$log=Join-Path $root 'postgres.log'
$started=$false;$activeBin=$null
$password=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')
Write-Output ('::add-mask::'+$password)
$prior=$env:PGPASSWORD
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
$report=[ordered]@{id='PG-PHYSICAL-MINOR-UPDATE';commit=$env:GITHUB_SHA;runId=$env:GITHUB_RUN_ID;status='UNEXECUTED';oldVersion='16.15';newVersion='16.16';freshUpstreamOnly=$true;physicalMachinesTouched=$false;recoveryAuthorityClaim='NOT_ESTABLISHED_BY_THIS_STORAGE_LAYER_TEST'}
$out=Join-Path (Get-Location) 'test-results/wave2-runtime'
[void][IO.Directory]::CreateDirectory($out)
try {
  Invoke-WebRequest -Uri 'https://get.enterprisedb.com/postgresql/postgresql-16.15-5-windows-x64-binaries.zip' -OutFile $archive
  $digest=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
  if($digest -cne '43bb45f173a6f08cf1d29a97a6d8deb119e8e8093a24c00d2d1001a0ccaa8281' -or (Get-Item $archive).Length -ne 373254386){throw 'Fresh legacy upstream archive mismatch'}
  $report.oldArchiveSha256=$digest
  Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $root 'legacy')
  if((& (Join-Path $oldBin 'postgres.exe') --version) -cne 'postgres (PostgreSQL) 16.15'){throw 'Legacy version mismatch'}
  $pwFile=Join-Path $root 'password.txt';[IO.File]::WriteAllText($pwFile,$password,[Text.UTF8Encoding]::new($false))
  & (Join-Path $oldBin 'initdb.exe') -D $data --no-sync --locale=C --username=ventio_minor_fixture --auth=scram-sha-256 "--pwfile=$pwFile"
  if($LASTEXITCODE){throw 'Legacy fixture initialization failed'}
  $env:PGPASSWORD=$password
  $activeBin=$oldBin
  & (Join-Path $activeBin 'pg_ctl.exe') -D $data -l $log -o "-h 127.0.0.1 -p $port" -w start
  if($LASTEXITCODE){throw 'Legacy fixture start failed'}
  $started=$true
  $sql="CREATE TABLE minor_update_probe(id integer PRIMARY KEY, payload text NOT NULL); INSERT INTO minor_update_probe VALUES(1,'preserved-before-update'); CREATE TABLE minor_scope_probe(tenant text, secret text); INSERT INTO minor_scope_probe VALUES('a','private-a'),('b','private-b'); ALTER TABLE minor_scope_probe ENABLE ROW LEVEL SECURITY; ALTER TABLE minor_scope_probe FORCE ROW LEVEL SECURITY; CREATE ROLE minor_runtime NOSUPERUSER NOBYPASSRLS; GRANT SELECT ON minor_scope_probe TO minor_runtime; CREATE POLICY tenant_scope ON minor_scope_probe TO minor_runtime USING(tenant='a');"
  & (Join-Path $activeBin 'psql.exe') -X -w -h 127.0.0.1 -p $port -U ventio_minor_fixture -d postgres -v ON_ERROR_STOP=1 -c $sql
  if($LASTEXITCODE){throw 'Legacy SQL seed failed'}
  & (Join-Path $activeBin 'pg_ctl.exe') -D $data -m fast -w stop
  if($LASTEXITCODE){throw 'Legacy fixture did not stop cleanly'}
  $started=$false
  $activeBin=$newBin
  & (Join-Path $activeBin 'pg_ctl.exe') -D $data -l $log -o "-h 127.0.0.1 -p $port" -w start
  if($LASTEXITCODE){throw 'New engine could not open actual legacy data files'}
  $started=$true
  $version= & (Join-Path $activeBin 'psql.exe') -X -w -h 127.0.0.1 -p $port -U ventio_minor_fixture -d postgres -Atc 'SHOW server_version'
  if($LASTEXITCODE -or $version.Trim() -cne '16.16'){throw 'New engine authentication/version mismatch'}
  $query="SELECT payload FROM minor_update_probe WHERE id=1; SET ROLE minor_runtime; SELECT string_agg(tenant||':'||secret,',') FROM minor_scope_probe;"
  $values=@(& (Join-Path $activeBin 'psql.exe') -X -q -w -h 127.0.0.1 -p $port -U ventio_minor_fixture -d postgres -At -v ON_ERROR_STOP=1 -c $query)
  if($LASTEXITCODE -or ($values -join '|') -cne 'preserved-before-update|a:private-a'){throw 'Physical data or restricted RLS changed across minor update'}
  $report.status='PASSED';$report.actualNewVersion=$version.Trim();$report.storageAndRlsPreserved=$true
} catch {$report.status='FAILED';$report.reason=$_.Exception.Message;throw} finally {
  $env:PGPASSWORD=$prior
  if($started){& (Join-Path $activeBin 'pg_ctl.exe') -D $data -m fast -w stop | Out-Null;if($LASTEXITCODE){$report.cleanup='BLOCKED_RUNNING_CLUSTER_PRESERVED'}else{$started=$false}}
  $report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'postgres-minor-update.json')
  $report | ConvertTo-Json -Depth 5
  # Preserve fixture/log evidence for this ephemeral runner; never recursively
  # remove a cluster after an ambiguous shutdown. The whole VM is discarded.
  $password=$null
}
