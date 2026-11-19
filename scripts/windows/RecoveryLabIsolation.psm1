Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function New-RecoveryLabIsolationPlan {
  [CmdletBinding()]param()
  # The only approved management route. No DNS, Internet, production or LAN allows.
  $rules=@(
    @{direction='Inbound';remoteIPAddress='172.19.240.1';localPort='22';remotePort='';protocol='TCP';action='Allow';weight=200;stateful=$true},
    @{direction='Outbound';remoteIPAddress='255.255.255.255';localPort='68';remotePort='67';protocol='UDP';action='Allow';weight=190;stateful=$false},
    @{direction='Outbound';remoteIPAddress='172.19.240.1';localPort='68';remotePort='67';protocol='UDP';action='Allow';weight=180;stateful=$false},
    @{direction='Inbound';remoteIPAddress='172.19.240.1';localPort='68';remotePort='67';protocol='UDP';action='Allow';weight=170;stateful=$false}
  )
  $denyWeight=10
  foreach($family in @('0.0.0.0/0','::/0')){foreach($direction in @('Inbound','Outbound')){
    $rules+=@{direction=$direction;remoteIPAddress=$family;localPort='';remotePort='';protocol='';action='Deny';weight=$denyWeight;stateful=$false}
    $denyWeight--
  }}
  [pscustomobject][ordered]@{schemaVersion=1;managementHost='BAHAA';managementHostMachineGuid='206b0dfe-e035-49c5-8b38-3d1d19ceadf7';vmId='99aba626-2cc9-486e-86ab-af7966848126';vmName='Ventio-Recovery-Lab';adapterMac='00155D016805';switchId='c08cb7b8-9b3c-408e-8e30-5e16a3aeb444';requireEmptyPriorAcl=$true;rules=$rules;rollback='REMOVE_EXACT_PLAN_RULES_ONLY';effectiveEnforcementVerified=$false}
}
function Get-RecoveryRuleKey($Rule){
  return (@('direction','remoteIPAddress','localPort','remotePort','protocol','action','weight','stateful') | ForEach-Object {[string]$Rule.$_}) -join '|'
}
function Assert-RecoveryLabIsolationPlan {
  [CmdletBinding()]param([Parameter(Mandatory)]$Plan)
  $expected=New-RecoveryLabIsolationPlan
  foreach($field in @('schemaVersion','managementHost','managementHostMachineGuid','vmId','vmName','adapterMac','switchId','requireEmptyPriorAcl','rollback')){
    if([string]$Plan.$field -cne [string]$expected.$field){throw 'RECOVERY_NETWORK_TARGET_OR_MODE_CHANGED'}
  }
  $actualKeys=@($Plan.rules | ForEach-Object {Get-RecoveryRuleKey $_})
  $expectedKeys=@($expected.rules | ForEach-Object {Get-RecoveryRuleKey $_})
  if($actualKeys.Count -ne $expectedKeys.Count -or (Compare-Object $actualKeys $expectedKeys)){throw 'RECOVERY_NETWORK_RULES_CHANGED'}
}
function Get-RecoveryLabIsolationArguments {
  [CmdletBinding()]param([Parameter(Mandatory)]$Rule)
  $parameters=@{Direction=$Rule.direction;RemoteIPAddress=$Rule.remoteIPAddress;Action=$Rule.action;Weight=[int]$Rule.weight;Stateful=[bool]$Rule.stateful}
  foreach($field in @('LocalPort','RemotePort','Protocol')){if($Rule.$field){$parameters[$field]=[string]$Rule.$field}}
  return $parameters
}
function Get-RecoveryLabRollbackRules {
  [CmdletBinding()]param([Parameter(Mandatory)]$Plan,[AllowEmptyCollection()][object[]]$ExistingRules=@())
  Assert-RecoveryLabIsolationPlan $Plan
  foreach($actual in $ExistingRules){
    $matches=@($Plan.rules | Where-Object {
      ([string]$actual.Direction -eq $_.direction -or ($_.stateful -and [bool]$actual.Stateful)) -and [int]$actual.Weight -eq $_.weight -and
      [string]$actual.RemoteIPAddress -eq $_.remoteIPAddress -and [string]$actual.Action -eq $_.action -and
      [string]$actual.LocalPort -eq $_.localPort -and [string]$actual.RemotePort -eq $_.remotePort -and
      [string]$actual.Protocol -eq $_.protocol -and [bool]$actual.Stateful -eq $_.stateful
    })
    if($matches.Count -ne 1){throw 'RECOVERY_CONCURRENT_ACL_CHANGE_REVIEW_REQUIRED'}
  }
  foreach($rule in @($Plan.rules|Sort-Object {[int]$_.weight})){
    if(@($ExistingRules | Where-Object {[int]$_.Weight -eq $rule.weight -and [string]$_.Direction -eq $rule.direction}).Count){$rule}
  }
}
Export-ModuleMember -Function New-RecoveryLabIsolationPlan,Assert-RecoveryLabIsolationPlan,Get-RecoveryLabIsolationArguments,Get-RecoveryRuleKey,Get-RecoveryLabRollbackRules
