Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('Ventio.Setup.ServiceRecovery.Native' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Ventio.Setup.ServiceRecovery {
  [StructLayout(LayoutKind.Sequential)]
  public struct ScAction {
    public int Type;
    public uint Delay;
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct FailureActionsNative {
    public uint ResetPeriod;
    public IntPtr RebootMessage;
    public IntPtr Command;
    public uint ActionCount;
    public IntPtr Actions;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct FailureActionsFlagNative {
    [MarshalAs(UnmanagedType.Bool)] public bool Enabled;
  }

  public sealed class ActionValue {
    public int Type { get; set; }
    public uint Delay { get; set; }
    public ActionValue() { }
    public ActionValue(int type, uint delay) { Type = type; Delay = delay; }
  }

  public sealed class PolicyValue {
    public uint ResetPeriod { get; set; }
    public string RebootMessage { get; set; }
    public string Command { get; set; }
    public ActionValue[] Actions { get; set; }
    public bool FailureActionsOnNonCrashFailures { get; set; }
    public PolicyValue() { }
    public PolicyValue(uint resetPeriod, string rebootMessage, string command, ActionValue[] actions, bool failureActionsOnNonCrashFailures) {
      ResetPeriod = resetPeriod;
      RebootMessage = rebootMessage;
      Command = command;
      Actions = actions;
      FailureActionsOnNonCrashFailures = failureActionsOnNonCrashFailures;
    }
  }

  public static class Native {
    const uint ScManagerConnect = 0x0001;
    const uint ServiceQueryConfig = 0x0001;
    const uint ServiceChangeConfig = 0x0002;
    const uint ServiceConfigFailureActions = 2;
    const uint ServiceConfigFailureActionsFlag = 4;

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr OpenSCManagerW(string machine, string database, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr OpenServiceW(IntPtr manager, string name, uint access);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool CloseServiceHandle(IntPtr handle);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "QueryServiceConfig2W", SetLastError = true)]
    static extern bool QueryServiceConfig2(IntPtr service, uint infoLevel, IntPtr buffer, uint bufferSize, out uint bytesNeeded);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeServiceConfig2W", SetLastError = true)]
    static extern bool ChangeServiceConfig2(IntPtr service, uint infoLevel, IntPtr info);

    static IntPtr Open(string name, uint access, out IntPtr manager) {
      manager = OpenSCManagerW(null, null, ScManagerConnect);
      if (manager == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
      IntPtr service = OpenServiceW(manager, name, access);
      if (service == IntPtr.Zero) {
        int error = Marshal.GetLastWin32Error();
        CloseServiceHandle(manager);
        manager = IntPtr.Zero;
        throw new Win32Exception(error);
      }
      return service;
    }

    static IntPtr QueryBuffer(IntPtr service, uint level) {
      uint needed;
      QueryServiceConfig2(service, level, IntPtr.Zero, 0, out needed);
      int error = Marshal.GetLastWin32Error();
      if (needed == 0 || error != 122) throw new Win32Exception(error);
      IntPtr buffer = Marshal.AllocHGlobal((int)needed);
      if (!QueryServiceConfig2(service, level, buffer, needed, out needed)) {
        error = Marshal.GetLastWin32Error();
        Marshal.FreeHGlobal(buffer);
        throw new Win32Exception(error);
      }
      return buffer;
    }

    public static PolicyValue Query(string name) {
      IntPtr manager = IntPtr.Zero;
      IntPtr service = IntPtr.Zero;
      IntPtr actionsBuffer = IntPtr.Zero;
      IntPtr flagBuffer = IntPtr.Zero;
      try {
        service = Open(name, ServiceQueryConfig, out manager);
        actionsBuffer = QueryBuffer(service, ServiceConfigFailureActions);
        FailureActionsNative native = (FailureActionsNative)Marshal.PtrToStructure(actionsBuffer, typeof(FailureActionsNative));
        if (native.ActionCount > 64) throw new InvalidOperationException("Service recovery action count is invalid.");
        ActionValue[] actions = new ActionValue[native.ActionCount];
        int size = Marshal.SizeOf(typeof(ScAction));
        for (int i = 0; i < actions.Length; i++) {
          IntPtr at = new IntPtr(native.Actions.ToInt64() + (long)i * size);
          ScAction action = (ScAction)Marshal.PtrToStructure(at, typeof(ScAction));
          actions[i] = new ActionValue { Type = action.Type, Delay = action.Delay };
        }
        flagBuffer = QueryBuffer(service, ServiceConfigFailureActionsFlag);
        FailureActionsFlagNative flag = (FailureActionsFlagNative)Marshal.PtrToStructure(flagBuffer, typeof(FailureActionsFlagNative));
        return new PolicyValue {
          ResetPeriod = native.ResetPeriod,
          RebootMessage = native.RebootMessage == IntPtr.Zero ? null : Marshal.PtrToStringUni(native.RebootMessage),
          Command = native.Command == IntPtr.Zero ? null : Marshal.PtrToStringUni(native.Command),
          Actions = actions,
          FailureActionsOnNonCrashFailures = flag.Enabled
        };
      } finally {
        if (flagBuffer != IntPtr.Zero) Marshal.FreeHGlobal(flagBuffer);
        if (actionsBuffer != IntPtr.Zero) Marshal.FreeHGlobal(actionsBuffer);
        if (service != IntPtr.Zero) CloseServiceHandle(service);
        if (manager != IntPtr.Zero) CloseServiceHandle(manager);
      }
    }

    public static void Change(string name, PolicyValue policy) {
      if (policy == null || policy.Actions == null || policy.Actions.Length > 64) throw new ArgumentException("Service recovery policy is invalid.");
      IntPtr manager = IntPtr.Zero;
      IntPtr service = IntPtr.Zero;
      IntPtr reboot = IntPtr.Zero;
      IntPtr command = IntPtr.Zero;
      IntPtr actionArray = IntPtr.Zero;
      IntPtr nativeBuffer = IntPtr.Zero;
      IntPtr flagBuffer = IntPtr.Zero;
      try {
        service = Open(name, ServiceChangeConfig, out manager);
        if (policy.RebootMessage != null) reboot = Marshal.StringToHGlobalUni(policy.RebootMessage);
        if (policy.Command != null) command = Marshal.StringToHGlobalUni(policy.Command);
        int actionSize = Marshal.SizeOf(typeof(ScAction));
        if (policy.Actions.Length > 0) {
          actionArray = Marshal.AllocHGlobal(actionSize * policy.Actions.Length);
          for (int i = 0; i < policy.Actions.Length; i++) {
            IntPtr at = new IntPtr(actionArray.ToInt64() + (long)i * actionSize);
            Marshal.StructureToPtr(new ScAction { Type = policy.Actions[i].Type, Delay = policy.Actions[i].Delay }, at, false);
          }
        }
        FailureActionsNative actions = new FailureActionsNative {
          ResetPeriod = policy.ResetPeriod,
          RebootMessage = reboot,
          Command = command,
          ActionCount = (uint)policy.Actions.Length,
          Actions = actionArray
        };
        nativeBuffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(FailureActionsNative)));
        Marshal.StructureToPtr(actions, nativeBuffer, false);
        if (!ChangeServiceConfig2(service, ServiceConfigFailureActions, nativeBuffer)) throw new Win32Exception(Marshal.GetLastWin32Error());

        FailureActionsFlagNative flag = new FailureActionsFlagNative { Enabled = policy.FailureActionsOnNonCrashFailures };
        flagBuffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(FailureActionsFlagNative)));
        Marshal.StructureToPtr(flag, flagBuffer, false);
        if (!ChangeServiceConfig2(service, ServiceConfigFailureActionsFlag, flagBuffer)) throw new Win32Exception(Marshal.GetLastWin32Error());
      } finally {
        if (flagBuffer != IntPtr.Zero) Marshal.FreeHGlobal(flagBuffer);
        if (nativeBuffer != IntPtr.Zero) Marshal.FreeHGlobal(nativeBuffer);
        if (actionArray != IntPtr.Zero) Marshal.FreeHGlobal(actionArray);
        if (command != IntPtr.Zero) Marshal.FreeHGlobal(command);
        if (reboot != IntPtr.Zero) Marshal.FreeHGlobal(reboot);
        if (service != IntPtr.Zero) CloseServiceHandle(service);
        if (manager != IntPtr.Zero) CloseServiceHandle(manager);
      }
    }
  }
}
'@
}

