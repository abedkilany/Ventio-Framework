using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

internal static class PostgresCredentialMaintenanceFixture
{
    internal static int Dispatch(string[] args)
    {
        var target = args.Length >= 4 ? Target(args) : null;
        if (args[0] == "--pg-maintenance-coordinator" && args.Length is 4 or 5)
            return HostPostgresCredentialMaintenance.Coordinate(target!, WorkerArguments(args), phase => FixturePhase(target!, args.Length == 5 ? args[4] : null, phase));
        if (args[0] == "--pg-maintenance-reconcile" && args.Length is 4 or 5)
            return HostPostgresCredentialMaintenance.Reconcile(target!, WorkerArguments(args));
        if (args[0] == "--pg-maintenance-worker" && args.Length is 7 or 8 && int.TryParse(args[^2], out var pid))
        {
            VerifyWorkerJobRights(target!, args[^3]);
            return HostPostgresCredentialMaintenance.RunService(target!, WorkerArguments(args), args[^3], pid, args[^1], args.Length == 8 ? (backend, stop) => HoldBackend(target!, backend, stop) : null);
        }
        if (args[0] == "--postgres-recovery-fixture" && args.Length == 2) return Run(args[1]);
        return 2;
    }
    private static string[] WorkerArguments(string[] args) => args.Length > 4 && args[4] == "hold-backend" ? ["--pg-maintenance-worker", args[1], args[2], args[3], "hold-backend"] : ["--pg-maintenance-worker", args[1], args[2], args[3]];
    private static void HoldBackend(PostgresMaintenanceTarget target, int pid, CancellationToken stop)
    {
        using (var marker = new FileStream(Path.Combine(target.DataDirectory, "maintenance-backend-pid.txt"), FileMode.CreateNew, FileAccess.Write, FileShare.Read, 4096, FileOptions.WriteThrough))
        { marker.Write(Encoding.ASCII.GetBytes(pid.ToString(System.Globalization.CultureInfo.InvariantCulture))); marker.Flush(true); }
        stop.WaitHandle.WaitOne(30000);
    }
    private static void VerifyWorkerJobRights(PostgresMaintenanceTarget target, string pipeName)
    {
        var rows = new List<object>();
        foreach (var request in new[] { (Rights: 0x00020005u, Allowed: true), (Rights: 0x0002u, Allowed: false), (Rights: 0x0008u, Allowed: false), (Rights: 0x00040000u, Allowed: false) })
        {
            var handle = OpenJobObjectW(request.Rights, false, "Global\\" + pipeName + ".BackendLifetime");
            var error = handle == IntPtr.Zero ? Marshal.GetLastWin32Error() : 0;
            if (handle != IntPtr.Zero) CloseHandle(handle);
            if ((handle != IntPtr.Zero) != request.Allowed || (!request.Allowed && error != 5)) throw new InvalidOperationException("SCM worker job-rights boundary failed.");
            rows.Add(new { rights = "0x" + request.Rights.ToString("X"), allowed = request.Allowed, win32 = error });
        }
        File.WriteAllText(Path.Combine(target.DataDirectory, "maintenance-job-rights.json"), JsonSerializer.Serialize(rows));
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr OpenJobObjectW(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, string name);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    private static PostgresMaintenanceTarget Target(string[] args) => new(args[1], args[2], args[3], Path.Combine(Path.GetDirectoryName(args[3])! + "-management", "maintenance"));
    private static void FixturePhase(PostgresMaintenanceTarget target, string? fault, HostPostgresCredentialMaintenance.Phase phase)
    {
        if (fault == "throw:" + phase) throw new InvalidOperationException("HOST_POSTGRES_MAINTENANCE_FIXTURE_INJECTED_FAILURE");
        if (fault == "pause:" + phase)
        {
            using (var marker = new FileStream(PhaseMarker(target, phase), FileMode.CreateNew, FileAccess.Write, FileShare.Read, 1, FileOptions.WriteThrough)) { marker.WriteByte(1); marker.Flush(true); }
            Thread.Sleep(30000);
            throw new InvalidOperationException("HOST_POSTGRES_MAINTENANCE_FIXTURE_FAULT_NOT_INTERRUPTED");
        }
    }
    private static string PhaseMarker(PostgresMaintenanceTarget target, HostPostgresCredentialMaintenance.Phase phase) => Path.Combine(Path.GetDirectoryName(target.JournalDirectory)!, "phase-" + phase);
    private static readonly List<string> Passed = [];
    private static void Pass(string name) { Passed.Add(name); Console.WriteLine("PASS " + name); }
    private static void Require(bool condition, string name) { if (!condition) throw new InvalidOperationException(name); Pass(name); }

    private static int Run(string postgresRoot)
    {
        // Fixture-only entry point is compiled into the test program, never the
        // shipped service. It creates only its unique hosted-runner service/root.
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" ||
            Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted" ||
            !new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))
            throw new InvalidOperationException("Disposable elevated GitHub-hosted Windows fixture required.");
        var suffix = Guid.NewGuid().ToString("N");
        var name = "VentioPgRecoveryTest-" + suffix;
        var root = Path.Combine(Path.GetPathRoot(Environment.SystemDirectory)!, name);
        var data = Path.Combine(root, "data");
        var passwordFile = Path.Combine(root, "bootstrap-password.tmp");
        var management = root + "-management";
        var target = new PostgresMaintenanceTarget(name, Path.GetFullPath(postgresRoot), data, Path.Combine(management, "maintenance"));
        var bootstrap = Secret(32);
        var oldRuntime = Secret(36);
        var oldIdentity = Secret(36);
        var runtime = Secret(36);
        var identity = Secret(36);
        var migrator = Secret(32);
        var pgCtl = target.PgCtl;
        var portListener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        portListener.Start();
        var port = ((System.Net.IPEndPoint)portListener.LocalEndpoint).Port;
        portListener.Stop();
        var registered = false;
        var retained = false;
        try
        {
            Directory.CreateDirectory(management);
            Protect(management, null);
            Directory.CreateDirectory(root);
            Protect(root, null, includeCurrentUser: true);
            File.WriteAllText(passwordFile, bootstrap, new UTF8Encoding(false));
            var initialized = Execute(Path.Combine(target.PostgresRoot, "bin", "initdb.exe"),
                ["--no-sync", "--locale=C", "--username=ventio_bootstrap", "--auth-local=scram-sha-256", "--auth-host=scram-sha-256", "--pwfile=" + passwordFile, "-D", data]);
            Require(initialized.ExitCode == 0, "service-fixture-initialized");
            File.Delete(passwordFile);
            File.AppendAllText(Path.Combine(data, "postgresql.conf"), "\nlisten_addresses='127.0.0.1'\nport=" + port + "\npassword_encryption='scram-sha-256'\n");
            Require(Execute(pgCtl, ["register", "-D", data, "-N", name, "-U", "NT SERVICE\\" + name, "-S", "demand"]).ExitCode == 0,
                "disposable-virtual-account-service-registered");
            registered = true;
            Require(Sc(["sidtype", name, "unrestricted"]).ExitCode == 0, "service-sid-enabled");
            Protect(root, target.ServiceSid);
            Protect(data, target.ServiceSid);
            // initdb gives explicit current-user ACLs to its descendants. Replace
            // these in this fresh fixture to reproduce installed service-only ACLs.
            foreach (var path in Directory.EnumerateFileSystemEntries(data, "*", SearchOption.AllDirectories))
                Protect(path, target.ServiceSid);
            var witness = Path.Combine(root, "recovery-authority-preserved.bin");
            var witnessBytes = RandomNumberGenerator.GetBytes(64);
            File.WriteAllBytes(witness, witnessBytes);
            Protect(witness, null);
            Start(name, target, port);
            var seed = Sql(target, port, "ventio_bootstrap", bootstrap,
                "CREATE ROLE ventio_runtime_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '" + oldRuntime + "';\n" +
                "CREATE ROLE ventio_identity_api_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '" + oldIdentity + "';\n");
            Require(seed.ExitCode == 0, "bounded-roles-seeded");
            SeedLedger(target, port, bootstrap, migrator);
            Require(ValidateLedger(target, port, migrator).ExitCode == 0, "actual-product-migrator-profile-and-ledger-validator-before-rotation");
            Require(Sql(target, port, "ventio_migrator_app", migrator, "SELECT count(*) FROM public.ventio_schema_migrations;", "ventio_host").ExitCode != 0,
                "migrator-direct-ledger-read-denied");
            var dataAcl = new DirectoryInfo(data).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All);
            var hbaAcl = new FileInfo(Path.Combine(data, "pg_hba.conf")).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All);
            var hba = File.ReadAllBytes(Path.Combine(data, "pg_hba.conf"));
            Stop(name);
            var originalBoundary = Execute(target.Postgres, ["--single", "-D", data, "postgres"], "SELECT 1;\n");
            Require(originalBoundary.ExitCode != 0 && originalBoundary.Error.Contains("administrative", StringComparison.OrdinalIgnoreCase),
                "direct-administrator-backend-is-rejected");
            Start(name, target, port);

            VerifyScmInterruption(target, name, port, oldRuntime, oldIdentity);

            using (var coordinator = Begin(target))
            {
                Stop(name);
                var result = Complete(coordinator, runtime, identity);
                Require(result.ExitCode == 0 && result.Output.Trim() == HostPostgresCredentialMaintenance.Complete,
                    "same-service-account-scm-single-user-rotation-succeeded");
            }
            Start(name, target, port);
            Require(Login(target, port, "ventio_runtime_app", runtime) && Login(target, port, "ventio_identity_api_app", identity), "both-new-role-passwords-authenticate");
            Require(!Login(target, port, "ventio_runtime_app", oldRuntime) && !Login(target, port, "ventio_identity_api_app", oldIdentity), "both-old-role-passwords-rejected");
            Require(ValidateLedger(target, port, migrator).ExitCode == 0, "actual-product-migration-ledger-and-profile-preserved-after-rotation");
            Require(Sql(target, port, "ventio_bootstrap", bootstrap, "SELECT value FROM public.recovery_fixture_preserved;").Output.Trim() == "original-business-data",
                "existing-cluster-data-preserved");
            var profile = Sql(target, port, "ventio_runtime_app", runtime,
                "SELECT rolsuper::text || ':' || rolcreatedb::text || ':' || rolcreaterole::text || ':' || rolreplication::text || ':' || rolbypassrls::text FROM pg_roles WHERE rolname=current_user;");
            Require(profile.ExitCode == 0 && profile.Output.Trim() == "false:false:false:false:false", "runtime-role-privileges-preserved");
            Require(Sql(target, port, "ventio_runtime_app", runtime, "SELECT rolpassword FROM pg_authid;").ExitCode != 0, "runtime-cannot-read-role-secrets");

            // Existing service still running: wrong extra launch arguments must
            // be rejected before a token is used or the cluster is touched.
            var command = "\"" + pgCtl + "\" runservice -N \"" + name + "\" -D \"" + data + "\" -w";
            Require(Sc(["config", name, "binPath=", command + " -o unsafe-extra"]).ExitCode == 0, "fixture-service-command-negative-staged");
            try
            {
                var rejected = CoordinatorWithoutHandshake(target, "");
                Require(rejected.ExitCode != 0 && !rejected.Output.Contains(HostPostgresCredentialMaintenance.Ready), "unexpected-service-command-rejected");
            }
            finally { if (Sc(["config", name, "binPath=", command]).ExitCode != 0) throw new InvalidOperationException("Fixture command restoration failed."); }

            using (var abandoned = Begin(target))
            {
                abandoned.StandardInput.Close();
                Require(abandoned.WaitForExit(20000) && abandoned.ExitCode != 0, "abandoned-stdin-terminates-without-rotation");
            }
            Require(Login(target, port, "ventio_runtime_app", runtime), "abandoned-request-keeps-service-and-password");
            using (var invalid = Begin(target))
            {
                invalid.StandardInput.WriteLine("{\"runtime\":\"" + runtime + "\",\"identity\":\"" + identity + "\",\"sql\":\"DROP ROLE\"}");
                invalid.StandardInput.Close();
                Require(invalid.WaitForExit(20000) && invalid.ExitCode != 0, "arbitrary-request-properties-rejected");
            }

            // A missing second role must roll back the first ALTER ROLE too.
            Require(Sql(target, port, "ventio_bootstrap", bootstrap, "DROP ROLE ventio_identity_api_app;").ExitCode == 0, "missing-role-negative-staged");
            var attemptedRuntime = Secret(36);
            using (var failed = Begin(target))
            {
                Stop(name);
                var result = Complete(failed, attemptedRuntime, Secret(36));
                Require(result.ExitCode != 0 && !result.Output.Contains(HostPostgresCredentialMaintenance.Complete), "missing-role-rotation-rejected");
                Require(!result.Output.Contains(attemptedRuntime) && !result.Error.Contains(attemptedRuntime), "failure-diagnostics-redact-passwords");
            }
            Start(name, target, port);
            Require(Login(target, port, "ventio_runtime_app", runtime) && !Login(target, port, "ventio_runtime_app", attemptedRuntime), "missing-role-transaction-preserves-first-password");
            Require(dataAcl == new DirectoryInfo(data).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All) &&
                hbaAcl == new FileInfo(Path.Combine(data, "pg_hba.conf")).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All), "cluster-and-hba-acls-unchanged");
            Require(hba.SequenceEqual(File.ReadAllBytes(Path.Combine(data, "pg_hba.conf"))), "authentication-rules-unchanged");
            Require(witnessBytes.SequenceEqual(File.ReadAllBytes(witness)), "external-recovery-authority-sentinel-unchanged");
            Require(Sql(target, port, "ventio_bootstrap", bootstrap, "DELETE FROM public.ventio_schema_migrations WHERE name=(SELECT min(name) FROM public.ventio_schema_migrations);", "ventio_host").ExitCode == 0,
                "migration-ledger-count-negative-staged");
            Require(ValidateLedger(target, port, migrator).ExitCode != 0, "actual-product-validator-rejects-missing-ledger-row");
            Console.WriteLine("POSTGRES_SINGLE_USER_RECOVERY_PASS");
            return 0;
        }
        catch (Exception exception)
        {
            // Do not emit subprocess text from SQL setup: it may echo secrets.
            Console.Error.WriteLine("POSTGRES_MAINTENANCE_FIXTURE_FAILED " + exception.GetType().Name + " " + exception.Message);
            return 3;
        }
        finally
        {
            if (registered)
            {
                try { Stop(name); } catch { retained = true; }
                if (!retained && Sc(["delete", name]).ExitCode != 0) retained = true;
            }
            if (!retained && Directory.Exists(root) && Path.GetFileName(root) == name &&
                name.StartsWith("VentioPgRecoveryTest-", StringComparison.Ordinal) && name.Length == "VentioPgRecoveryTest-".Length + 32)
            {
                if (Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories).Any(p => (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0)) retained = true;
                else Directory.Delete(root, recursive: true);
            }
            if (!retained && Directory.Exists(management) && Path.GetFileName(management) == name + "-management" && !Directory.EnumerateFileSystemEntries(management, "*", SearchOption.AllDirectories).Any(p => (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0)) Directory.Delete(management, recursive: true);
            var reportRoot = Path.Combine(Environment.CurrentDirectory, "test-results", "wave2-runtime");
            Directory.CreateDirectory(reportRoot);
            File.WriteAllText(Path.Combine(reportRoot, "postgres-maintenance-cases.json"), JsonSerializer.Serialize(new
            { sourceCommit = Environment.GetEnvironmentVariable("GITHUB_SHA"), runId = Environment.GetEnvironmentVariable("GITHUB_RUN_ID"), cases = Passed.Select(id => new { id, status = "PASSED" }), retainedFixture = retained, physicalAcceptance = false }, new JsonSerializerOptions { WriteIndented = true }));
        }
    }

    private static Process Begin(PostgresMaintenanceTarget target, string? fault = null)
    {
        var process = StartCoordinator(target, fault);
        var ready = process.StandardOutput.ReadLineAsync();
        if (!ready.Wait(45000) || ready.GetAwaiter().GetResult() != HostPostgresCredentialMaintenance.Ready)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            process.WaitForExit(10000);
            var code = process.StandardError.ReadToEnd().Trim();
            process.Dispose();
            throw new InvalidOperationException("Coordinator readiness failed: " + code);
        }
        return process;
    }
    private static Process StartCoordinator(PostgresMaintenanceTarget target, string? fault = null)
    {
        var info = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in new[] { "--pg-maintenance-coordinator", target.ServiceName, target.PostgresRoot, target.DataDirectory }) info.ArgumentList.Add(argument);
        if (fault is not null) info.ArgumentList.Add(fault);
        return Process.Start(info) ?? throw new InvalidOperationException("Coordinator start failed.");
    }
    private static Result CoordinatorWithoutHandshake(PostgresMaintenanceTarget target, string input)
    {
        using var process = StartCoordinator(target);
        process.StandardInput.Write(input); process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(45000)) { process.Kill(entireProcessTree: true); throw new InvalidOperationException("Coordinator timeout."); }
        return new(process.ExitCode, output.GetAwaiter().GetResult(), error.GetAwaiter().GetResult());
    }
    private static void VerifyScmInterruption(PostgresMaintenanceTarget target, string name, int port, string runtime, string identity)
    {
        var original = Sc(["qc", name]).Output;
        var permissions = Sc(["sdshow", name]).Output;
        using (var holder = Begin(target))
        {
            Require(!File.Exists(target.JournalPath) && Sc(["qc", name]).Output == original, "ready-before-backup-does-not-change-service-image");
            var rejected = CoordinatorWithoutHandshake(target, "");
            Require(rejected.ExitCode != 0 && !rejected.Output.Contains(HostPostgresCredentialMaintenance.Ready, StringComparison.Ordinal), "concurrent-coordinator-refused-by-private-operation-lease");
            holder.StandardInput.Close();
            Require(holder.WaitForExit(20000) && holder.ExitCode != 0, "abandoned-pre-backup-coordinator-terminates");
        }
        using (var failed = Begin(target, "throw:ImageChanged"))
        {
            Stop(name);
            var result = Complete(failed, runtime, identity);
            Require(result.ExitCode != 0 && !File.Exists(target.JournalPath) && Sc(["qc", name]).Output == original, "injected-post-image-failure-restores-exact-original-configuration");
        }
        Start(name, target, port);
        foreach (var phase in new[] { HostPostgresCredentialMaintenance.Phase.JournalDurable, HostPostgresCredentialMaintenance.Phase.ImageChanged,
            HostPostgresCredentialMaintenance.Phase.WorkerReady, HostPostgresCredentialMaintenance.Phase.RequestDelivered })
        {
            File.Delete(PhaseMarker(target, phase));
            using var interrupted = Begin(target, "pause:" + phase);
            Stop(name);
            interrupted.StandardInput.WriteLine(JsonSerializer.Serialize(new { runtime, identity })); interrupted.StandardInput.Close();
            WaitFile(PhaseMarker(target, phase));
            Require(File.Exists(target.JournalPath), "durable-journal-exists-before-crash-" + phase);
            interrupted.Kill(entireProcessTree: true); interrupted.WaitForExit(10000);
            var reconciled = Execute(Environment.ProcessPath!, ["--pg-maintenance-reconcile", target.ServiceName, target.PostgresRoot, target.DataDirectory]);
            Require(reconciled.ExitCode == 0 && !File.Exists(target.JournalPath) && Sc(["qc", name]).Output == original,
                "crash-reconciliation-restores-configuration-" + phase);
            Start(name, target, port);
            Require(Login(target, port, "ventio_runtime_app", runtime) && Login(target, port, "ventio_identity_api_app", identity), "crash-reconciliation-preserves-role-authentication-" + phase);
        }
        var backendMarker = Path.Combine(target.DataDirectory, "maintenance-backend-pid.txt");
        File.Delete(backendMarker);
        using (var interrupted = Begin(target, "hold-backend"))
        {
            Stop(name);
            interrupted.StandardInput.WriteLine(JsonSerializer.Serialize(new { runtime, identity })); interrupted.StandardInput.Close();
            WaitFile(backendMarker);
            var backendPid = int.Parse(File.ReadAllText(backendMarker), System.Globalization.CultureInfo.InvariantCulture);
            using var backend = Process.GetProcessById(backendPid);
            Require(!backend.HasExited, "real-single-user-backend-alive-before-worker-hard-crash");
            var pid = Regex.Match(Sc(["queryex", name]).Output, @"\bPID\s*:\s*(\d+)", RegexOptions.CultureInvariant);
            if (!pid.Success) throw new InvalidOperationException("SCM worker PID missing.");
            using (var worker = Process.GetProcessById(int.Parse(pid.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture)))
            { worker.Kill(); worker.WaitForExit(10000); }
            Require(interrupted.WaitForExit(60000) && interrupted.ExitCode != 0, "worker-hard-crash-does-not-report-success");
            Require(backend.WaitForExit(15000) && !File.Exists(target.JournalPath) && Sc(["qc", name]).Output == original,
                "owned-job-terminates-backend-before-service-image-restoration");
        }
        File.Delete(backendMarker);
        Start(name, target, port);
        Require(Login(target, port, "ventio_runtime_app", runtime) && Login(target, port, "ventio_identity_api_app", identity), "hard-worker-crash-preserves-both-passwords");
        using (var jobPermissions = JsonDocument.Parse(File.ReadAllText(Path.Combine(target.DataDirectory, "maintenance-job-rights.json"))))
            Require(jobPermissions.RootElement.GetArrayLength() == 4, "real-service-worker-job-query-and-assignment-allowed-modification-and-termination-denied");
        var evidenceRoot = Path.Combine(Environment.CurrentDirectory, "test-results", "wave2-runtime");
        Directory.CreateDirectory(evidenceRoot);
        File.Copy(Path.Combine(target.DataDirectory, "maintenance-job-rights.json"), Path.Combine(evidenceRoot, "postgres-worker-job-rights.json"), overwrite: true);
        Require(Sc(["sdshow", name]).Output == permissions, "service-security-descriptor-unchanged-by-maintenance-and-reconciliation");
    }
    private static void WaitFile(string path)
    {
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (!File.Exists(path) || new FileInfo(path).Length == 0) { if (DateTime.UtcNow >= deadline) throw new InvalidOperationException("Fixture phase marker timeout."); Thread.Sleep(25); }
    }
    private static Result Complete(Process process, string runtime, string identity)
    {
        process.StandardInput.WriteLine(JsonSerializer.Serialize(new { runtime, identity })); process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(60000)) { process.Kill(entireProcessTree: true); throw new InvalidOperationException("Rotation timeout."); }
        return new(process.ExitCode, output.GetAwaiter().GetResult(), error.GetAwaiter().GetResult());
    }
    private static string Secret(int count) => Convert.ToBase64String(RandomNumberGenerator.GetBytes(count)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static bool Login(PostgresMaintenanceTarget target, int port, string role, string secret) => Sql(target, port, role, secret, "SELECT current_user;").ExitCode == 0;
    private static Result Sql(PostgresMaintenanceTarget target, int port, string role, string secret, string sql, string database = "postgres") =>
        Execute(Path.Combine(target.PostgresRoot, "bin", "psql.exe"), ["-X", "-w", "-h", "127.0.0.1", "-p", port.ToString(System.Globalization.CultureInfo.InvariantCulture), "-U", role, "-d", database, "-At", "-v", "ON_ERROR_STOP=1"], sql, secret);
    private static void SeedLedger(PostgresMaintenanceTarget target, int port, string bootstrap, string migrator)
    {
        var files = Directory.GetFiles(Path.Combine(Environment.CurrentDirectory, "migrations", "postgres"), "*.sql", SearchOption.AllDirectories);
        var rows = files.Select(path => "('" + Path.GetFileName(path).Replace("'", "''", StringComparison.Ordinal) + "','" +
            Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant() + "')");
        var sql = "CREATE ROLE ventio_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;\n" +
            "CREATE ROLE ventio_migrator NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;\n" +
            "GRANT ventio_owner TO ventio_migrator WITH INHERIT FALSE, SET TRUE;\n" +
            "CREATE ROLE ventio_migrator_app LOGIN PASSWORD '" + migrator + "' INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;\n" +
            "GRANT ventio_migrator TO ventio_migrator_app;\nCREATE DATABASE ventio_host;\n" +
            "CREATE TABLE public.recovery_fixture_preserved(value text);\nINSERT INTO public.recovery_fixture_preserved VALUES ('original-business-data');\n" +
            "\\connect ventio_host\nGRANT CREATE ON SCHEMA public TO ventio_owner;\nSET ROLE ventio_owner;\n" +
            "CREATE TABLE public.ventio_schema_migrations(name text PRIMARY KEY, sha256 text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now());\n" +
            "INSERT INTO public.ventio_schema_migrations(name,sha256) VALUES " + string.Join(",", rows) + ";\nRESET ROLE;\n";
        Require(Sql(target, port, "ventio_bootstrap", bootstrap, sql).ExitCode == 0, "real-ledger-table-and-restricted-migrator-profile-seeded");
    }
    private static Result ValidateLedger(PostgresMaintenanceTarget target, int port, string secret) =>
        Execute(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
            ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", Path.Combine(Environment.CurrentDirectory, "scripts", "windows", "test-postgres-single-user-recovery.ps1"),
                "-PostgresRoot", target.PostgresRoot, "-ValidateMigrationPort", port.ToString(System.Globalization.CultureInfo.InvariantCulture)],
            environment: new Dictionary<string, string> { ["VENTIO_TEST_MIGRATOR_PASSWORD"] = secret });
    private static Result Sc(string[] args) => Execute(Path.Combine(Environment.SystemDirectory, "sc.exe"), args);
    private static void Start(string service, PostgresMaintenanceTarget target, int port)
    {
        if (Sc(["start", service]).ExitCode != 0) throw new InvalidOperationException("Fixture service start failed.");
        var deadline = DateTime.UtcNow.AddSeconds(60);
        while (DateTime.UtcNow < deadline)
        {
            if (Execute(Path.Combine(target.PostgresRoot, "bin", "pg_isready.exe"), ["-h", "127.0.0.1", "-p", port.ToString(System.Globalization.CultureInfo.InvariantCulture), "-t", "1"]).ExitCode == 0) return;
            Thread.Sleep(250);
        }
        throw new InvalidOperationException("Fixture PostgreSQL readiness failed.");
    }
    private static void Stop(string service)
    {
        var stopped = Sc(["stop", service]);
        if (stopped.ExitCode != 0 && !stopped.Output.Contains("1062", StringComparison.Ordinal)) throw new InvalidOperationException("Fixture service stop failed.");
        var deadline = DateTime.UtcNow.AddSeconds(60);
        while (DateTime.UtcNow < deadline)
        {
            if (Sc(["query", service]).Output.Contains("STOPPED", StringComparison.Ordinal)) return;
            Thread.Sleep(250);
        }
        throw new InvalidOperationException("Fixture service stop timeout.");
    }
    private static void Protect(string path, string? serviceSid, bool includeCurrentUser = false)
    {
        var directory = Directory.Exists(path);
        FileSystemSecurity security = directory ? new DirectorySecurity() : new FileSecurity();
        security.SetAccessRuleProtection(true, false);
        var admin = new SecurityIdentifier("S-1-5-32-544");
        security.SetOwner(admin);
        var sids = new List<SecurityIdentifier> { admin, new("S-1-5-18") };
        if (serviceSid is not null) sids.Add(new(serviceSid));
        if (includeCurrentUser) sids.Add(WindowsIdentity.GetCurrent().User!);
        foreach (var sid in sids.Distinct()) security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
            directory ? InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit : InheritanceFlags.None, PropagationFlags.None, AccessControlType.Allow));
        if (directory) new DirectoryInfo(path).SetAccessControl((DirectorySecurity)security); else new FileInfo(path).SetAccessControl((FileSecurity)security);
    }
    private sealed record Result(int ExitCode, string Output, string Error);
    private static Result Execute(string executable, string[] arguments, string? input = null, string? password = null, IReadOnlyDictionary<string, string>? environment = null)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        if (password is not null) info.Environment["PGPASSWORD"] = password;
        if (environment is not null) foreach (var entry in environment) info.Environment[entry.Key] = entry.Value;
        info.Environment["PGCONNECT_TIMEOUT"] = "3";
        using var process = Process.Start(info) ?? throw new InvalidOperationException("Fixture process failed.");
        var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
        if (input is not null) process.StandardInput.Write(input);
        process.StandardInput.Close();
        if (!process.WaitForExit(90000)) { process.Kill(entireProcessTree: true); throw new InvalidOperationException("Fixture process timed out."); }
        return new(process.ExitCode, output.GetAwaiter().GetResult(), error.GetAwaiter().GetResult());
    }
}
