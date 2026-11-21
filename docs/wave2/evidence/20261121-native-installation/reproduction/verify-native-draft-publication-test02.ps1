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
$path='C:\Ventio-Acceptance\native-draft-publication-20261121.json'
if(Test-Path -LiteralPath $path){throw 'PRIOR_PUBLICATION_REQUIRES_REVIEW'}
$module='com.example.new_extension';$version='0.1.0';$digest='b1cd0ad560c7589debe3724bd0cf3a2ff6101810aa5dd3be22a681784e8ab327'
$scope=@{companyId=$fixture.companyId;branchId=$fixture.branchId;moduleId=$module;version=$version}
$before=Http '/api/v1/extensions/read' $token $scope
Require ($before.Status -eq 404) 'PENDING_CANDIDATE_VISIBLE_AS_APPROVED'
$pending=Http '/api/v1/extensions/submissions' $admin.token @{companyId=$fixture.companyId;branchId=$fixture.branchId;limit=3}
$entry=@($pending.Body.submissions|Where-Object {$_.moduleId -ceq $module -and $_.version -ceq $version -and $_.packageSha256 -ceq $digest -and $_.submittedBy -ceq $fixture.actorId})
Require ($pending.Status -eq 200 -and $entry.Count -eq 1) 'NATIVE_CANDIDATE_NOT_VERIFIED'
$decision=@{companyId=$fixture.companyId;branchId=$fixture.branchId;moduleId=$module;version=$version;packageSha256=$digest;decision='APPROVE'}
$denied=Http '/api/v1/extensions/review' $token $decision
Require ($denied.Status -eq 403) 'SUBMITTING_BUSINESS_ACTOR_REVIEW_NOT_DENIED'
$approved=Http '/api/v1/extensions/review' $admin.token $decision
Require ($approved.Status -eq 200 -and $approved.Body.review.status -ceq 'APPROVED') 'INDEPENDENT_APPROVAL_FAILED'
$read=Http '/api/v1/extensions/read' $token $scope
Require ($read.Status -eq 200 -and $read.Body.packageResult.packageSha256 -ceq $digest) 'APPROVED_PACKAGE_READBACK_FAILED'
$r=[ordered]@{case='NATIVE-DRAFT-TO-INDEPENDENT-HOST-PUBLICATION';status='PASS';utc=[datetime]::UtcNow.ToString('o');moduleId=$module;version=$version;packageSha256=$digest;nativeSubmitter=$fixture.actorId;independentReviewer=$admin.actorId;candidateHiddenBeforeApproval=$true;businessReviewDenied=$true;approvedExactDigest=$true;approvedReadbackMatched=$true;clientSource='81661f7f2f10844d0132a5f3b91ab14580ec9a52';hostSource='29e36a84875228baf518a2a7030a86bbcb164908';nativeInstallFromHost='PENDING';capabilityComplete=$false;directSqlUsed=$false}
$r|ConvertTo-Json|Set-Content -LiteralPath $path -Encoding UTF8
$r|ConvertTo-Json -Compress
}finally{$token=$null;$business=$null;$admin=$null}
}
