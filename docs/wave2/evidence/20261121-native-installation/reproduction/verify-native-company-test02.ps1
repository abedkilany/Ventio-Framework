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
 $organization=Read-Platform 'organization/list' @{}
 $company=@($organization.entities|Where-Object {$_.kind -ceq 'company' -and $_.id -ceq 'installed-company'})
 if($company.Count -ne 1 -or $company[0].revision -ne 2 -or $company[0].displayName -cne 'Native acceptance company' -or $company[0].archived){throw 'NATIVE_COMPANY_UPDATE_NOT_AUTHORITATIVE'}
 [ordered]@{case='NATIVE-COMPANY-UPDATE';status='PASS';checkedAtUtc=[datetime]::UtcNow.ToString('o');actualInstalledClient=$true;actualInstalledHost=$true;companyId='installed-company';displayName=$company[0].displayName;revision=$company[0].revision;directSqlUsed=$false;limitation='Hierarchy, membership, archival and concurrency remain separate gates.'}|ConvertTo-Json -Depth 4|Tee-Object -FilePath 'C:\Ventio-Acceptance\native-company-update-20261121.json'
}finally{[Array]::Clear($cipher,0,$cipher.Length);if($plain){[Array]::Clear($plain,0,$plain.Length)};$business=$null;$headers=$null}
}
