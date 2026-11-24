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
try {
$inputs=Get-Content -LiteralPath 'C:\Ventio-Acceptance\wave2-business-inputs.json' -Raw|ConvertFrom-Json
Case 'IAPI053' 'Installed settings reject arbitrary outbound endpoints without executing them' {$body=$inputs.configuration|ConvertTo-Json -Depth 20|ConvertFrom-Json;$body|Add-Member -NotePropertyName outboundUrl -NotePropertyValue 'https://example.invalid/ventio-test';$r=Http '/api/v1/platform/definitions/save' $token (Scope @{kind='configuration';id='scope';body=$body;requestId=[guid]::NewGuid().ToString();expectedRevision=0});Require ($r.Status -eq 400) 'UNDECLARED_OUTBOUND_URL_NOT_REJECTED'}
Case 'IAPI054' 'Installed extension metadata rejects webhook executable fields' {$body=$inputs.bundle|ConvertTo-Json -Depth 20|ConvertFrom-Json;$body.manifest|Add-Member -NotePropertyName webhookCode -NotePropertyValue 'unsupported executable metadata';$r=Http '/api/v1/extensions/submit' $token @{companyId=$fixture.companyId;branchId=$fixture.branchId;package=$body};Require ($r.Status -eq 400) 'EXECUTABLE_WEBHOOK_METADATA_NOT_REJECTED'}
$r=[ordered]@{recordedAtUtc=[datetime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME;hostSource='29e36a84875228baf518a2a7030a86bbcb164908';actualInstalledHost=$true;directSqlUsed=$false;cases=@($cases.ToArray());capabilityCompletionClaimed=$false;P001_P006Executed=$false}
$r|ConvertTo-Json -Depth 7|Set-Content -LiteralPath 'C:\Ventio-Acceptance\actual-host-bounded-integration-cases-29e.json' -Encoding UTF8
$r|ConvertTo-Json -Depth 7 -Compress
}finally{$token=$null;$business=$null;$admin=$null}
}
