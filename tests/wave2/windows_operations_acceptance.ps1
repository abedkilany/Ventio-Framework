[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$FixtureManifest,
  [switch]$ApproveLocalOperations,
  [switch]$AllowDisposableRestore
)

# PREPARED / NOT EXECUTED. Real installed operator, Task Scheduler and cluster.
# Requires a separately provisioned DISPOSABLE VM and explicit elevated approval.
# It never installs Ventio, obtains a secret from protected stores, resets a
# witness, starts Host after restore, changes AV/policy, or deletes the fixture.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Test-Case([string]$Id,[string]$Capabilities,[string]$Requirement,[scriptblock]$Body){& $Body;Write-Output "PASS $Id [$Capabilities] $Requirement"}
Assert-True ($env:VENTIO_WAVE2_PREPARED_TESTS -ceq 'yes') 'Explicit disposable-fixture test opt-in required.'
Assert-True ($env:COMPUTERNAME -notin @('VENTIO-TEST-01','VENTIO-TEST-02') -and $env:COMPUTERNAME -match '^VENTIO-W2-VM[0-9]{2}$') 'Only a separately provisioned disposable Windows VM is permitted.'
Assert-True ($ApproveLocalOperations -and $AllowDisposableRestore) 'Explicit local-operation and disposable-restore approvals are both required.'
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
Assert-True ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Launch this reviewed test suite through normal local administrator elevation.'
$fixture=Get-Content -LiteralPath $FixtureManifest -Raw|ConvertFrom-Json
$programData=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$markerPath=Join-Path $programData 'Ventio-W2-Disposable\fixture.json'
$marker=Get-Content -LiteralPath $markerPath -Raw|ConvertFrom-Json
Assert-True ($fixture.fixtureOnly -eq $true -and $marker.fixtureOnly -eq $true -and $fixture.fixtureNonce -ceq $marker.fixtureNonce -and $fixture.machineName -ceq $env:COMPUTERNAME -and $marker.machineName -ceq $env:COMPUTERNAME) 'Disposable VM marker/manifest mismatch.'
Assert-True ($fixture.machineGuid -ceq $marker.machineGuid -and $marker.machineGuid -ceq (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid) 'Disposable marker belongs to another Windows installation.'
$markerAcl=Get-Acl -LiteralPath $markerPath
Assert-True ($markerAcl.AreAccessRulesProtected -and $markerAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ceq 'S-1-5-32-544') 'Fixture marker must be administrator-owned and private.'
foreach($id in @($fixture.tenantId,$fixture.companyId,$fixture.branchId,$fixture.actorId,$fixture.deviceId)){
  Assert-True ($id -cmatch '^[A-Za-z0-9_.-]{1,128}$') 'Bounded disposable fixture identities required.'
}
Assert-True ($fixture.tenantId -ceq 'w2-physical-disposable') 'Expected dedicated disposable tenant.'
Assert-True (-not [string]::IsNullOrWhiteSpace($env:VENTIO_W2_TOKEN)) 'Supply supported fixture credential through environment; do not put it in the manifest.'
Assert-True (-not [string]::IsNullOrWhiteSpace($env:VENTIO_W2_OBSERVER_DSN)) 'Supply dedicated disposable observer access before any fixture mutation.'
$payload=Join-Path $env:ProgramFiles 'Ventio\host-payload'
$manifestPath=Join-Path $payload 'payload-manifest.json'
Assert-True ($fixture.payloadManifestSha256 -cmatch '^[0-9a-f]{64}$' -and (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $fixture.payloadManifestSha256) 'Payload must match the separately approved candidate manifest.'
$payloadManifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
foreach($entry in $payloadManifest.verifiedFiles){
  $file=[IO.Path]::GetFullPath((Join-Path $payload ([string]$entry.path).Replace('/','\')))
  Assert-True ($file.StartsWith([IO.Path]::GetFullPath($payload).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) 'Payload inventory escapes root.'
  Assert-True ((Get-Item -LiteralPath $file).Length -eq $entry.length -and (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $entry.sha256) 'Candidate payload bytes differ.'
}
Import-Module (Join-Path $payload 'setup\HostBackupIntegrity.psm1') -Force
Import-Module (Join-Path $payload 'setup\HostOperationStorage.psm1') -Force
$operator=Join-Path $payload 'setup\manage-host-operations.ps1'
$backups=Join-Path $programData 'Ventio\Backups'
$state=Join-Path $programData 'Ventio\Installer\Operations'
$spool=Join-Path $programData 'Ventio\Host\Operations'
$liveData=Join-Path $programData 'Ventio\PostgreSQL\data'
$witness=[IO.Path]::GetFullPath([string]$fixture.recoveryWitnessPath)
Assert-True (-not $witness.StartsWith([IO.Path]::GetFullPath($liveData),[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $witness -PathType Leaf)) 'Independent existing recovery witness required.'
Assert-True (-not (Test-Path -LiteralPath $backups) -or @(Get-ChildItem -LiteralPath $backups -Directory).Count -eq 0) 'Fresh disposable backup root required; preserved backups are never reused.'
$headers=@{Authorization='Bearer '+$env:VENTIO_W2_TOKEN}
function Api([string]$Action,[hashtable]$Fields=@{}){
  $body=@{contractVersion=1;companyId=$fixture.companyId;branchId=$fixture.branchId}
  foreach($key in $Fields.Keys){$body[$key]=$Fields[$key]}
  $reply=Invoke-RestMethod -Uri ('http://127.0.0.1:8080/api/v1/platform/'+$Action) -Method Post -Headers $headers -ContentType 'application/json' -Body ($body|ConvertTo-Json -Depth 30 -Compress)
  return $reply.result
}
function Wait-Until([scriptblock]$Probe,[string]$Failure,[int]$Seconds=180){
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt $Seconds){$value=& $Probe;if($value){return $value};Start-Sleep -Milliseconds 250}
  throw $Failure
}
function Invoke-ScheduledFixture {
  [void](Wait-Until {(Get-ScheduledTask -TaskPath '\Ventio\' -TaskName 'VentioHostBackups').State -eq 'Ready'} 'Previous scheduled invocation did not finish.')
  $previousRun=(Get-ScheduledTaskInfo -TaskPath '\Ventio\' -TaskName 'VentioHostBackups').LastRunTime
  # LastRunTime can have coarse resolution. Cross that boundary before firing,
  # then require a NEW completed invocation rather than observing the old Ready
  # state immediately after Start-ScheduledTask returns.
  [void](Wait-Until {[DateTime]::UtcNow -gt $previousRun.ToUniversalTime().AddSeconds(2)} 'Scheduler run timestamp did not advance.')
  Start-ScheduledTask -TaskPath '\Ventio\' -TaskName 'VentioHostBackups'
  return Wait-Until {
    $info=Get-ScheduledTaskInfo -TaskPath '\Ventio\' -TaskName 'VentioHostBackups'
    $task=Get-ScheduledTask -TaskPath '\Ventio\' -TaskName 'VentioHostBackups'
    if($info.LastRunTime -gt $previousRun -and $task.State -eq 'Ready'){
      Assert-True ($info.LastTaskResult -eq 0) 'New scheduled invocation did not complete successfully.'
      return $info
    }
  } 'No new completed scheduled invocation was observed.'
}
function Prepare([string]$Operation,[hashtable]$Body=@{}){
  $id=[guid]::NewGuid().ToString()
  $reply=Api 'operations/prepare' @{operationId=$id;operation=$Operation;body=$Body}
  Assert-True ($reply.state -ceq 'AWAITING_LOCAL_APPROVAL') 'Operation was not admitted for local approval.'
  [void](Wait-Until {Test-Path -LiteralPath (Join-Path $spool ($id+'.request.json')) -PathType Leaf} 'Host offer was not delivered.')
  return $id
}
function Invoke-Local([string]$Id,[switch]$Restore,[string]$PlanHash){
  if($Restore){& $operator -OperationId $Id -ConfirmRestore -ExpectedPlanSha256 $PlanHash|Out-Null;return}
  & $operator -OperationId $Id|Out-Null
  return Wait-Until {
    $entry=@((Api 'operations/list').operations|Where-Object operationId -CEQ $Id)
    if($entry.Count -eq 1 -and $entry[0].state -in @('SUCCEEDED','FAILED')){return $entry[0]}
  } 'Operation did not reconcile its terminal result.'
}
function Backup-Root([string]$Name){
  Assert-True ($Name -cmatch '^ventio-postgresql-before-upgrade-[0-9]{8}T[0-9]{9}Z-[0-9a-f]{32}$') 'Invalid fixture backup identity.'
  $root=[IO.Path]::GetFullPath((Join-Path $backups $Name))
  Assert-True ([IO.Path]::GetDirectoryName($root) -ceq [IO.Path]::GetFullPath($backups)) 'Backup escapes fixture root.'
  return $root
}
function Verify-Backup([string]$Name){
  $root=Backup-Root $Name
  $manifest=Read-VentioOperationJson (Join-Path $root 'backup-manifest.json') 'S-1-5-32-544' 134217728
  Assert-True ($manifest.formatVersion -eq 2 -and $manifest.recoveryAuthorityIncluded -eq $false -and $manifest.integrityAlgorithm -ceq 'SHA-256') 'Backup integrity/trust profile differs.'
  Assert-HostBackupIntegrity (Join-Path $root 'data') @($manifest.files)
  return $manifest
}
function Record-Command([string]$Type,[string]$Value,[int]$Revision=0){
  $id=[guid]::NewGuid().ToString()
  $body=@{protocolVersion=0;commandId=$id;type=$Type;typeVersion=1;tenantId=$fixture.tenantId;companyId=$fixture.companyId;branchId=$fixture.branchId;aggregateId='W2-BACKUP-SENTINEL';expectedRevision=$(if($Revision -gt 0){$Revision}else{$null});dependsOn=@();payload=@{moduleId='com.example.wave2';docType='Asset';values=@{name=$Value}};clientContext=@{actorId=$fixture.actorId;deviceId=$fixture.deviceId;moduleVersion='1.0.0';docTypeVersion=1}}
  $reply=Invoke-RestMethod -Uri 'http://127.0.0.1:8080/api/v1/commands' -Method Post -Headers $headers -ContentType 'application/json' -Body ($body|ConvertTo-Json -Depth 15 -Compress)
  Assert-True ($reply.receipt.status -ceq 'ACCEPTED') 'Fixture command was not accepted.'
  return $reply.receipt
}
function Observer-Query([string]$Sql){
  # Only dedicated VM administrator-supplied fixture observer access. No
  # application secret-store reads, token dumping or passwords in argv/logs.
  $dsn=[uri]$env:VENTIO_W2_OBSERVER_DSN
  Assert-True ($dsn.Scheme -ceq 'postgresql' -and $dsn.Host -ceq '127.0.0.1' -and $dsn.Port -eq 54329 -and $dsn.AbsolutePath -ceq '/ventio_host') 'Pinned disposable observer endpoint required.'
  $parts=$dsn.UserInfo.Split(':',2)
  Assert-True ($parts.Length -eq 2) 'Observer fixture authentication missing.'
  $previous=$env:PGPASSWORD
  try{
    $env:PGPASSWORD=[uri]::UnescapeDataString($parts[1])
    $output=& (Join-Path $payload 'postgresql\bin\psql.exe') -X -w -h 127.0.0.1 -p 54329 -U ([uri]::UnescapeDataString($parts[0])) -d ventio_host -A -t -v ON_ERROR_STOP=1 -c $Sql 2>$null
    Assert-True ($LASTEXITCODE -eq 0) 'Disposable observer query failed.'
    return ([string]::Join('',@($output))).Trim()
  }finally{$env:PGPASSWORD=$previous}
}
$backupName=$null;$createReceipt=$null;$policy=@{contractVersion=1;enabled=$true;utcTime='00:00';retainDays=1;retainCopies=2;maximumAttempts=2;retryMinutes=5}
Test-Case 'W2-P001' 'D09,M05,M09' 'Real disposable installed Host authenticates the approved fixture identity' {
  $session=Invoke-RestMethod -Uri 'http://127.0.0.1:8080/api/v1/session' -Method Get -Headers $headers
  Assert-True ($session.identity.actorId -ceq $fixture.actorId -and $session.identity.tenantId -ceq $fixture.tenantId) 'Wrong fixture identity.'
  Assert-True ((Get-Service VentioHost).Status -eq 'Running' -and (Get-Service VentioPostgres).Status -eq 'Running') 'Installed fixture services not running.'
  $script:createReceipt=Record-Command 'extension.record.create' 'before-backup'
  Assert-True ((Observer-Query "SELECT record_data->>'name' FROM public.ventio_records WHERE tenant_id='$($fixture.tenantId)' AND record_id='W2-BACKUP-SENTINEL'") -ceq 'before-backup') 'Observer does not see actual committed seed.'
}
Test-Case 'W2-P002' 'M05' 'Supported Host authorization and elevated local approval arm the fixed SYSTEM schedule' {
  Assert-True (@((Api 'definitions/list' @{kind='backup_policy'}).definitions).Count -eq 0) 'Fresh policy fixture required.'
  $saved=Api 'definitions/save' @{kind='backup_policy';id='scope';expectedRevision=0;requestId=[guid]::NewGuid().ToString();body=$policy}
  Assert-True ($saved.status -ceq 'SAVED') 'Policy was not saved.'
  $result=Invoke-Local (Prepare 'APPLY_POLICY')
  Assert-True ($result.state -ceq 'SUCCEEDED' -and $result.result.code -ceq 'BACKUP_POLICY_ARMED') 'Local policy approval failed.'
  $task=Get-ScheduledTask -TaskPath '\Ventio\' -TaskName 'VentioHostBackups'
  Assert-True ($task.Principal.UserId -in @('SYSTEM','S-1-5-18') -and $task.Principal.RunLevel -eq 'Highest' -and $task.Settings.MultipleInstances -eq 'IgnoreNew') 'Scheduler identity/concurrency differs.'
  Assert-True ($task.Actions.Execute -ceq (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -and $task.Actions.Arguments.Contains($operator) -and $task.Actions.Arguments.Contains('-RunScheduled')) 'Scheduler executes an unexpected action.'
}
Test-Case 'W2-P003' 'M05' 'Real scheduled backup verifies content and does not repeat a completed daily offer' {
  $scheduled=Wait-Until {@((Api 'operations/list').operations|Where-Object {$null -ne $_.scheduledFor -and $_.state -in @('AWAITING_LOCAL_APPROVAL','SUCCEEDED')})|Select-Object -First 1} 'No due scheduled offer.'
  [void](Invoke-ScheduledFixture)
  $id=$scheduled.operationId
  $result=Wait-Until {$row=@((Api 'operations/list').operations|Where-Object operationId -CEQ $id);if($row.Count -eq 1 -and $row[0].state -in @('SUCCEEDED','FAILED')){$row[0]}} 'Scheduled backup did not finish.'
  Assert-True ($result.state -ceq 'SUCCEEDED' -and $result.result.code -ceq 'BACKUP_COMPLETE') 'Scheduled backup failed.'
  $script:backupName=[string]$result.result.backupName
  [void](Verify-Backup $backupName)
  $before=@(Get-ChildItem -LiteralPath $backups -Directory).Count
  [void](Invoke-ScheduledFixture)
  Assert-True (@(Get-ChildItem -LiteralPath $backups -Directory).Count -eq $before) 'Completed daily backup repeated.'
}
Test-Case 'W2-P004' 'M05' 'Actual retention removes only eligible old copies and preserves pins foreign kinds and newest backup' {
  $original=Backup-Root $backupName
  $clones=@()
  for($i=0;$i -lt 4;$i++){
    $name='ventio-postgresql-before-upgrade-20000101T00000000'+$i+'Z-'+[guid]::NewGuid().ToString('N')
    $target=Backup-Root $name
    Copy-Item -LiteralPath $original -Destination $target -Recurse
    Set-Acl -LiteralPath $target -AclObject (Get-Acl -LiteralPath $original)
    $metadata=Get-Content -LiteralPath (Join-Path $target 'backup-manifest.json') -Raw|ConvertFrom-Json
    $metadata.createdAtUtc=[DateTime]::UtcNow.AddDays(-20-$i).ToString('o')
    if($i -eq 3){$metadata.backupKind='upgrade'}
    Write-VentioOperationJson (Join-Path $target 'backup-manifest.json') $metadata 'S-1-5-32-544'
    [void](Verify-Backup $name);$clones+= $name
  }
  $pin=Invoke-Local (Prepare 'RESTORE_PLAN' @{backupName=$clones[0]})
  Assert-True ($pin.state -ceq 'SUCCEEDED') 'Pin fixture not approved.'
  $applied=Invoke-Local (Prepare 'APPLY_POLICY')
  Assert-True ($applied.state -ceq 'SUCCEEDED') 'Fresh local policy approval failed.'
  $scheduled=Wait-Until {@((Api 'operations/list').operations|Where-Object {$null -ne $_.scheduledFor -and $_.state -eq 'AWAITING_LOCAL_APPROVAL'})|Select-Object -First 1} 'No retention offer.'
  [void](Invoke-ScheduledFixture)
  $id=$scheduled.operationId
  $result=Wait-Until {$row=@((Api 'operations/list').operations|Where-Object operationId -CEQ $id);if($row.Count -eq 1 -and $row[0].state -in @('SUCCEEDED','FAILED')){$row[0]}} 'Retention did not finish.'
  Assert-True ($result.state -ceq 'SUCCEEDED') 'Retention backup failed.'
  foreach($name in @($clones[1],$clones[2])){Assert-True (-not (Test-Path -LiteralPath (Backup-Root $name))) 'Eligible old copy survived retention.'}
  foreach($name in @($clones[0],$clones[3],$backupName,[string]$result.result.backupName)){Assert-True (Test-Path -LiteralPath (Backup-Root $name)) 'Pinned foreign-kind or good backup was removed.'}
  Assert-True (Test-Path -LiteralPath (Join-Path $liveData 'PG_VERSION')) 'Retention touched live data.'
}
Test-Case 'W2-P005' 'M05,M09' 'Real restore planning detects same-size corruption before stopping Host' {
  $name='ventio-postgresql-before-upgrade-20000102T000000000Z-'+[guid]::NewGuid().ToString('N')
  $target=Backup-Root $name;$original=Backup-Root $backupName
  Copy-Item -LiteralPath $original -Destination $target -Recurse
  Set-Acl -LiteralPath $target -AclObject (Get-Acl -LiteralPath $original)
  $file=Get-ChildItem -LiteralPath (Join-Path $target 'data') -Recurse -File|Where-Object Length -GT 0|Select-Object -First 1
  $stream=[IO.File]::Open($file.FullName,'Open','ReadWrite','None')
  try{$byte=$stream.ReadByte();$stream.Position=0;$stream.WriteByte([byte]($byte -bxor 1));$stream.Flush($true)}finally{$stream.Dispose()}
  $result=Invoke-Local (Prepare 'RESTORE_PLAN' @{backupName=$name})
  Assert-True ($result.state -ceq 'FAILED' -and $result.result.code -ceq 'HOST_BACKUP_INTEGRITY_CONTENT_MISMATCH') 'Corrupt backup passed restore planning.'
  Assert-True ((Get-Service VentioHost).Status -eq 'Running') 'Rejected plan stopped Host.'
}
Test-Case 'W2-P006' 'M09,M05,J03' 'Disposable restoration preserves current cluster external witness and original record/receipt while leaving Host stopped' {
  $plan=Invoke-Local (Prepare 'RESTORE_PLAN' @{backupName=$backupName})
  Assert-True ($plan.state -ceq 'SUCCEEDED') 'Restore plan failed.'
  [void](Record-Command 'extension.record.update' 'after-backup' 1)
  [void](Api 'definitions/save' @{kind='preferences';id='post-backup-witness';expectedRevision=0;requestId=[guid]::NewGuid().ToString();body=@{contractVersion=1;theme='dark';density='compact';moduleOrder=@('com.example.wave2')}})
  $id=Prepare 'RESTORE' @{backupName=$backupName;planOperationId=$plan.operationId;planSha256=$plan.result.planSha256}
  # Preparing an authorized operation can advance the live admission witness.
  # Compare the restore itself against the witness AFTER that admitted change.
  $witnessHash=(Get-FileHash -LiteralPath $witness -Algorithm SHA256).Hash
  Invoke-Local $id -Restore -PlanHash $plan.result.planSha256
  $serviceSid=[Security.Principal.NTAccount]::new('NT SERVICE','VentioHost').Translate([Security.Principal.SecurityIdentifier]).Value
  $result=Read-VentioOperationJson (Join-Path $spool ($id+'.result.json')) $serviceSid
  Assert-True ($result.state -ceq 'SUCCEEDED' -and $result.code -ceq 'RESTORED_RECOVERY_AUTHORITY_RECONCILIATION_REQUIRED' -and $result.restoreRequiresRecovery -eq $true) 'Restore not durably recorded as requiring recovery.'
  Assert-True ((Get-Service VentioHost).Status -eq 'Stopped') 'Restore automatically reopened Host.'
  Assert-True ((Get-FileHash -LiteralPath $witness -Algorithm SHA256).Hash -ceq $witnessHash) 'Restore rewrote independent witness.'
  Assert-True ((Observer-Query "SELECT record_data->>'name' FROM public.ventio_records WHERE tenant_id='$($fixture.tenantId)' AND record_id='W2-BACKUP-SENTINEL'") -ceq 'before-backup') 'Restored data does not match backup.'
  Assert-True ((Observer-Query "SELECT count(*) FROM public.ventio_command_journal WHERE tenant_id='$($fixture.tenantId)' AND command_id='$($createReceipt.commandId)' AND receipt->>'status'='ACCEPTED'") -ceq '1') 'Original receipt missing from restore.'
  Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $liveData) -Directory -Filter 'data.failed-upgrade-*').Count -gt 0) 'Current cluster was not preserved.'
  # Deliberately no witness adoption, credential resurrection or Host restart.
}
