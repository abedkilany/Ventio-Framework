using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

internal sealed record PostgresMaintenanceTarget(string ServiceName, string PostgresRoot, string DataDirectory, string? PrivateDirectory = null)
{
    internal static PostgresMaintenanceTarget Installed => new("VentioPostgres",
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Ventio", "host-payload", "postgresql"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Ventio", "PostgreSQL", "data"));
    internal string ServiceSid => new NTAccount("NT SERVICE", ServiceName).Translate(typeof(SecurityIdentifier)).Value;
    internal string Postgres => Path.Combine(PostgresRoot, "bin", "postgres.exe");
    internal string PgCtl => Path.Combine(PostgresRoot, "bin", "pg_ctl.exe");
    internal string JournalDirectory => PrivateDirectory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Ventio", "Installer", "PostgresMaintenance");
    internal string JournalPath => Path.Combine(JournalDirectory, "maintenance.json");
}

// SCM creates the worker under the existing virtual service account. Its token
// is never copied, its DACL is never changed, and no privilege is enabled here.
internal static class HostPostgresCredentialMaintenance
{
    internal const string Ready = "HOST_POSTGRES_MAINTENANCE_READY";
    internal const string Complete = "HOST_POSTGRES_MAINTENANCE_PASS";
    private const int MaximumRequestChars = 1024;
    private static readonly TimeSpan BackupDeadline = TimeSpan.FromMinutes(30);
    private static readonly JsonSerializerOptions JournalJson = new() { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow, MaxDepth = 8 };
    internal enum Phase { JournalDurable, ImageChanged, WorkerReady, RequestDelivered }

