$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'HostProductDataRoot.psm1') -Force
$serviceSid='S-1-5-80-2937531145-1946914961-2559665931-1852289769-150109794'
$acl=New-HostProductDataRootAcl -ServiceSids @($serviceSid,$serviceSid)
if(-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-32-544'){throw 'Root owner or inheritance is unsafe.'}
$rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
if($rules.Count -ne 3){throw 'Unexpected root ACL principal.'}
foreach($rule in $rules){
  $sid=$rule.IdentityReference.Value
  if($rule.IsInherited -or $rule.AccessControlType -ne 'Allow' -or $rule.InheritanceFlags -ne 'None'){throw 'Root ACL propagates unreviewed child access.'}
  $expected=if($sid -eq $serviceSid){[Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize}else{[Security.AccessControl.FileSystemRights]::FullControl}
  if($sid -notin @($serviceSid,'S-1-5-18','S-1-5-32-544') -or $rule.FileSystemRights -ne $expected){throw 'Unexpected root ACL capability.'}
}
$rejected=$false
try{New-HostProductDataRootAcl -ServiceSids @('S-1-5-21-1-2-3-1001') | Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Interactive user SID accepted as a service identity.'}
$rejected=$false
try{Protect-HostProductDataRoot -TestRoot 'C:\Unrelated'}catch{$rejected=$true}
if(-not $rejected){throw 'Production path override was accepted.'}
Write-Output 'HOST_PRODUCT_DATA_ROOT_SECURITY_TESTS_PASS: administrator ownership, protected inheritance, service-only traversal, duplicate SID handling, interactive writer rejection, and fixed production boundary.'
