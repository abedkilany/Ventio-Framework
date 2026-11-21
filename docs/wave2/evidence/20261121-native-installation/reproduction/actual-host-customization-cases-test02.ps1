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
 try{$arguments=@{Uri=('http://127.0.0.1:8080'+$path);Method=$method;Headers=$headers;UseBasicParsing=$true;TimeoutSec=30};if($null -ne $body){$arguments.ContentType='application/json';$arguments.Body=($body|ConvertTo-Json -Depth 24 -Compress)};$response=Invoke-WebRequest @arguments;return [pscustomobject]@{Status=[int]$response.StatusCode;Body=($response.Content|ConvertFrom-Json)}}catch{$status=0;$parsed=$null;if($_.Exception.Response){$status=[int]$_.Exception.Response.StatusCode};if($_.ErrorDetails.Message){try{$parsed=$_.ErrorDetails.Message|ConvertFrom-Json}catch{}};return [pscustomobject]@{Status=$status;Body=$parsed}}
}
function Scope([hashtable]$extra=@{}){$body=@{contractVersion=1;companyId=$fixture.companyId;branchId=$fixture.branchId};foreach($key in $extra.Keys){$body[$key]=$extra[$key]};return $body}
function Require([bool]$condition,[string]$failure){if(-not $condition){throw $failure}}
$cases=[Collections.Generic.List[object]]::new()
function Case([string]$id,[string]$description,[scriptblock]$probe){$watch=[Diagnostics.Stopwatch]::StartNew();try{& $probe;$cases.Add([ordered]@{id=$id;description=$description;status='PASS';elapsedMs=$watch.ElapsedMilliseconds})}catch{$cases.Add([ordered]@{id=$id;description=$description;status='FAIL';safeFailure=$_.Exception.Message;elapsedMs=$watch.ElapsedMilliseconds})}}
function Platform([string]$action,[hashtable]$fields=@{}){return Http ('/api/v1/platform/'+$action) $token (Scope $fields)}
function Save([object]$body,[int]$revision){return Platform 'definitions/save' @{kind='customization';id='com.example.wave2:1.0.0:Asset';body=$body;requestId=[guid]::NewGuid().ToString();expectedRevision=$revision}}
function Clone($object){return $object|ConvertTo-Json -Depth 25|ConvertFrom-Json}
try {
$before=Platform 'definitions/list' @{kind='customization'}
Require ($before.Status -eq 200) 'CUSTOMIZATION_READ_FAILED'
$definition=@($before.Body.result.definitions|Where-Object id -ceq 'com.example.wave2:1.0.0:Asset')
if($definition.Count -eq 0){$definition=@($before.Body.result.definitions|Where-Object definitionId -ceq 'com.example.wave2:1.0.0:Asset')}
Require ($definition.Count -eq 1) 'CURRENT_CUSTOMIZATION_REQUIRED'
$current=$definition[0];$overlay=$current.body;$revision=[int]$current.revision
Require (@($overlay.fields).Count -eq 1 -and $overlay.fields[0].name -ceq 'custom_note') 'EXPECTED_GOVERNED_FIELD_REQUIRED'
Case 'IAPI046' 'Installed Host rejects a customization pinned to another base digest' {$bad=Clone $overlay;$bad.baseSha256='a'*64;$r=Save $bad $revision;Require ($r.Status -eq 409 -and $r.Body.result.reasonCode -ceq 'CUSTOMIZATION_BASE_CHANGED') 'BASE_DIGEST_MISMATCH_NOT_REJECTED'}
Case 'IAPI047' 'Stored custom fields cannot be removed without an explicit migration' {$bad=Clone $overlay;$bad.fields=@();$r=Save $bad $revision;Require ($r.Status -eq 403 -and $r.Body.result.reasonCode -ceq 'CUSTOMIZATION_MIGRATION_REQUIRED') 'DESTRUCTIVE_REMOVAL_NOT_REJECTED'}
Case 'IAPI048' 'Stored custom field constraints cannot change destructively' {$bad=Clone $overlay;$bad.fields[0].maxLength=81;$r=Save $bad $revision;Require ($r.Status -eq 403 -and $r.Body.result.reasonCode -ceq 'CUSTOMIZATION_MIGRATION_REQUIRED') 'DESTRUCTIVE_CONSTRAINT_CHANGE_NOT_REJECTED'}
Case 'IAPI049' 'Customizations cannot weaken field operation permissions' {$bad=Clone $overlay;$bad.fields[0].readPermission='asset.create';$r=Save $bad $revision;Require ($r.Status -eq 400) 'CUSTOM_FIELD_PERMISSION_WEAKENING_NOT_REJECTED'}
Case 'IAPI050' 'Unknown fields cannot be injected into generated presentation layouts' {$bad=Clone $overlay;$bad.ui=New-Object psobject -Property @{formFields=@('name','unknown_field')};$r=Save $bad $revision;Require ($r.Status -eq 400) 'UNKNOWN_LAYOUT_FIELD_NOT_REJECTED'}
Case 'IAPI051' 'Required custom fields cannot invalidate historical records' {$bad=Clone $overlay;$bad.fields[0].required=$true;$r=Save $bad $revision;Require ($r.Status -eq 400) 'REQUIRED_CUSTOM_FIELD_NOT_REJECTED'}
Case 'IAPI052' 'Stale customization revision cannot overwrite a current definition' {$r=Save $overlay 0;Require ($r.Status -eq 409) 'STALE_CUSTOMIZATION_NOT_REJECTED'}
$after=Platform 'definitions/list' @{kind='customization'}
Require ($after.Status -eq 200 -and ($after.Body.result|ConvertTo-Json -Depth 25 -Compress) -ceq ($before.Body.result|ConvertTo-Json -Depth 25 -Compress)) 'REJECTED_OPERATIONS_CHANGED_AUTHORITATIVE_DEFINITION'
$r=[ordered]@{recordedAtUtc=[datetime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME;hostSource='29e36a84875228baf518a2a7030a86bbcb164908';actualInstalledHost=$true;directSqlUsed=$false;cases=@($cases.ToArray());deniedOperationsLeftDefinitionUnchanged=$true;capabilityCompletionClaimed=$false;P001_P006Executed=$false}
$r|ConvertTo-Json -Depth 7|Set-Content -LiteralPath 'C:\Ventio-Acceptance\actual-host-customization-cases-29e.json' -Encoding UTF8
$r|ConvertTo-Json -Depth 7 -Compress
}finally{$token=$null;$business=$null;$admin=$null}
}