$script:VentioFailurePolicyEntropy = [Text.Encoding]::UTF8.GetBytes('Ventio Host service recovery policy snapshot v1')

function Get-VentioServiceFailurePolicy([string] $ServiceName) {
  return [Ventio.Setup.ServiceRecovery.Native]::Query($ServiceName)
}

function Set-VentioServiceFailurePolicy([string] $ServiceName, [object] $Policy) {
  [Ventio.Setup.ServiceRecovery.Native]::Change($ServiceName, $Policy)
}

function Test-VentioServiceFailurePolicyEqual([object] $Left, [object] $Right) {
  if ($null -eq $Left -or $null -eq $Right -or
      [uint32]$Left.ResetPeriod -ne [uint32]$Right.ResetPeriod -or
      [string]$Left.RebootMessage -cne [string]$Right.RebootMessage -or
      [string]$Left.Command -cne [string]$Right.Command -or
      [bool]$Left.FailureActionsOnNonCrashFailures -ne [bool]$Right.FailureActionsOnNonCrashFailures) { return $false }
  $leftActions = @($Left.Actions)
  $rightActions = @($Right.Actions)
  if ($leftActions.Count -ne $rightActions.Count) { return $false }
  for ($index = 0; $index -lt $leftActions.Count; $index++) {
    if ([int]$leftActions[$index].Type -ne [int]$rightActions[$index].Type -or
        [uint32]$leftActions[$index].Delay -ne [uint32]$rightActions[$index].Delay) { return $false }
  }
  return $true
}

