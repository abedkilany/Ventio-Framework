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
 $binding=@{contractVersion=1;companyId=$fixture.companyId;branchId=$fixture.branchId;moduleId='com.example.wave2';moduleVersion='1.0.0';docType='Asset';recordId='f176a984-67a7-4365-a224-fda35ecd5451'}
 $query=$binding.Clone();$query.columns=@('name','secret');$query.limit=50
 $result=Invoke-RestMethod -Uri 'http://127.0.0.1:8080/api/v1/platform/records/query' -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($query|ConvertTo-Json -Compress)))
 $rows=@($result.result.records)
 if($rows.Count -ne 1 -or $rows[0].revision -ne 2 -or $rows[0].values.name -cne 'Native updated asset 20261121' -or $rows[0].values.secret -cne 'Native redaction sentinel'){throw 'NATIVE_UPDATE_NOT_AUTHORITATIVE_REVISION_TWO'}
 $history=Invoke-RestMethod -Uri 'http://127.0.0.1:8080/api/v1/platform/history/list' -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($binding|ConvertTo-Json -Compress)))
 $encoded=$history.result|ConvertTo-Json -Depth 20 -Compress
 foreach($id in @('88913750-b329-4f0e-b463-4a29f5e0411c','296ffa13-170c-46b9-9bc6-631f67e8f2e2')){if(-not $encoded.Contains($id)){throw 'CREATE_OR_UPDATE_COMMAND_ABSENT_FROM_HISTORY'}}
 [ordered]@{case='NATIVE-UI-CREATE-UPDATE-HOST-CONFIRMATION';status='PASS';checkedAtUtc=[datetime]::UtcNow.ToString('o');actualInstalledClient=$true;clientSource='81661f7f2f10844d0132a5f3b91ab14580ec9a52';actualInstalledHost=$true;hostSource='29e36a84875228baf518a2a7030a86bbcb164908';recordId=$binding.recordId;authoritativeMatchingRecords=$rows.Count;authoritativeRevision=$rows[0].revision;createCommandId='88913750-b329-4f0e-b463-4a29f5e0411c';updateCommandId='296ffa13-170c-46b9-9bc6-631f67e8f2e2';bothCommandsInAuthoritativeHistory=$true;nativeUiHostConfirmed=2;nativeUiPending=0;nativeUiUpdateAttempts=1;verification='Independent read-only authenticated Host API query/history after native UI Save and Retry; no direct database writes';limitation='Single installed Client; multi-device conflicts and convergence remain separate.'}|ConvertTo-Json -Depth 5|Tee-Object -FilePath 'C:\Ventio-Acceptance\native-business-update-20261121.json'
}finally{[Array]::Clear($cipher,0,$cipher.Length);if($plain){[Array]::Clear($plain,0,$plain.Length)};$business=$null;$headers=$null}
}

