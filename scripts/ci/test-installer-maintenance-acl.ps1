param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Elevated disposable Windows test process required'}
$iscc=Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
$id=[guid]::NewGuid().ToString('N')
$root=Join-Path $env:ProgramFiles ('Ventio-Acl-Regression-'+$id)
$output=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $root){throw 'Fresh regression root required'}
[void](New-Item -ItemType Directory -Path $output -Force)
& $iscc ('/DFixtureOutput='+$output) ('/DFixtureId='+$id) tests/wave2/maintenance_file_acl_fixture.iss
if($LASTEXITCODE){throw 'Actual Inno security fixture compilation failed'}
$exe=Join-Path $output 'maintenance-acl-fixture.exe'
$process=Start-Process -FilePath $exe -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' -PassThru -Wait -WindowStyle Hidden
if($process.ExitCode){throw 'Actual Inno security fixture execution failed'}
if((Get-Content -LiteralPath (Join-Path $root 'completed.txt') -Raw) -cne 'PRIVATE_FILE_PROTECTED_AND_MISSING_FILE_REJECTED'){throw 'Fixed-operation completion evidence missing'}
function PrivateRules($acl){
 $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
 return ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ceq 'S-1-5-32-544' -and $rules.Count -eq 2 -and @($rules | Where-Object { $_.IdentityReference.Value -notin @('S-1-5-32-544','S-1-5-18') -or $_.AccessControlType -ne 'Allow' -or $_.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl }).Count -eq 0)
}
$before=Get-Acl -LiteralPath (Join-Path $root 'inherited.txt')
$after=Get-Acl -LiteralPath (Join-Path $root 'protected.txt')
if($before.AreAccessRulesProtected -or -not(PrivateRules $before)){throw 'Original copied-file failure was not reproduced'}
if(-not $after.AreAccessRulesProtected -or -not(PrivateRules $after)){throw 'Installer did not create exact protected administrator/SYSTEM file ACL'}
$report=[ordered]@{case='INNO-MAINTENANCE-PRIVATE-FILE-ACL';status='PASS';utc=[datetime]::UtcNow.ToString('o');originalInheritedFileRejectedByProtectedAclContract=$true;fixedFileProtected=$after.AreAccessRulesProtected;administratorOwned=$true;onlyAdministratorsAndSystemFullControl=$true;missingFileRejected=$true;brokerSecurityContractChanged=$false;fixtureSha256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant();beforeSddl=$before.Sddl;afterSddl=$after.Sddl;root=$root}
$report|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $output 'maintenance-acl-results.json') -Encoding UTF8
$report|ConvertTo-Json -Depth 4