function New-VentioServicePolicyObject([object] $Source, [switch] $DisableActions) {
  $actions = if ($DisableActions) { @() } else {
    @($Source.Actions | ForEach-Object { [Ventio.Setup.ServiceRecovery.ActionValue]::new([int]$_.Type, [uint32]$_.Delay) })
  }
  return [Ventio.Setup.ServiceRecovery.PolicyValue]::new(
    [uint32]$Source.ResetPeriod,
    [string]$Source.RebootMessage,
    [string]$Source.Command,
    [Ventio.Setup.ServiceRecovery.ActionValue[]]$actions,
    $(if ($DisableActions) { $false } else { [bool]$Source.FailureActionsOnNonCrashFailures })
  )
}

function Get-VentioRecoveryPolicyStatePath([string] $StateDirectory, [string] $ServiceName, [switch] $TestMode) {
  if ($ServiceName -notmatch '^[A-Za-z0-9_-]{1,80}$') { throw 'HOST_SERVICE_RECOVERY_SERVICE_NAME_INVALID' }
  if ($TestMode) {
    $full = [IO.Path]::GetFullPath($StateDirectory)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ventio-service-policy-test-'
    if (-not $full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'HOST_SERVICE_RECOVERY_TEST_PATH_INVALID' }
  } else {
    $expected = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\Installer'
    if (-not [IO.Path]::GetFullPath($StateDirectory).Equals([IO.Path]::GetFullPath($expected), [StringComparison]::OrdinalIgnoreCase)) {
      throw 'HOST_SERVICE_RECOVERY_STATE_PATH_INVALID'
    }
  }
  return Join-Path $StateDirectory (('host-service-recovery-policy.' + $ServiceName + '.v1.dpapi'))
}

