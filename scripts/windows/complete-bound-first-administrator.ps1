# Pinned, service-controlled recovery of the original owner-approved scope.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security
$statusRoot='C:\Program Files\Ventio\SetupStatus'
$resultPath=Join-Path $statusRoot 'maintenance-bound-completion-20261031.json'
$phase='PREFLIGHT'
function Exchange($Command) {
  $pipe=[IO.Pipes.NamedPipeClientStream]::new('.','Ventio.Host.FirstAdmin.v1',[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous,[Security.Principal.TokenImpersonationLevel]::Impersonation)
  try {
    $pipe.Connect(10000); $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Command | ConvertTo-Json -Compress)+"`n")
    $pipe.Write($bytes,0,$bytes.Length); $pipe.Flush()
    $reader=[IO.StreamReader]::new($pipe,[Text.UTF8Encoding]::new($false),$false,1024,$true)
    try {$read=$reader.ReadLineAsync(); if(-not $read.Wait(100000)){throw 'PIPE_TIMEOUT'}; $line=$read.GetAwaiter().GetResult(); if(-not $line -or $line.Length -gt 8192){throw 'PIPE_RESPONSE_INVALID'}; return (ConvertFrom-Json -InputObject $line)} finally {$reader.Dispose()}
  } finally {$pipe.Dispose()}
}
try {
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $pendingPath=Join-Path $env:LOCALAPPDATA 'VentioFramework\host-setup-pending.json'
  $pending=Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json
  if($pending.operationId -cne 'c5e5563e1eade9857513a8046aac4274' -or $pending.requesterSid -cne $sid -or
    (Get-FileHash 'C:\Program Files\Ventio\host-payload\VentioHostService.exe' -Algorithm SHA256).Hash -ne '16463268DE7BCB48AEC4F62A3D0CE850403B4D31E36B5CF1E804070ACEFA4431'){throw 'TARGET_CHANGED'}
  $phase='READ_BOUND_STATUS'
  $bound=Exchange @{operation='status'}
  if(-not $bound.success -or $bound.status -cne 'pending' -or $bound.scope.tenantId -cne 'Test-Project' -or $bound.scope.companyId -cne 'Test-Company' -or $bound.scope.branchId -cne 'Test-Branch'){throw 'BOUND_SCOPE_CHANGED'}
  $phase='BACKUP_ACL'
  $root='C:\ProgramData\Ventio'; $oldAcl=Get-Acl -LiteralPath $root
  if((Get-Item $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'ROOT_REPARSE'}
  $backup=Join-Path 'C:\ProgramData\Ventio\RecoveryEvidence' ('bound-first-admin-' + [Guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($backup) | Out-Null
  $private=[Security.AccessControl.DirectorySecurity]::new(); $private.SetAccessRuleProtection($true,$false)
  foreach($trusted in @('S-1-5-18','S-1-5-32-544')){$private.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($trusted),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
  Set-Acl -LiteralPath $backup -AclObject $private
  [IO.File]::WriteAllText((Join-Path $backup 'root-acl-before.sddl'),$oldAcl.Sddl)
  Copy-Item -LiteralPath $pendingPath -Destination (Join-Path $backup 'pending-before.json')
  $phase='PROTECT_PARENT'
  $acl=[Security.AccessControl.DirectorySecurity]::new(); $acl.SetAccessRuleProtection($true,$false)
  $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
  foreach($trusted in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($trusted),'FullControl','Allow'))}
  foreach($name in @('VentioHost','VentioPostgres')){$serviceSid=[Security.Principal.NTAccount]::new('NT SERVICE',$name).Translate([Security.Principal.SecurityIdentifier]);$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($serviceSid,'ReadAndExecute','Allow'))}
  Set-Acl -LiteralPath $root -AclObject $acl
  $phase='BOOTSTRAP'
  $reply=Exchange @{operation='bootstrap';tenantId='Test-Project';companyId='Test-Company';branchId='Test-Branch'}
  if(-not $reply.success -or $reply.status -cne 'pending' -or $reply.token -notmatch '^[A-Za-z0-9_-]{43}$' -or $reply.requestId -notmatch '^[A-Za-z0-9_-]{43}$' -or $reply.actorId -notmatch '^usr_[A-Za-z0-9_-]{43}$') {
    $safeCode=if($reply.failureCode -match '^HOST_FIRST_ADMIN_[A-Z_]+$'){$reply.failureCode}else{'HOST_FIRST_ADMINISTRATOR_FAILED'}
    [IO.File]::WriteAllText($resultPath,(@{state='failed';phase=$phase;code=$safeCode}|ConvertTo-Json -Compress));exit 1
  }
  $phase='PROTECT_HANDOFF'
  $operationId=[Guid]::NewGuid().ToString('N')
  $document=@{formatVersion=1;operationId=$operationId;requestId=$reply.requestId;actorId=$reply.actorId;token=$reply.token;expiresAt=$reply.expiresAt}|ConvertTo-Json -Compress
  $plain=[Text.UTF8Encoding]::new($false).GetBytes($document);$entropy=[Text.UTF8Encoding]::new($false).GetBytes($operationId)
  try{$encrypted=[Security.Cryptography.ProtectedData]::Protect($plain,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)}finally{[Array]::Clear($plain,0,$plain.Length);[Array]::Clear($entropy,0,$entropy.Length)}
  $destination=Join-Path $statusRoot ($operationId+'.credential.dpapi')
  $stream=[IO.FileStream]::new($destination,'CreateNew','Write','None')
  try{$stream.Write($encrypted,0,$encrypted.Length);$stream.Flush($true)}finally{$stream.Dispose();[Array]::Clear($encrypted,0,$encrypted.Length)}
  $fileAcl=[Security.AccessControl.FileSecurity]::new();$fileAcl.SetAccessRuleProtection($true,$false);$fileAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
  foreach($trusted in @('S-1-5-18','S-1-5-32-544')){$fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($trusted),'FullControl','Allow'))}
  $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),([Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::Delete),'Allow'));Set-Acl -LiteralPath $destination -AclObject $fileAcl
  $phase='ACKNOWLEDGE'
  $ack=Exchange @{operation='acknowledge';requestId=$reply.requestId};$reply=$null;$document=$null
  if(-not $ack.success -or $ack.status -cne 'acknowledged'){throw 'ACKNOWLEDGEMENT_FAILED'}
  $pending.operationId=$operationId;$pending.tenantId='Test-Project';$pending.companyId='Test-Company';$pending.branchId='Test-Branch'
  $temporary=$pendingPath+'.resume.tmp';[IO.File]::WriteAllText($temporary,($pending|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  [IO.File]::Replace($temporary,$pendingPath,($pendingPath+'.before-bound-resume-'+$operationId),$false)
  $state=@{formatVersion=1;operationId=$operationId;state='complete';phase='HOST_READINESS';failureCode=$null;updatedAtUtc=[DateTime]::UtcNow.ToString('o')}
  [IO.File]::WriteAllText((Join-Path $statusRoot ($operationId+'.json')),($state|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($resultPath,(@{state='complete';code='BOUND_FIRST_ADMIN_HANDOFF_READY';operationId=$operationId}|ConvertTo-Json -Compress))
} catch {$safe=if($_.Exception.Message -match '^[A-Z_]+$'){$_.Exception.Message}else{'BOUND_FIRST_ADMIN_COMPLETION_FAILED'};[IO.File]::WriteAllText($resultPath,(@{state='failed';phase=$phase;code=$safe;failureType=$_.Exception.GetType().Name}|ConvertTo-Json -Compress));exit 1}
