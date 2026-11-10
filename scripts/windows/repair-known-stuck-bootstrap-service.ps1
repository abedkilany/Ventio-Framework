param([switch] $Apply, [switch] $SelfTest)

# Development-only maintenance for the pinned, previously installed bootstrap build.
# No database, credential, Recovery Authority, or service-registration data is removed.
# This is not a general process-termination or elevated command interface.
$ErrorActionPreference = 'Stop'
$serviceName = 'VentioHost'
$expectedPid = 9492
$expectedCreationTime = [long]134379112590479010
$serviceExecutable = 'C:\Program Files\Ventio\host-payload\VentioHostService.exe'
$legacyHash = 'C020FDE0987579E7949108DFA428ED7C7DA14A7C953EC34411A3E3E432660009'
$replacementHash = '129E4F4AB295FA161C32BE35C09F488107206250B9FAB6701D930A9F7B3113C3'
$clientExecutable = 'C:\Program Files\Ventio\ventio_native_client.exe'
$replacementClientHash = '45057486D3D04211139734DE805ED5FDCA779ACCB927DF5A57D1B90DFF6F4240'
$installer = 'C:\Users\User\Desktop\Ventio Framework\dist\windows\host-stop-wait-fix-20261031\Ventio-Setup-0.1.0.exe'
$installerHash = 'C4A9EE52A9167BC5C0D56770C52253F65F681886FE3CDD26693E594568F64E32'
$statusDirectory = 'C:\Program Files\Ventio\SetupStatus'
$statusPath = Join-Path $statusDirectory 'maintenance-stuck-bootstrap-20261031.json'
$sc = Join-Path $env:SystemRoot 'System32\sc.exe'
$phase = 'PREFLIGHT'
$evidenceDirectory = $null
$serviceHandle = [IntPtr]::Zero
$installerStream = $null
$startupChanged = $false
$statusEnabled = $false

function Assert-NoReparse([string] $Path) {
  $current = [IO.Path]::GetFullPath($Path)
  while ($current) {
    if (Test-Path -LiteralPath $current) {
      if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'VENTIO_REPAIR_REPARSE_POINT'
      }
    }
    $parent = [IO.Directory]::GetParent($current)
    if ($null -eq $parent) { break }
    $current = $parent.FullName
  }
}

function Assert-RepairSnapshot($Snapshot) {
  if ($Snapshot.Name -cne 'VentioHost' -or $Snapshot.Account -cne 'NT SERVICE\VentioHost' -or
      -not $Snapshot.Image.Trim('"').Equals($serviceExecutable, [StringComparison]::OrdinalIgnoreCase) -or
      $Snapshot.ServiceType -cne 'Own Process' -or $Snapshot.State -cne 'Stop Pending' -or
      $Snapshot.StartMode -cne 'Auto' -or $Snapshot.ProcessId -ne $expectedPid -or
      [Math]::Abs([long]$Snapshot.CreationTime - $expectedCreationTime) -gt 10000 -or
      $Snapshot.CheckPoint -ne 1 -or $Snapshot.WaitHint -ne 20000 -or
      $Snapshot.BinaryHash -ne $legacyHash -or $Snapshot.PackageHash -ne $installerHash -or
      $Snapshot.ChildCount -ne 0 -or $Snapshot.OtherHostProcessCount -ne 0 -or $Snapshot.SetupCount -ne 0 -or
      $Snapshot.PostgresState -cne 'Running' -or $Snapshot.PostgresAccount -cne 'NT SERVICE\VentioPostgres' -or
      $Snapshot.PostgresImage -cne '"C:\Program Files\Ventio\host-payload\postgresql\bin\pg_ctl.exe" runservice -N "VentioPostgres" -D "C:\ProgramData\Ventio\PostgreSQL\data" -w') {
    throw 'VENTIO_REPAIR_TARGET_CHANGED'
  }
}

