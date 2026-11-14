Set-StrictMode -Version Latest

function Enter-VentioMaintenanceLock {
  $security=[Security.AccessControl.MutexSecurity]::new()
  foreach($sid in @('S-1-5-18','S-1-5-32-544')){
    $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.MutexRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
  }
  $created=$false
  $mutex=[Threading.Mutex]::new($false,'Global\VentioHostDatabaseMaintenance',[ref]$created,$security)
  try {
    try {$held=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$held=$true}
    if(-not $held){throw 'HOST_OPERATION_MAINTENANCE_BUSY'}
    return $mutex
  } catch {$mutex.Dispose();throw}
}

function Assert-VentioOperationPath([string]$Path,[string]$OwnerSid,[switch]$Directory){
  $full=[IO.Path]::GetFullPath($Path)
  if($full -notmatch '^[A-Za-z]:\\' -or ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))).DriveType -ne 'Fixed'){throw 'HOST_OPERATION_PATH_INVALID'}
  $cursor=Get-Item -LiteralPath $full -Force -ErrorAction Stop
  if($Directory -and -not $cursor.PSIsContainer){throw 'HOST_OPERATION_DIRECTORY_REQUIRED'}
  if(-not $Directory -and $cursor.PSIsContainer){throw 'HOST_OPERATION_FILE_REQUIRED'}
  while($null -ne $cursor){
    if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'HOST_OPERATION_REPARSE_POINT'}
    $acl=Get-Acl -LiteralPath $cursor.FullName
    $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $trusted=@($OwnerSid,'S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    if($trusted -notcontains $owner){throw 'HOST_OPERATION_UNTRUSTED_OWNER'}
    $rules=$acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
    foreach($rule in $rules){
      if($rule.AccessControlType -ne 'Allow'){continue}
      if($cursor.FullName -eq $full){
        if($trusted[0..2] -notcontains $rule.IdentityReference.Value -or [int]$rule.FileSystemRights -ne [int][Security.AccessControl.FileSystemRights]::FullControl){throw 'HOST_OPERATION_UNTRUSTED_ACL'}
      }elseif($trusted -notcontains $rule.IdentityReference.Value){
        $destructive=[Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
        if($rule.FileSystemRights -band $destructive){throw 'HOST_OPERATION_UNTRUSTED_ANCESTOR'}
      }
    }
    if($cursor.FullName -eq $full){foreach($required in @($OwnerSid,'S-1-5-18','S-1-5-32-544')|Select-Object -Unique){if(-not @($rules|Where-Object {$_.IdentityReference.Value -eq $required -and $_.AccessControlType -eq 'Allow'}).Count){throw 'HOST_OPERATION_REQUIRED_ACL_MISSING'}}}
    if($cursor.FullName -eq $full -and ($owner -ne $OwnerSid -or -not $acl.AreAccessRulesProtected)){throw 'HOST_OPERATION_PRIVATE_OWNER_REQUIRED'}
    $parent=Split-Path -Parent $cursor.FullName
    if(-not $parent -or $parent -eq $cursor.FullName){break}
    $cursor=Get-Item -LiteralPath $parent -Force
  }
  return $full
}

function Write-VentioOperationJson([string]$Path,[object]$Value,[string]$OwnerSid){
  $parent=Split-Path -Parent ([IO.Path]::GetFullPath($Path))
  [void](Assert-VentioOperationPath $parent $OwnerSid -Directory)
  if(Test-Path -LiteralPath $Path){[void](Assert-VentioOperationPath $Path $OwnerSid)}
  $temp=Join-Path $parent ('.operation-'+[guid]::NewGuid().ToString('N')+'.tmp')
  $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 15 -Compress))
    $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
  }finally{$stream.Dispose()}
  $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false)
  $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($OwnerSid))
  foreach($sid in @($OwnerSid,'S-1-5-18','S-1-5-32-544')|Select-Object -Unique){
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
  }
  Set-Acl -LiteralPath $temp -AclObject $acl
  if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,$null)}else{[IO.File]::Move($temp,$Path)}
}

function Read-VentioOperationJson([string]$Path,[string]$OwnerSid,[int]$MaximumBytes=1048576){
  [void](Assert-VentioOperationPath $Path $OwnerSid)
  if((Get-Item -LiteralPath $Path).Length -gt $MaximumBytes){throw 'HOST_OPERATION_FILE_LIMIT'}
  return [IO.File]::ReadAllText($Path)|ConvertFrom-Json
}

Export-ModuleMember -Function Enter-VentioMaintenanceLock,Assert-VentioOperationPath,Write-VentioOperationJson,Read-VentioOperationJson