function Set-VentioRecoveryStateAcl([string] $Path, [switch] $Directory, [switch] $TestMode) {
  $security = if ($Directory) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
  $security.SetAccessRuleProtection($true, $false)
  if ($TestMode) {
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $allowed = @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
  } else {
    $owner = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $allowed = @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
  }
  $security.SetOwner($owner)
  foreach ($sid in $allowed) {
    $inheritance = if ($Directory) {
      [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else { [Security.AccessControl.InheritanceFlags]::None }
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      $sid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
      [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
  }
  Set-Acl -LiteralPath $Path -AclObject $security -ErrorAction Stop
}

function Assert-VentioRecoveryStateAcl([string] $Path, [switch] $Directory, [switch] $TestMode) {
  $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
  if (-not $acl.AreAccessRulesProtected) { throw 'HOST_SERVICE_RECOVERY_STATE_ACL_INVALID' }
  $allowed = @{}
  if ($TestMode) {
    $allowed[[Security.Principal.WindowsIdentity]::GetCurrent().User.Value] = $true
  } else {
    $allowed['S-1-5-32-544'] = $true
  }
  $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
  $allowed[$ownerSid] = $true
  $allowed['S-1-5-18'] = $true
  $rules = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
  if ($rules.Count -ne $allowed.Count) { throw 'HOST_SERVICE_RECOVERY_STATE_ACL_INVALID' }
  foreach ($rule in $rules) {
    if (-not $allowed.ContainsKey($rule.IdentityReference.Value) -or
        $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl) {
      throw 'HOST_SERVICE_RECOVERY_STATE_ACL_INVALID'
    }
  }
}

function Get-VentioServiceIdentity([string] $ServiceName) {
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
  if ($null -eq $service) { throw 'HOST_SERVICE_RECOVERY_IDENTITY_INVALID' }
  return [pscustomobject]@{ Name = [string]$service.Name; StartName = [string]$service.StartName; PathName = [string]$service.PathName }
}

function Read-VentioRecoveryJournal([string] $Path, [switch] $TestMode) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  Assert-VentioRecoveryStateAcl $Path -TestMode:$TestMode
  $protectedBytes = [IO.File]::ReadAllBytes($Path)
  $clearBytes = $null
  try {
    $clearBytes = [Security.Cryptography.ProtectedData]::Unprotect(
      $protectedBytes, $script:VentioFailurePolicyEntropy, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    $json = [Text.Encoding]::UTF8.GetString($clearBytes)
    $journal = $json | ConvertFrom-Json
    if ($journal.formatVersion -ne 1 -or [string]$journal.serviceName -notmatch '^[A-Za-z0-9_-]{1,80}$' -or
        [string]$journal.operationId -notmatch '^[0-9a-f]{32}$' -or
        [string]::IsNullOrWhiteSpace([string]$journal.serviceStartName) -or
        -not $journal.originalPolicy) { throw 'HOST_SERVICE_RECOVERY_STATE_INVALID' }
    return $journal
  } catch {
    if ($_.Exception.Message -match '^HOST_SERVICE_RECOVERY_[A-Z0-9_]+$') { throw }
    throw 'HOST_SERVICE_RECOVERY_STATE_INVALID'
  } finally {
    [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
    if ($clearBytes) { [Array]::Clear($clearBytes, 0, $clearBytes.Length) }
  }
}

function Write-VentioRecoveryJournal([string] $Path, [object] $Journal, [switch] $TestMode) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($directory)
    Set-VentioRecoveryStateAcl $directory -Directory -TestMode:$TestMode
  } else {
    Assert-VentioRecoveryStateAcl $directory -Directory -TestMode:$TestMode
  }
  $clearBytes = [Text.UTF8Encoding]::new($false).GetBytes(($Journal | ConvertTo-Json -Depth 8 -Compress))
  $protectedBytes = $null
  $tempPath = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  try {
    $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
      $clearBytes, $script:VentioFailurePolicyEntropy, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    [IO.File]::WriteAllBytes($tempPath, $protectedBytes)
    Set-VentioRecoveryStateAcl $tempPath -TestMode:$TestMode
    [IO.File]::Move($tempPath, $Path)
  } finally {
    [Array]::Clear($clearBytes, 0, $clearBytes.Length)
    if ($protectedBytes) { [Array]::Clear($protectedBytes, 0, $protectedBytes.Length) }
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
  }
}

function Convert-VentioJournalPolicy([object] $Journal) {
  $policy = $Journal.originalPolicy
  $actions = @($policy.Actions | ForEach-Object {
    [Ventio.Setup.ServiceRecovery.ActionValue]::new([int]$_.Type, [uint32]$_.Delay)
  })
  return [Ventio.Setup.ServiceRecovery.PolicyValue]::new(
    [uint32]$policy.ResetPeriod,
    $(if ($null -eq $policy.RebootMessage) { $null } else { [string]$policy.RebootMessage }),
    $(if ($null -eq $policy.Command) { $null } else { [string]$policy.Command }),
    [Ventio.Setup.ServiceRecovery.ActionValue[]]$actions,
    [bool]$policy.FailureActionsOnNonCrashFailures
  )
}

function Assert-VentioJournalIdentity([object] $Journal, [object] $Identity) {
  if ([string]$Journal.serviceName -cne [string]$Identity.Name -or
      [string]$Journal.serviceStartName -cne [string]$Identity.StartName -or
      [string]$Journal.servicePathName -cne [string]$Identity.PathName) {
    throw 'HOST_SERVICE_RECOVERY_IDENTITY_CONFLICT'
  }
}

function Wait-VentioServiceStoppedStable(
  [string] $ServiceName,
  [int] $QuietSeconds,
  [int] $TimeoutSeconds,
  [scriptblock] $StatusProvider,
  [scriptblock] $StopProvider
) {
  if ($null -eq $StatusProvider) { $StatusProvider = { param($name) (Get-Service -Name $name -ErrorAction Stop).Status.ToString() } }
  if ($null -eq $StopProvider) { $StopProvider = { param($name) Stop-Service -Name $name -Force -ErrorAction Stop } }
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $stableUntil = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    $serviceState = [string](& $StatusProvider $ServiceName)
    if ($serviceState -eq 'Running') {
      & $StopProvider $ServiceName
      $stableUntil = $null
    } elseif ($serviceState -eq 'StartPending' -or $serviceState -eq 'StopPending' -or
        $serviceState -eq 'PausePending' -or $serviceState -eq 'ContinuePending') {
      $stableUntil = $null
    } elseif ($serviceState -eq 'Stopped') {
      if ($null -eq $stableUntil) { $stableUntil = [DateTime]::UtcNow.AddSeconds($QuietSeconds) }
      if ([DateTime]::UtcNow -ge $stableUntil) { return }
    } else {
      throw 'HOST_SERVICE_RECOVERY_UNEXPECTED_SERVICE_STATE'
    }
    Start-Sleep -Milliseconds 250
  }
  throw 'HOST_SERVICE_RECOVERY_DRAIN_TIMEOUT'
}

function Get-VentioHostRecoveryPolicyState(
  [string] $StateDirectory = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\Installer'),
  [switch] $TestMode,
  [string] $ServiceName = 'VentioHost'
) {
  $path = Get-VentioRecoveryPolicyStatePath $StateDirectory $ServiceName -TestMode:$TestMode
  return [pscustomobject]@{ Path = $path; Directory = $StateDirectory }
}

function Start-VentioHostServiceMaintenance(
  [object] $ValidatedIdentity,
  [string] $StateDirectory = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\Installer'),
  [switch] $TestMode,
  [string] $ServiceName = 'VentioHost',
  [string] $ExpectedStartName = 'NT SERVICE\VentioHost'
) {
  if ([string]$ValidatedIdentity.Name -cne $ServiceName -or [string]$ValidatedIdentity.StartName -cne $ExpectedStartName) {
    throw 'HOST_SERVICE_RECOVERY_IDENTITY_INVALID'
  }
  $state = Get-VentioHostRecoveryPolicyState $StateDirectory -TestMode:$TestMode -ServiceName $ServiceName
  $journal = Read-VentioRecoveryJournal $state.Path -TestMode:$TestMode
  if ($null -eq $journal) {
    $original = Get-VentioServiceFailurePolicy $ServiceName
    foreach ($action in @($original.Actions)) {
      if ([int]$action.Type -notin @(0, 1)) { throw 'HOST_SERVICE_RECOVERY_POLICY_UNSUPPORTED_ACTION' }
    }
    $maxDelay = 0L
    foreach ($action in @($original.Actions)) {
      if ([int]$action.Type -eq 1) { $maxDelay = [Math]::Max($maxDelay, [long]$action.Delay) }
    }
    if ($maxDelay -gt 300000) { throw 'HOST_SERVICE_RECOVERY_POLICY_DELAY_UNSUPPORTED' }
    $journal = [pscustomobject]@{
      formatVersion = 1
      operationId = [guid]::NewGuid().ToString('N')
      serviceName = $ServiceName
      serviceStartName = [string]$ValidatedIdentity.StartName
      servicePathName = [string]$ValidatedIdentity.PathName
      createdAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
      originalPolicy = $original
    }
    Write-VentioRecoveryJournal $state.Path $journal -TestMode:$TestMode
  } else {
    Assert-VentioJournalIdentity $journal $ValidatedIdentity
    $original = Convert-VentioJournalPolicy $journal
    $maxDelay = 0L
    foreach ($action in @($original.Actions)) {
      if ([int]$action.Type -notin @(0, 1)) { throw 'HOST_SERVICE_RECOVERY_POLICY_UNSUPPORTED_ACTION' }
      if ([int]$action.Type -eq 1) { $maxDelay = [Math]::Max($maxDelay, [long]$action.Delay) }
    }
    if ($maxDelay -gt 300000) { throw 'HOST_SERVICE_RECOVERY_POLICY_DELAY_UNSUPPORTED' }
    $current = Get-VentioServiceFailurePolicy $ServiceName
    $disabled = New-VentioServicePolicyObject $original -DisableActions
    if (-not (Test-VentioServiceFailurePolicyEqual $current $disabled) -and
        -not (Test-VentioServiceFailurePolicyEqual $current $original)) {
      throw 'HOST_SERVICE_RECOVERY_POLICY_CONFLICT'
    }
  }

  $current = Get-VentioServiceFailurePolicy $ServiceName
  $disabled = New-VentioServicePolicyObject $original -DisableActions
  if (-not (Test-VentioServiceFailurePolicyEqual $current $disabled)) {
    try {
      Set-VentioServiceFailurePolicy $ServiceName $disabled
    } catch {
      throw 'HOST_SERVICE_RECOVERY_POLICY_SUPPRESS_FAILED'
    }
  }
  $verified = Get-VentioServiceFailurePolicy $ServiceName
  if (-not (Test-VentioServiceFailurePolicyEqual $verified $disabled)) { throw 'HOST_SERVICE_RECOVERY_POLICY_SUPPRESS_VERIFICATION_FAILED' }

  $quietSeconds = [Math]::Max(2, [Math]::Ceiling($maxDelay / 1000.0) + 3)
  $timeoutSeconds = [Math]::Min(1200, [Math]::Max(30, ($quietSeconds + 2) * 4))
  Wait-VentioServiceStoppedStable $ServiceName $quietSeconds $timeoutSeconds $null $null
  [pscustomobject]@{ OperationId = [string]$journal.operationId; QuietSeconds = $quietSeconds; StatePath = $state.Path }
}

function Assert-VentioHostServiceMaintenance(
  [object] $ValidatedIdentity,
  [string] $ExpectedStatus = 'Stopped',
  [string] $StateDirectory = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\Installer'),
  [switch] $TestMode,
  [string] $ServiceName = 'VentioHost'
) {
  $state = Get-VentioHostRecoveryPolicyState $StateDirectory -TestMode:$TestMode -ServiceName $ServiceName
  $journal = Read-VentioRecoveryJournal $state.Path -TestMode:$TestMode
  if ($null -eq $journal) { throw 'HOST_SERVICE_RECOVERY_MAINTENANCE_NOT_ACTIVE' }
  Assert-VentioJournalIdentity $journal $ValidatedIdentity
  $expected = New-VentioServicePolicyObject (Convert-VentioJournalPolicy $journal) -DisableActions
  $current = Get-VentioServiceFailurePolicy $ServiceName
  if (-not (Test-VentioServiceFailurePolicyEqual $current $expected)) { throw 'HOST_SERVICE_RECOVERY_POLICY_CONFLICT' }
  if ((Get-Service -Name $ServiceName -ErrorAction Stop).Status.ToString() -cne $ExpectedStatus) {
    throw 'HOST_DATABASE_UPGRADE_HOST_SERVICE_MUST_BE_STOPPED'
  }
}

function Restore-VentioHostServiceFailureActions(
  [object] $ValidatedIdentity,
  [string] $StateDirectory = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'Ventio\Installer'),
  [switch] $TestMode,
  [string] $ServiceName = 'VentioHost'
) {
  $state = Get-VentioHostRecoveryPolicyState $StateDirectory -TestMode:$TestMode -ServiceName $ServiceName
  $journal = Read-VentioRecoveryJournal $state.Path -TestMode:$TestMode
  if ($null -eq $journal) { return }
  Assert-VentioJournalIdentity $journal $ValidatedIdentity
  $original = Convert-VentioJournalPolicy $journal
  $disabled = New-VentioServicePolicyObject $original -DisableActions
  $current = Get-VentioServiceFailurePolicy $ServiceName
  if (Test-VentioServiceFailurePolicyEqual $current $disabled) {
    try { Set-VentioServiceFailurePolicy $ServiceName $original }
    catch { throw 'HOST_SERVICE_RECOVERY_POLICY_RESTORE_FAILED' }
  } elseif (-not (Test-VentioServiceFailurePolicyEqual $current $original)) {
    throw 'HOST_SERVICE_RECOVERY_POLICY_CONFLICT'
  }
  $verified = Get-VentioServiceFailurePolicy $ServiceName
  if (-not (Test-VentioServiceFailurePolicyEqual $verified $original)) { throw 'HOST_SERVICE_RECOVERY_POLICY_RESTORE_VERIFICATION_FAILED' }
  Remove-Item -LiteralPath $state.Path -Force -ErrorAction Stop
  if (Test-Path -LiteralPath $state.Path) { throw 'HOST_SERVICE_RECOVERY_POLICY_STATE_CLEANUP_FAILED' }
}

Export-ModuleMember -Function Get-VentioServiceFailurePolicy, Set-VentioServiceFailurePolicy,
  Test-VentioServiceFailurePolicyEqual, Get-VentioHostRecoveryPolicyState,
  Start-VentioHostServiceMaintenance, Assert-VentioHostServiceMaintenance,
  Restore-VentioHostServiceFailureActions, Wait-VentioServiceStoppedStable
