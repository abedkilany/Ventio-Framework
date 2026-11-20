$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:COMPUTERNAME -in @('BAHAA','TEST-01','TEST-02','VENTIO-TEST-01','VENTIO-W2-VM01')){throw 'Disposable GitHub-hosted fixture only'}
$product=Join-Path $env:ProgramData 'Ventio'
$app=Join-Path $env:ProgramFiles 'Ventio'
if((Test-Path -LiteralPath $product) -or (Test-Path -LiteralPath $app) -or (Get-Service VentioHost,VentioPostgres -ErrorAction SilentlyContinue)){throw 'Fresh disposable machine required'}
$out=Join-Path (Get-Location) 'test-results/wave2-native-installation'
[void][IO.Directory]::CreateDirectory($out)
$results=[Collections.Generic.List[object]]::new()
$policiesBefore=@(Get-ExecutionPolicy -List|ForEach-Object { @{scope=[string]$_.Scope;policy=[string]$_.ExecutionPolicy} })
$payload=Join-Path $app 'host-payload'
$built=Join-Path (Get-Location) 'packages/ventio_host_api/build/windows/host-payload'
[void][IO.Directory]::CreateDirectory($app)
Copy-Item -LiteralPath $built -Destination $payload -Recurse
$admin=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$system=[Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$users=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
function Protect-PayloadDirectory([string]$Path){
  $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($admin)
  foreach($sid in @($admin,$system)){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
  Set-Acl -LiteralPath $Path -AclObject $acl
}
Protect-PayloadDirectory $app
Protect-PayloadDirectory $payload
$broker=Join-Path $payload 'VentioSetupBroker.exe'
$requester=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function Native([string]$File,[string[]]$Arguments){
  $info=[Diagnostics.ProcessStartInfo]::new($File);$info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $info.Environment['PSExecutionPolicyPreference']='Restricted'
  # A pwsh 7 parent otherwise passes its incompatible module search path to
  # Windows PowerShell 5.1. The read-only policy probe uses only OS modules.
  $info.Environment['PSModulePath']="$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules"
  foreach($arg in $Arguments){$info.ArgumentList.Add($arg)}
  $process=[Diagnostics.Process]::Start($info)
  $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  try {
    if(-not $process.WaitForExit(480000)){$process.Kill($true);throw 'Native test timeout'}
    return @{code=$process.ExitCode;output=$stdout.GetAwaiter().GetResult();error=$stderr.GetAwaiter().GetResult()}
  } finally {$process.Dispose()}
}
function Request-NewHost {
  $script:operation=[guid]::NewGuid().ToString('N')
  return Native $broker @('--setup-new-host',$script:operation,'w2-ci-tenant','w2-ci-company','w2-ci-branch',$requester)
}
function Require([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Case([string]$Id,[scriptblock]$Body){
  try {& $Body;$results.Add(@{id=$Id;status='PASSED'})}
  catch {$results.Add(@{id=$Id;status='FAILED';reason=$_.Exception.Message});throw}
}
$networkManager=$null
$networks=@()
try {
  Case 'NHI001-effective-Restricted-child-policy' {
    $p=Native "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" @('-NoLogo','-NoProfile','-NonInteractive','-Command','Get-ExecutionPolicy')
    $p|ConvertTo-Json|Set-Content (Join-Path $out 'policy-probe.json')
    Require ($p.code -eq 0 -and $p.output.Trim() -ceq 'Restricted') 'Child policy was not Restricted'
    $p=Native "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $payload 'setup/provision-host-installation.ps1'))
    Require ($p.code -ne 0 -and $p.error -match 'running scripts is disabled') 'Legacy script was not rejected under Restricted'
    Require (-not(Test-Path -LiteralPath $product)) 'Policy probe changed product data'
  }
  Case 'NHI002-arbitrary-arguments-denied' {
    $p=Native $broker @('--setup-new-host',[guid]::NewGuid().ToString('N'),'t','c','b',$requester,'--script','C:\untrusted.ps1')
    Require ($p.code -eq 2 -and -not(Test-Path -LiteralPath $product)) 'Arbitrary arguments were accepted'
  }
  Case 'NHI009-requester-SID-mismatch-denied' {
    $id=[guid]::NewGuid().ToString('N')
    $p=Native $broker @('--setup-new-host',$id,'w2-ci-tenant','w2-ci-company','w2-ci-branch','S-1-5-18')
    Require ($p.code -eq 9 -and -not(Test-Path -LiteralPath $product)) 'Requester identity boundary was not enforced'
  }
  Case 'NHI003-native-payload-tampering-denied-before-mutation' {
    $target=Join-Path $payload 'postgresql/bin/createdb.exe'
    $original=[IO.File]::ReadAllBytes($target)
    try {
      $altered=[byte[]]$original.Clone();$altered[$altered.Length-1]=$altered[$altered.Length-1] -bxor 1
      [IO.File]::WriteAllBytes($target,$altered)
      $p=Request-NewHost
      Require ($p.code -eq 5 -and -not(Test-Path -LiteralPath $product)) 'Tampered payload mutated product state'
    } finally {[IO.File]::WriteAllBytes($target,$original)}
  }
  Case 'NHI004-untrusted-payload-write-access-denied' {
    $target=Join-Path $payload 'ventio_migrate.exe';$original=Get-Acl -LiteralPath $target
    try {
      $acl=Get-Acl -LiteralPath $target
      $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users,'Modify','Allow'))
      Set-Acl -LiteralPath $target -AclObject $acl
      $p=Request-NewHost
      Require ($p.code -eq 5 -and -not(Test-Path -LiteralPath $product)) 'Writable payload was accepted'
    } finally {Set-Acl -LiteralPath $target -AclObject $original}
  }
  # The network category below belongs exclusively to this ephemeral hosted VM.
  # Firewall profiles stay enabled/default-block and no Public rule is created.
  $networkManager=New-Object -ComObject NetworkListManager
  $networks=@($networkManager.GetNetworks(1)|ForEach-Object { @{network=$_;category=$_.GetCategory()} })
  foreach($entry in $networks){if($entry.category -eq 0){$entry.network.SetCategory(1)}}
  Case 'NHI005-real-native-Host-installation-and-first-administrator' {
    $p=Request-NewHost
    if($p.code -ne 0){
      $diagnostics=Join-Path $product 'Installer/ProvisioningDiagnostics'
      if(Test-Path -LiteralPath $diagnostics){Copy-Item (Join-Path $diagnostics '*.json') $out}
    }
    Require ($p.code -eq 0) ('Native provisioning returned '+$p.code)
    $status=Get-Content -LiteralPath (Join-Path $app ('SetupStatus/'+$script:operation+'.json')) -Raw|ConvertFrom-Json
    Require ($status.state -ceq 'complete') 'First administrator did not complete'
    $status|ConvertTo-Json|Set-Content (Join-Path $out 'native-status.json')
    $ready=$null
    for($i=0;$i -lt 90;$i++){
      try {$ready=Invoke-RestMethod -Uri 'http://127.0.0.1:8080/healthz' -TimeoutSec 2;if($ready.status -ceq 'alive' -and $ready.apiVersion -eq 1){break}} catch {}
      Start-Sleep -Seconds 1
    }
    Require ($ready.status -ceq 'alive' -and $ready.apiVersion -eq 1) 'Installed Host health was not ready'
    $ready|ConvertTo-Json -Depth 5|Set-Content (Join-Path $out 'host-health.json')
    Require ((Get-Service VentioHost).Status -eq 'Running' -and (Get-Service VentioPostgres).Status -eq 'Running') 'Services are not running'
  }
  Case 'NHI006-service-identities-and-private-data-preserved' {
    $services=@(Get-CimInstance Win32_Service|Where-Object Name -in @('VentioHost','VentioPostgres'))
    foreach($service in $services){Require ($service.StartName -ceq ('NT SERVICE\'+$service.Name)) 'Unexpected service identity'}
    $services|Select-Object Name,StartName,State,PathName|ConvertTo-Json|Set-Content (Join-Path $out 'services.json')
    $acl=Get-Acl -LiteralPath (Join-Path $product 'Installer/migration-credential.dpapi')
    Require $acl.AreAccessRulesProtected 'Migration credential inherits permissions'
    $sids=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|ForEach-Object {$_.IdentityReference.Value})
    Require ($sids.Count -eq 2 -and 'S-1-5-32-544' -in $sids -and 'S-1-5-18' -in $sids) 'Migration credential is exposed'
    Require (Test-Path -LiteralPath (Join-Path $product 'Host/recovery.witness')) 'Actual Recovery Authority witness is missing'
  }
  Case 'NHI007-new-installation-cannot-overwrite-existing-Host' {
    $before=(Get-FileHash -LiteralPath (Join-Path $product 'Host/service-config.dpapi')).Hash
    $p=Request-NewHost
    Require ($p.code -eq 5) 'Existing Host was accepted as new'
    Require ((Get-FileHash -LiteralPath (Join-Path $product 'Host/service-config.dpapi')).Hash -ceq $before) 'Existing configuration changed'
    Require ((Get-Service VentioHost).Status -eq 'Running') 'Existing Host was stopped'
  }
  Case 'NHI008-firewall-remains-enabled-and-scoped' {
    $policy=New-Object -ComObject HNetCfg.FwPolicy2
    foreach($profile in @(1,2,4)){Require ($policy.FirewallEnabled($profile) -and $policy.DefaultInboundAction($profile) -eq 0) 'Firewall protection changed'}
    $rule=$policy.Rules.Item('Ventio Host HTTPS LAN')
    Require ($rule.Enabled -and $rule.Profiles -gt 0 -and ($rule.Profiles -band 4) -eq 0 -and $rule.LocalPorts -ceq '8443' -and $rule.Protocol -eq 6 -and -not $rule.EdgeTraversal) 'Host firewall scope changed'
    Require ($rule.RemoteAddresses -match '^LocalSubnet(4,LocalSubnet6)?$') 'Firewall remote scope widened'
    $status=Get-MpComputerStatus
    Require ($status.AntivirusEnabled -and $status.RealTimeProtectionEnabled) 'Defender is not enabled'
  }
} finally {
  foreach($entry in $networks){try {$entry.network.SetCategory($entry.category)} catch {}}
  $policiesAfter=@(Get-ExecutionPolicy -List|ForEach-Object { @{scope=[string]$_.Scope;policy=[string]$_.ExecutionPolicy} })
  $unchanged=($policiesBefore|ConvertTo-Json -Compress) -ceq ($policiesAfter|ConvertTo-Json -Compress)
  [ordered]@{sourceCommit=$env:GITHUB_SHA;runId=$env:GITHUB_RUN_ID;cases=@($results.ToArray());childEffectivePolicy='Restricted';executionPoliciesUnchanged=$unchanged;physicalMachinesTouched=$false;installedRecoveryCasesExecuted=$false}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $out 'results.json')
  if(-not $unchanged){throw 'Execution policy changed'}
}
