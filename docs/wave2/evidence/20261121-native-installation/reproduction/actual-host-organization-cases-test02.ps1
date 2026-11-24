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

$orgIdsPath='C:\Ventio-Acceptance\actual-organization-case-ids.json'
if(-not(Test-Path -LiteralPath $orgIdsPath)){@{createBranch=[guid]::NewGuid().ToString()}|ConvertTo-Json|Set-Content -LiteralPath $orgIdsPath -Encoding UTF8}
$orgIds=Get-Content -LiteralPath $orgIdsPath -Raw|ConvertFrom-Json
$original=Platform 'organization/list';Require ($original.Status -eq 200) 'ORGANIZATION_SNAPSHOT_UNAVAILABLE'
$originalCompany=@($original.Body.result.entities|Where-Object {$_.kind -ceq 'company' -and $_.id -ceq 'installed-company'})[0]
Require ($originalCompany.revision -eq 2 -and $originalCompany.displayName -ceq 'Native acceptance company') 'EXPECTED_NATIVE_COMPANY_REVISION_REQUIRED'
Case 'IAPI038' 'Installed organization CAS denies a stale company edit and preserves the native update' {
 $r=Platform 'organization/change' @{change=@{kind='company';id='installed-company';displayName='Must not overwrite newer native company';archived=$false;expectedRevision=1;requestId=[guid]::NewGuid().ToString()}}
 Require ($r.Status -eq 409) 'STALE_COMPANY_UPDATE_NOT_DENIED'
 $after=Platform 'organization/list';$company=@($after.Body.result.entities|Where-Object {$_.kind -ceq 'company' -and $_.id -ceq 'installed-company'})[0]
 Require ($company.revision -eq 2 -and $company.displayName -ceq $originalCompany.displayName) 'STALE_COMPANY_EDIT_CHANGED_ENTITY'
}
Case 'IAPI039' 'Installed current company cannot be archived while in use' {
 $r=Platform 'organization/change' @{change=@{kind='company';id='w2-company';displayName='w2-company';archived=$true;expectedRevision=1;requestId=[guid]::NewGuid().ToString()}}
 Require ($r.Status -eq 403 -and $r.Body.result.reasonCode -ceq 'COMPANY_IN_USE') 'CURRENT_COMPANY_ARCHIVAL_NOT_DENIED'
}
Case 'IAPI040' 'Installed current branch cannot archive its active scope' {
 $r=Platform 'organization/change' @{change=@{kind='branch';id='w2-branch';parentId='w2-company';displayName='w2-branch';archived=$true;expectedRevision=1;requestId=[guid]::NewGuid().ToString()}}
 Require ($r.Status -eq 403 -and $r.Body.result.reasonCode -ceq 'CURRENT_SCOPE_IN_USE') 'CURRENT_BRANCH_ARCHIVAL_NOT_DENIED'
}
Case 'IAPI041' 'Installed branch creation rejects an unavailable company parent' {
 $r=Platform 'organization/change' @{change=@{kind='branch';id='invalid-parent-branch';parentId='missing-company';displayName='Must remain absent';archived=$false;expectedRevision=0;requestId=[guid]::NewGuid().ToString()}}
 Require ($r.Status -eq 403 -and $r.Body.result.reasonCode -ceq 'PARENT_UNAVAILABLE') 'MISSING_PARENT_WAS_ADMITTED'
}
Case 'IAPI042' 'Installed platform denies an ungranted branch binding' {
 $r=Platform 'settings/read' @{branchId='not-granted'};Require ($r.Status -eq 403) 'UNGRANTED_BRANCH_SETTINGS_WERE_EXPOSED'
}
$branchChange=@{kind='branch';id='installed-extra-branch';parentId='w2-company';displayName='Installed additional branch';archived=$false;expectedRevision=0;requestId=$orgIds.createBranch}
Case 'IAPI043' 'Authorized installed branch creation persists a valid parent hierarchy' {
 $r=Platform 'organization/change' @{change=$branchChange};Require ($r.Status -eq 200 -and $r.Body.result.status -ceq 'SAVED' -and $r.Body.result.revision -eq 1) 'AUTHORIZED_BRANCH_CREATION_FAILED'
 $list=Platform 'organization/list';$branch=@($list.Body.result.entities|Where-Object {$_.kind -ceq 'branch' -and $_.id -ceq 'installed-extra-branch'})
 Require ($branch.Count -eq 1 -and $branch[0].parentId -ceq 'w2-company' -and $branch[0].revision -eq 1) 'BRANCH_PARENT_OR_REVISION_NOT_PERSISTED'
}
Case 'IAPI044' 'Creating a branch grants no implicit business membership or credential scope' {
 $r=Platform 'settings/read' @{branchId='installed-extra-branch'};Require ($r.Status -eq 403) 'NEW_BRANCH_IMPLICITLY_GRANTED_BUSINESS_ACCESS'
}
Case 'IAPI045' 'Installed branch creation retry preserves its original revision receipt' {
 $r=Platform 'organization/change' @{change=$branchChange};Require ($r.Status -eq 200 -and $r.Body.result.status -ceq 'SAVED' -and $r.Body.result.revision -eq 1) 'BRANCH_RETRY_CHANGED_REVISION'
}
$final=Platform 'organization/list';Require ($final.Status -eq 200) 'ORGANIZATION_SNAPSHOT_LOST'
foreach($entity in @($final.Body.result.entities|Where-Object {($_.kind -ceq 'company' -and $_.id -ceq 'w2-company') -or ($_.kind -ceq 'branch' -and $_.id -ceq 'w2-branch')})){Require (-not $entity.archived -and $entity.revision -eq 1) 'DENIED_ARCHIVAL_CHANGED_ACTIVE_SCOPE'}
Require (@($final.Body.result.entities|Where-Object id -CEQ 'invalid-parent-branch').Count -eq 0) 'REJECTED_PARENT_CREATED_ENTITY'
$record=[ordered]@{recordedAtUtc=[datetime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME;hostSource=$payloadManifest.sourceCommit;actualInstalledHost=$true;directSqlUsed=$false;credentialContentsRecorded=$false;cases=@($cases.ToArray());capabilityCompletionClaimed=$false;P001_P006Executed=$false}
$record|ConvertTo-Json -Depth 7|Set-Content -LiteralPath 'C:\Ventio-Acceptance\actual-host-organization-cases-29e.json' -Encoding UTF8
$record|ConvertTo-Json -Depth 7 -Compress
}finally{$token=$null;$business=$null;$admin=$null}
}