function Get-RepairSnapshot {
  $hostService = Get-CimInstance Win32_Service -Filter "Name='VentioHost'"
  $databaseService = Get-CimInstance Win32_Service -Filter "Name='VentioPostgres'"
  $processes = @(Get-CimInstance Win32_Process)
  $target = @($processes | Where-Object ProcessId -eq $expectedPid)
  if ($null -eq $hostService -or $null -eq $databaseService -or $target.Count -ne 1) { throw 'VENTIO_REPAIR_TARGET_MISSING' }
  return @{
    Name = $hostService.Name; Account = $hostService.StartName; Image = $hostService.PathName
    ServiceType = $hostService.ServiceType; State = $hostService.State; StartMode = $hostService.StartMode
    ProcessId = $hostService.ProcessId; CreationTime = $target[0].CreationDate.ToUniversalTime().ToFileTimeUtc()
    CheckPoint = $hostService.CheckPoint; WaitHint = $hostService.WaitHint
    BinaryHash = (Get-FileHash -LiteralPath $serviceExecutable -Algorithm SHA256).Hash
    PackageHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    ChildCount = @($processes | Where-Object ParentProcessId -eq $expectedPid).Count
    OtherHostProcessCount = @($processes | Where-Object { $_.Name -in @('ventio_host.exe','ventio_identity_bootstrap.exe','ventio_native_client.exe') }).Count
    SetupCount = @($processes | Where-Object { $_.Name -like 'Ventio-Setup-*' }).Count
    PostgresState = $databaseService.State; PostgresAccount = $databaseService.StartName; PostgresImage = $databaseService.PathName
  }
}

