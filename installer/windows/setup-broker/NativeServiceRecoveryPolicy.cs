// Native SCM interop ported from the existing reviewed recovery-policy module.
// Kept byte-equivalent below during migration to preserve Query/Change semantics.
#nullable disable
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
    const uint ServiceStart = 0x0010;
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
        // SCM requires SERVICE_START on the service handle when the supplied
        // failure actions contain SC_ACTION_RESTART.  Suppression uses an
        // empty action list and therefore needs only SERVICE_CHANGE_CONFIG.
        uint access = ServiceChangeConfig;
        for (int i = 0; i < policy.Actions.Length; i++) {
          if (policy.Actions[i] != null && policy.Actions[i].Type == 1) {
            access |= ServiceStart;
            break;
          }
        }
        service = Open(name, access, out manager);
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
        if (!ChangeServiceConfig2(service, ServiceConfigFailureActions, nativeBuffer))
          throw new Win32Exception(Marshal.GetLastWin32Error(), "SERVICE_CONFIG_FAILURE_ACTIONS update failed");

        FailureActionsFlagNative flag = new FailureActionsFlagNative { Enabled = policy.FailureActionsOnNonCrashFailures };
        flagBuffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(FailureActionsFlagNative)));
        Marshal.StructureToPtr(flag, flagBuffer, false);
        if (!ChangeServiceConfig2(service, ServiceConfigFailureActionsFlag, flagBuffer))
          throw new Win32Exception(Marshal.GetLastWin32Error(), "SERVICE_CONFIG_FAILURE_ACTIONS_FLAG update failed");
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
