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

Case 'IAPI024' 'Installed CSV preview handles BOM quoted commas escaped quotes and embedded newlines' {$fields=@{};foreach($key in $metadata.Keys){$fields[$key]=$metadata[$key]};$fields.csv=[char]0xFEFF+"id,Name`n"+'quoted-csv-a,"Line one,'+"`n"+'Line two ""quoted"""';$fields.mapping=@{Name='name'};$fields.recordIdHeader='id';$r=Platform 'imports/preview' $fields;$expected="Line one,`nLine two "+'"quoted"';Require ($r.Status -eq 200 -and $r.Body.result.validRows -eq 1 -and $r.Body.result.rows[0].values.name -ceq $expected) 'ACTUAL_QUOTED_CSV_DID_NOT_ROUND_TRIP'}
Case 'IAPI025' 'Installed CSV preview enforces its configured 500-row bound' {$fields=@{};foreach($key in $metadata.Keys){$fields[$key]=$metadata[$key]};$fields.csv="id,Name`n"+((1..501|ForEach-Object {'row-'+$_+',Name '+$_}) -join "`n");$fields.mapping=@{Name='name'};$fields.recordIdHeader='id';$r=Platform 'imports/preview' $fields;Require ($r.Status -eq 400) 'ACTUAL_CSV_ROW_BOUND_NOT_ENFORCED'}
Case 'IAPI026' 'Unknown installed API routes are refused' {$r=Http '/api/v1/platform/arbitrary-handler' $token (Scope);Require ($r.Status -eq 400 -and $r.Body.error.code -ceq 'INVALID_COMMAND') 'UNKNOWN_ROUTE_WAS_ADMITTED'}
Case 'IAPI027' 'Caller cannot override its authenticated tenant' {$r=Platform 'settings/read' @{tenantId='other-tenant'};Require ($r.Status -eq 400) 'TENANT_SPOOFING_FIELD_WAS_ADMITTED'}
Case 'IAPI028' 'Oversized integration bodies are rejected before processing' {$r=Platform 'settings/read' @{padding=('x'*70000)};Require ($r.Status -eq 413) 'ACTUAL_REQUEST_BYTE_BOUND_NOT_ENFORCED'}
Case 'IAPI029' 'Current field revocation stops the next export page despite an unchanged token ceiling' {
 $fields=@{};foreach($key in $metadata.Keys){$fields[$key]=$metadata[$key]};$fields.columns=@('name','secret');$fields.limit=1;$fields.sortField='name';$fields.descending=$false;$fields.search='';$fields.filters=@{}
 $first=Platform 'exports/page' $fields;Require ($first.Status -eq 200 -and $first.Body.result.hasMore -and $first.Body.result.nextCursor) 'EXPORT_REVOCATION_FIXTURE_MISSING_CURSOR'
 $body=@{managementApiVersion=1;companyId=$fixture.companyId;branchId=$fixture.branchId;actorId=$fixture.actorId;permission='extension.com_example_wave2.asset.secret_read'}
 $revoked=$false
 try{
  $r=Http '/api/v1/management/users/revoke' $admin.token $body;Require ($r.Status -eq 200 -and $r.Body.userOperation.status -ceq 'APPLIED') 'CURRENT_FIELD_REVOCATION_FAILED';$revoked=$true
  $fields.cursor=$first.Body.result.nextCursor;$r=Platform 'exports/page' $fields;Require ($r.Status -eq 403) 'REVOKED_FIELD_WAS_EXPORTED_ON_NEXT_PAGE'
  $query=@{};foreach($key in $metadata.Keys){$query[$key]=$metadata[$key]};$query.columns=@('name');$query.sortField='secret';$r=Platform 'records/query' $query;Require ($r.Status -eq 403) 'REVOKED_SORT_FIELD_PERMITTED_INFERENCE'
 }finally{if($revoked){$restored=Http '/api/v1/management/users/grant' $admin.token $body;Require ($restored.Status -eq 200 -and $restored.Body.userOperation.status -ceq 'APPLIED') 'FIXTURE_FIELD_PERMISSION_RESTORE_FAILED'}}
}
Case 'IAPI030' 'Governed overlays leave the approved base package byte identity unchanged' {$r=Http '/api/v1/extensions/read' $token @{companyId=$fixture.companyId;branchId=$fixture.branchId;moduleId='com.example.wave2';version='1.0.0'};Require ($r.Status -eq 200 -and $r.Body.packageResult.packageSha256 -ceq $inputs.bundleSha256 -and -not ($r.Body.packageResult.package.docTypes[0].fields.name -ccontains 'custom_note')) 'APPROVED_BASE_PACKAGE_CHANGED_WITH_OVERLAY'}
Case 'IAPI031' 'Executable SQL properties are rejected in declarative customizations' {$bad=$inputs.overlay|ConvertTo-Json -Depth 20|ConvertFrom-Json;$bad.fields[0]|Add-Member -NotePropertyName sql -NotePropertyValue 'SELECT 1';$r=Save 'customization' 'com.example.wave2:1.0.0:Asset' $bad ([guid]::NewGuid().ToString()) 1;Require ($r.Status -eq 400) 'DECLARATIVE_SQL_FIELD_WAS_ADMITTED'}
Case 'IAPI032' 'Declarative extension cannot supply executable command handlers' {$bad=$inputs.bundle|ConvertTo-Json -Depth 20|ConvertFrom-Json;$bad.manifest.commands=@(@{type='powershell.exe';handler='arbitrary'});$r=Http '/api/v1/extensions/submit' $token @{companyId=$fixture.companyId;branchId=$fixture.branchId;package=$bad};Require ($r.Status -eq 400) 'EXECUTABLE_EXTENSION_HANDLER_WAS_ADMITTED'}
Case 'IAPI033' 'Installed report rejects a filter not declared in report metadata' {$r=Http '/api/v1/extensions/reports/query' $token @{companyId=$fixture.companyId;branchId=$fixture.branchId;moduleId='com.example.wave2';version='1.0.0';docType='Asset';reportId='asset_count';filters=@{secret='forbidden'}};Require ($r.Status -eq 422 -and $r.Body.reportResult.reasonCode -ceq 'INVALID_REPORT_FILTER') 'UNDECLARED_REPORT_FILTER_WAS_ADMITTED'}
Case 'IAPI034' 'Cancellation of a paused durable job prevents its future business effect' {
 # Configuration definition reads require host.status.read. Keep that separate
 # from the scoped business management grant rather than inventing a permission.
 $definitionReply=Http '/api/v1/platform/definitions/list' $admin.token (Scope @{kind='configuration'});Require ($definitionReply.Status -eq 200) 'AUTHORIZED_CONFIGURATION_READ_FAILED';$definitions=@($definitionReply.Body.result.definitions);Require ($definitions.Count -eq 1) 'CURRENT_CONFIGURATION_REQUIRED'
 $current=$definitions[0];$paused=$current.body|ConvertTo-Json -Depth 15|ConvertFrom-Json;$paused.jobsPaused=$true
 $saved=Save 'configuration' 'scope' $paused ([guid]::NewGuid().ToString()) ([int]$current.revision);Require ($saved.Status -eq 200 -and $saved.Body.result.status -ceq 'SAVED') 'JOB_PAUSE_CONFIGURATION_FAILED'
 try{
  $jobId=[guid]::NewGuid().ToString();$recordId='cancelled-'+[guid]::NewGuid().ToString('N');$command=Command ([guid]::NewGuid().ToString()) $recordId 'Must remain uncreated'
  $submitted=Platform 'jobs/submit' @{jobId=$jobId;commands=@($command)};Require ($submitted.Status -eq 200) 'PAUSED_JOB_SUBMISSION_FAILED'
  $cancel=Platform 'jobs/cancel' @{jobId=$jobId};Require ($cancel.Status -eq 200) 'ACTUAL_JOB_CANCELLATION_FAILED'
  $list=Platform 'jobs/list';$job=@($list.Body.result.jobs|Where-Object jobId -CEQ $jobId);Require ($job.Count -eq 1 -and $job[0].state -ceq 'CANCELLED') 'ACTUAL_JOB_NOT_DURABLY_CANCELLED'
  $query=@{};foreach($key in $metadata.Keys){$query[$key]=$metadata[$key]};$query.columns=@('name');$query.recordId=$recordId;$r=Platform 'records/query' $query;Require ($r.Status -eq 200 -and @($r.Body.result.records).Count -eq 0) 'CANCELLED_JOB_CREATED_A_BUSINESS_RECORD'
 }finally{$restored=Save 'configuration' 'scope' $current.body ([guid]::NewGuid().ToString()) ([int]$saved.Body.result.revision);Require ($restored.Status -eq 200 -and $restored.Body.result.status -ceq 'SAVED') 'FIXTURE_CONFIGURATION_RESTORE_FAILED'}
}

$record=[ordered]@{recordedAtUtc=[datetime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME;hostSource=$payloadManifest.sourceCommit;actualInstalledHost=$true;directSqlUsed=$false;credentialContentsRecorded=$false;cases=@($cases.ToArray());capabilityCompletionClaimed=$false;P001_P006Executed=$false}
$record|ConvertTo-Json -Depth 7|Set-Content -LiteralPath 'C:\Ventio-Acceptance\actual-host-negative-cases-29e.json' -Encoding UTF8
$record|ConvertTo-Json -Depth 7 -Compress
}finally{$token=$null;$business=$null;$admin=$null}
}