function Set-PrivateDirectoryAcl([string] $Path) {
  $acl = [Security.AccessControl.DirectorySecurity]::new()
  $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
  $acl.SetOwner($administrators)
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
  }
  Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-StatusDirectoryAcl {
  Assert-NoReparse $statusDirectory
  if (-not (Test-Path -LiteralPath $statusDirectory -PathType Container)) { throw 'VENTIO_REPAIR_STATUS_DIRECTORY_MISSING' }
  $writeMask = [Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor
    [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
  foreach ($entry in (Get-Acl -LiteralPath $statusDirectory).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
    if ($entry.AccessControlType -eq 'Allow' -and ($entry.FileSystemRights -band $writeMask) -ne 0 -and
        $entry.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544')) { throw 'VENTIO_REPAIR_STATUS_ACL_INVALID' }
  }
  Assert-NoReparse $statusPath
}

function Publish-Status([string] $State, [string] $Code) {
  if (-not $statusEnabled) { return }
  $record = [ordered]@{ formatVersion=1; operation='known-stuck-bootstrap-repair'; state=$State; phase=$phase; code=$Code; timestamp=[DateTime]::UtcNow.ToString('o') }
  $json = $record | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($statusPath, $json, [Text.UTF8Encoding]::new($false))
  if ($evidenceDirectory) { [IO.File]::WriteAllText((Join-Path $evidenceDirectory 'checkpoint.json'), $json, [Text.UTF8Encoding]::new($false)) }
}

function Wait-ServiceState([string] $Name, [string] $State) {
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  do {
    if ((Get-Service -Name $Name -ErrorAction Stop).Status.ToString() -eq $State) { return }
    if ([DateTime]::UtcNow -ge $deadline) { throw 'VENTIO_REPAIR_SERVICE_WAIT_TIMEOUT' }
    Start-Sleep -Milliseconds 500
  } while ($true)
}

function Initialize-NativeProcessAccess {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
public static class VentioPinnedProcess {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref uint length);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr process, uint exitCode);
  [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
  [DllImport("advapi32.dll", SetLastError=true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
  public static string UserSid(IntPtr process) {
    IntPtr token;
    if (!OpenProcessToken(process, 8, out token)) throw new InvalidOperationException("VENTIO_REPAIR_TOKEN_QUERY_FAILED");
    try { using (var identity = new WindowsIdentity(token)) { return identity.User.Value; } }
    finally { CloseHandle(token); }
  }
}
'@
}

function Stop-KnownFailedInstaller {
  # The owner explicitly authorized recovering the failed pre-file-copy installer.
  $oldInstaller = 'C:\Users\User\Desktop\Ventio Framework\dist\windows\host-first-admin-repair-20261031-verified\Ventio-Setup-0.1.0.exe'
  if ((Get-FileHash -LiteralPath $oldInstaller -Algorithm SHA256).Hash -ne '94BE03AE9F03A1E7960CF682E2DAAC988C4BB4FA4E05C19BC1D622F8497FB512') { throw 'VENTIO_REPAIR_OLD_INSTALLER_CHANGED' }
  $expectedParents = @{ 2600=10088; 9736=2600; 20056=9736; 21700=20056 }
  $all = @(Get-CimInstance Win32_Process)
  $targets = @($all | Where-Object { $expectedParents.ContainsKey([int]$_.ProcessId) })
  if ($targets.Count -ne 4 -or @($all | Where-Object { $expectedParents.ContainsKey([int]$_.ParentProcessId) -and -not $expectedParents.ContainsKey([int]$_.ProcessId) }).Count -ne 0) { throw 'VENTIO_REPAIR_OLD_INSTALLER_TREE_CHANGED' }
  $handles = @{}
  try {
    foreach ($target in $targets) {
      $id = [int]$target.ProcessId
      if ($target.ParentProcessId -ne $expectedParents[$id]) { throw 'VENTIO_REPAIR_OLD_INSTALLER_TREE_CHANGED' }
      if ($id -in @(2600,20056)) {
        if (-not $target.ExecutablePath.Equals($oldInstaller,[StringComparison]::OrdinalIgnoreCase)) { throw 'VENTIO_REPAIR_OLD_INSTALLER_IMAGE_CHANGED' }
      } elseif ($target.ExecutablePath -notmatch '^C:\\Users\\User\\AppData\\Local\\Temp\\is-[A-Za-z0-9]+\.tmp\\Ventio-Setup-0\.1\.0\.tmp$') { throw 'VENTIO_REPAIR_OLD_INSTALLER_IMAGE_CHANGED' }
      $handle = [VentioPinnedProcess]::OpenProcess(0x00101001,$false,$id)
      if ($handle -eq [IntPtr]::Zero) { throw 'VENTIO_REPAIR_OLD_INSTALLER_OPEN_FAILED' }
      $handles[$id] = $handle
      $path = [Text.StringBuilder]::new(32768); [uint32]$pathLength=32768
      [long]$created=0; [long]$exited=0; [long]$kernel=0; [long]$user=0
      if (-not [VentioPinnedProcess]::QueryFullProcessImageName($handle,0,$path,[ref]$pathLength) -or
          -not $path.ToString().Equals($target.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -or
          -not [VentioPinnedProcess]::GetProcessTimes($handle,[ref]$created,[ref]$exited,[ref]$kernel,[ref]$user) -or
          [Math]::Abs($created-$target.CreationDate.ToUniversalTime().ToFileTimeUtc()) -gt 10000) { throw 'VENTIO_REPAIR_OLD_INSTALLER_PROCESS_REUSED' }
    }
    $targets | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CreationDate | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidenceDirectory 'failed-installer-processes.json') -Encoding UTF8
    foreach ($id in @(21700,20056,9736,2600)) {
      if ([VentioPinnedProcess]::WaitForSingleObject($handles[$id],0) -ne 0) {
        if (-not [VentioPinnedProcess]::TerminateProcess($handles[$id],0) -or [VentioPinnedProcess]::WaitForSingleObject($handles[$id],5000) -ne 0) { throw 'VENTIO_REPAIR_OLD_INSTALLER_STOP_FAILED' }
      }
    }
  } finally { foreach ($handle in $handles.Values) { [VentioPinnedProcess]::CloseHandle($handle) | Out-Null } }
}

if ($SelfTest) {
  if ($Apply) { throw 'VENTIO_REPAIR_INVALID_MODE' }
  $valid = @{
    Name='VentioHost'; Account='NT SERVICE\VentioHost'; Image=$serviceExecutable; ServiceType='Own Process'
    State='Stop Pending'; StartMode='Auto'; ProcessId=$expectedPid; CreationTime=$expectedCreationTime
    CheckPoint=1; WaitHint=20000; BinaryHash=$legacyHash; PackageHash=$installerHash; ChildCount=0; OtherHostProcessCount=0; SetupCount=0
    PostgresState='Running'; PostgresAccount='NT SERVICE\VentioPostgres'
    PostgresImage='"C:\Program Files\Ventio\host-payload\postgresql\bin\pg_ctl.exe" runservice -N "VentioPostgres" -D "C:\ProgramData\Ventio\PostgreSQL\data" -w'
  }
  Assert-RepairSnapshot $valid
  $cases = @(@('ProcessId',1),@('Account','LocalSystem'),@('Image','C:\Other\service.exe'),@('State','Running'),
    @('BinaryHash','00'),@('PackageHash','00'),@('ChildCount',1),@('OtherHostProcessCount',1),@('SetupCount',1),
    @('CreationTime',0),@('PostgresAccount','LocalSystem'),@('PostgresImage','C:\Other\postgres.exe'))
  foreach ($case in $cases) {
    $invalid = $valid.Clone(); $invalid[$case[0]] = $case[1]; $rejected = $false
    try { Assert-RepairSnapshot $invalid } catch { $rejected = $true }
    if (-not $rejected) { throw 'VENTIO_REPAIR_GUARD_SELF_TEST_FAILED' }
  }
  Initialize-NativeProcessAccess
  $ownHandle = [VentioPinnedProcess]::OpenProcess(0x00101000, $false, $PID)
  if ($ownHandle -eq [IntPtr]::Zero) { throw 'VENTIO_REPAIR_NATIVE_QUERY_TEST_FAILED' }
  try {
    $ownImage = [Text.StringBuilder]::new(32768); [uint32]$ownLength = 32768
    if (-not [VentioPinnedProcess]::QueryFullProcessImageName($ownHandle,0,$ownImage,[ref]$ownLength) -or
        -not $ownImage.ToString().Equals((Get-Process -Id $PID).Path,[StringComparison]::OrdinalIgnoreCase) -or
        [VentioPinnedProcess]::UserSid($ownHandle) -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
      throw 'VENTIO_REPAIR_NATIVE_QUERY_TEST_FAILED'
    }
  } finally { [VentioPinnedProcess]::CloseHandle($ownHandle) | Out-Null }
  Write-Output 'VENTIO_REPAIR_GUARD_TESTS_PASS: valid pinned target, 12 rejection cases, and native identity query against this test process; no system changes.'
  exit 0
}

try {
  foreach ($path in @($serviceExecutable,$installer,$statusDirectory,'C:\ProgramData\Ventio\RecoveryEvidence')) { Assert-NoReparse $path }
  $snapshot = Get-RepairSnapshot
  $preflightSnapshot = $snapshot.Clone()
  if ($Apply -and $preflightSnapshot.SetupCount -eq 4) { $preflightSnapshot.SetupCount = 0 }
  Assert-RepairSnapshot $preflightSnapshot
  if (-not $Apply) { Write-Output 'VENTIO_REPAIR_PREFLIGHT_PASS: pinned legacy service, no children or Host clients, PostgreSQL running; no system changes.'; exit 0 }
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'VENTIO_REPAIR_ELEVATION_REQUIRED' }
  Assert-StatusDirectoryAcl
  $statusEnabled = $true
  $evidenceDirectory = Join-Path 'C:\ProgramData\Ventio\RecoveryEvidence' ('host-stop-repair-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($evidenceDirectory) | Out-Null
  Set-PrivateDirectoryAcl $evidenceDirectory
  $snapshot | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidenceDirectory 'preflight.json') -Encoding UTF8
  Publish-Status 'running' 'VENTIO_REPAIR_VALIDATED'

  Initialize-NativeProcessAccess
  if ($snapshot.SetupCount -gt 0) {
    $phase = 'CLOSE_KNOWN_FAILED_INSTALLER'
    Publish-Status 'running' 'VENTIO_REPAIR_CLOSING_FAILED_INSTALLER'
    Stop-KnownFailedInstaller
    Assert-RepairSnapshot (Get-RepairSnapshot)
  }
  $serviceHandle = [VentioPinnedProcess]::OpenProcess(0x00101001, $false, $expectedPid)
  if ($serviceHandle -eq [IntPtr]::Zero) { throw 'VENTIO_REPAIR_PROCESS_OPEN_FAILED' }
  $image = [Text.StringBuilder]::new(32768); [uint32]$length = 32768
  if (-not [VentioPinnedProcess]::QueryFullProcessImageName($serviceHandle, 0, $image, [ref]$length) -or
      -not $image.ToString().Equals($serviceExecutable, [StringComparison]::OrdinalIgnoreCase)) { throw 'VENTIO_REPAIR_PROCESS_IMAGE_CHANGED' }
  [long]$created=0; [long]$exited=0; [long]$kernel=0; [long]$user=0
  if (-not [VentioPinnedProcess]::GetProcessTimes($serviceHandle,[ref]$created,[ref]$exited,[ref]$kernel,[ref]$user) -or
      [Math]::Abs($created-$expectedCreationTime) -gt 10000) { throw 'VENTIO_REPAIR_PROCESS_REUSED' }
  $expectedSid = [Security.Principal.NTAccount]::new('NT SERVICE','VentioHost').Translate([Security.Principal.SecurityIdentifier]).Value
  if ([VentioPinnedProcess]::UserSid($serviceHandle) -cne $expectedSid) { throw 'VENTIO_REPAIR_PROCESS_IDENTITY_CHANGED' }
  $installerStream = [IO.File]::Open($installer, 'Open', 'Read', 'Read')
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $pinnedHash = [BitConverter]::ToString($sha.ComputeHash($installerStream)).Replace('-','') } finally { $sha.Dispose() }
  if ($pinnedHash -ne $installerHash) { throw 'VENTIO_REPAIR_INSTALLER_CHANGED' }
  Start-Sleep -Seconds 1
  Assert-RepairSnapshot (Get-RepairSnapshot)

  $phase = 'STOP_LEGACY_SERVICE'
  & $sc config $serviceName 'start=' 'disabled' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'VENTIO_REPAIR_DISABLE_FAILED' }
  $startupChanged = $true
  Publish-Status 'running' 'VENTIO_REPAIR_LEGACY_STOP_REQUESTED'
  if (-not [VentioPinnedProcess]::TerminateProcess($serviceHandle, 0) -or
      [VentioPinnedProcess]::WaitForSingleObject($serviceHandle, 15000) -ne 0) { throw 'VENTIO_REPAIR_PROCESS_STOP_FAILED' }
  Wait-ServiceState $serviceName 'Stopped'
  [VentioPinnedProcess]::CloseHandle($serviceHandle) | Out-Null
  $serviceHandle = [IntPtr]::Zero

  $phase = 'INSTALL_FIXED_FILES'
  Publish-Status 'running' 'VENTIO_REPAIR_INSTALLING_FIXED_FILES'
  $installerArguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /ALLUSERS /DIR="C:\Program Files\Ventio" /LOG="' + (Join-Path $evidenceDirectory 'installer.log') + '"'
  $setup = Start-Process -FilePath $installer -ArgumentList $installerArguments -WindowStyle Hidden -PassThru
  if (-not $setup.WaitForExit(900000)) { throw 'VENTIO_REPAIR_INSTALLER_STILL_RUNNING' }
  $setup.Refresh()
  if ($setup.ExitCode -ne 0) { throw 'VENTIO_REPAIR_INSTALLER_FAILED' }
  if ((Get-FileHash -LiteralPath $serviceExecutable -Algorithm SHA256).Hash -ne $replacementHash -or
      (Get-FileHash -LiteralPath $clientExecutable -Algorithm SHA256).Hash -ne $replacementClientHash) { throw 'VENTIO_REPAIR_INSTALLED_BINARY_MISMATCH' }

  $phase = 'RESTORE_SERVICE'
  Publish-Status 'running' 'VENTIO_REPAIR_RESTORING_SERVICE'
  & $sc config $serviceName 'start=' 'auto' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'VENTIO_REPAIR_STARTUP_RESTORE_FAILED' }
  $startupChanged = $false
  if ((Get-Service -Name VentioPostgres).Status -ne 'Running') { throw 'VENTIO_REPAIR_POSTGRES_NOT_RUNNING' }
  if ((Get-Service -Name VentioHost).Status -ne 'Running') {
    & $sc start $serviceName | Out-Null
    if ($LASTEXITCODE -notin @(0,1056)) { throw 'VENTIO_REPAIR_HOST_START_FAILED' }
  }
  Wait-ServiceState $serviceName 'Running'
  $phase = 'COMPLETE'
  Publish-Status 'complete' 'VENTIO_REPAIR_FILES_UPDATED_BOOTSTRAP_PENDING'
  Write-Output 'VENTIO_REPAIR_FILES_UPDATED_BOOTSTRAP_PENDING'
}
catch {
  $code = [string]$_.Exception.Message
  if ($code -notmatch '^VENTIO_REPAIR_[A-Z_]+$') { $code = 'VENTIO_REPAIR_FAILED' }
  try { Publish-Status 'failed' $code } catch { }
  [Console]::Error.WriteLine($code)
  exit 1
}
finally {
  if ($serviceHandle -ne [IntPtr]::Zero) { [VentioPinnedProcess]::CloseHandle($serviceHandle) | Out-Null }
  if ($installerStream) { $installerStream.Dispose() }
  if ($startupChanged) {
    try {
      $currentHash = (Get-FileHash -LiteralPath $serviceExecutable -Algorithm SHA256).Hash
      if ($currentHash -in @($legacyHash,$replacementHash)) { & $sc config $serviceName 'start=' 'auto' | Out-Null }
    } catch { }
  }
}
