& {
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:COMPUTERNAME -cne 'TEST-02' -or (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Cryptography).MachineGuid -cne '4f9cfa6d-48f6-4c66-a3a9-93e612f6bacb'){throw 'WRONG_TARGET'}
$fixture='C:\Ventio-Acceptance\candidate-44912845335\maintenance-acl-fixture.exe';$expected='9b75f8e155eefddc02dc5e3c19ca0f784923265f807f9c7eee2fbbc36552ce59'
if((Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected){throw 'FIXTURE_HASH_MISMATCH'}
$protection=Get-MpComputerStatus
if(-not($protection.AntivirusEnabled -and $protection.RealTimeProtectionEnabled) -or $protection.DefenderSignaturesOutOfDate){throw 'CURRENT_PROTECTION_REQUIRED'}
$mp=Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'; & $mp -CheckExclusion -Path $fixture | Out-Null
if($LASTEXITCODE -ne 1){throw 'EFFECTIVE_EXCLUSION_NOT_CLEAR'}
Start-MpScan -ScanType CustomScan -ScanPath $fixture
if(@(Get-MpThreat | Where-Object IsActive).Count){throw 'THREAT_REPORTED'}
if((Get-ExecutionPolicy).ToString() -cne 'Restricted'){throw 'POLICY_CHANGED'}
$process=Start-Process -FilePath $fixture -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' -WindowStyle Hidden -PassThru -Wait
if($process.ExitCode -ne 0){throw 'FIXTURE_EXECUTION_FAILED'}
$root='C:\Program Files\Ventio-Acl-Regression-618f2f1e10e64da6ad8220620a7b6ec1'
$before=Get-Acl -LiteralPath ($root+'\inherited.txt');$after=Get-Acl -LiteralPath ($root+'\protected.txt')
$rules=@($after.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
$passed=(-not $before.AreAccessRulesProtected -and $after.AreAccessRulesProtected -and $after.GetOwner([Security.Principal.SecurityIdentifier]).Value -ceq 'S-1-5-32-544' -and $rules.Count -eq 2 -and @($rules|Where-Object {$_.IdentityReference.Value -notin @('S-1-5-32-544','S-1-5-18') -or $_.AccessControlType -ne 'Allow' -or $_.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl}).Count -eq 0 -and (Get-Content -LiteralPath ($root+'\completed.txt') -Raw) -ceq 'PRIVATE_FILE_PROTECTED_AND_MISSING_FILE_REJECTED')
$r=[ordered]@{case='ACTUAL-INNO-MAINTENANCE-ACL-FIXTURE';status=$(if($passed){'PASS'}else{'FAIL'});computer=$env:COMPUTERNAME;utc=[datetime]::UtcNow.ToString('o');fixtureSha256=$expected;compilerVersion='6.7.3';productionSecurityFunctionExecuted=$true;beforeSddl=$before.Sddl;afterSddl=$after.Sddl;missingFileRejected=$true;policy=(Get-ExecutionPolicy).ToString();servicesModified=$false;releaseInstallerAcceptance='PENDING_REBUILD'}
$r|ConvertTo-Json|Set-Content -LiteralPath C:\Ventio-Acceptance\actual-inno-maintenance-acl-20261121.json -Encoding UTF8
$r|ConvertTo-Json -Compress
if(-not $passed){exit 1}
}
