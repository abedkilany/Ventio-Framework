& {
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -cne 'TEST-02' -or (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid -cne '4f9cfa6d-48f6-4c66-a3a9-93e612f6bacb') { throw 'TARGET_IDENTITY_MISMATCH' }
$manifest = Get-Content -LiteralPath 'C:\Program Files\Ventio\host-payload\payload-manifest.json' -Raw | ConvertFrom-Json
if ($manifest.sourceCommit -cne '29e36a84875228baf518a2a7030a86bbcb164908') { throw 'INSTALLED_HOST_SOURCE_CHANGED' }
Add-Type -AssemblyName System.Security
$fixture = Get-Content -LiteralPath 'C:\Ventio-Acceptance\wave2-business-fixture-246.json' -Raw | ConvertFrom-Json
$encrypted = [IO.File]::ReadAllBytes((Join-Path $env:LOCALAPPDATA 'VentioFramework\Acceptance\business-enrollment-246.dpapi'))
$plain = $null
try {
  $plain = [Security.Cryptography.ProtectedData]::Unprotect($encrypted,[Text.Encoding]::UTF8.GetBytes($fixture.pairingOperationId),[Security.Cryptography.DataProtectionScope]::CurrentUser)
  $credential = ([Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json).enrollment.credential
} finally {
  [Array]::Clear($encrypted,0,$encrypted.Length)
  if ($plain) { [Array]::Clear($plain,0,$plain.Length) }
}
function Call([string]$action,[hashtable]$fields) {
  $body = @{contractVersion=1;companyId=$fixture.companyId;branchId=$fixture.branchId}
  foreach ($key in $fields.Keys) { $body[$key] = $fields[$key] }
  try {
    $response = Invoke-WebRequest -Uri ('http://127.0.0.1:8080/api/v1/platform/'+$action) -Method POST -Headers @{Authorization=('Bearer '+$credential)} -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 20 -Compress))) -UseBasicParsing -TimeoutSec 30
    return [pscustomobject]@{code=[int]$response.StatusCode;body=($response.Content | ConvertFrom-Json)}
  } catch {
    $code = 0
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    $body = $null
    if ($_.ErrorDetails.Message) { try { $body = $_.ErrorDetails.Message | ConvertFrom-Json } catch {} }
    return [pscustomobject]@{code=$code;body=$body}
  }
}
function Check([bool]$condition,[string]$failure) { if (-not $condition) { throw $failure } }
$id = 'w2-archive-20261122'
$report = [ordered]@{case='M01-INSTALLED-ORGANIZATION-ARCHIVE-REACTIVATE';machine=$env:COMPUTERNAME;sourceCommit=$manifest.sourceCommit;startedAtUtc=[DateTime]::UtcNow.ToString('o');status='FAIL';branchId=$id;cases=@();credentialsRecorded=$false;directSqlUsed=$false}
try {
  $before = Call 'organization/list' @{}
  Check ($before.code -eq 200) 'INITIAL_ORGANIZATION_LIST_FAILED'
  Check (@($before.body.result.entities | Where-Object id -CEQ $id).Count -eq 0) 'BRANCH_ID_ALREADY_USED'
  $create = Call 'organization/change' @{change=@{kind='branch';id=$id;parentId='w2-company';displayName='Wave 2 archive roundtrip';archived=$false;expectedRevision=0;requestId=[guid]::NewGuid().ToString()}}
  Check ($create.code -eq 200 -and $create.body.result.status -ceq 'SAVED' -and $create.body.result.revision -eq 1) 'CREATE_FAILED'
  $report.cases += [ordered]@{id='M01-AR01';status='PASS';observed='create revision 1'}
  $archive = Call 'organization/change' @{change=@{kind='branch';id=$id;parentId='w2-company';displayName='Wave 2 archive roundtrip';archived=$true;expectedRevision=1;requestId=[guid]::NewGuid().ToString()}}
  Check ($archive.code -eq 200 -and $archive.body.result.status -ceq 'SAVED' -and $archive.body.result.revision -eq 2) 'ARCHIVE_FAILED'
  $archived = Call 'organization/list' @{}
  $item = @($archived.body.result.entities | Where-Object id -CEQ $id)
  Check ($archived.code -eq 200 -and $item.Count -eq 1 -and $item[0].archived -and $item[0].revision -eq 2) 'ARCHIVE_NOT_VISIBLE'
  $report.cases += [ordered]@{id='M01-AR02';status='PASS';observed='archived revision 2 in Host list'}
  $stale = Call 'organization/change' @{change=@{kind='branch';id=$id;parentId='w2-company';displayName='Must not overwrite';archived=$false;expectedRevision=1;requestId=[guid]::NewGuid().ToString()}}
  Check ($stale.code -eq 409 -and $stale.body.result.reasonCode -ceq 'ENTITY_CHANGED') 'STALE_REVISION_NOT_REJECTED'
  $report.cases += [ordered]@{id='M01-AR03';status='PASS';observed='stale revision rejected'}
  $restore = Call 'organization/change' @{change=@{kind='branch';id=$id;parentId='w2-company';displayName='Wave 2 archive roundtrip';archived=$false;expectedRevision=2;requestId=[guid]::NewGuid().ToString()}}
  Check ($restore.code -eq 200 -and $restore.body.result.status -ceq 'SAVED' -and $restore.body.result.revision -eq 3) 'REACTIVATION_FAILED'
  $final = Call 'organization/list' @{}
  $item = @($final.body.result.entities | Where-Object id -CEQ $id)
  Check ($final.code -eq 200 -and $item.Count -eq 1 -and -not $item[0].archived -and $item[0].revision -eq 3) 'REACTIVATION_NOT_VISIBLE'
  $report.cases += [ordered]@{id='M01-AR04';status='PASS';observed='active revision 3 in Host list'}
  $report.status = 'PASS_SUBSET'
} catch { $report.reason = $_.Exception.Message }
$report.completedAtUtc = [DateTime]::UtcNow.ToString('o')
$report | ConvertTo-Json -Depth 8 -Compress
$credential = $null
if ($report.status -cne 'PASS_SUBSET') { exit 1 }
}
