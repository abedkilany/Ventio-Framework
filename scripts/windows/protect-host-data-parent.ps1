$ErrorActionPreference='Stop'
$root='C:\ProgramData\Ventio'
$current=[Security.Principal.WindowsIdentity]::GetCurrent().User
$previous=Get-Acl -LiteralPath $root
if((([Security.Principal.NTAccount]::new($previous.Owner)).Translate([Security.Principal.SecurityIdentifier])).Value -cne $current.Value -or
  ((Get-Item $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'HOST_PARENT_STATE_CHANGED'}
$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
foreach($trusted in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($trusted),'FullControl','Allow'))}
foreach($name in @('VentioHost','VentioPostgres')){$sid=[Security.Principal.NTAccount]::new('NT SERVICE',$name).Translate([Security.Principal.SecurityIdentifier]);$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'ReadAndExecute','Allow'))}
[IO.File]::WriteAllText('C:\ProgramData\Ventio\RecoveryEvidence\host-parent-before-20261031.sddl',$previous.Sddl)
Set-Acl -LiteralPath $root -AclObject $acl
& 'C:\Users\User\Desktop\Ventio Framework\scripts\windows\diagnose-pending-first-administrator.ps1' -ResumeBoundScope
