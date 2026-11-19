[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Export','Apply','Rollback')][string]$Mode,
  [Parameter(Mandatory)][string]$PlanPath,[string]$ExpectedPlanSha256,[switch]$ApproveAdapterConfigurationChange)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RecoveryLabIsolation.psm1') -Force
if($Mode -eq 'Export'){
  if(Test-Path -LiteralPath $PlanPath){throw 'RECOVERY_PLAN_OVERWRITE_REFUSED'}
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($PlanPath),((New-RecoveryLabIsolationPlan)|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  Get-FileHash -LiteralPath $PlanPath -Algorithm SHA256
  return
}
if(-not $ApproveAdapterConfigurationChange){throw 'RECOVERY_ADAPTER_CHANGE_APPROVAL_REQUIRED'}
if($ExpectedPlanSha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath $PlanPath).Hash.ToLowerInvariant() -cne $ExpectedPlanSha256){throw 'RECOVERY_NETWORK_PLAN_DIGEST_MISMATCH'}
$plan=Get-Content -LiteralPath $PlanPath -Raw|ConvertFrom-Json
Assert-RecoveryLabIsolationPlan $plan
if($env:COMPUTERNAME -cne $plan.managementHost -or (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid -cne $plan.managementHostMachineGuid){throw 'RECOVERY_MANAGEMENT_HOST_MISMATCH'}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'RECOVERY_MANAGEMENT_ELEVATION_REQUIRED'}
$vm=Get-VM -Id ([guid]$plan.vmId)
if($vm.Name -cne $plan.vmName -or $vm.Generation -ne 2){throw 'RECOVERY_HYPERV_IDENTITY_CHANGED'}
$adapters=@($vm | Get-VMNetworkAdapter)
if($adapters.Count -ne 1 -or $adapters[0].MacAddress -cne $plan.adapterMac){throw 'RECOVERY_HYPERV_ADAPTER_CHANGED'}
$adapter=$adapters[0]
if(@($adapter | Get-VMNetworkAdapterAcl).Count){throw 'RECOVERY_EXISTING_STANDARD_ACL_REVIEW_REQUIRED'}
$existing=@($adapter | Get-VMNetworkAdapterExtendedAcl)
if($Mode -eq 'Apply'){
  if($existing.Count){throw 'RECOVERY_EXISTING_EXTENDED_ACL_REVIEW_REQUIRED'}
  # SSH allow is installed before deny rules. Partial failures require console
  # review/rollback; never silently flush ACLs or change the switch/firewall.
  foreach($rule in $plan.rules){$arguments=Get-RecoveryLabIsolationArguments $rule;Add-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $adapter @arguments -ErrorAction Stop}
} else {
  # Remove by exact match only. Refuse rules not owned by this plan; a partially
  # applied plan is eligible for rollback without removing concurrent additions.
  foreach($actual in $existing){
    $matches=@($plan.rules | Where-Object {
      ([string]$actual.Direction -eq $_.direction -or ($_.stateful -and [bool]$actual.Stateful)) -and [int]$actual.Weight -eq $_.weight -and
      [string]$actual.RemoteIPAddress -eq $_.remoteIPAddress -and [string]$actual.Action -eq $_.action -and
      [string]$actual.LocalPort -eq $_.localPort -and [string]$actual.RemotePort -eq $_.remotePort -and
      [string]$actual.Protocol -eq $_.protocol -and [bool]$actual.Stateful -eq $_.stateful
    })
    if($matches.Count -ne 1){throw 'RECOVERY_CONCURRENT_ACL_CHANGE_REVIEW_REQUIRED'}
  }
  # Deny rules first, retaining the management allowance until last.
  foreach($rule in @($plan.rules | Sort-Object weight)){
    if(@($existing | Where-Object {[int]$_.Weight -eq $rule.weight -and [string]$_.Direction -eq $rule.direction}).Count){
      Remove-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $adapter -Direction $rule.direction -Weight $rule.weight -ErrorAction Stop
    }
  }
}
$adapter | Get-VMNetworkAdapterExtendedAcl
Write-Output 'NETWORK_CONFIGURATION_ONLY_EFFECTIVE_ISOLATION_REQUIRES_WITNESS_VERIFICATION'
