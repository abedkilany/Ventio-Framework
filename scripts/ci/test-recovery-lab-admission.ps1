$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:COMPUTERNAME -in @('BAHAA','TEST-01','TEST-02')){throw 'HOSTED_FIXTURE_ONLY'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
Import-Module (Join-Path $repo 'scripts/windows/RecoveryLabAdmission.psm1') -Force
Import-Module (Join-Path $repo 'scripts/windows/RecoveryLabIsolation.psm1') -Force
$results=[Collections.Generic.List[object]]::new()
function Case([string]$Id,[scriptblock]$Body){try{& $Body;$results.Add(@{id=$Id;status='PASSED'});Write-Output "PASS $Id"}catch{$results.Add(@{id=$Id;status='FAILED';reason=$_.Exception.Message});Write-Output "FAIL $Id $($_.Exception.Message)"}}
function Reject([scriptblock]$Body){$rejected=$false;try{& $Body}catch{$rejected=$true};if(-not $rejected){throw 'Expected security rejection'}}
function Clone($Value){return $Value | ConvertTo-Json -Depth 12 | ConvertFrom-Json}
$record=Get-Content (Join-Path $repo 'tests/wave2/recovery-lab.admission.example.json') -Raw|ConvertFrom-Json
$record.ownerApproved=$true;$record.networkEffectiveVerified=$true;$record.operatorSystemPolicyVerified=$true;$record.publisherThumbprint='A'*40;$record.networkPlanSha256='1'*64;$record.networkEvidenceSha256='2'*64;$record.signingEvidenceSha256='3'*64
$observation=@{machineName='VENTIO-W2-VM01';machineGuid=$record.guest.machineGuid;smbiosUuid=$record.guest.smbiosUuid;manufacturer='Microsoft Corporation';model='Virtual Machine';adapterMacs=@('00155D016805')}
Case 'ADM01-pinned-guest' {Assert-RecoveryLabIdentity $record $observation}
Case 'ADM02-owner-approval' {$r=Clone $record;$r.ownerApproved=$false;Reject {Assert-RecoveryLabIdentity $r $observation}}
Case 'ADM03-current-wrong-name' {$o=Clone $observation;$o.machineName='DESKTOP-CJVPE84';Reject {Assert-RecoveryLabIdentity $record $o}}
Case 'ADM04-preserved-host' {$o=Clone $observation;$o.machineGuid='206b0dfe-e035-49c5-8b38-3d1d19ceadf7';Reject {Assert-RecoveryLabIdentity $record $o}}
Case 'ADM05-physical-test-hosts' {foreach($name in @('BAHAA','TEST-01','TEST-02','VENTIO-TEST-01','VENTIO-TEST-02')){$o=Clone $observation;$o.machineName=$name;Reject {Assert-RecoveryLabIdentity $record $o}}}
Case 'ADM06-copied-marker' {$o=Clone $observation;$o.machineGuid=[guid]::NewGuid().ToString();Reject {Assert-RecoveryLabIdentity $record $o}}
Case 'ADM07-smbios-not-vmid' {$o=Clone $observation;$o.smbiosUuid=$record.management.vmId;Reject {Assert-RecoveryLabIdentity $record $o}}
Case 'ADM08-extra-adapter' {$o=Clone $observation;$o.adapterMacs=@('00155D016805','00155D999999');Reject {Assert-RecoveryLabIdentity $record $o}}
Case 'ADM09-nonvirtual-hardware' {$o=Clone $observation;$o.model='Physical';Reject {Assert-RecoveryLabIdentity $record $o}}
Case 'ADM10-missing-evidence' {$r=Clone $record;$r.networkEvidenceSha256='0'*64;Reject {Assert-RecoveryLabIdentity $r $observation}}
Case 'ADM11-changed-ssh-pin' {$r=Clone $record;$r.ssh.ed25519Fingerprint='SHA256:wrong';Reject {Assert-RecoveryLabIdentity $r $observation}}
Case 'ADM12-independent-record-digest' {
  $path=Join-Path $env:RUNNER_TEMP ('admission-'+[guid]::NewGuid().ToString('N')+'.json');$record|ConvertTo-Json -Depth 8|Set-Content $path
  $hash=(Get-FileHash $path).Hash.ToLowerInvariant();[void](Read-RecoveryLabAdmission $path $hash)
  Add-Content $path ' ';Reject {Read-RecoveryLabAdmission $path $hash}
}
Case 'ADM13-boolean-approval-required' {$r=Clone $record;$r.ownerApproved='true';Reject {Assert-RecoveryLabIdentity $r $observation}}
Case 'ADM14-physical-prerequisite-evidence' {$r=Clone $record;$r.networkEffectiveVerified=$false;Reject {Assert-RecoveryLabIdentity $r $observation}}
$plan=New-RecoveryLabIsolationPlan
Case 'NET01-exact-adapter-plan' {Assert-RecoveryLabIsolationPlan $plan;if($plan.rules.Count -ne 8){throw 'Rule closure incomplete'}}
Case 'NET02-only-management-ssh' {$ssh=@($plan.rules|Where-Object {$_.protocol -eq 'TCP' -and $_.action -eq 'Allow'});if($ssh.Count -ne 1 -or $ssh[0].direction -ne 'Inbound' -or $ssh[0].remoteIPAddress -ne '172.19.240.1' -or $ssh[0].localPort -ne '22' -or -not $ssh[0].stateful){throw 'SSH flow widened'}}
Case 'NET03-dual-stack-denial' {foreach($ip in @('0.0.0.0/0','::/0')){foreach($direction in @('Inbound','Outbound')){if(@($plan.rules|Where-Object {$_.remoteIPAddress -eq $ip -and $_.direction -eq $direction -and $_.action -eq 'Deny'}).Count -ne 1){throw 'Missing default deny'}}}}
Case 'NET04-unique-priorities' {if(@($plan.rules.weight|Select-Object -Unique).Count -ne $plan.rules.Count){throw 'Duplicate Hyper-V rule priority'}}
Case 'NET05-no-general-egress' {foreach($rule in @($plan.rules|Where-Object {$_.action -eq 'Allow' -and $_.direction -eq 'Outbound'})){if($rule.protocol -ne 'UDP' -or $rule.localPort -ne '68' -or $rule.remotePort -ne '67'){throw 'Unexpected egress'}}}
Case 'NET06-forbidden-extra-rule' {$p=Clone $plan;$p.rules+=@{direction='Outbound';remoteIPAddress='0.0.0.0/0';localPort='';remotePort='443';protocol='TCP';action='Allow';weight=300;stateful=$true};Reject {Assert-RecoveryLabIsolationPlan $p}}
Case 'NET07-stateful-mutation' {$p=Clone $plan;$p.rules[0].stateful=$false;Reject {Assert-RecoveryLabIsolationPlan $p}}
Case 'NET08-target-mutation' {$p=Clone $plan;$p.adapterMac='00155D999999';Reject {Assert-RecoveryLabIsolationPlan $p}}
Case 'NET09-export-and-rollback-contract' {
  $path=Join-Path $env:RUNNER_TEMP ('network-'+[guid]::NewGuid().ToString('N')+'.json')
  & (Join-Path $repo 'scripts/windows/prepare-recovery-lab-isolation.ps1') -Mode Export -PlanPath $path|Out-Null
  Assert-RecoveryLabIsolationPlan (Get-Content $path -Raw|ConvertFrom-Json)
  Reject {& (Join-Path $repo 'scripts/windows/prepare-recovery-lab-isolation.ps1') -Mode Apply -PlanPath $path}
  Reject {& (Join-Path $repo 'scripts/windows/prepare-recovery-lab-isolation.ps1') -Mode Rollback -PlanPath $path}
}
Case 'NET10-command-parameter-scope' {foreach($rule in $plan.rules){$arguments=Get-RecoveryLabIsolationArguments $rule;if($arguments.ContainsKey('ManagementOS') -or $arguments.ContainsKey('VMName') -or -not $arguments.ContainsKey('Weight')){throw 'Unsafe parameter scope'}}}
Case 'NET11-complete-rollback-order' {$selected=@(Get-RecoveryLabRollbackRules -Plan $plan -ExistingRules $plan.rules);if($selected.Count -ne 8 -or $selected[0].action -ne 'Deny' -or $selected[-1].localPort -ne '22'){throw 'Rollback removes SSH before deny rules'}}
Case 'NET12-partial-rollback' {$selected=@(Get-RecoveryLabRollbackRules -Plan $plan -ExistingRules @($plan.rules[0],$plan.rules[1]));if($selected.Count -ne 2){throw 'Partial apply cannot be rolled back'}}
Case 'NET13-rollback-refuses-concurrent-change' {$foreign=Clone $plan.rules[0];$foreign.remoteIPAddress='192.168.1.107';Reject {Get-RecoveryLabRollbackRules -Plan $plan -ExistingRules @($foreign)}}
Case 'NET14-empty-rollback' {if(@(Get-RecoveryLabRollbackRules -Plan $plan -ExistingRules @()).Count -ne 0){throw 'Empty rollback generated mutations'}}
Case 'NET15-stateful-reflection-removed-once' {$reflected=Clone $plan.rules[0];$reflected.direction='Outbound';$selection=@(Get-RecoveryLabRollbackRules -Plan $plan -ExistingRules @($plan.rules[0],$reflected));if($selection.Count -ne 1){throw 'Stateful pair removed twice'}}
$out=Join-Path $repo 'test-results/recovery-admission';[void][IO.Directory]::CreateDirectory($out)
& (Join-Path $repo 'scripts/windows/prepare-recovery-lab-isolation.ps1') -Mode Export -PlanPath (Join-Path $out 'isolation-plan.json') | Out-Null
[ordered]@{sourceCommit=$env:GITHUB_SHA;runId=$env:GITHUB_RUN_ID;cases=@($results.ToArray());effectiveIsolation='UNEXECUTED_REQUIRES_OWNER_APPROVED_VNIC';physicalVmTouched=$false} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $out 'admission-network.json')
if(@($results|Where-Object status -eq 'FAILED').Count){throw 'Recovery admission/network cases failed'}
