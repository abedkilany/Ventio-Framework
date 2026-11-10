# One-time, pinned administrative deployment and recovery through VentioSetupBroker.
# No credential plaintext is read or emitted by this script.
$ErrorActionPreference='Stop'
$source='C:\Users\User\Desktop\Ventio Framework\packages\ventio_host_api\build\windows\host-resume-broker-20261031\VentioSetupBroker.exe'
$target='C:\Program Files\Ventio\host-payload\VentioSetupBroker.exe'
$manifestPath='C:\Program Files\Ventio\host-payload\payload-manifest.json'
$statusDirectory='C:\Program Files\Ventio\SetupStatus'
$resultPath=Join-Path $statusDirectory 'maintenance-bound-handoff-20261031.json'
$phase='PREFLIGHT'
try {
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$sid=$identity.User.Value
  if(-not [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'ELEVATION_REQUIRED'}
  if((Get-FileHash $source -Algorithm SHA256).Hash -ne '6C7F354530E7C1204CF7158868A947376053FC043FC1249194839D226E47EE21' -or
    (Get-FileHash $target -Algorithm SHA256).Hash -ne '6C7F354530E7C1204CF7158868A947376053FC043FC1249194839D226E47EE21' -or
    (Get-FileHash 'C:\Program Files\Ventio\host-payload\VentioHostService.exe' -Algorithm SHA256).Hash -ne '309AFC2E2530913E7913BFB53BD2E24A7759AC1BD90D052DC06C97DE015B034E'){throw 'PINNED_TARGET_CHANGED'}
  if(Get-Process ventio_native_client,VentioSetupBroker -ErrorAction SilentlyContinue){throw 'APPLICATION_MUST_BE_IDLE'}
  $pendingPath=Join-Path $env:LOCALAPPDATA 'VentioFramework\host-setup-pending.json'
  $pending=Get-Content -LiteralPath $pendingPath -Raw|ConvertFrom-Json
  if($pending.operationId -cne 'c5e5563e1eade9857513a8046aac4274' -or $pending.requesterSid -cne $sid){throw 'LOCAL_REQUEST_CHANGED'}
  $backup=Join-Path 'C:\ProgramData\Ventio\RecoveryEvidence' ('bound-handoff-'+[Guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($backup)|Out-Null
  $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
  foreach($trusted in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($trusted),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
  Set-Acl -LiteralPath $backup -AclObject $acl
  Copy-Item -LiteralPath $target -Destination (Join-Path $backup 'VentioSetupBroker.exe')
  Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $backup 'payload-manifest.json')
  Copy-Item -LiteralPath $pendingPath -Destination (Join-Path $backup 'pending-before.json')
  $phase='DEPLOY_BROKER'
  Copy-Item -LiteralPath $source -Destination $target -Force
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  $entry=@($manifest.verifiedFiles|Where-Object path -ceq 'VentioSetupBroker.exe')
  if($entry.Count -ne 1){throw 'MANIFEST_INVALID'}
  $entry[0].length=(Get-Item $target).Length;$entry[0].sha256='6c7f354530e7c1204cf7158868a947376053fc043fc1249194839d226e47ee21'
  [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  $phase='RESUME_SERVICE_BOOTSTRAP'
  $operationId='1ce9872c74d44c638f710b9cb8b6dc93'
  $broker=Start-Process -FilePath $target -ArgumentList ('--resume-first-administrator '+$operationId+' Test-Project Test-Company Test-Branch '+$sid) -WindowStyle Hidden -PassThru
  if(-not $broker.WaitForExit(120000)){throw 'BROKER_STILL_RUNNING'}
  $broker.Refresh()
  $statusPath=Join-Path $statusDirectory ($operationId+'.json')
  $status=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json
  if($broker.ExitCode -ne 0 -or $status.state -cne 'complete' -or $status.operationId -cne $operationId){
    $safe=if($status.failureCode -match '^[A-Z0-9_]{1,96}$'){$status.failureCode}else{'BOUND_HANDOFF_FAILED'}
    [IO.File]::WriteAllText($resultPath,(@{state='failed';phase=$phase;code=$safe;operationId=$operationId}|ConvertTo-Json -Compress));exit 1
  }
  if(-not (Test-Path -LiteralPath (Join-Path $statusDirectory ($operationId+'.credential.dpapi')) -PathType Leaf)){throw 'PROTECTED_HANDOFF_MISSING'}
  $phase='RECONCILE_LOCAL_REQUEST'
  $pending.operationId=$operationId;$pending.tenantId='Test-Project';$pending.companyId='Test-Company';$pending.branchId='Test-Branch'
  $temporary=$pendingPath+'.resume-'+$operationId
  [IO.File]::WriteAllText($temporary,($pending|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  [IO.File]::Replace($temporary,$pendingPath,($pendingPath+'.before-bound-resume-'+$operationId),$false)
  [IO.File]::WriteAllText($resultPath,(@{state='complete';code='BOUND_HANDOFF_READY';operationId=$operationId}|ConvertTo-Json -Compress))
} catch {
  $safe=if($_.Exception.Message -match '^[A-Z_]+$'){$_.Exception.Message}else{'BOUND_HANDOFF_FAILED'}
  [IO.File]::WriteAllText($resultPath,(@{state='failed';phase=$phase;code=$safe;failureType=$_.Exception.GetType().Name}|ConvertTo-Json -Compress));exit 1
}
