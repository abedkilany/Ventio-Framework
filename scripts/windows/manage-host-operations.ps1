param(
 [ValidatePattern('^[0-9a-f-]{36}$')][string]$OperationId,
 [switch]$RunScheduled,
 [switch]$ConfirmRestore,
 [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPlanSha256
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'HOST_OPERATION_LOCAL_ELEVATION_REQUIRED'}
if(($RunScheduled -and $OperationId) -or (-not $RunScheduled -and -not $OperationId)){throw 'HOST_OPERATION_MODE_INVALID'}
Import-Module (Join-Path $PSScriptRoot 'HostOperationStorage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'HostBackupIntegrity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'HostServiceRecoveryPolicy.psm1') -Force
$programData=[IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
$payload=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio\host-payload'))
if(-not ([IO.Path]::GetFullPath($PSScriptRoot)).Equals((Join-Path $payload 'setup'),[StringComparison]::OrdinalIgnoreCase)){throw 'HOST_OPERATION_INSTALLED_PAYLOAD_REQUIRED'}
$serviceSid=[Security.Principal.NTAccount]::new('NT SERVICE','VentioHost').Translate([Security.Principal.SecurityIdentifier]).Value
$adminSid='S-1-5-32-544'
$spool=Join-Path $programData 'Ventio\Host\Operations'
$installer=Join-Path $programData 'Ventio\Installer'
$state=Join-Path $installer 'Operations'
$backups=Join-Path $programData 'Ventio\Backups'
[void](Assert-VentioOperationPath $spool $serviceSid -Directory)
[void](Assert-VentioOperationPath $installer $adminSid -Directory)
if(-not (Test-Path -LiteralPath $state)){
 [void][IO.Directory]::CreateDirectory($state)
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]::new($adminSid))
 foreach($sid in @($adminSid,'S-1-5-18')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
 Set-Acl -LiteralPath $state -AclObject $acl
}
[void](Assert-VentioOperationPath $state $adminSid -Directory)
$machine=(Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
$schemaHash=(Get-FileHash -LiteralPath (Join-Path $payload 'security\schema_profile.sql') -Algorithm SHA256).Hash.ToLowerInvariant()

function Get-Backup([string]$Name){
 if($Name -notmatch '^ventio-postgresql-before-upgrade-\d{8}T\d{9}Z-[0-9a-f]{32}$'){throw 'HOST_OPERATION_BACKUP_ID_INVALID'}
 $root=[IO.Path]::GetFullPath((Join-Path $backups $Name));$prefix=[IO.Path]::GetFullPath($backups).TrimEnd('\')+'\'
 if(-not $root.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($root) -ne $prefix.TrimEnd('\')){throw 'HOST_OPERATION_BACKUP_PATH_INVALID'}
 [void](Assert-VentioOperationPath $root $adminSid -Directory)
 $manifestPath=Join-Path $root 'backup-manifest.json'
 $manifest=Read-VentioOperationJson $manifestPath $adminSid 134217728
 if($manifest.formatVersion -ne 2 -or $manifest.integrityAlgorithm -cne 'SHA-256' -or $manifest.recoveryAuthorityIncluded -ne $false -or
   $manifest.postgresVersion -cne '16.15' -or $manifest.dataDirectory -cne 'data'){throw 'HOST_OPERATION_BACKUP_PROFILE_INVALID'}
 if(-not ($manifest.PSObject.Properties.Name -contains 'machineId') -or $manifest.machineId -cne $machine -or
   -not ($manifest.PSObject.Properties.Name -contains 'schemaProfileSha256') -or $manifest.schemaProfileSha256 -cne $schemaHash){throw 'HOST_OPERATION_RESTORE_COMPATIBILITY_DENIED'}
 Assert-HostBackupIntegrity (Join-Path $root 'data') @($manifest.files)
 return [pscustomobject]@{Root=$root;Manifest=$manifest;Hash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()}
}

function Assert-Policy([object]$Policy){
 $expected=@('contractVersion','enabled','utcTime','retainDays','retainCopies','maximumAttempts','retryMinutes')|Sort-Object
 if((@($Policy.PSObject.Properties.Name|Sort-Object)-join ',') -cne ($expected-join ',') -or $Policy.contractVersion -ne 1 -or $Policy.enabled -isnot [bool] -or
  $Policy.utcTime -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$'){throw 'HOST_OPERATION_POLICY_INVALID'}
 foreach($bound in @(@('retainDays',1,3650),@('retainCopies',2,1000),@('maximumAttempts',1,5),@('retryMinutes',5,1440))){
  $value=$Policy.($bound[0]);if($value -isnot [int] -and $value -isnot [long]){throw 'HOST_OPERATION_POLICY_INVALID'}
  if($value -lt $bound[1] -or $value -gt $bound[2]){throw 'HOST_OPERATION_POLICY_INVALID'}
 }
}

function Get-Pins {
 $pins=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($file in Get-ChildItem -LiteralPath $state -Filter '*.plan.json' -File){
  $plan=Read-VentioOperationJson $file.FullName $adminSid
  if([DateTime]::Parse($plan.expiresAtUtc).ToUniversalTime() -gt [DateTime]::UtcNow){[void]$pins.Add([string]$plan.backupName)}
 }
 return ,$pins
}

function Invoke-Retention([object]$Policy,[string]$Newest){
 Assert-Policy $Policy
 $pins=Get-Pins;$candidates=@()
 foreach($entry in Get-ChildItem -LiteralPath $backups -Directory){
  if($entry.Name -notmatch '^ventio-postgresql-before-upgrade-\d{8}T\d{9}Z-[0-9a-f]{32}$'){continue}
  [void](Assert-VentioOperationPath $entry.FullName $adminSid -Directory)
  $manifest=Read-VentioOperationJson (Join-Path $entry.FullName 'backup-manifest.json') $adminSid 134217728
  # Upgrade, recovery, incomplete, foreign-machine and foreign-release backups
  # are never selected by the scheduled-backup retention policy.
  if(($manifest.PSObject.Properties.Name -contains 'backupKind') -and $manifest.backupKind -ceq 'scheduled' -and
    $manifest.machineId -ceq $machine -and $manifest.schemaProfileSha256 -ceq $schemaHash){
    [void](Get-Backup $entry.Name)
    if($candidates.Count -ge 2000){throw 'HOST_OPERATION_RETENTION_INVENTORY_LIMIT'}
    $candidates+= [pscustomobject]@{Name=$entry.Name;Path=$entry.FullName;Date=[DateTime]::Parse($manifest.createdAtUtc).ToUniversalTime()}
  }
 }
 $ordered=@($candidates|Sort-Object Date -Descending)
 $deleted=[Collections.Generic.List[string]]::new()
 for($i=0;$i -lt $ordered.Count;$i++){
  $item=$ordered[$i]
  if($i -lt [int]$Policy.retainCopies -or $item.Name -eq $Newest -or $pins.Contains($item.Name) -or $item.Date -gt [DateTime]::UtcNow.AddDays(-[int]$Policy.retainDays)){continue}
  # Resolve and check the exact target immediately before recursive deletion.
  $verified=Get-Backup $item.Name
  $target=[IO.Path]::GetFullPath($verified.Root)
  $expected=[IO.Path]::GetFullPath((Join-Path $backups $item.Name))
  if($target -cne $expected -or [IO.Path]::GetDirectoryName($target) -cne [IO.Path]::GetFullPath($backups)){throw 'HOST_OPERATION_RETENTION_PATH_INVALID'}
  Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
  $deleted.Add($item.Name)
 }
 return @($deleted)
}

function Set-Schedule {
 $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $scriptPath=Join-Path $payload 'setup\manage-host-operations.ps1'
 $action=New-ScheduledTaskAction -Execute $powershell -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$scriptPath+'" -RunScheduled')
 $trigger=New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
 $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6)
 $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
 $task=New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal
 Register-ScheduledTask -TaskName 'VentioHostBackups' -TaskPath '\Ventio\' -InputObject $task -Force|Out-Null
 # The scheduler task only consumes current Host offers matching an admin-only
 # approved policy. No credentials or caller-controlled executable are stored.
}

function Invoke-Operation([string]$Id,[switch]$Scheduled){
 $requestPath=Join-Path $spool ($Id+'.request.json')
 if(-not (Test-Path -LiteralPath $requestPath)){if($Scheduled){return}else{throw 'HOST_OPERATION_OFFER_NOT_DELIVERED_REFRESH'}}
 $request=Read-VentioOperationJson $requestPath $serviceSid
 $expected=@('formatVersion','operationId','offerId','operation','tenantId','companyId','branchId','requestedBy','body','requestHash','validUntilUtc','scheduled')|Sort-Object
 if((@($request.PSObject.Properties.Name|Sort-Object)-join ',') -cne ($expected-join ',') -or $request.formatVersion -ne 1 -or $request.operationId -cne $Id -or
   $request.offerId -notmatch '^[0-9a-f-]{36}$' -or $request.operation -notin @('APPLY_POLICY','BACKUP_NOW','RESTORE_PLAN','RESTORE') -or
   [DateTime]::Parse($request.validUntilUtc).ToUniversalTime() -le [DateTime]::UtcNow){throw 'HOST_OPERATION_OFFER_INVALID_OR_EXPIRED'}
 if($Scheduled){
  if($request.scheduled -ne $true -or $request.operation -cne 'BACKUP_NOW'){return}
  $policyId=[string]$request.body.policyOperationId
  if($policyId -notmatch '^[0-9a-f-]{36}$'){throw 'HOST_OPERATION_POLICY_ID_INVALID'}
  $approved=Read-VentioOperationJson (Join-Path $state ($policyId+'.policy.json')) $adminSid
  if($approved.policySha256 -cne $request.body.policySha256 -or $approved.tenantId -cne $request.tenantId -or
    $approved.companyId -cne $request.companyId -or $approved.branchId -cne $request.branchId -or $approved.enabled -ne $true){throw 'HOST_OPERATION_LOCAL_POLICY_NOT_APPROVED'}
  Assert-Policy $request.body.policy
  Assert-Policy $approved.policy
  foreach($key in $approved.policy.PSObject.Properties.Name){if($approved.policy.$key -cne $request.body.policy.$key){throw 'HOST_OPERATION_LOCAL_POLICY_CHANGED'}}
  $scopeText=[string]$request.tenantId+[char]0+[string]$request.companyId+[char]0+[string]$request.branchId
  $hash=[Security.Cryptography.SHA256]::Create()
  try{$scopeKey=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($scopeText))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
  $active=Read-VentioOperationJson (Join-Path $state ('active-'+$scopeKey+'.json')) $adminSid
  if($active.operationId -cne $policyId -or $active.enabled -ne $true){throw 'HOST_OPERATION_LOCAL_POLICY_SUPERSEDED'}
  if([string]$request.body.scheduledFor -cne [DateTime]::UtcNow.ToString('yyyy-MM-dd') -or [DateTime]::UtcNow.TimeOfDay -lt [TimeSpan]::Parse([string]$approved.policy.utcTime)){throw 'HOST_OPERATION_SCHEDULE_NOT_DUE'}
  $dailyPath=Join-Path $state ($policyId+'-'+[DateTime]::UtcNow.ToString('yyyyMMdd')+'.daily.json')
  $daily=$null
  if(Test-Path -LiteralPath $dailyPath){$daily=Read-VentioOperationJson $dailyPath $adminSid}
  if($null -ne $daily -and ($daily.state -ne 'FAILED' -or $daily.attempts -ge $approved.policy.maximumAttempts -or
    [DateTime]::Parse($daily.updatedAtUtc).ToUniversalTime().AddMinutes([int]$approved.policy.retryMinutes) -gt [DateTime]::UtcNow)){throw 'HOST_OPERATION_DAILY_EXECUTION_LIMIT'}
 }
 if($request.operation -eq 'RESTORE' -and (-not $ConfirmRestore -or $ExpectedPlanSha256 -cne $request.body.planSha256)){throw 'HOST_OPERATION_RESTORE_CONFIRMATION_REQUIRED'}
 $journal=Join-Path $state ($Id+'.journal.json')
 if(Test-Path -LiteralPath $journal){throw 'HOST_OPERATION_ALREADY_CLAIMED_REVIEW_JOURNAL'}
 $claimed=Join-Path $spool ($Id+'.claimed.json')
 # Renaming the leased offer is the physical idempotency boundary. A crashed
 # claimed operation never automatically repeats or silently overwrites data.
 [IO.File]::Move($requestPath,$claimed)
 Write-VentioOperationJson $journal @{operationId=$Id;operation=$request.operation;state='RUNNING';startedAtUtc=[DateTime]::UtcNow.ToString('o')} $adminSid
 if($Scheduled){$attempts=if($null -eq $daily){1}else{[int]$daily.attempts+1};Write-VentioOperationJson $dailyPath @{state='RUNNING';attempts=$attempts;updatedAtUtc=[DateTime]::UtcNow.ToString('o')} $adminSid}
 $result=@{operationId=$Id;offerId=$request.offerId;operation=$request.operation;tenantId=$request.tenantId;companyId=$request.companyId;branchId=$request.branchId;actorId=$request.requestedBy;state='RUNNING';code='LOCAL_OPERATION_RUNNING';retryable=$false}
 $resultPath=Join-Path $spool ($Id+'.result.json')
 Write-VentioOperationJson $resultPath $result $serviceSid
 $restartHost=$false;$keepStopped=$false;$maintenance=$false;$hostService=$null
 try{
  $hostService=Get-CimInstance Win32_Service -Filter "Name='VentioHost'"
  $postgres=Get-CimInstance Win32_Service -Filter "Name='VentioPostgres'"
  if($hostService.StartName -cne 'NT SERVICE\VentioHost' -or $hostService.PathName -notmatch [regex]::Escape((Join-Path $payload 'VentioHostService.exe')) -or
    $postgres.StartName -cne 'NT SERVICE\VentioPostgres' -or $postgres.PathName -notmatch [regex]::Escape((Join-Path $payload 'postgresql\bin\pg_ctl.exe'))){throw 'HOST_OPERATION_SERVICE_IDENTITY_INVALID'}
  switch($request.operation){
   'APPLY_POLICY'{
    Assert-Policy $request.body.policy
    if($request.body.policySha256 -notmatch '^[0-9a-f]{64}$'){throw 'HOST_OPERATION_POLICY_INVALID'}
    Write-VentioOperationJson (Join-Path $state ($Id+'.policy.json')) @{tenantId=$request.tenantId;companyId=$request.companyId;branchId=$request.branchId;policySha256=$request.body.policySha256;policy=$request.body.policy;enabled=$request.body.policy.enabled} $adminSid
    $scopeText=[string]$request.tenantId+[char]0+[string]$request.companyId+[char]0+[string]$request.branchId
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$scopeKey=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($scopeText))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
    Write-VentioOperationJson (Join-Path $state ('active-'+$scopeKey+'.json')) @{operationId=$Id;enabled=$request.body.policy.enabled} $adminSid
    Set-Schedule
    $result.code=if($request.body.policy.enabled){'BACKUP_POLICY_ARMED'}else{'BACKUP_POLICY_DISABLED'}
   }
   'BACKUP_NOW'{
    $restartHost=$hostService.State -eq 'Running'
    $maintenance=$true;Start-VentioHostServiceMaintenance $hostService|Out-Null
    if($restartHost){Stop-Service -Name VentioHost -ErrorAction Stop}
    Wait-VentioServiceStoppedStable 'VentioHost' 2 120 $null $null
    Assert-VentioHostServiceMaintenance (Get-CimInstance Win32_Service -Filter "Name='VentioHost'") 'Stopped'
    $output=@(& (Join-Path $PSScriptRoot 'upgrade-host-database.ps1') -Apply -BackupOnly)
    $name=@($output|Where-Object {$_ -match '^HOST_OPERATION_BACKUP_NAME='})
    if($name.Count -ne 1){throw 'HOST_OPERATION_BACKUP_OUTCOME_UNKNOWN'}
    $backup=Get-Backup ($name[0].Substring('HOST_OPERATION_BACKUP_NAME='.Length))
    $result.backupName=Split-Path -Leaf $backup.Root;$result.manifestSha256=$backup.Hash
    $result.code='BACKUP_COMPLETE'
    if($Scheduled){$result.deletedBackups=@(Invoke-Retention $request.body.policy $result.backupName)}
   }
   'RESTORE_PLAN'{
    $backup=Get-Backup ([string]$request.body.backupName)
    $plan=@{formatVersion=1;operationId=$Id;backupName=$request.body.backupName;manifestSha256=$backup.Hash;schemaProfileSha256=$schemaHash;machineId=$machine;
      tenantId=$request.tenantId;companyId=$request.companyId;branchId=$request.branchId;expiresAtUtc=[DateTime]::UtcNow.AddHours(1).ToString('o');recoveryAuthorityAction='PRESERVE_EXTERNAL_WITNESS_HOST_REMAINS_STOPPED'}
    $planPath=Join-Path $state ($Id+'.plan.json');Write-VentioOperationJson $planPath $plan $adminSid
    $result.planSha256=(Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant();$result.backupName=$request.body.backupName
    $result.manifestSha256=$backup.Hash;$result.restoreRequiresRecovery=$true;$result.code='RESTORE_PLAN_READY'
   }
   'RESTORE'{
    $planId=[string]$request.body.planOperationId
    if($planId -notmatch '^[0-9a-f-]{36}$'){throw 'HOST_OPERATION_PLAN_INVALID'}
    $planPath=Join-Path $state ($planId+'.plan.json');$plan=Read-VentioOperationJson $planPath $adminSid
    if((Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedPlanSha256 -or
      [DateTime]::Parse($plan.expiresAtUtc).ToUniversalTime() -le [DateTime]::UtcNow -or $plan.backupName -cne $request.body.backupName -or
      $plan.machineId -cne $machine -or $plan.schemaProfileSha256 -cne $schemaHash -or $plan.tenantId -cne $request.tenantId -or
      $plan.companyId -cne $request.companyId -or $plan.branchId -cne $request.branchId){throw 'HOST_OPERATION_RESTORE_PLAN_CHANGED'}
    $backup=Get-Backup ([string]$plan.backupName)
    if($backup.Hash -cne $plan.manifestSha256){throw 'HOST_OPERATION_RESTORE_BACKUP_CHANGED'}
    $keepStopped=$true
    $maintenance=$true;Start-VentioHostServiceMaintenance $hostService|Out-Null
    if($hostService.State -eq 'Running'){Stop-Service -Name VentioHost -ErrorAction Stop}
    Wait-VentioServiceStoppedStable 'VentioHost' 2 120 $null $null
    & (Join-Path $PSScriptRoot 'restore-host-upgrade-backup.ps1') -BackupDirectory $backup.Root -ConfirmRestore|Out-Null
    $result.backupName=$plan.backupName;$result.restoreRequiresRecovery=$true;$result.code='RESTORED_RECOVERY_AUTHORITY_RECONCILIATION_REQUIRED'
   }
  }
  $result.state='SUCCEEDED'
 }catch{
  $result.state='FAILED'
  $message=[string]$_.Exception.Message
  $result.code=if($message -match '^HOST_[A-Z0-9_]{1,120}$'){$message}else{'HOST_OPERATION_FAILED'}
  # Only a completed, known failure before any restore permits a fresh backup
  # attempt. Unknown crash journals require local inspection, never replay.
  $result.retryable=$request.operation -eq 'BACKUP_NOW' -and -not $result.ContainsKey('backupName') -and $result.code -notmatch 'OUTCOME_UNKNOWN|IDENTITY|ACL|TRUST|REPARSE|PATH|INTEGRITY|VERSION'
 }finally{
  try{
   if($maintenance -and -not $keepStopped){
    Restore-VentioHostServiceFailureActions (Get-CimInstance Win32_Service -Filter "Name='VentioHost'")
    if($restartHost){Start-Service -Name VentioHost -ErrorAction Stop}
   }
  }catch{$result.state='FAILED';$result.code='HOST_OPERATION_SERVICE_RECOVERY_REQUIRED';$result.retryable=$false}
  $result.completedAtUtc=[DateTime]::UtcNow.ToString('o')
  Write-VentioOperationJson $resultPath $result $serviceSid
  Write-VentioOperationJson $journal $result $adminSid
  if($Scheduled){Write-VentioOperationJson $dailyPath @{state=$result.state;attempts=$attempts;updatedAtUtc=$result.completedAtUtc} $adminSid}
 }
}

$mutex=Enter-VentioMaintenanceLock
try{
 if($RunScheduled){
  foreach($file in Get-ChildItem -LiteralPath $spool -Filter '*.request.json' -File|Select-Object -First 100){
   $id=$file.Name -replace '\.request\.json$',''
   if($id -match '^[0-9a-f-]{36}$'){Invoke-Operation $id -Scheduled}
  }
 }else{Invoke-Operation $OperationId}
}finally{$mutex.ReleaseMutex();$mutex.Dispose()}
