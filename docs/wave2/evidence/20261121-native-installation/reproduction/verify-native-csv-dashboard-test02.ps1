& {
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'TEST-02' -or (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid -cne '4f9cfa6d-48f6-4c66-a3a9-93e612f6bacb'){throw 'IDENTITY_MISMATCH'}
Add-Type -AssemblyName System.Security
$fixture=Get-Content -LiteralPath 'C:\Ventio-Acceptance\wave2-business-fixture-246.json' -Raw|ConvertFrom-Json
$cipher=[IO.File]::ReadAllBytes((Join-Path $env:LOCALAPPDATA 'VentioFramework\Acceptance\business-enrollment-246.dpapi'));$plain=$null
try {
 $plain=[Security.Cryptography.ProtectedData]::Unprotect($cipher,[Text.Encoding]::UTF8.GetBytes($fixture.pairingOperationId),[Security.Cryptography.DataProtectionScope]::CurrentUser)
 $business=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json
 $headers=@{Authorization='Bearer '+$business.enrollment.credential}
 function Read-Platform([string]$action,[hashtable]$fields){$request=@{contractVersion=1;companyId=$fixture.companyId;branchId=$fixture.branchId};foreach($key in $fields.Keys){$request[$key]=$fields[$key]};return (Invoke-RestMethod -Uri ('http://127.0.0.1:8080/api/v1/platform/'+$action) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($request|ConvertTo-Json -Depth 15 -Compress)))).result}
 $jobId='23836c20-d945-48a9-b647-919a3a43648d'
 $jobs=Read-Platform 'jobs/list' @{}
 $job=@($jobs.jobs|Where-Object jobId -CEQ $jobId)
 if($job.Count -ne 1 -or $job[0].state -cne 'SUCCEEDED'){throw 'NATIVE_IMPORT_JOB_NOT_SUCCESSFUL'}
 $expected=@{'native-csv-20261121-a'='Native CSV, first';'native-csv-20261121-b'='Native CSV "quoted"'}
 $records=@()
 foreach($id in $expected.Keys){$query=Read-Platform 'records/query' @{moduleId='com.example.wave2';moduleVersion='1.0.0';docType='Asset';recordId=$id;columns=@('name');limit=50};$rows=@($query.records);if($rows.Count -ne 1 -or $rows[0].revision -ne 1 -or $rows[0].values.name -cne $expected[$id]){throw 'NATIVE_IMPORT_VALUE_OR_SINGLE_EFFECT_MISMATCH'};$records+=@{recordId=$id;revision=$rows[0].revision;name=$rows[0].values.name}}
 $invalid=Read-Platform 'records/query' @{moduleId='com.example.wave2';moduleVersion='1.0.0';docType='Asset';recordId='native-csv-20261121-invalid';columns=@('name')}
 if(@($invalid.records).Count -ne 0){throw 'INVALID_PREVIEW_ROW_CREATED_A_RECORD'}
 $definitions=Read-Platform 'definitions/list' @{kind='dashboard'}
 $dashboard=@($definitions.definitions|Where-Object id -CEQ 'home')
 if($dashboard.Count -ne 1 -or $dashboard[0].revision -ne 1 -or @($dashboard[0].body.cards).Count -ne 1 -or $dashboard[0].body.cards[0].reportId -cne 'asset_count'){throw 'NATIVE_DASHBOARD_NOT_PUBLISHED'}
 [ordered]@{case='NATIVE-UI-CSV-MAPPING-PREVIEW-DURABLE-JOB-AND-DASHBOARD';status='PASS';checkedAtUtc=[datetime]::UtcNow.ToString('o');actualInstalledClient=$true;clientSource='81661f7f2f10844d0132a5f3b91ab14580ec9a52';actualInstalledHost=$true;hostSource='29e36a84875228baf518a2a7030a86bbcb164908';nativeUiJobId=$jobId;authoritativeJobState=$job[0].state;validAuthoritativeRecords=$records;invalidPreviewRowAbsent=$true;dashboardId='home';dashboardRevision=$dashboard[0].revision;directSqlUsed=$false;verification='Native UI input, mapping, Host preview, submit, dashboard publish; independent read-only authenticated API verification.';limitation='Additional revocation, two-device conflict, restart and release compatibility gates remain.'}|ConvertTo-Json -Depth 7|Tee-Object -FilePath 'C:\Ventio-Acceptance\native-csv-dashboard-20261121.json'
}finally{[Array]::Clear($cipher,0,$cipher.Length);if($plain){[Array]::Clear($plain,0,$plain.Length)};$business=$null;$headers=$null}
}

