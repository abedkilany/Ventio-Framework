& {
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'TEST-02' -or (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid -cne '4f9cfa6d-48f6-4c66-a3a9-93e612f6bacb'){throw 'IDENTITY_MISMATCH'}
Add-Type -AssemblyName System.Security
$fixture=Get-Content -LiteralPath 'C:\Ventio-Acceptance\wave2-business-fixture-246.json' -Raw|ConvertFrom-Json
$cipher=[IO.File]::ReadAllBytes((Join-Path $env:LOCALAPPDATA 'VentioFramework\Acceptance\business-enrollment-246.dpapi'));$plain=$null
try {
 $plain=[Security.Cryptography.ProtectedData]::Unprotect($cipher,[Text.Encoding]::UTF8.GetBytes($fixture.pairingOperationId),[Security.Cryptography.DataProtectionScope]::CurrentUser)
 $enrollment=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json
 $headers=@{Authorization='Bearer '+$enrollment.enrollment.credential}
 $binding=@{contractVersion=1;companyId=$fixture.companyId;branchId=$fixture.branchId;moduleId='com.example.wave2';moduleVersion='1.0.0';docType='Asset'}
 $query=$binding.Clone();$query.columns=@('name');$query.search='Native offline asset 20261121';$query.limit=50
 $reply=Invoke-RestMethod -Uri 'http://127.0.0.1:8080/api/v1/platform/records/query' -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($query|ConvertTo-Json -Compress)))
 $rows=@($reply.result.records)
 if($rows.Count -ne 1 -or $rows[0].revision -ne 1 -or $rows[0].values.name -cne 'Native offline asset 20261121'){throw 'NATIVE_EFFECT_NOT_EXACTLY_ONCE'}
 $path='C:\Ventio-Acceptance\native-business-offline-20261121.json'
 $record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
 $historyBinding=$binding.Clone();$historyBinding.recordId=$rows[0].recordId
 $history=Invoke-RestMethod -Uri 'http://127.0.0.1:8080/api/v1/platform/history/list' -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($historyBinding|ConvertTo-Json -Compress)))
 if(-not($history.result|ConvertTo-Json -Depth 20 -Compress).Contains($record.nativeCommandId)){throw 'NATIVE_COMMAND_NOT_IN_AUTHORITATIVE_HISTORY'}
 $record.phase='PASS_SINGLE_CLIENT_HOST_UNAVAILABLE_RESTART_AND_RECONNECT'
 $record|Add-Member nativeUiHostConfirmedAfterRetry 1
 $record|Add-Member nativeUiPendingAfterRetry 0
 $record|Add-Member sameNativeCommandIdRetained $true
 $record|Add-Member authoritativeRecordId $rows[0].recordId
 $record|Add-Member authoritativeMatchingRecordCount $rows.Count
 $record|Add-Member authoritativeRevision $rows[0].revision
 $record|Add-Member nativeCommandFoundInAuthoritativeHistory $true
 $record|Add-Member completedAtUtc ([datetime]::UtcNow.ToString('o'))
 $record|Add-Member limitation 'Host unavailability on one installed Client; two-device network disconnection, conflicts and convergence remain separate acceptance.'
 $record|ConvertTo-Json -Depth 6|Tee-Object -FilePath $path
}finally{[Array]::Clear($cipher,0,$cipher.Length);if($plain){[Array]::Clear($plain,0,$plain.Length)};$enrollment=$null;$headers=$null}
}

