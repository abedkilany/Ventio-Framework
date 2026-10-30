using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

internal static class Program
{
    private const string ServiceName = "VentioHost";
    private const int ServiceWin32OwnProcess = 0x00000010;
    private const int ServiceStartPending = 2;
    private const int ServiceRunning = 4;
    private const int ServiceStopPending = 3;
    private const int ServiceStopped = 1;
    private const int ServiceAcceptStop = 1;
    private const int ServiceAcceptShutdown = 4;
    private const int ControlStop = 1;
    private const int ControlShutdown = 5;
    private const int DpapiLocalMachine = 4;
    private const uint MaximumConfigBytes = 64 * 1024;

    private static readonly string ConfigPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "Ventio", "Host", "service-config.dpapi");

    private static readonly ManualResetEventSlim StopRequested = new(false);
    private static readonly object Sync = new();
    private static readonly ServiceMainCallback ServiceMainThunk = ServiceMain;
    private static readonly HandlerCallback HandlerThunk = HandleControl;
    private static IntPtr _statusHandle;
    private static Process? _hostProcess;
    private static ServiceStatus _status;
    private static int _serviceExitCode;

    private static int Main()
    {
        var table = new[]
        {
            new ServiceTableEntry { ServiceName = ServiceName, ServiceMain = ServiceMainThunk },
            new ServiceTableEntry { ServiceName = null, ServiceMain = null },
        };
        if (!StartServiceCtrlDispatcher(table))
        {
            // SCM error details can include machine state. Keep console output generic.
            var error = Marshal.GetLastWin32Error();
            Console.Error.WriteLine($"Ventio Host service must be started by Windows Service Control Manager (Win32 {error}).");
            return error == 1063 ? 2 : 3;
        }
        return _serviceExitCode;
    }

    private static void ServiceMain(int argc, IntPtr argv)
    {
        _statusHandle = RegisterServiceCtrlHandlerEx(ServiceName, HandlerThunk, IntPtr.Zero);
        if (_statusHandle == IntPtr.Zero)
        {
            _serviceExitCode = 3;
            return;
        }

        SetStatus(ServiceStartPending, checkpoint: 1, waitHintMs: 15000);
        try
        {
            var environment = ReadAndValidateConfiguration(ConfigPath);
            var hostExecutable = Path.Combine(AppContext.BaseDirectory, "ventio_host.exe");
            if (!File.Exists(hostExecutable))
            {
                throw new InvalidOperationException("Host payload executable is missing.");
            }

            var start = new ProcessStartInfo
            {
                FileName = hostExecutable,
                WorkingDirectory = AppContext.BaseDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            start.Environment.Clear();
            CopyRequiredSystemEnvironment(start.Environment);
            start.Environment["PATH"] = Path.Combine(AppContext.BaseDirectory, "postgresql", "bin");
            start.Environment["VENTIO_ENABLE_LOCAL_HOST"] = "yes";
            foreach (var pair in environment) start.Environment[pair.Key] = pair.Value;

            var process = new Process { StartInfo = start, EnableRaisingEvents = true };
            process.OutputDataReceived += (_, _) => { }; // Deliberately discard process output; never persist secrets.
            process.ErrorDataReceived += (_, _) => { };
            lock (Sync)
            {
                if (StopRequested.IsSet) throw new InvalidOperationException("Host service start was cancelled.");
                if (!process.Start()) throw new InvalidOperationException("Host process could not start.");
                _hostProcess = process;
            }
            environment.Clear();
            start.Environment.Clear();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            lock (Sync)
            {
                if (!StopRequested.IsSet)
                    SetStatus(ServiceRunning, checkpoint: 0, waitHintMs: 0,
                        controlsAccepted: ServiceAcceptStop | ServiceAcceptShutdown);
            }

            process.WaitForExit();
            _serviceExitCode = StopRequested.IsSet ? 0 : (process.ExitCode == 0 ? 2 : process.ExitCode);
        }
        catch
        {
            // Do not write exceptions: they may contain database URLs or local paths.
            _serviceExitCode = 2;
        }
        finally
        {
            lock (Sync)
            {
                if (_hostProcess is { HasExited: false } process)
                {
                    try { process.Kill(entireProcessTree: true); } catch { }
                }
                _hostProcess?.Dispose();
                _hostProcess = null;
            }
            SetStatus(ServiceStopped, checkpoint: 0, waitHintMs: 0, win32ExitCode: _serviceExitCode);
        }
    }

    private static int HandleControl(int control, int eventType, IntPtr eventData, IntPtr context)
    {
        if (control is not (ControlStop or ControlShutdown)) return 0;
        StopRequested.Set();
        lock (Sync) SetStatus(ServiceStopPending, checkpoint: 1, waitHintMs: 20000);
        _ = Task.Run(() =>
        {
            try
            {
                lock (Sync)
                {
                    if (_hostProcess is { HasExited: false } process)
                    {
                        // Host has no Windows service-control endpoint yet. Termination closes
                        // connections; PostgreSQL rolls back incomplete transactions on exit.
                        process.Kill(entireProcessTree: true);
                    }
                }
            }
            catch { _serviceExitCode = 2; }
        });
        return 0;
    }

    private static Dictionary<string, string> ReadAndValidateConfiguration(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length is <= 0 or > MaximumConfigBytes)
            throw new InvalidOperationException("Protected Host configuration is missing or invalid.");
        ValidatePrivateConfigurationAcl(info);

        var encrypted = File.ReadAllBytes(path);
        try
        {
            var plaintext = UnprotectMachineData(encrypted);
            try
            {
                var text = new UTF8Encoding(false, true).GetString(plaintext);
                var allowed = new HashSet<string>(StringComparer.Ordinal)
                {
                    "VENTIO_HOST_DATABASE_URL",
                    "VENTIO_HOST_IDENTITY_API_DATABASE_URL",
                    "VENTIO_RECOVERY_AUTHORITY_FILE",
                    "VENTIO_RECOVERY_AUTHORITY_HOST_WRITES",
                    "VENTIO_RECOVERY_AUTHORITY_OWNER_SID",
                    "VENTIO_RECOVERY_AUTHORITY_READER_SID",
                    "VENTIO_HOST_DIAGNOSTICS_FILE",
                    "VENTIO_HOST_BIND_ADDRESS",
                    "VENTIO_HOST_PORT",
                    "VENTIO_HOST_TLS_CERTIFICATE_FILE",
                    "VENTIO_HOST_TLS_PRIVATE_KEY_FILE",
                };
                var values = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
                {
                    var valueLine = line.TrimEnd('\r');
                    var separator = valueLine.IndexOf('=');
                    if (separator <= 0) throw new InvalidOperationException("Protected Host configuration is malformed.");
                    var key = valueLine[..separator];
                    var value = valueLine[(separator + 1)..];
                    if (!allowed.Contains(key) || value.Contains('\r') || value.Contains('\n') || !values.TryAdd(key, value))
                        throw new InvalidOperationException("Protected Host configuration contains an unsupported setting.");
                }

                Require(values, "VENTIO_HOST_DATABASE_URL");
                Require(values, "VENTIO_HOST_IDENTITY_API_DATABASE_URL");
                Require(values, "VENTIO_RECOVERY_AUTHORITY_FILE");
                Require(values, "VENTIO_RECOVERY_AUTHORITY_OWNER_SID");
                Require(values, "VENTIO_RECOVERY_AUTHORITY_READER_SID");
                Require(values, "VENTIO_HOST_DIAGNOSTICS_FILE");
                values["VENTIO_RECOVERY_AUTHORITY_HOST_WRITES"] = Require(values, "VENTIO_RECOVERY_AUTHORITY_HOST_WRITES");
                if (values["VENTIO_RECOVERY_AUTHORITY_HOST_WRITES"] != "yes")
                    throw new InvalidOperationException("Invalid Host write-authority setting.");
                if (!values.TryGetValue("VENTIO_HOST_BIND_ADDRESS", out var address) || string.IsNullOrWhiteSpace(address))
                    values["VENTIO_HOST_BIND_ADDRESS"] = "127.0.0.1";
                if (!values.TryGetValue("VENTIO_HOST_PORT", out var port))
                    values["VENTIO_HOST_PORT"] = "8080";
                else if (!int.TryParse(port, out var portNumber) || portNumber is < 1 or > 65535)
                    throw new InvalidOperationException("Host listener port is invalid.");
                if (values.ContainsKey("VENTIO_HOST_TLS_PRIVATE_KEY_FILE") != values.ContainsKey("VENTIO_HOST_TLS_CERTIFICATE_FILE"))
                    throw new InvalidOperationException("Both TLS certificate and private key are required together.");
                foreach (var tlsPath in new[] { "VENTIO_HOST_TLS_PRIVATE_KEY_FILE", "VENTIO_HOST_TLS_CERTIFICATE_FILE" })
                {
                    if (values.TryGetValue(tlsPath, out var configuredPath) && !Path.IsPathFullyQualified(configuredPath))
                        throw new InvalidOperationException("TLS paths must be absolute.");
                }
                if (values["VENTIO_HOST_BIND_ADDRESS"] != "127.0.0.1" &&
                    (!values.ContainsKey("VENTIO_HOST_TLS_PRIVATE_KEY_FILE") || !values.ContainsKey("VENTIO_HOST_TLS_CERTIFICATE_FILE")))
                    throw new InvalidOperationException("External Host listeners require TLS.");

                ValidateSid(values["VENTIO_RECOVERY_AUTHORITY_OWNER_SID"]);
                ValidateSid(values["VENTIO_RECOVERY_AUTHORITY_READER_SID"]);
                return values;
            }
            finally { CryptographicOperations.ZeroMemory(plaintext); }
        }
        finally { CryptographicOperations.ZeroMemory(encrypted); }
    }

    private static string Require(Dictionary<string, string> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || string.IsNullOrWhiteSpace(value))
            throw new InvalidOperationException("Required Host configuration setting is missing.");
        return value;
    }

    private static void ValidateSid(string sid)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(sid, @"^S-1-\d+(?:-\d+)+$", System.Text.RegularExpressions.RegexOptions.CultureInvariant))
            throw new InvalidOperationException("Recovery Authority Windows SID is invalid.");
    }

    private static byte[] UnprotectMachineData(byte[] encrypted)
    {
        var inputPointer = Marshal.AllocHGlobal(encrypted.Length);
        try
        {
            Marshal.Copy(encrypted, 0, inputPointer, encrypted.Length);
            var input = new DataBlob { Size = encrypted.Length, Data = inputPointer };
            if (!CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    DpapiLocalMachine, out var output))
                throw new InvalidOperationException("Protected Host configuration could not be opened.");
            try
            {
                var plaintext = new byte[output.Size];
                Marshal.Copy(output.Data, plaintext, 0, output.Size);
                return plaintext;
            }
            finally
            {
                var zeroes = new byte[output.Size];
                Marshal.Copy(zeroes, 0, output.Data, zeroes.Length);
                CryptographicOperations.ZeroMemory(zeroes);
                LocalFree(output.Data);
            }
        }
        finally { Marshal.FreeHGlobal(inputPointer); }
    }

    private static void ValidatePrivateConfigurationAcl(FileInfo file)
    {
        if ((file.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException("Protected Host configuration path is invalid.");
        var directory = file.Directory ?? throw new InvalidOperationException("Protected Host configuration directory is missing.");
        if ((directory.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException("Protected Host configuration directory is invalid.");

        var serviceSid = WindowsIdentity.GetCurrent().User?.Value
            ?? throw new InvalidOperationException("Host service identity is unavailable.");
        var permitted = new HashSet<string>(StringComparer.Ordinal)
        {
            serviceSid, "S-1-5-18", "S-1-5-32-544", // service SID, SYSTEM, Administrators
        };
        FileSystemSecurity[] securityDescriptors =
        [directory.GetAccessControl(AccessControlSections.Access), file.GetAccessControl(AccessControlSections.Access)];
        foreach (var security in securityDescriptors)
        {
            var rules = security.GetAccessRules(includeExplicit: true, includeInherited: true, targetType: typeof(SecurityIdentifier));
            foreach (FileSystemAccessRule rule in rules)
            {
                if (rule.AccessControlType == AccessControlType.Allow &&
                    rule.FileSystemRights != 0 &&
                    (rule.IdentityReference as SecurityIdentifier)?.Value is { } sid &&
                    !permitted.Contains(sid))
                    throw new InvalidOperationException("Protected Host configuration ACL grants access to an unsupported identity.");
            }
        }
    }

    private static void CopyRequiredSystemEnvironment(IDictionary<string, string?> environment)
    {
        foreach (var name in new[] { "SystemRoot", "WINDIR", "SystemDrive", "TEMP", "TMP", "USERPROFILE" })
        {
            var value = Environment.GetEnvironmentVariable(name);
            if (!string.IsNullOrWhiteSpace(value)) environment[name] = value;
        }
    }

    private static void SetStatus(int state, int checkpoint, int waitHintMs,
        int controlsAccepted = 0, int win32ExitCode = 0)
    {
        if (_statusHandle == IntPtr.Zero) return;
        _status = new ServiceStatus
        {
            ServiceType = ServiceWin32OwnProcess,
            CurrentState = state,
            ControlsAccepted = controlsAccepted,
            Win32ExitCode = win32ExitCode,
            ServiceSpecificExitCode = 0,
            CheckPoint = checkpoint,
            WaitHint = waitHintMs,
        };
        _ = SetServiceStatus(_statusHandle, ref _status);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ServiceTableEntry
    {
        [MarshalAs(UnmanagedType.LPWStr)] public string? ServiceName;
        public ServiceMainCallback? ServiceMain;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatus
    {
        public int ServiceType;
        public int CurrentState;
        public int ControlsAccepted;
        public int Win32ExitCode;
        public int ServiceSpecificExitCode;
        public int CheckPoint;
        public int WaitHint;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void ServiceMainCallback(int argc, IntPtr argv);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int HandlerCallback(int control, int eventType, IntPtr eventData, IntPtr context);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool StartServiceCtrlDispatcher([In] ServiceTableEntry[] serviceTable);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr RegisterServiceCtrlHandlerEx(string serviceName, HandlerCallback callback, IntPtr context);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetServiceStatus(IntPtr serviceStatusHandle, ref ServiceStatus serviceStatus);
    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, IntPtr description, IntPtr optionalEntropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);
}
