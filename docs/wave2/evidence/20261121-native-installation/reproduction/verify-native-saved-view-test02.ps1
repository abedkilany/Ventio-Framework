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
 $definitions=Read-Platform 'definitions/list' @{kind='saved_view'}
 $view=@($definitions.definitions|Where-Object id -CEQ 'installed-assets')
 if($view.Count -ne 1 -or $view[0].revision -ne 2 -or $view[0].body.search -cne 'Native CSV' -or -not $view[0].body.descending -or ($view[0].body.columns -join ',') -cne 'name,custom_note'){throw 'NATIVE_SAVED_VIEW_NOT_PUBLISHED_EXACTLY'}
 $v=$view[0].body
 $binding=@{moduleId=$v.moduleId;moduleVersion=$v.moduleVersion;docType=$v.docType;search=$v.search;filters=$v.filters;sortField=$v.sortField;descending=$v.descending;columns=$v.columns;limit=50}
 $query=Read-Platform 'records/query' $binding
 $export=Read-Platform 'exports/page' $binding
 $csv=@($export.csv|ConvertFrom-Csv)
 if(@($query.records).Count -ne 2 -or $csv.Count -ne 2){throw 'QUERY_EXPORT_COUNT_MISMATCH'}
 for($i=0;$i -lt 2;$i++){if($query.records[$i].recordId -cne $csv[$i].recordId -or $query.records[$i].values.name -cne $csv[$i].name){throw 'QUERY_EXPORT_VALUE_OR_ORDER_MISMATCH'}}
 [ordered]@{case='NATIVE-SAVED-VIEW-SEARCH-SORT-CUSTOM-COLUMN-EXPORT';status='PASS';checkedAtUtc=[datetime]::UtcNow.ToString('o');actualInstalledClient=$true;actualInstalledHost=$true;clientSource='81661f7f2f10844d0132a5f3b91ab14580ec9a52';hostSource='29e36a84875228baf518a2a7030a86bbcb164908';viewId='installed-assets';revision=2;search=$v.search;sortField=$v.sortField;descending=$v.descending;columns=$v.columns;matchingQueryAndExportRows=2;directSqlUsed=$false;limitation='Restart, scope switching, concurrent edits and device acceptance remain separate gates.'}|ConvertTo-Json -Depth 5|Tee-Object -FilePath 'C:\Ventio-Acceptance\native-saved-view-export-20261121.json'
}finally{[Array]::Clear($cipher,0,$cipher.Length);if($plain){[Array]::Clear($plain,0,$plain.Length)};$business=$null;$headers=$null}
}
