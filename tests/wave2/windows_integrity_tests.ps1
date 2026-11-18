[CmdletBinding()]
param([string]$PrivateFixtureParent = $env:TEMP)

# PREPARED / NOT EXECUTED. No Pester install, service, scheduler or Host needed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:VENTIO_WAVE2_PREPARED_TESTS -cne 'yes' -or $env:COMPUTERNAME -in @('VENTIO-TEST-01','VENTIO-TEST-02','TEST-01','TEST-02','BAHAA')) {
  throw 'Explicit disposable test opt-in required; TEST-01/TEST-02 prohibited.'
}
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
Import-Module (Join-Path $repository 'scripts\windows\HostBackupIntegrity.psm1') -Force
Import-Module (Join-Path $repository 'scripts\windows\HostOperationStorage.psm1') -Force
$parent = [IO.Path]::GetFullPath($PrivateFixtureParent).TrimEnd('\')
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Existing private test parent required.' }
$name = 'ventio-wave2-integrity-' + [guid]::NewGuid().ToString('N')
$root = [IO.Path]::GetFullPath((Join-Path $parent $name))
if ([IO.Path]::GetDirectoryName($root) -cne $parent) { throw 'Fixture root is outside its parent.' }
[void][IO.Directory]::CreateDirectory($root)
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function Set-PrivateDirectory([string]$Path) {
  $acl = [Security.AccessControl.DirectorySecurity]::new()
  $acl.SetAccessRuleProtection($true,$false)
  $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($sid))
  foreach ($identity in @($sid,'S-1-5-18','S-1-5-32-544') | Select-Object -Unique) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($identity),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
  }
  Set-Acl -LiteralPath $Path -AclObject $acl
}
Set-PrivateDirectory $root
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Failure([scriptblock]$Action,[string]$Code) {
  $failure = $null
  try { & $Action } catch { $failure = $_.Exception.Message }
  Assert-True ($null -ne $failure -and $failure -ceq $Code) "Expected exact failure $Code"
}
function Test-Case([string]$Id,[string]$Capabilities,[string]$Requirement,[scriptblock]$Body) {
  try {
    & $Body
    Write-Output "PASS $Id [$Capabilities] $Requirement"
  } catch {
    Write-Output "FAIL $Id [$Capabilities] $Requirement"
    throw
  }
}
$data = Join-Path $root 'data'
[void][IO.Directory]::CreateDirectory((Join-Path $data 'base'))
[IO.File]::WriteAllText((Join-Path $data 'PG_VERSION'),'16')
[IO.File]::WriteAllBytes((Join-Path $data 'base\relation'),[byte[]](1,2,3,4))
$link = Join-Path $root 'junction'
try {
  Test-Case 'W2-W001' 'M05' 'Real nested backup inventory contains sorted per-file lengths and SHA-256' {
    $inventory = @(Get-HostBackupIntegrity $data)
    Assert-True ($inventory.Count -eq 2 -and $inventory[0].path -ceq 'base/relation' -and $inventory[0].bytes -eq 4) 'Inventory mismatch'
    foreach ($entry in $inventory) { Assert-True ($entry.sha256 -cmatch '^[0-9a-f]{64}$') 'Missing digest' }
    Assert-HostBackupIntegrity $data $inventory
  }
  Test-Case 'W2-W002' 'M05,M09' 'Same-size one-byte corruption is detected' {
    $inventory = @(Get-HostBackupIntegrity $data)
    [IO.File]::WriteAllBytes((Join-Path $data 'base\relation'),[byte[]](1,2,3,5))
    Assert-Failure { Assert-HostBackupIntegrity $data $inventory } 'HOST_BACKUP_INTEGRITY_CONTENT_MISMATCH'
    [IO.File]::WriteAllBytes((Join-Path $data 'base\relation'),[byte[]](1,2,3,4))
  }
  Test-Case 'W2-W003' 'M05,M09' 'Missing files cannot pass inventory verification' {
    $inventory = @(Get-HostBackupIntegrity $data)
    $file = Join-Path $data 'base\relation'
    [IO.File]::Move($file,(Join-Path $root 'saved-relation'))
    try { Assert-Failure { Assert-HostBackupIntegrity $data $inventory } 'HOST_BACKUP_INTEGRITY_FILE_COUNT_MISMATCH' }
    finally { [IO.File]::Move((Join-Path $root 'saved-relation'),$file) }
  }
  Test-Case 'W2-W004' 'M05,M09' 'Unexpected files cannot pass inventory verification' {
    $inventory = @(Get-HostBackupIntegrity $data)
    [IO.File]::WriteAllText((Join-Path $data 'extra'),'unexpected')
    try { Assert-Failure { Assert-HostBackupIntegrity $data $inventory } 'HOST_BACKUP_INTEGRITY_FILE_COUNT_MISMATCH' }
    finally { Remove-Item -LiteralPath (Join-Path $data 'extra') -Force }
  }
  Test-Case 'W2-W005' 'M05,M09' 'Manifest path traversal absolute paths duplicate names invalid hashes and negative lengths fail' {
    foreach ($path in @('../outside','C:/outside','base\relation','base//relation')) {
      Assert-Failure { Assert-HostBackupIntegrity $data @([pscustomobject]@{path=$path;bytes=1;sha256=('a'*64)}) } 'HOST_BACKUP_INTEGRITY_MANIFEST_INVALID'
    }
    $entry = [pscustomobject]@{path='PG_VERSION';bytes=2;sha256=('a'*64)}
    Assert-Failure { Assert-HostBackupIntegrity $data @($entry,$entry) } 'HOST_BACKUP_INTEGRITY_MANIFEST_INVALID'
    Assert-Failure { Assert-HostBackupIntegrity $data @([pscustomobject]@{path='PG_VERSION';bytes=-1;sha256=('a'*64)}) } 'HOST_BACKUP_INTEGRITY_MANIFEST_INVALID'
    Assert-Failure { Assert-HostBackupIntegrity $data @([pscustomobject]@{path='PG_VERSION';bytes=2;sha256='not-a-hash'}) } 'HOST_BACKUP_INTEGRITY_MANIFEST_INVALID'
  }
  Test-Case 'W2-W006' 'M05,M09' 'Junction ancestors are rejected and their target remains intact' {
    [void](New-Item -ItemType Junction -Path $link -Target $data)
    try { Assert-Failure { Get-HostBackupIntegrity $link } 'HOST_BACKUP_INTEGRITY_REPARSE_POINT' }
    finally { Remove-Item -LiteralPath $link -Force }
    Assert-True ([IO.File]::ReadAllText((Join-Path $data 'PG_VERSION')) -ceq '16') 'Junction target changed'
  }
  Test-Case 'W2-W007' 'M05,M09' 'Staged backup copies must match original content before acceptance' {
    $inventory = @(Get-HostBackupIntegrity $data)
    $stage = Join-Path $root 'staged'
    Copy-Item -LiteralPath $data -Destination $stage -Recurse
    Assert-HostBackupIntegrity $stage $inventory
    [IO.File]::WriteAllBytes((Join-Path $stage 'base\relation'),[byte[]](4,3,2,1))
    Assert-Failure { Assert-HostBackupIntegrity $stage $inventory } 'HOST_BACKUP_INTEGRITY_CONTENT_MISMATCH'
  }
  Test-Case 'W2-W008' 'M05,M09' 'Protected operation JSON is replaced atomically with no temporary residue' {
    # An inherit-only ACE grants no right on the ancestor itself; a protected
    # child must remain usable. The same ACE applied to the ancestor is unsafe.
    $ancestor = Join-Path $root 'inherit-only-parent'
    $child = Join-Path $ancestor 'private-child'
    [void][IO.Directory]::CreateDirectory($child)
    Set-PrivateDirectory $ancestor
    Set-PrivateDirectory $child
    $acl = Get-Acl -LiteralPath $ancestor
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),'FullControl','ContainerInherit,ObjectInherit','InheritOnly','Allow'))
    Set-Acl -LiteralPath $ancestor -AclObject $acl
    Assert-True ((Assert-VentioOperationPath $child $sid -Directory) -ceq $child) 'Inherit-only ancestor rule was treated as an effective grant'
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),'Delete','Allow'))
    Set-Acl -LiteralPath $ancestor -AclObject $acl
    Assert-Failure { Assert-VentioOperationPath $child $sid -Directory } 'HOST_OPERATION_UNTRUSTED_ANCESTOR'
    Set-PrivateDirectory $ancestor
    $file = Join-Path $root 'operation.json'
    Write-VentioOperationJson $file @{formatVersion=1;state='RUNNING'} $sid
    Write-VentioOperationJson $file @{formatVersion=1;state='SUCCEEDED'} $sid
    $value = Read-VentioOperationJson $file $sid
    Assert-True ($value.state -ceq 'SUCCEEDED') 'Replacement did not persist'
    Assert-True (@(Get-ChildItem -LiteralPath $root -Filter '.operation-*.tmp' -File).Count -eq 0) 'Temporary file remains'
    $acl = Get-Acl -LiteralPath $file
    Assert-True ($acl.AreAccessRulesProtected -and $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ceq $sid) 'Private ACL missing'
  }
  Test-Case 'W2-W009' 'M05,M09' 'Protected operation JSON enforces byte bounds before decoding' {
    $file = Join-Path $root 'large.json'
    Write-VentioOperationJson $file @{text=('x'*1024)} $sid
    Assert-Failure { Read-VentioOperationJson $file $sid 16 } 'HOST_OPERATION_FILE_LIMIT'
  }
  Test-Case 'W2-W010' 'M05,M09' 'An untrusted read ACL on a fixture file is rejected' {
    $file = Join-Path $root 'untrusted.json'
    Write-VentioOperationJson $file @{state='fixture'} $sid
    $acl = Get-Acl -LiteralPath $file
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),'Read','Allow'))
    Set-Acl -LiteralPath $file -AclObject $acl
    Assert-Failure { Read-VentioOperationJson $file $sid } 'HOST_OPERATION_UNTRUSTED_ACL'
    # Only this disposable fixture file's ACL is changed; no OS policy changes.
  }
  Test-Case 'W2-W011' 'M09' 'The real restore entry point refuses missing confirmation before touching services' {
    Assert-Failure { & (Join-Path $repository 'scripts\windows\restore-host-upgrade-backup.ps1') -BackupDirectory $data } 'HOST_UPGRADE_RESTORE_CONFIRMATION_REQUIRED'
  }
} finally {
  if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
  $resolved = [IO.Path]::GetFullPath($root)
  if ($resolved -cne (Join-Path $parent $name) -or [IO.Path]::GetDirectoryName($resolved) -cne $parent) { throw 'Refusing cleanup outside the exact created fixture.' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