    internal static int Coordinate(PostgresMaintenanceTarget target, string[] workerArguments, Action<Phase>? fixturePhase = null)
    {
        FileStream? lease = null;
        IntPtr lifetimeJob = IntPtr.Zero;
        var result = 3;
        string? error = null;
        try
        {
            RequireAdministrator(); ValidateTarget(target);
            lease = AcquireLease(target);
            ReconcileLocked(target, workerArguments);
            using var service = OpenService(target.ServiceName, 0x0037);
            var original = ReadConfig(service);
            ValidateOriginal(target, original);
            var running = ReadStatus(service);
            if (running.CurrentState != 4 || running.ProcessId == 0 || !SamePath(ProcessImage(checked((int)running.ProcessId)), target.PgCtl)) throw Failure("SERVICE_STATE");
            if (target.ServiceName == "VentioPostgres" && ServiceExists("VentioHost")) throw Failure("HOST_SERVICE_PRESENT");
            // The caller can now stop PostgreSQL and make its guarded backup.
            // No service configuration has changed at this first READY boundary.
            Console.Out.WriteLine(Ready); Console.Out.Flush();
            using var input = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false, true), false, 1024, leaveOpen: true);
            var request = ReadLine(input, BackupDeadline);
            ValidateRequest(request);
            if (ReadStatus(service).CurrentState != 1 || !Equivalent(original, ReadConfig(service))) throw Failure("SERVICE_CHANGED_BEFORE_MAINTENANCE");
            if (File.Exists(Path.Combine(target.DataDirectory, "postmaster.pid"))) throw Failure("CLUSTER_NOT_STOPPED");
            var owner = WindowsIdentity.GetCurrent().User!.Value;
            var pipeName = "Ventio.PostgresMaintenance." + Guid.NewGuid().ToString("N");
            using var pipe = CreatePipe(pipeName, target.ServiceSid);
            lifetimeJob = CreateLifetimeJob(pipeName, target.ServiceSid, owner);
            var command = Command(workerArguments, pipeName, Environment.ProcessId, owner);
            WriteJournal(target, new Journal(1, target.ServiceName, target.PostgresRoot, target.DataDirectory, target.ServiceSid, HelperHash(), command, original));
            fixturePhase?.Invoke(Phase.JournalDurable);
            ChangeImage(service, command);
            if (!Equivalent(original, ReadConfig(service), command)) throw Failure("SERVICE_CHANGE_VERIFICATION");
            fixturePhase?.Invoke(Phase.ImageChanged);
            if (!StartServiceW(service, 0, IntPtr.Zero)) throw NativeFailure("SERVICE_START");
            using var connectionDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            pipe.WaitForConnectionAsync(connectionDeadline.Token).GetAwaiter().GetResult();
            var workerStatus = ReadStatus(service);
            if (workerStatus.CurrentState != 4 || !GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var workerPid) || workerPid != workerStatus.ProcessId ||
                !SamePath(ProcessImage(checked((int)workerPid)), Environment.ProcessPath!)) throw Failure("WORKER_PIPE_IDENTITY");
            using var reader = new StreamReader(pipe, new UTF8Encoding(false, true), false, 1024, leaveOpen: true);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, leaveOpen: true) { AutoFlush = true };
            var ready = ReadLine(reader, TimeSpan.FromSeconds(15));
            if (ready != Ready) throw ReplyFailure(ready, "WORKER_READINESS");
            fixturePhase?.Invoke(Phase.WorkerReady);
            writer.WriteLine(request); request = null;
            fixturePhase?.Invoke(Phase.RequestDelivered);
            var outcome = ReadLine(reader, TimeSpan.FromSeconds(45));
            if (outcome == "HOST_POSTGRES_MAINTENANCE_BACKEND_READY")
            {
                writer.WriteLine("HOST_POSTGRES_MAINTENANCE_EXECUTE");
                outcome = ReadLine(reader, TimeSpan.FromSeconds(45));
            }
            if (outcome != Complete) throw ReplyFailure(outcome, "ROTATION_FAILED");
            WaitStopped(service);
            result = 0;
        }
        catch (Exception exception) { error = SafeCode(exception); }
        finally
        {
            if (lease is not null)
            {
                try { ReconcileLocked(target, workerArguments); }
                catch (Exception exception) { error = SafeCode(exception); result = 3; }
                lease.Dispose();
            }
            if (lifetimeJob != IntPtr.Zero) CloseHandle(lifetimeJob);
        }
        if (result == 0) Console.Out.WriteLine(Complete);
        else Console.Error.WriteLine(error ?? "HOST_POSTGRES_MAINTENANCE_FAILED");
        return result;
    }

    internal static int Reconcile(PostgresMaintenanceTarget target, string[] workerArguments)
    {
        try
        {
            RequireAdministrator(); ValidateTarget(target);
            using var lease = AcquireLease(target);
            ReconcileLocked(target, workerArguments);
            return 0;
        }
        catch (Exception exception) { Console.Error.WriteLine(SafeCode(exception)); return 3; }
    }

    private static void ReconcileLocked(PostgresMaintenanceTarget target, string[] workerArguments)
    {
        if (!File.Exists(target.JournalPath)) return;
        ValidatePrivate(new FileInfo(target.JournalPath));
        using var input = new FileStream(target.JournalPath, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (input.Length is < 1 or > 32768) throw Failure("JOURNAL_SIZE");
        var journal = JsonSerializer.Deserialize<Journal>(input, JournalJson) ?? throw Failure("JOURNAL_INVALID");
        input.Dispose();
        if (journal.Version != 1 || journal.Service != target.ServiceName || journal.ServiceSid != target.ServiceSid ||
            !SamePath(journal.PostgresRoot, target.PostgresRoot) || !SamePath(journal.DataDirectory, target.DataDirectory) || journal.HelperSha256 != HelperHash()) throw Failure("JOURNAL_IDENTITY");
        ValidateOriginal(target, journal.Original);
        ValidateMaintenanceCommand(journal.MaintenanceImage, workerArguments);
        using var service = OpenService(target.ServiceName, 0x0037);
        var configuration = ReadConfig(service);
        var workerCommand = Arguments(journal.MaintenanceImage);
        var job = OpenLifetimeJob(workerCommand[^3], workerCommand[^1], assign: false);
        try
        {
        if (Equivalent(journal.Original, configuration, journal.MaintenanceImage))
        {
            var status = ReadStatus(service);
            if (status.CurrentState != 1)
            {
                if (status.ProcessId == 0 || !SamePath(ProcessImage(checked((int)status.ProcessId)), Environment.ProcessPath!)) throw Failure("RECONCILE_PROCESS_IDENTITY");
                // The worker handles STOP by cancelling/terminating only its
                // own PostgreSQL child before reporting SERVICE_STOPPED.
                if (!ControlService(service, 1, out _) && Marshal.GetLastWin32Error() != 1062) throw NativeFailure("RECONCILE_STOP");
                if (!WaitStopped(service, 10000) && job == IntPtr.Zero) throw Failure("RECONCILE_WORKER_STOP_TIMEOUT");
            }
            if (!Equivalent(journal.Original, ReadConfig(service), journal.MaintenanceImage)) throw Failure("RECONCILE_CONCURRENT_CHANGE");
        }
        else if (!Equivalent(journal.Original, configuration)) throw Failure("RECONCILE_FOREIGN_CONFIGURATION");
        else
        {
            var status = ReadStatus(service);
            if (status.CurrentState != 1)
            {
                var image = status.ProcessId == 0 ? "" : ProcessImage(checked((int)status.ProcessId));
                if (SamePath(image, Environment.ProcessPath!))
                {
                    if (!ControlService(service, 1, out _) && Marshal.GetLastWin32Error() != 1062) throw NativeFailure("RECONCILE_STOP");
                    if (!WaitStopped(service, 10000) && job == IntPtr.Zero) throw Failure("RECONCILE_WORKER_STOP_TIMEOUT");
                }
                else if (!SamePath(image, target.PgCtl)) throw Failure("RECONCILE_ORIGINAL_PROCESS_IDENTITY");
            }
        }
        // The coordinator keeps an independent handle to this operation's
        // private job. Even a hard worker crash cannot leave its backend alive
        // while ImagePath is restored. Never terminate an unverified named job.
        if (job != IntPtr.Zero) DrainLifetimeJob(job);
        if (ReadConfig(service).BinaryPath == journal.MaintenanceImage)
        {
            WaitStopped(service);
            if (!Equivalent(journal.Original, ReadConfig(service), journal.MaintenanceImage)) throw Failure("RECONCILE_CONCURRENT_CHANGE");
            ChangeImage(service, journal.Original.BinaryPath);
        }
        if (!Equivalent(journal.Original, ReadConfig(service))) throw Failure("RECONCILE_VERIFICATION");
        File.Delete(target.JournalPath);
        }
        finally { if (job != IntPtr.Zero) CloseHandle(job); }
    }

    internal static int RunService(PostgresMaintenanceTarget target, string[] workerArguments, string pipeName, int parentPid, string ownerSid, Action<int, CancellationToken>? fixtureBackendStarted = null)
    {
        using var stop = new CancellationTokenSource();
        IntPtr statusHandle = IntPtr.Zero;
        ServiceHandler handler = (control, _, _, _) => { if (control is 1 or 5) stop.Cancel(); return 0; };
        ServiceMain main = (_, _) =>
        {
            statusHandle = RegisterServiceCtrlHandlerExW(target.ServiceName, handler, IntPtr.Zero);
            if (statusHandle == IntPtr.Zero) return;
            var status = new BasicServiceStatus { ServiceType = 16, CurrentState = 4, ControlsAccepted = 1 | 4 };
            IntPtr retainedJob = IntPtr.Zero;
            if (SetServiceStatus(statusHandle, ref status)) Work(target, workerArguments, pipeName, parentPid, ownerSid, stop.Token, out retainedJob, fixtureBackendStarted);
            // Functional denial is delivered through the authenticated pipe.
            // A clean stop must not trigger configured crash-restart actions.
            status.CurrentState = 1; status.ControlsAccepted = 0;
            SetServiceStatus(statusHandle, ref status);
            // Report a clean stop before closing the last possible job handle.
            // If the coordinator died, this close also terminates this worker.
            if (retainedJob != IntPtr.Zero) CloseHandle(retainedJob);
        };
        var table = new[] { new ServiceEntry { Name = target.ServiceName, Callback = main }, new ServiceEntry() };
        var started = StartServiceCtrlDispatcherW(table);
        GC.KeepAlive(main); GC.KeepAlive(handler);
        return started ? 0 : 3;
    }

    private static void Work(PostgresMaintenanceTarget target, string[] workerArguments, string pipeName, int parentPid, string ownerSid, CancellationToken stop, out IntPtr retainedJob, Action<int, CancellationToken>? fixtureBackendStarted)
    {
        retainedJob = IntPtr.Zero;
        NamedPipeClientStream? pipe = null;
        StreamWriter? writer = null;
        try
        {
            ValidateTarget(target); ValidatePipeName(pipeName);
            using var identity = WindowsIdentity.GetCurrent();
            if (identity.User?.Value != target.ServiceSid || new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) throw Failure("WORKER_IDENTITY");
            pipe = new NamedPipeClientStream(".", pipeName, PipeAccessRights.ReadWrite, PipeOptions.Asynchronous, TokenImpersonationLevel.Identification, HandleInheritability.None);
            pipe.Connect(15000);
            if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var serverPid) || serverPid != parentPid ||
                pipe.GetAccessControl().GetOwner(typeof(SecurityIdentifier))?.Value != new SecurityIdentifier(ownerSid).Value) throw Failure("PARENT_PIPE_IDENTITY");
            // ownerSid/PID come from administrator-controlled SCM ImagePath.
            // An unprivileged pipe server cannot adopt that SID as its owner.
            using var service = OpenService(target.ServiceName, 0x0005);
            var configuration = ReadConfig(service);
            if (configuration.StartName != "NT SERVICE\\" + target.ServiceName || configuration.ServiceType != 16 ||
                configuration.BinaryPath != Command(workerArguments, pipeName, parentPid, ownerSid) || ReadStatus(service).ProcessId != Environment.ProcessId)
                throw Failure("WORKER_SCM_IDENTITY");
            writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, leaveOpen: true) { AutoFlush = true };
            using var reader = new StreamReader(pipe, new UTF8Encoding(false, true), false, 1024, leaveOpen: true);
            writer.WriteLine(Ready);
            var secrets = ValidateRequest(ReadLine(reader, TimeSpan.FromSeconds(30), stop));
            if (stop.IsCancellationRequested || !PeerAlive(pipe, parentPid) || File.Exists(Path.Combine(target.DataDirectory, "postmaster.pid"))) throw Failure("CLUSTER_NOT_STOPPED");
            retainedJob = OpenLifetimeJob(pipeName, ownerSid, assign: true);
            if (retainedJob == IntPtr.Zero || !AssignProcessToJobObject(retainedJob, GetCurrentProcess())) throw NativeFailure("CHILD_JOB_ASSIGN");
            var info = new ProcessStartInfo(target.Postgres) { UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Path.Combine(target.PostgresRoot, "bin") };
            foreach (var argument in new[] { "--single", "-D", target.DataDirectory, "-j", "postgres" }) info.ArgumentList.Add(argument);
            info.Environment.Clear(); info.Environment["SystemRoot"] = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            using var postgres = Process.Start(info) ?? throw Failure("POSTGRES_START");
            try
            {
                var stdout = postgres.StandardOutput.ReadToEndAsync(); var stderr = postgres.StandardError.ReadToEndAsync();
                fixtureBackendStarted?.Invoke(postgres.Id, stop);
                writer.WriteLine("HOST_POSTGRES_MAINTENANCE_BACKEND_READY");
                if (ReadLine(reader, TimeSpan.FromSeconds(5), stop) != "HOST_POSTGRES_MAINTENANCE_EXECUTE" || stop.IsCancellationRequested || !PeerAlive(pipe, parentPid)) throw Failure("POSTGRES_CANCELLED");
                postgres.StandardInput.Write("BEGIN;\nALTER ROLE ventio_runtime_app WITH LOGIN PASSWORD '" + secrets.Runtime +
                    "';\nALTER ROLE ventio_identity_api_app WITH LOGIN PASSWORD '" + secrets.Identity + "';\nCOMMIT;\n\n");
                postgres.StandardInput.Close(); secrets = new("", "");
                var deadline = DateTime.UtcNow.AddSeconds(30);
                while (!postgres.WaitForExit(100)) if (stop.IsCancellationRequested || !PeerAlive(pipe, parentPid) || DateTime.UtcNow >= deadline) throw Failure("POSTGRES_TIMEOUT");
                if (postgres.ExitCode != 0 || Regex.IsMatch(stdout.GetAwaiter().GetResult() + "\n" + stderr.GetAwaiter().GetResult(), @"\b(ERROR|FATAL|PANIC):", RegexOptions.CultureInvariant)) throw Failure("POSTGRES_REJECTED");
                writer.WriteLine(Complete);
            }
            finally { if (!postgres.HasExited) { postgres.Kill(entireProcessTree: true); if (!postgres.WaitForExit(10000)) throw Failure("POSTGRES_STILL_RUNNING"); } }
        }
        catch (Exception exception) { try { writer?.WriteLine(SafeCode(exception)); } catch { } }
        finally { writer?.Dispose(); pipe?.Dispose(); }
    }

    internal static (string Runtime, string Identity) ValidateRequest(string? request)
    {
        if (request is null || request.Length > MaximumRequestChars) throw Failure("REQUEST");
        using var json = JsonDocument.Parse(request);
        if (json.RootElement.ValueKind != JsonValueKind.Object) throw Failure("REQUEST");
        var properties = json.RootElement.EnumerateObject().ToArray();
        if (properties.Length != 2 || properties.Count(p => p.Name == "runtime") != 1 || properties.Count(p => p.Name == "identity") != 1) throw Failure("REQUEST");
        var runtime = json.RootElement.GetProperty("runtime").GetString(); var identity = json.RootElement.GetProperty("identity").GetString();
        if (runtime is null || identity is null || !Regex.IsMatch(runtime, "\\A[A-Za-z0-9_-]{48}\\z", RegexOptions.CultureInvariant) || !Regex.IsMatch(identity, "\\A[A-Za-z0-9_-]{48}\\z", RegexOptions.CultureInvariant)) throw Failure("REQUEST");
        return (runtime, identity);
    }
    private static string? ReadLine(TextReader reader, TimeSpan timeout, CancellationToken cancellation = default)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation); deadline.CancelAfter(timeout);
        var result = new StringBuilder(); var character = new char[1];
        while (true)
        {
            var count = reader.ReadAsync(character.AsMemory(), deadline.Token).AsTask().WaitAsync(deadline.Token).GetAwaiter().GetResult();
            if (count == 0) return result.Length == 0 ? null : result.ToString();
            if (character[0] == '\n') return result.ToString().TrimEnd('\r');
            result.Append(character[0]); if (result.Length > MaximumRequestChars) throw Failure("REQUEST_SIZE");
        }
    }
    private static NamedPipeServerStream CreatePipe(string name, string serviceSid)
    {
        var security = new PipeSecurity(); security.SetAccessRuleProtection(true, false); security.SetOwner(WindowsIdentity.GetCurrent().User!);
        security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User!, PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(serviceSid), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        return NamedPipeServerStreamAcl.Create(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.FirstPipeInstance, 1024, 1024, security);
    }
    private static bool PeerAlive(NamedPipeClientStream pipe, int pid) => GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var actual) && actual == pid &&
        PeekNamedPipe(pipe.SafePipeHandle, IntPtr.Zero, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

    private static FileStream AcquireLease(PostgresMaintenanceTarget target)
    {
        NoReparse(target.JournalDirectory);
        var directory = new DirectoryInfo(target.JournalDirectory);
        if (!directory.Exists) { ValidatePrivate(directory.Parent!); directory.Create(); ProtectPrivate(directory); }
        ValidatePrivate(directory);
        var path = Path.Combine(directory.FullName, "operation.lock"); NoReparse(path);
        var existing = File.Exists(path);
        if (existing) ValidatePrivate(new FileInfo(path));
        var stream = new FileStream(path, existing ? FileMode.Open : FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.WriteThrough);
        try { if (stream.Length != 0) throw Failure("LEASE_INVALID"); if (!existing) ProtectPrivate(new FileInfo(path)); ValidatePrivate(new FileInfo(path)); return stream; }
        catch { stream.Dispose(); throw; }
    }
    private static void WriteJournal(PostgresMaintenanceTarget target, Journal value)
    {
        using var stream = new FileStream(target.JournalPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough);
        ProtectPrivate(new FileInfo(target.JournalPath));
        JsonSerializer.Serialize(stream, value, JournalJson); stream.Flush(true);
    }
    private static void ProtectPrivate(FileSystemInfo item)
    {
        FileSystemSecurity security = item is DirectoryInfo ? new DirectorySecurity() : new FileSecurity();
        security.SetAccessRuleProtection(true, false); security.SetOwner(new SecurityIdentifier("S-1-5-32-544"));
        foreach (var sid in new[] { "S-1-5-32-544", "S-1-5-18" }) security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid), FileSystemRights.FullControl,
            item is DirectoryInfo ? InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit : InheritanceFlags.None, PropagationFlags.None, AccessControlType.Allow));
        if (item is DirectoryInfo directory) directory.SetAccessControl((DirectorySecurity)security); else ((FileInfo)item).SetAccessControl((FileSecurity)security);
    }
    private static void ValidatePrivate(FileSystemInfo item)
    {
        NoReparse(item.FullName);
        FileSystemSecurity security = item is DirectoryInfo directory ? directory.GetAccessControl() : ((FileInfo)item).GetAccessControl();
        var owner = security.GetOwner(typeof(SecurityIdentifier))?.Value;
        var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        if (!security.AreAccessRulesProtected || owner is not ("S-1-5-32-544" or "S-1-5-18") || rules.Length != 2 ||
            rules.Any(rule => rule.AccessControlType != AccessControlType.Allow || rule.FileSystemRights != FileSystemRights.FullControl ||
                ((SecurityIdentifier)rule.IdentityReference).Value is not ("S-1-5-32-544" or "S-1-5-18"))) throw Failure("PRIVATE_STORAGE_ACL");
    }
    private static void ValidateMaintenanceCommand(string command, string[] workerArguments)
    {
        var args = Arguments(command);
        if (args.Length != workerArguments.Length + 4 || !SamePath(args[0], Environment.ProcessPath!) || !args.Skip(1).Take(workerArguments.Length).SequenceEqual(workerArguments)) throw Failure("JOURNAL_WORKER_COMMAND");
        ValidatePipeName(args[^3]);
        if (!int.TryParse(args[^2], out var pid) || pid < 1) throw Failure("JOURNAL_WORKER_PID");
        _ = new SecurityIdentifier(args[^1]);
    }
    private static void ValidatePipeName(string value) { if (!Regex.IsMatch(value, "\\AVentio\\.PostgresMaintenance\\.[0-9a-f]{32}\\z", RegexOptions.CultureInvariant)) throw Failure("PIPE_NAME"); }
    private static string Command(string[] args, string pipe, int pid, string owner) => Quote(Environment.ProcessPath!) + " " + string.Join(" ", args.Concat(new[] { pipe, pid.ToString(System.Globalization.CultureInfo.InvariantCulture), owner }).Select(Quote));
    private static string HelperHash() { using var file = File.OpenRead(Environment.ProcessPath!); return Convert.ToHexString(SHA256.HashData(file)).ToLowerInvariant(); }

    private static void ValidateOriginal(PostgresMaintenanceTarget target, Configuration config)
    {
        if (config.StartName != "NT SERVICE\\" + target.ServiceName || config.ServiceType != 16) throw Failure("SERVICE_ACCOUNT");
        var args = Arguments(config.BinaryPath);
        if (args.Length < 6 || !SamePath(args[0], target.PgCtl) || args[1] != "runservice" || !Pair(args, "-N", target.ServiceName) || !Pair(args, "-D", target.DataDirectory, true)) throw Failure("SERVICE_COMMAND");
        for (var i = 2; i < args.Length; i++) { if (args[i] is "-N" or "-D") { i++; continue; } if (args[i] != "-w") throw Failure("SERVICE_COMMAND"); }
    }
    private static bool Pair(string[] args, string key, string expected, bool path = false)
    {
        var indices = Enumerable.Range(0, args.Length).Where(i => args[i] == key).ToArray();
        return indices.Length == 1 && indices[0] + 1 < args.Length && (path ? SamePath(args[indices[0] + 1], expected) : args[indices[0] + 1] == expected);
    }
    private static string[] Arguments(string command)
    {
        var argv = CommandLineToArgvW(command, out var count); if (argv == IntPtr.Zero) throw NativeFailure("SERVICE_COMMAND");
        try { return Enumerable.Range(0, count).Select(i => Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size))!).ToArray(); }
        finally { LocalFree(argv); }
    }
    private static bool Equivalent(Configuration original, Configuration actual, string? image = null) => actual.ServiceType == original.ServiceType && actual.StartType == original.StartType &&
        actual.ErrorControl == original.ErrorControl && actual.StartName == original.StartName && actual.BinaryPath == (image ?? original.BinaryPath) && actual.LoadOrderGroup == original.LoadOrderGroup &&
        actual.TagId == original.TagId && actual.Dependencies.SequenceEqual(original.Dependencies) && actual.DisplayName == original.DisplayName;
    private static SafeServiceHandle OpenService(string name, uint rights)
    {
        using var manager = OpenSCManagerW(null, null, 1); if (manager.IsInvalid) throw NativeFailure("SCM_OPEN");
        var service = OpenServiceW(manager, name, rights); if (service.IsInvalid) { service.Dispose(); throw NativeFailure("SERVICE_OPEN"); } return service;
    }
    private static bool ServiceExists(string name)
    {
        using var manager = OpenSCManagerW(null, null, 1); if (manager.IsInvalid) throw NativeFailure("SCM_OPEN");
        using var service = OpenServiceW(manager, name, 1);
        if (!service.IsInvalid) return true;
        var error = Marshal.GetLastWin32Error(); if (error == 1060) return false;
        throw Failure("SERVICE_PRESENCE_WIN32_" + error.ToString(System.Globalization.CultureInfo.InvariantCulture));
    }
    private static Configuration ReadConfig(SafeServiceHandle service)
    {
        if (QueryServiceConfigW(service, IntPtr.Zero, 0, out var needed) || Marshal.GetLastWin32Error() != 122 || needed < Marshal.SizeOf<NativeConfig>() || needed > 8192) throw Failure("SERVICE_CONFIG_SIZE");
        var buffer = Marshal.AllocHGlobal(needed);
        try
        {
            if (!QueryServiceConfigW(service, buffer, needed, out _)) throw NativeFailure("SERVICE_CONFIG");
            var value = Marshal.PtrToStructure<NativeConfig>(buffer);
            var dependencies = new List<string>(); var pointer = value.Dependencies;
            while (pointer != IntPtr.Zero && Marshal.ReadInt16(pointer) != 0) { var dependency = Marshal.PtrToStringUni(pointer)!; dependencies.Add(dependency); pointer = IntPtr.Add(pointer, (dependency.Length + 1) * 2); }
            return new(value.ServiceType, value.StartType, value.ErrorControl, Marshal.PtrToStringUni(value.BinaryPath)!, Marshal.PtrToStringUni(value.StartName)!,
                Marshal.PtrToStringUni(value.LoadOrderGroup) ?? "", value.TagId, dependencies.ToArray(), Marshal.PtrToStringUni(value.DisplayName) ?? "");
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    private static ServiceStatus ReadStatus(SafeServiceHandle service) { if (!QueryServiceStatusEx(service, 0, out var status, Marshal.SizeOf<ServiceStatus>(), out _)) throw NativeFailure("SERVICE_STATUS"); return status; }
    private static void ChangeImage(SafeServiceHandle service, string command)
    {
        if (!ChangeServiceConfigW(service, uint.MaxValue, uint.MaxValue, uint.MaxValue, command, null, IntPtr.Zero, null, null, null, null)) throw NativeFailure("SERVICE_IMAGE_CHANGE");
    }
    private static void WaitStopped(SafeServiceHandle service) { if (!WaitStopped(service, 45000)) throw Failure("SERVICE_STOP_TIMEOUT"); }
    private static bool WaitStopped(SafeServiceHandle service, int milliseconds)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(milliseconds);
        while (ReadStatus(service).CurrentState != 1) { if (DateTime.UtcNow >= deadline) return false; Thread.Sleep(100); }
        return true;
    }
    internal static void ValidateTarget(PostgresMaintenanceTarget target)
    {
        foreach (var path in new[] { target.Postgres, target.PgCtl, Path.Combine(target.DataDirectory, "PG_VERSION") }) { NoReparse(path); if (!File.Exists(path)) throw Failure("TARGET_MISSING"); }
        if (File.ReadAllText(Path.Combine(target.DataDirectory, "PG_VERSION")).Trim() != "16") throw Failure("CLUSTER_VERSION");
    }
    private static void NoReparse(string path)
    {
        for (var item = new FileInfo(Path.GetFullPath(path)) as FileSystemInfo; item is not null; item = item is DirectoryInfo dir ? dir.Parent : ((FileInfo)item).Directory)
            if ((File.Exists(item.FullName) || Directory.Exists(item.FullName)) && (item.Attributes & FileAttributes.ReparsePoint) != 0) throw Failure("TARGET_REPARSE");
    }
    private static void RequireAdministrator() { using var identity = WindowsIdentity.GetCurrent(); if (!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) throw Failure("ADMIN_REQUIRED"); }
    private static string ProcessImage(int pid)
    {
        var process = OpenProcess(0x1000, false, pid); if (process == IntPtr.Zero) throw NativeFailure("PROCESS_QUERY");
        try { var path = new StringBuilder(32768); var size = path.Capacity; if (!QueryFullProcessImageNameW(process, 0, path, ref size)) throw NativeFailure("PROCESS_IMAGE"); return path.ToString(); }
        finally { CloseHandle(process); }
    }
    private static bool SamePath(string left, string right) => Path.GetFullPath(left).TrimEnd('\\').Equals(Path.GetFullPath(right).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
    private static string Quote(string value) => "\"" + Regex.Replace(Regex.Replace(value, "(\\\\*)\"", "$1$1\\\""), "(\\\\+)$", "$1$1") + "\"";
    private static InvalidOperationException Failure(string code) => new("HOST_POSTGRES_MAINTENANCE_" + code);
    private static Exception NativeFailure(string code) => Failure(code + "_WIN32_" + Marshal.GetLastWin32Error().ToString(System.Globalization.CultureInfo.InvariantCulture));
    private static string SafeCode(Exception exception) => Regex.IsMatch(exception.Message, "\\AHOST_POSTGRES_MAINTENANCE_[A-Z0-9_]+\\z", RegexOptions.CultureInvariant) ? exception.Message : "HOST_POSTGRES_MAINTENANCE_FAILED";
    private static Exception ReplyFailure(string? reply, string fallback) => reply is not null && SafeCode(new Exception(reply)) == reply ? new InvalidOperationException(reply) : Failure(fallback);

    private sealed record Configuration(uint ServiceType, uint StartType, uint ErrorControl, string BinaryPath, string StartName, string LoadOrderGroup, uint TagId, string[] Dependencies, string DisplayName);
    private sealed record Journal(int Version, string Service, string PostgresRoot, string DataDirectory, string ServiceSid, string HelperSha256, string MaintenanceImage, Configuration Original);
    private static string JobName(string pipeName) => "Global\\" + pipeName + ".BackendLifetime";
    private static IntPtr CreateLifetimeJob(string pipeName, string serviceSid, string ownerSid)
    {
        var descriptor = new RawSecurityDescriptor("O:" + ownerSid + "D:P(A;;GA;;;" + ownerSid + ")(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x00020005;;;" + serviceSid + ")");
        var bytes = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(bytes, 0);
        var memory = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, memory, bytes.Length);
            var attributes = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Descriptor = memory };
            var job = CreateJobObjectW(ref attributes, JobName(pipeName)); var error = Marshal.GetLastWin32Error();
            if (job == IntPtr.Zero) throw Failure("CHILD_JOB_CREATE_WIN32_" + error.ToString(System.Globalization.CultureInfo.InvariantCulture));
            if (error == 183) { CloseHandle(job); throw Failure("CHILD_JOB_ALREADY_EXISTS"); }
            var limits = new JobLimits { Basic = new BasicJobLimits { Flags = 0x2000 } };
            if (!SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf<JobLimits>())) { CloseHandle(job); throw NativeFailure("CHILD_JOB_LIMITS"); }
            return job;
        }
        finally { Marshal.FreeHGlobal(memory); }
    }
    private static IntPtr OpenLifetimeJob(string pipeName, string ownerSid, bool assign)
    {
        var job = OpenJobObjectW(0x00020000 | 0x0004 | (assign ? 0x0001u : 0x0008u), false, JobName(pipeName));
        if (job == IntPtr.Zero) { var error = Marshal.GetLastWin32Error(); if (!assign && error == 2) return IntPtr.Zero; throw Failure("CHILD_JOB_OPEN_WIN32_" + error.ToString(System.Globalization.CultureInfo.InvariantCulture)); }
        try
        {
            var error = GetSecurityInfo(job, 6, 1, out var owner, out _, out _, out _, out var descriptor);
            if (error != 0) throw Failure("CHILD_JOB_SECURITY");
            try { if (new SecurityIdentifier(owner).Value != ownerSid) throw Failure("CHILD_JOB_OWNER"); }
            finally { LocalFree(descriptor); }
            return job;
        }
        catch { CloseHandle(job); throw; }
    }
    private static void DrainLifetimeJob(IntPtr job)
    {
        if (!TerminateJobObject(job, 3)) throw NativeFailure("CHILD_JOB_TERMINATE");
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (true)
        {
            if (!QueryInformationJobObject(job, 1, out var accounting, Marshal.SizeOf<JobAccounting>(), out _)) throw NativeFailure("CHILD_JOB_QUERY");
            if (accounting.ActiveProcesses == 0) return;
            if (DateTime.UtcNow >= deadline) throw Failure("CHILD_JOB_NOT_EMPTY");
            Thread.Sleep(100);
        }
    }
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
    [StructLayout(LayoutKind.Sequential)] private struct JobAccounting { public long UserTime, KernelTime, PeriodUserTime, PeriodKernelTime; public uint PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses; }
    [StructLayout(LayoutKind.Sequential)] private struct BasicJobLimits { public long ProcessTime, JobTime; public uint Flags; public UIntPtr MinimumWorkingSet, MaximumWorkingSet; public uint ActiveProcesses; public UIntPtr Affinity; public uint Priority, Scheduling; }
    [StructLayout(LayoutKind.Sequential)] private struct JobLimits { public BasicJobLimits Basic; public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
    [StructLayout(LayoutKind.Sequential)] private struct ServiceStatus { public uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint, ProcessId, ServiceFlags; }
    [StructLayout(LayoutKind.Sequential)] private struct BasicServiceStatus { public uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint; }
    [StructLayout(LayoutKind.Sequential)] private struct NativeConfig { public uint ServiceType, StartType, ErrorControl; public IntPtr BinaryPath, LoadOrderGroup; public uint TagId; public IntPtr Dependencies, StartName, DisplayName; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct ServiceEntry { [MarshalAs(UnmanagedType.LPWStr)] public string? Name; public ServiceMain? Callback; }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate void ServiceMain(int argc, IntPtr argv);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate uint ServiceHandler(uint control, uint eventType, IntPtr data, IntPtr context);
    private sealed class SafeServiceHandle : SafeHandleZeroOrMinusOneIsInvalid { private SafeServiceHandle() : base(true) { } protected override bool ReleaseHandle() => CloseServiceHandle(handle); }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeServiceHandle OpenSCManagerW(string? machine, string? database, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeServiceHandle OpenServiceW(SafeServiceHandle manager, string service, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryServiceConfigW(SafeServiceHandle service, IntPtr buffer, int size, out int needed);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryServiceStatusEx(SafeServiceHandle service, int level, out ServiceStatus status, int size, out int needed);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ChangeServiceConfigW(SafeServiceHandle service, uint type, uint start, uint error, string binary, string? group, IntPtr tag, string? dependencies, string? account, string? password, string? display);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool StartServiceW(SafeServiceHandle service, int count, IntPtr args);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ControlService(SafeServiceHandle service, uint control, out BasicServiceStatus status);
    [DllImport("advapi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseServiceHandle(IntPtr service);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool StartServiceCtrlDispatcherW([In] ServiceEntry[] table);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr RegisterServiceCtrlHandlerExW(string name, ServiceHandler handler, IntPtr context);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetServiceStatus(IntPtr handle, ref BasicServiceStatus status);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PeekNamedPipe(SafePipeHandle pipe, IntPtr buffer, uint size, IntPtr read, IntPtr available, IntPtr left);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, int pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder path, ref int size);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObjectW(ref SecurityAttributes attributes, string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr OpenJobObjectW(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryInformationJobObject(IntPtr job, int type, out JobAccounting accounting, int length, out int needed);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern uint GetSecurityInfo(IntPtr handle, int type, uint information, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(IntPtr job, int type, ref JobLimits limits, int length);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
}
