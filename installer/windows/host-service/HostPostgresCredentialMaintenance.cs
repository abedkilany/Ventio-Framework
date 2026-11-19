using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

// The administrator coordinates the stopped-cluster backup. Only a child using
// the *existing PostgreSQL service token* opens the cluster for single-user SQL.
// There is no password logon, ACL change, HBA relaxation, or arbitrary SQL route.
internal sealed record PostgresMaintenanceTarget(string ServiceName, string PostgresRoot, string DataDirectory)
{
    internal static PostgresMaintenanceTarget Installed => new("VentioPostgres",
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Ventio", "host-payload", "postgresql"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Ventio", "PostgreSQL", "data"));
    internal string ServiceSid => new NTAccount("NT SERVICE", ServiceName).Translate(typeof(SecurityIdentifier)).Value;
    internal string Postgres => Path.Combine(PostgresRoot, "bin", "postgres.exe");
    internal string PgCtl => Path.Combine(PostgresRoot, "bin", "pg_ctl.exe");
}

internal static class HostPostgresCredentialMaintenance
{
    internal const string Ready = "HOST_POSTGRES_MAINTENANCE_READY";
    internal const string Complete = "HOST_POSTGRES_MAINTENANCE_PASS";
    private const int MaximumRequestChars = 1024;
    // Covers the admitted 120s service stop and 900s copy, plus inventory and
    // manifest work. A stale coordinator/token lease still expires fail-closed.
    private static readonly TimeSpan BackupDeadline = TimeSpan.FromMinutes(30);
    private static readonly TimeSpan RotationDeadline = TimeSpan.FromSeconds(30);
    private static readonly object ServiceTokenInspectionLock = new();

