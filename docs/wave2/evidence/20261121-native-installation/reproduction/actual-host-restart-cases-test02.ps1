& {
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'TEST-02' -or (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid -cne '4f9cfa6d-48f6-4c66-a3a9-93e612f6bacb'){throw 'IDENTITY_MISMATCH'}
Add-Type -AssemblyName System.Security
$fixture=Get-Content 'C:\Ventio-Acceptance\wave2-business-fixture-246.json' -Raw|ConvertFrom-Json
function Protected-Json([string]$path,[string]$entropy){$encrypted=[IO.File]::ReadAllBytes($path);$plain=$null;try{$plain=[Security.Cryptography.ProtectedData]::Unprotect($encrypted,[Text.Encoding]::UTF8.GetBytes($entropy),[Security.Cryptography.DataProtectionScope]::CurrentUser);return [Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json}finally{[Array]::Clear($encrypted,0,$encrypted.Length);if($plain){[Array]::Clear($plain,0,$plain.Length)}}}
$business=Protected-Json (Join-Path $env:LOCALAPPDATA 'VentioFramework\Acceptance\business-enrollment-246.dpapi') $fixture.pairingOperationId
$admin=Protected-Json (Join-Path $env:LOCALAPPDATA 'VentioFramework\Acceptance\bootstrap-246.dpapi') '922f550e4a5f40dca7764ec180899718'
$token=$business.enrollment.credential
function Http([string]$path,[string]$credential,[object]$body=$null,[string]$method='POST'){
 $headers=@{};if($credential){$headers.Authorization='Bearer '+$credential}
 try{$arguments=@{Uri=('http://127.0.0.1:8080'+$path);Method=$method;Headers=$headers;UseBasicParsing=$true;TimeoutSec=30};if($null -ne $body){$arguments.ContentType='application/json; charset=utf-8';$arguments.Body=[Text.Encoding]::UTF8.GetBytes(($body|ConvertTo-Json -Depth 24 -Compress))};$response=Invoke-WebRequest @arguments;return [pscustomobject]@{Status=[int]$response.StatusCode;Body=($response.Content|ConvertFrom-Json)}}catch{$status=0;$parsed=$null;if($_.Exception.Response){$status=[int]$_.Exception.Response.StatusCode};if($_.ErrorDetails.Message){try{$parsed=$_.ErrorDetails.Message|ConvertFrom-Json}catch{}};return [pscustomobject]@{Status=$status;Body=$parsed}}
}
function Scope([hashtable]$extra=@{}){$body=@{contractVersion=1;companyId=$fixture.companyId;branchId=$fixture.branchId};foreach($key in $extra.Keys){$body[$key]=$extra[$key]};return $body}
function Require([bool]$condition,[string]$failure){if(-not $condition){throw $failure}}
$cases=[Collections.Generic.List[object]]::new()
function Case([string]$id,[string]$description,[scriptblock]$probe){$watch=[Diagnostics.Stopwatch]::StartNew();try{& $probe;$cases.Add([ordered]@{id=$id;description=$description;status='PASS';elapsedMs=$watch.ElapsedMilliseconds})}catch{$cases.Add([ordered]@{id=$id;description=$description;status='FAIL';safeFailure=$_.Exception.Message;elapsedMs=$watch.ElapsedMilliseconds})}}
[Net.ServicePointManager]::Expect100Continue=$false
try {
$payloadManifest=Get-Content 'C:\Program Files\Ventio\host-payload\payload-manifest.json' -Raw|ConvertFrom-Json
Require ($payloadManifest.sourceCommit -ceq '29e36a84875228baf518a2a7030a86bbcb164908') 'PATCHED_NATIVE_PAYLOAD_REQUIRED_BEFORE_MUTATING_ACCEPTANCE'
$inputs=Get-Content 'C:\Ventio-Acceptance\wave2-business-inputs.json' -Raw|ConvertFrom-Json
$statePath='C:\Ventio-Acceptance\actual-business-mutation-state.json'
if(Test-Path -LiteralPath $statePath){$ids=Get-Content $statePath -Raw|ConvertFrom-Json}else{$newIds=[ordered]@{};foreach($name in @('configuration','preferences','view','overlay','create','update','jobCreate','job','organization')){$newIds[$name]=[guid]::NewGuid().ToString()};$newIds|ConvertTo-Json|Set-Content -LiteralPath $statePath -Encoding UTF8;$ids=Get-Content $statePath -Raw|ConvertFrom-Json}
function Platform([string]$action,[hashtable]$fields=@{}){return Http ('/api/v1/platform/'+$action) $token (Scope $fields)}
function Save([string]$kind,[string]$id,[object]$body,[string]$requestId,[int]$revision=0){return Platform 'definitions/save' @{kind=$kind;id=$id;body=$body;requestId=$requestId;expectedRevision=$revision}}
function Command([string]$commandId,[string]$recordId,[string]$name){$command=$inputs.createCommand|ConvertTo-Json -Depth 15|ConvertFrom-Json;$command.commandId=$commandId;$command.tenantId=$fixture.tenantId;$command.companyId=$fixture.companyId;$command.branchId=$fixture.branchId;$command.aggregateId=$recordId;$command.clientContext.actorId=$business.enrollment.actorId;$command.clientContext.deviceId=$business.enrollment.deviceId;$command.payload.values.name=$name;return $command}
$metadata=@{moduleId='com.example.wave2';moduleVersion='1.0.0';docType='Asset'}

$restartIdsPath='C:\Ventio-Acceptance\actual-host-restart-case-ids.json'
if(-not(Test-Path -LiteralPath $restartIdsPath)){
 $generated=[ordered]@{};foreach($key in @('restartJob','restartCommand','deniedJob','deniedCommand')){$generated[$key]=[guid]::NewGuid().ToString()}
 $generated|ConvertTo-Json|Set-Content -LiteralPath $restartIdsPath -Encoding UTF8
}
$restartIds=Get-Content -LiteralPath $restartIdsPath -Raw|ConvertFrom-Json
function Get-CaseConfiguration { $r=Http '/api/v1/platform/definitions/list' $admin.token (Scope @{kind='configuration'});Require ($r.Status -eq 200 -and @($r.Body.result.definitions).Count -eq 1) 'CURRENT_CONFIG_UNAVAILABLE';return $r.Body.result.definitions[0] }
function Set-Pause([bool]$pause) { $current=Get-CaseConfiguration;$next=$current.body|ConvertTo-Json -Depth 15|ConvertFrom-Json;$next.jobsPaused=$pause;$saved=Save 'configuration' 'scope' $next ([guid]::NewGuid().ToString()) ([int]$current.revision);Require ($saved.Status -eq 200 -and $saved.Body.result.status -ceq 'SAVED') 'PAUSE_CHANGE_NOT_APPLIED' }
function Job([string]$id) { $r=Platform 'jobs/list';Require ($r.Status -eq 200) 'JOB_LIST_UNAVAILABLE';$found=@($r.Body.result.jobs|Where-Object jobId -CEQ $id);Require ($found.Count -eq 1) 'JOB_NOT_FOUND';return $found[0] }
function Terminal([string]$id) { $deadline=[datetime]::UtcNow.AddSeconds(60);do{$entry=Job $id;if($entry.state -in @('SUCCEEDED','FAILED','COMPLETED_WITH_ERRORS','CANCELLED')){return $entry};Start-Sleep -Milliseconds 500}while([datetime]::UtcNow -lt $deadline);throw 'JOB_TERMINAL_TIMEOUT' }
function Query-Record([string]$id) { $fields=@{};foreach($key in $metadata.Keys){$fields[$key]=$metadata[$key]};$fields.recordId=$id;$fields.columns=@('name');$r=Platform 'records/query' $fields;Require ($r.Status -eq 200) 'RECORD_QUERY_FAILED';return $r.Body.result }
$originalPause=[bool](Get-CaseConfiguration).body.jobsPaused
Require (-not $originalPause) 'TEST_REQUIRES_ORIGINAL_WORKER_ENABLED'
Case 'IAPI035' 'Queued job and scoped definitions survive actual installed Host service restart' {
 Set-Pause $true
 try{
  $command=Command $restartIds.restartCommand 'installed-restart-job' 'Durable across actual service restart'
  $r=Platform 'jobs/submit' @{jobId=$restartIds.restartJob;commands=@($command)};Require ($r.Status -eq 200) 'RESTART_JOB_SUBMISSION_FAILED'
  Require ((Job $restartIds.restartJob).state -ceq 'QUEUED') 'RESTART_JOB_NOT_QUEUED'
  $service=Get-CimInstance Win32_Service -Filter "Name='VentioHost'"
  Require ($service.StartName -ceq 'NT SERVICE\VentioHost' -and $service.PathName -ceq '"C:\Program Files\Ventio\host-payload\VentioHostService.exe"') 'UNEXPECTED_INSTALLED_SERVICE'
  Require (-not (Get-Content -LiteralPath 'C:\ProgramData\Ventio\Host\recovery.witness' -Raw|ConvertFrom-Json).pending) 'AUTHORITY_PENDING_BEFORE_RESTART'
  Stop-Service VentioHost;(Get-Service VentioHost).WaitForStatus('Stopped',[timespan]::FromSeconds(30))
  Start-Service VentioHost;(Get-Service VentioHost).WaitForStatus('Running',[timespan]::FromSeconds(30))
  $deadline=[datetime]::UtcNow.AddSeconds(60);do{$r=Http '/api/v1/session' $token $null 'GET';if($r.Status -eq 200){break};Start-Sleep -Milliseconds 500}while([datetime]::UtcNow -lt $deadline)
  Require ($r.Status -eq 200 -and $r.Body.identity.deviceId -ceq $business.enrollment.deviceId) 'SESSION_NOT_RESTORED_AFTER_SERVICE_RESTART'
  Require ((Job $restartIds.restartJob).state -ceq 'QUEUED') 'PAUSED_JOB_NOT_DURABLE_AFTER_RESTART'
  foreach($kind in @('saved_view','preferences')){$read=Platform 'definitions/list' @{kind=$kind};Require ($read.Status -eq 200 -and @($read.Body.result.definitions).Count -ge 1) 'SCOPED_DEFINITION_LOST_AFTER_RESTART'}
  $effective=Platform 'metadata/effective' $metadata;Require ($effective.Status -eq 200 -and ($effective.Body.result|ConvertTo-Json -Depth 20 -Compress).Contains('custom_note')) 'CUSTOM_FIELD_LOST_AFTER_RESTART'
 }finally{if((Get-Service VentioHost).Status -ne 'Running'){Start-Service VentioHost};Set-Pause $false}
}
Case 'IAPI036' 'Persisted job executes after restart and retry preserves one original command receipt' {
 $job=Terminal $restartIds.restartJob;Require ($job.state -ceq 'SUCCEEDED') 'RESTART_JOB_DID_NOT_SUCCEED'
 $record=Query-Record 'installed-restart-job';Require (@($record.records).Count -eq 1 -and $record.records[0].revision -eq 1) 'RESTART_JOB_EFFECT_NOT_EXACTLY_ONCE'
 $command=Command $restartIds.restartCommand 'installed-restart-job' 'Durable across actual service restart'
 $retry=Platform 'jobs/submit' @{jobId=$restartIds.restartJob;commands=@($command)};Require ($retry.Status -eq 200) 'JOB_RETRY_NOT_ACCEPTED'
 $again=Terminal $restartIds.restartJob;Require ($again.state -ceq 'SUCCEEDED' -and @($again.outcomes).Count -eq 1 -and $again.outcomes[0].commandId -ceq $restartIds.restartCommand) 'ORIGINAL_JOB_RECEIPT_NOT_PRESERVED'
 $record=Query-Record 'installed-restart-job';Require (@($record.records).Count -eq 1 -and $record.records[0].revision -eq 1) 'JOB_RETRY_DUPLICATED_EFFECT'
}
Case 'IAPI037' 'Revoking a queued job execution permission prevents the real worker from creating a record' {
 Set-Pause $true
 $grant=@{managementApiVersion=1;companyId=$fixture.companyId;branchId=$fixture.branchId;actorId=$fixture.actorId;permission='extension.com_example_wave2.asset.create'}
 $revoked=$false
 try {
  $command=Command $restartIds.deniedCommand 'installed-denied-job' 'Must not be created after permission revocation'
  $r=Platform 'jobs/submit' @{jobId=$restartIds.deniedJob;commands=@($command)};Require ($r.Status -eq 200) 'DENIED_JOB_SUBMISSION_FAILED'
  Require ((Job $restartIds.deniedJob).state -ceq 'QUEUED') 'DENIED_JOB_NOT_PAUSED'
  $r=Http '/api/v1/management/users/revoke' $admin.token $grant;Require ($r.Status -eq 200 -and $r.Body.userOperation.status -ceq 'APPLIED') 'EXECUTION_PERMISSION_REVOCATION_FAILED';$revoked=$true
  Set-Pause $false
  $job=Terminal $restartIds.deniedJob
  Require ($job.state -in @('FAILED','COMPLETED_WITH_ERRORS')) 'REVOKED_WORKER_JOB_NOT_REJECTED'
  $record=Query-Record 'installed-denied-job';Require (@($record.records).Count -eq 0) 'REVOKED_WORKER_CREATED_RECORD'
 }finally{if($revoked){$r=Http '/api/v1/management/users/grant' $admin.token $grant;Require ($r.Status -eq 200 -and $r.Body.userOperation.status -ceq 'APPLIED') 'EXECUTION_PERMISSION_RESTORE_FAILED'};Set-Pause $false}
}

 $record=[ordered]@{recordedAtUtc=[datetime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME;hostSource=$payloadManifest.sourceCommit;actualInstalledHost=$true;actualScmServiceRestart=$true;databaseDirectlyModified=$false;credentialContentsRecorded=$false;cases=@($cases.ToArray());twoDeviceOfflineAcceptanceClaimed=$false;P001_P006Executed=$false}
 $record|ConvertTo-Json -Depth 7|Set-Content -LiteralPath 'C:\Ventio-Acceptance\actual-host-restart-cases-29e.json' -Encoding UTF8
 $record|ConvertTo-Json -Depth 7 -Compress
}finally{$token=$null;$business=$null;$admin=$null}
}

