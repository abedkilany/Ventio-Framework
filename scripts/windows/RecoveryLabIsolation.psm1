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
  [pscustomobject][ordered]@{schemaVersion=1;managementHost='BAHAA';managementHostMachineGuid='206b0dfe-e035-49c5-8b38-3d1d19ceadf7';vmId='99aba626-2cc9-486e-86ab-af7966848126';vmName='Ventio-Recovery-Lab';adapterMac='00155D016805';requireEmptyPriorAcl=$true;rules=$rules;rollback='REMOVE_EXACT_PLAN_RULES_ONLY';effectiveEnforcementVerified=$false}
}
function Get-RecoveryRuleKey($Rule){
  return (@('direction','remoteIPAddress','localPort','remotePort','protocol','action','weight','stateful') | ForEach-Object {[string]$Rule.$_}) -join '|'
}
function Assert-RecoveryLabIsolationPlan {
  [CmdletBinding()]param([Parameter(Mandatory)]$Plan)
  $expected=New-RecoveryLabIsolationPlan
  foreach($field in @('schemaVersion','managementHost','managementHostMachineGuid','vmId','vmName','adapterMac','requireEmptyPriorAcl','rollback')){
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
Export-ModuleMember -Function New-RecoveryLabIsolationPlan,Assert-RecoveryLabIsolationPlan,Get-RecoveryLabIsolationArguments,Get-RecoveryRuleKey