    internal static int Coordinate(PostgresMaintenanceTarget target, string[] workerArguments)
    {
        Process? worker = null;
        try
        {
            RequireAdministrator();
            ValidateTarget(target);
            using var service = OpenValidatedService(target, running: true);
            var before = ReadStatus(service);
            var servicePid = checked((int)before.ProcessId);
            if (!SamePath(ProcessImage(servicePid), target.PgCtl)) throw Failure("SERVICE_PROCESS");
            using (var primary = OpenServiceToken(servicePid))
            {
                using var identity = new WindowsIdentity(primary.DangerousGetHandle());
                if (identity.User?.Value != target.ServiceSid ||
                    new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
                    throw Failure("SERVICE_TOKEN_IDENTITY");
                var after = ReadStatus(service);
                if (after.CurrentState != 4 || after.ProcessId != before.ProcessId) throw Failure("SERVICE_PROCESS_CHANGED");
                var pipeName = "Ventio.PostgresMaintenance." + Guid.NewGuid().ToString("N");
                using var pipe = CreatePipe(pipeName, target.ServiceSid);
                worker = StartWorker(primary, workerArguments.Concat(new[] { pipeName, Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture) }).ToArray());
                using var connectionDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                pipe.WaitForConnectionAsync(connectionDeadline.Token).GetAwaiter().GetResult();
                if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var clientPid) || clientPid != worker.Id)
                    throw Failure("WORKER_PIPE_IDENTITY");
                using var reader = new StreamReader(pipe, new UTF8Encoding(false, true), false, 1024, leaveOpen: true);
                using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, leaveOpen: true) { AutoFlush = true };
                if (ReadLine(reader, TimeSpan.FromSeconds(15)) != Ready) throw Failure("WORKER_READINESS");
                Console.Out.WriteLine(Ready);
                Console.Out.Flush();
                using var input = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false, true), false, 1024, leaveOpen: true);
                var request = ReadLine(input, BackupDeadline);
                ValidateRequest(request);
                using var stopped = OpenValidatedService(target, running: false);
                writer.WriteLine(request);
                request = null;
                var result = ReadLine(reader, TimeSpan.FromSeconds(45));
                if (result != Complete) throw Failure("ROTATION_FAILED");
                if (!worker.WaitForExit(10000) || worker.ExitCode != 0) throw Failure("WORKER_EXIT");
                Console.Out.WriteLine(Complete);
                return 0;
            }
        }
        catch (Exception exception)
        {
            // Never report PostgreSQL output or the request: SQL errors can echo
            // the ALTER ROLE password. Diagnostics are fixed codes only.
            Console.Error.WriteLine(SafeCode(exception));
            return 3;
        }
        finally
        {
            if (worker is not null)
            {
                try { if (!worker.HasExited) { worker.Kill(entireProcessTree: true); worker.WaitForExit(10000); } } catch { }
                worker.Dispose();
            }
        }
    }

    internal static int Work(PostgresMaintenanceTarget target, string pipeName, int parentPid)
    {
        try
        {
            ValidateTarget(target);
            if (!Regex.IsMatch(pipeName, "\\AVentio\\.PostgresMaintenance\\.[0-9a-f]{32}\\z", RegexOptions.CultureInvariant))
                throw Failure("PIPE_NAME");
            using var identity = WindowsIdentity.GetCurrent();
            if (identity.User?.Value != target.ServiceSid || new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
                throw Failure("WORKER_IDENTITY");
            using var pipe = new NamedPipeClientStream(".", pipeName, PipeAccessRights.ReadWrite, PipeOptions.Asynchronous,
                TokenImpersonationLevel.Identification, HandleInheritability.None);
            pipe.Connect(15000);
            if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var serverPid) || serverPid != parentPid)
                throw Failure("PARENT_PIPE_IDENTITY");
            using var parent = Process.GetProcessById(parentPid);
            if (!SamePath(ProcessImage(parent.Id), Environment.ProcessPath!)) throw Failure("PARENT_EXECUTABLE");
            using var reader = new StreamReader(pipe, new UTF8Encoding(false, true), false, 1024, leaveOpen: true);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, leaveOpen: true) { AutoFlush = true };
            writer.WriteLine(Ready);
            var request = ReadLine(reader, BackupDeadline);
            var secrets = ValidateRequest(request);
            request = null;
            using var service = OpenValidatedService(target, running: false);
            if (File.Exists(Path.Combine(target.DataDirectory, "postmaster.pid"))) throw Failure("CLUSTER_NOT_STOPPED");
            var info = new ProcessStartInfo(target.Postgres) { UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                WorkingDirectory = Path.Combine(target.PostgresRoot, "bin") };
            foreach (var argument in new[] { "--single", "-D", target.DataDirectory, "-j", "postgres" }) info.ArgumentList.Add(argument);
            // Supply a bounded environment rather than inheriting administrative
            // configuration, PGPASSWORD, PGOPTIONS, or DLL search-path overrides.
            info.Environment.Clear();
            info.Environment["SystemRoot"] = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            using var postgres = Process.Start(info) ?? throw Failure("POSTGRES_START");
            try
            {
                var stdout = postgres.StandardOutput.ReadToEndAsync();
                var stderr = postgres.StandardError.ReadToEndAsync();
                // One transaction prevents a missing second role from rotating
                // only the first password. Single-user mode must receive EOF.
                postgres.StandardInput.Write("BEGIN;\nALTER ROLE ventio_runtime_app WITH LOGIN PASSWORD '" + secrets.Runtime +
                    "';\nALTER ROLE ventio_identity_api_app WITH LOGIN PASSWORD '" + secrets.Identity + "';\nCOMMIT;\n\n");
                postgres.StandardInput.Close();
                secrets = new("", "");
                var rotationEnds = DateTime.UtcNow + RotationDeadline;
                while (!postgres.WaitForExit(100))
                    if (parent.HasExited || DateTime.UtcNow >= rotationEnds) throw Failure("POSTGRES_TIMEOUT");
                var output = stdout.GetAwaiter().GetResult();
                var error = stderr.GetAwaiter().GetResult();
                if (postgres.ExitCode != 0 || Regex.IsMatch(output + "\n" + error, @"\b(ERROR|FATAL|PANIC):", RegexOptions.CultureInvariant))
                    throw Failure("POSTGRES_REJECTED");
                writer.WriteLine(Complete);
                return 0;
            }
            finally
            {
                if (!postgres.HasExited) { postgres.Kill(entireProcessTree: true); postgres.WaitForExit(10000); }
            }
        }
        catch { return 3; }
    }

    internal static (string Runtime, string Identity) ValidateRequest(string? request)
    {
        if (request is null || request.Length > MaximumRequestChars) throw Failure("REQUEST");
        using var json = JsonDocument.Parse(request);
        if (json.RootElement.ValueKind != JsonValueKind.Object) throw Failure("REQUEST");
        var properties = json.RootElement.EnumerateObject().ToArray();
        if (properties.Length != 2 || properties.Count(p => p.Name == "runtime") != 1 || properties.Count(p => p.Name == "identity") != 1)
            throw Failure("REQUEST");
        var runtime = json.RootElement.GetProperty("runtime").GetString();
        var identity = json.RootElement.GetProperty("identity").GetString();
        if (runtime is null || identity is null || !Regex.IsMatch(runtime, "\\A[A-Za-z0-9_-]{48}\\z", RegexOptions.CultureInvariant) ||
            !Regex.IsMatch(identity, "\\A[A-Za-z0-9_-]{48}\\z", RegexOptions.CultureInvariant)) throw Failure("REQUEST");
        return (runtime, identity);
    }

    private static string? ReadLine(TextReader reader, TimeSpan timeout)
    {
        using var deadline = new CancellationTokenSource(timeout);
        // Bound both request size and waiting. Do not allocate an unbounded line
        // from an inherited stdin handle or a compromised/abandoned peer.
        var result = new StringBuilder();
        var character = new char[1];
        while (true)
        {
            var count = reader.ReadAsync(character.AsMemory(), deadline.Token).AsTask().WaitAsync(deadline.Token).GetAwaiter().GetResult();
            if (count == 0) return result.Length == 0 ? null : result.ToString();
            if (character[0] == '\n') return result.ToString().TrimEnd('\r');
            result.Append(character[0]);
            if (result.Length > MaximumRequestChars) throw Failure("REQUEST_SIZE");
        }
    }

    private static NamedPipeServerStream CreatePipe(string name, string serviceSid)
    {
        var security = new PipeSecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(WindowsIdentity.GetCurrent().User!);
        security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User!, PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(serviceSid), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        return NamedPipeServerStreamAcl.Create(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.FirstPipeInstance, 1024, 1024, security);
    }

    private static Process StartWorker(SafeAccessTokenHandle token, string[] args)
    {
        var executable = Environment.ProcessPath ?? throw Failure("EXECUTABLE");
        var command = new StringBuilder(Quote(executable) + " " + string.Join(" ", args.Select(Quote)));
        var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>(), Desktop = "" };
        if (!CreateEnvironmentBlock(out var environment, token, false)) throw NativeFailure("ENVIRONMENT");
        try
        {
            if (!CreateProcessWithTokenW(token, 0, executable, command, 0x08000000 | 0x00000400,
                environment, Path.GetDirectoryName(executable)!, ref startup, out var child)) throw NativeFailure("WORKER_START");
            try { return Process.GetProcessById(checked((int)child.ProcessId)); }
            finally { CloseHandle(child.Thread); CloseHandle(child.Process); }
        }
        finally { DestroyEnvironmentBlock(environment); }
    }

    private static SafeServiceHandle OpenValidatedService(PostgresMaintenanceTarget target, bool running)
    {
        using var manager = OpenSCManagerW(null, null, 0x0001);
        if (manager.IsInvalid) throw NativeFailure("SCM_OPEN");
        var service = OpenServiceW(manager, target.ServiceName, 0x0001 | 0x0004);
        if (service.IsInvalid) { service.Dispose(); throw NativeFailure("SERVICE_OPEN"); }
        try
        {
            // SCM's RPC contract limits this buffer to 8 KiB. An oversized
            // fixed allocation is rejected with RPC_X_BAD_STUB_DATA (1783),
            // even when the actual service configuration is much smaller.
            if (QueryServiceConfigW(service, IntPtr.Zero, 0, out var requiredBytes)) throw Failure("SERVICE_CONFIG_PROBE");
            var probeError = Marshal.GetLastWin32Error();
            if (probeError != 122) throw Failure("SERVICE_CONFIG_PROBE_WIN32_" + probeError.ToString(System.Globalization.CultureInfo.InvariantCulture));
            if (requiredBytes < Marshal.SizeOf<ServiceConfig>() || requiredBytes > 8192) throw Failure("SERVICE_CONFIG_SIZE");
            var configuration = Marshal.AllocHGlobal(requiredBytes);
            try
            {
                // A concurrent configuration expansion fails closed; do not
                // widen the bound or silently read partially changed identity.
                if (!QueryServiceConfigW(service, configuration, requiredBytes, out _)) throw NativeFailure("SERVICE_CONFIG");
                var config = Marshal.PtrToStructure<ServiceConfig>(configuration);
                if (Marshal.PtrToStringUni(config.StartName) != "NT SERVICE\\" + target.ServiceName) throw Failure("SERVICE_ACCOUNT");
                var command = Marshal.PtrToStringUni(config.BinaryPath) ?? throw Failure("SERVICE_COMMAND");
                var argv = CommandLineToArgvW(command, out var count);
                if (argv == IntPtr.Zero) throw NativeFailure("SERVICE_COMMAND");
                try
                {
                    var arguments = Enumerable.Range(0, count).Select(i => Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size))!).ToArray();
                    if (arguments.Length < 6 || !SamePath(arguments[0], target.PgCtl) || arguments[1] != "runservice" ||
                        !Pair(arguments, "-N", target.ServiceName) || !Pair(arguments, "-D", target.DataDirectory, path: true)) throw Failure("SERVICE_COMMAND");
                    // pg_ctl's registered fixed service command permits only
                    // its service/data switches and wait flag.
                    for (var i = 2; i < arguments.Length; i++)
                    {
                        if (arguments[i] is "-N" or "-D") { i++; continue; }
                        if (arguments[i] != "-w") throw Failure("SERVICE_COMMAND");
                    }
                }
                finally { LocalFree(argv); }
            }
            finally { Marshal.FreeHGlobal(configuration); }
            var status = ReadStatus(service);
            if (status.CurrentState != (running ? 4u : 1u) || (running && status.ProcessId == 0)) throw Failure("SERVICE_STATE");
            return service;
        }
        catch { service.Dispose(); throw; }
    }

    private static bool Pair(string[] args, string key, string expected, bool path = false)
    {
        var indices = Enumerable.Range(0, args.Length).Where(i => args[i] == key).ToArray();
        return indices.Length == 1 && indices[0] + 1 < args.Length &&
            (path ? SamePath(args[indices[0] + 1], expected) : args[indices[0] + 1] == expected);
    }

    private static ServiceStatus ReadStatus(SafeServiceHandle service)
    {
        if (!QueryServiceStatusEx(service, 0, out var status, Marshal.SizeOf<ServiceStatus>(), out _)) throw NativeFailure("SERVICE_STATUS");
        return status;
    }

    internal static void ValidateTarget(PostgresMaintenanceTarget target)
    {
        foreach (var path in new[] { target.Postgres, target.PgCtl, Path.Combine(target.DataDirectory, "PG_VERSION") })
        {
            var full = Path.GetFullPath(path);
            if (!File.Exists(full)) throw Failure("TARGET_MISSING");
            for (var item = new FileInfo(full) as FileSystemInfo; item is not null; item = item is DirectoryInfo dir ? dir.Parent : ((FileInfo)item).Directory)
                if ((item.Attributes & FileAttributes.ReparsePoint) != 0) throw Failure("TARGET_REPARSE");
        }
        if (File.ReadAllText(Path.Combine(target.DataDirectory, "PG_VERSION")).Trim() != "16") throw Failure("CLUSTER_VERSION");
    }

    private static void RequireAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        if (!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) throw Failure("ADMIN_REQUIRED");
    }
    private static bool SamePath(string left, string right) => Path.GetFullPath(left).TrimEnd('\\').Equals(Path.GetFullPath(right).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
    internal static SafeAccessTokenHandle OpenServiceToken(int pid)
    {
        RequireAdministrator();
        lock (ServiceTokenInspectionLock)
        {
            SafeAccessTokenHandle? captured = null;
            try
            {
                // Windows requires this *already assigned* administrator
                // privilege to inspect the token of a different account. Keep
                // it enabled only while capturing that token, not while holding
                // the lease, copying data, launching the worker, or doing SQL.
                using (var inspection = EnableServiceTokenInspection())
                {
                    var process = OpenProcess(0x1000, false, pid);
                    if (process == IntPtr.Zero) throw NativeFailure("SERVICE_PROCESS_OPEN");
                    try
                    {
                        if (!OpenProcessToken(process, 0x0002 | 0x0008, out var source)) throw NativeFailure("SERVICE_TOKEN_OPEN");
                        using (source)
                        {
                            if (!DuplicateTokenEx(source, 0x0001 | 0x0002 | 0x0008, IntPtr.Zero, 2, 1, out var primary))
                                throw NativeFailure("SERVICE_TOKEN_DUPLICATE");
                            captured = primary;
                        }
                    }
                    finally { CloseHandle(process); }
                }
                return captured ?? throw Failure("SERVICE_TOKEN_OPEN");
            }
            catch { captured?.Dispose(); throw; }
        }
    }
    private static ServiceTokenInspectionScope EnableServiceTokenInspection()
    {
        if (!OpenProcessToken(GetCurrentProcess(), 0x0020 | 0x0008, out var token)) throw NativeFailure("INSPECTION_TOKEN_OPEN");
        try
        {
            if (!LookupPrivilegeValueW(null, "SeDebugPrivilege", out var luid)) throw NativeFailure("INSPECTION_PRIVILEGE_LOOKUP");
            var requested = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 0x00000002 };
            if (!AdjustTokenPrivileges(token, false, ref requested, (uint)Marshal.SizeOf<TokenPrivileges>(), out var previous, out _))
                throw NativeFailure("INSPECTION_PRIVILEGE_ENABLE");
            var error = Marshal.GetLastWin32Error();
            if (error != 0)
            {
                // AdjustTokenPrivileges can return true with
                // ERROR_NOT_ALL_ASSIGNED. It cannot grant a missing privilege.
                using var rollback = new ServiceTokenInspectionScope(token, previous);
                throw Failure("INSPECTION_PRIVILEGE_ENABLE_WIN32_" + error.ToString(System.Globalization.CultureInfo.InvariantCulture));
            }
            return new ServiceTokenInspectionScope(token, previous);
        }
        catch { token.Dispose(); throw; }
    }
    private sealed class ServiceTokenInspectionScope(SafeAccessTokenHandle token, TokenPrivileges previous) : IDisposable
    {
        private bool _disposed;
        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            try
            {
                if (previous.Count == 0) return;
                var restore = previous;
                if (!AdjustTokenPrivileges(token, false, ref restore, (uint)Marshal.SizeOf<TokenPrivileges>(), out _, out _))
                    throw NativeFailure("INSPECTION_PRIVILEGE_RESTORE");
                var error = Marshal.GetLastWin32Error();
                if (error != 0) throw Failure("INSPECTION_PRIVILEGE_RESTORE_WIN32_" + error.ToString(System.Globalization.CultureInfo.InvariantCulture));
            }
            finally { token.Dispose(); }
        }
    }
    private static string ProcessImage(int pid)
    {
        var process = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION, never PROCESS_VM_READ.
        if (process == IntPtr.Zero) throw NativeFailure("PROCESS_QUERY");
        try
        {
            var path = new StringBuilder(32768);
            var size = path.Capacity;
            if (!QueryFullProcessImageNameW(process, 0, path, ref size)) throw NativeFailure("PROCESS_IMAGE");
            return path.ToString();
        }
        finally { CloseHandle(process); }
    }
    private static string Quote(string value) => "\"" + Regex.Replace(Regex.Replace(value, "(\\\\*)\"", "$1$1\\\""), "(\\\\+)$", "$1$1") + "\"";
    private static InvalidOperationException Failure(string code) => new("HOST_POSTGRES_MAINTENANCE_" + code);
    private static Exception NativeFailure(string code) => Failure(code + "_WIN32_" + Marshal.GetLastWin32Error().ToString(System.Globalization.CultureInfo.InvariantCulture));
    private static string SafeCode(Exception exception) => Regex.IsMatch(exception.Message, "\\AHOST_POSTGRES_MAINTENANCE_[A-Z0-9_]+\\z", RegexOptions.CultureInvariant) ? exception.Message : "HOST_POSTGRES_MAINTENANCE_FAILED";

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct StartupInfo
    { public int Size; public string? Reserved; public string? Desktop; public string? Title; public uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags; public ushort ShowWindow, ReservedBytes; public IntPtr ReservedData, Stdin, Stdout, Stderr; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
    [StructLayout(LayoutKind.Sequential)] private struct ServiceStatus { public uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint, ProcessId, ServiceFlags; }
    [StructLayout(LayoutKind.Sequential)] private struct ServiceConfig { public uint ServiceType, StartType, ErrorControl; public IntPtr BinaryPath, LoadOrderGroup; public uint TagId; public IntPtr Dependencies, StartName, DisplayName; }
    [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] private struct TokenPrivileges { public uint Count; public Luid Luid; public uint Attributes; }
    private sealed class SafeServiceHandle : SafeHandleZeroOrMinusOneIsInvalid
    { private SafeServiceHandle() : base(true) { } protected override bool ReleaseHandle() => CloseServiceHandle(handle); }
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool OpenProcessToken(IntPtr process, uint access, out SafeAccessTokenHandle token);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool LookupPrivilegeValueW(string? system, string name, out Luid luid);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AdjustTokenPrivileges(SafeAccessTokenHandle token, [MarshalAs(UnmanagedType.Bool)] bool disableAll, ref TokenPrivileges requested, uint length, out TokenPrivileges previous, out uint needed);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DuplicateTokenEx(SafeAccessTokenHandle token, uint access, IntPtr attributes, int impersonation, int type, out SafeAccessTokenHandle primary);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateProcessWithTokenW(SafeAccessTokenHandle token, uint logonFlags, string application, StringBuilder command, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation child);
    [DllImport("userenv.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateEnvironmentBlock(out IntPtr environment, SafeAccessTokenHandle token, [MarshalAs(UnmanagedType.Bool)] bool inherit);
    [DllImport("userenv.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyEnvironmentBlock(IntPtr environment);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, int pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder path, ref int size);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeServiceHandle OpenSCManagerW(string? machine, string? database, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeServiceHandle OpenServiceW(SafeServiceHandle manager, string service, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryServiceConfigW(SafeServiceHandle service, IntPtr buffer, int size, out int needed);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryServiceStatusEx(SafeServiceHandle service, int level, out ServiceStatus status, int size, out int needed);
    [DllImport("advapi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseServiceHandle(IntPtr service);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
}
