using System.Diagnostics;
using System.IO.Pipes;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace Ventio.HostSetupBroker;

// The interactive broker already requires elevation and binds the requester SID.
// This implementation executes fixed native operations, never a script interpreter.
internal static partial class NativeHostInstallation
{
    private static readonly string Payload = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Ventio", "host-payload");
    private static readonly string Product = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Ventio");
    private static readonly string Data = Path.Combine(Product, "PostgreSQL", "data");
    private static readonly string HostDirectory = Path.Combine(Product, "Host");
    private static readonly string Installer = Path.Combine(Product, "Installer");
    private static readonly string Sc = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "sc.exe");
    private const string PgService = "VentioPostgres";
    private const string HostService = "VentioHost";
    private const string FirewallName = "Ventio Host HTTPS LAN";
    private const int Port = 54329;
    private static readonly SecurityIdentifier Administrators = new("S-1-5-32-544");
    private static readonly SecurityIdentifier SystemSid = new("S-1-5-18");

    internal static async Task InstallAsync(string payload, Action<string> phase)
    {
        RequireAdministrator();
        if (!SamePath(payload, Payload)) throw Failure("PAYLOAD_PATH_INVALID");
        using var verified = PinPayload(payload);
        AssertFreshInstallation();
        // Preflight the existing firewall before creating services or a database.
        var firewallProfiles = TrustedFirewallProfiles();
        AssertFreePort(Port);
        AssertFreePort(8443);
        var bootstrap = Secret(36);
        var runtime = Secret(36);
        var identity = Secret(36);
        var migrator = Secret(32);
        var stage = "PAYLOAD_VALIDATION";
        void Progress(string value) { stage = value; phase(value); }
        try
        {
            SetDirectoryAcl(Product, Administrators, [], root: true);
            SetDirectoryAcl(Installer, Administrators, []);
            // A durable marker prevents a partial installation being mistaken for
            // a new empty machine. It contains no credentials and is never erased
            // during failure handling.
            WritePrivate(Path.Combine(Installer, "native-install.json"),
                JsonSerializer.SerializeToUtf8Bytes(new { formatVersion = 1, state = "started", startedAtUtc = DateTimeOffset.UtcNow }), []);
            Progress("POSTGRES_SERVICE_PROVISIONING");
            SetDirectoryAcl(Path.Combine(Product, "PostgreSQL"), Administrators, []);
            SetDirectoryAcl(Data, Administrators, []);
            await RunAsync(Pg("pg_ctl.exe"), ["register", "-D", Data, "-N", PgService, "-U", "NT SERVICE\\" + PgService, "-S", "auto"]);
            await ScAsync("sidtype", PgService, "unrestricted");
            var pgSid = ServiceSid(PgService);
            VerifyService(PgService, Pg("pg_ctl.exe"), Data);
            SetDirectoryAcl(Product, Administrators, [pgSid], root: true);
            SetDirectoryAcl(Path.Combine(Product, "PostgreSQL"), Administrators, [pgSid]);
            using (var current = WindowsIdentity.GetCurrent())
                SetDirectoryAcl(Data, Administrators, [pgSid, current.User ?? throw Failure("REQUESTER_IDENTITY_INVALID")]);
            try { await InitializeClusterAsync(bootstrap); }
            finally { SetDirectoryAcl(Data, Administrators, [pgSid]); }
            File.AppendAllText(Path.Combine(Data, "postgresql.conf"),
                "\n# Ventio-managed local-only settings\nlisten_addresses = '127.0.0.1'\nport = 54329\npassword_encryption = 'scram-sha-256'\nmax_prepared_transactions = 1\n", new UTF8Encoding(false));
            await RecoveryActionsAsync(PgService);
            await ScAsync("start", PgService);
            await WaitServiceAsync(PgService, 4);
            Progress("DATABASE_INITIALIZATION");
            await InitializeDatabaseAsync(bootstrap, runtime, identity, migrator);
            Progress("MIGRATION_CREDENTIAL_PROTECTION");
            ProtectFile(Path.Combine(Installer, "migration-credential.dpapi"),
                JsonSerializer.SerializeToUtf8Bytes(new { formatVersion = 1, username = "ventio_migrator_app", password = migrator }), []);
            Progress("HOST_SERVICE_REGISTRATION");
            await ScAsync("create", HostService, "binPath=", Quote(Path.Combine(Payload, "VentioHostService.exe")),
                "start=", "auto", "obj=", "NT SERVICE\\" + HostService, "depend=", PgService, "DisplayName=", "Ventio Host Engine");
            await ScAsync("sidtype", HostService, "unrestricted");
            VerifyService(HostService, Path.Combine(Payload, "VentioHostService.exe"), null);
            await RecoveryActionsAsync(HostService);
            var hostSid = ServiceSid(HostService);
            SetDirectoryAcl(Product, Administrators, [pgSid, hostSid], root: true);
            Progress("HOST_CONFIGURATION_PROTECTION");
            SetDirectoryAcl(HostDirectory, hostSid, [hostSid]);
            SetDirectoryAcl(Path.Combine(HostDirectory, "Operations"), hostSid, [hostSid]);
            var settings = new Dictionary<string, string>
            {
                ["VENTIO_HOST_DATABASE_URL"] = DatabaseUrl("ventio_runtime_app", runtime),
                ["VENTIO_HOST_IDENTITY_API_DATABASE_URL"] = DatabaseUrl("ventio_identity_api_app", identity),
                ["VENTIO_RECOVERY_AUTHORITY_FILE"] = Path.Combine(HostDirectory, "recovery.witness"),
                ["VENTIO_RECOVERY_AUTHORITY_HOST_WRITES"] = "yes",
                ["VENTIO_RECOVERY_AUTHORITY_OWNER_SID"] = hostSid.Value,
                ["VENTIO_RECOVERY_AUTHORITY_READER_SID"] = hostSid.Value,
                ["VENTIO_HOST_DIAGNOSTICS_FILE"] = Path.Combine(HostDirectory, "host-diagnostics.jsonl"),
                ["VENTIO_HOST_BIND_ADDRESS"] = "127.0.0.1",
                ["VENTIO_HOST_PORT"] = "8080"
            };
            var config = Path.Combine(HostDirectory, "service-config.dpapi");
            ProtectFile(config, ConfigurationBytes(settings), [hostSid]);
            Progress("HOST_LAN_CONFIGURATION");
            await RunAsync(Path.Combine(Payload, "VentioHostService.exe"), ["--provision-lan-certificate"]);
            EnsureFirewallRule(firewallProfiles);
            File.Copy(config, config + ".pre-lan.bak", false);
            SetFileAcl(config + ".pre-lan.bak", [hostSid]);
            settings["VENTIO_HOST_LAN_BIND_ADDRESS"] = "0.0.0.0";
            settings["VENTIO_HOST_LAN_PORT"] = "8443";
            settings["VENTIO_HOST_TLS_CERTIFICATE_FILE"] = Path.Combine(HostDirectory, "host-lan-certificate.pem");
            settings["VENTIO_HOST_TLS_PRIVATE_KEY_FILE"] = Path.Combine(HostDirectory, "host-lan-private-key.pem");
            ProtectFile(config, ConfigurationBytes(settings), [hostSid], replace: true);
            settings.Clear();
            Progress("HOST_SERVICE_STARTUP");
            await ScAsync("start", HostService);
            await WaitServiceAsync(HostService, 4);
            Progress("HOST_READINESS");
            WritePrivate(Path.Combine(Installer, "native-install.json"),
                JsonSerializer.SerializeToUtf8Bytes(new { formatVersion = 1, state = "awaitingFirstAdministrator", updatedAtUtc = DateTimeOffset.UtcNow }), [], replace: true);
        }
        catch (Exception exception)
        {
            // Never delete an initialized cluster, loosen authentication, or
            // restart a partly configured Host after a failure.
            try { if (ServiceState(HostService) is > 1) await ScAsync("stop", HostService); } catch { }
            try
            {
                var directory = Path.Combine(Installer, "ProvisioningDiagnostics");
                SetDirectoryAcl(directory, Administrators, []);
                WritePrivate(Path.Combine(directory, "native-" + Guid.NewGuid().ToString("N") + ".json"),
                    JsonSerializer.SerializeToUtf8Bytes(new {
                        timestampUtc = DateTimeOffset.UtcNow, phase = stage,
                        failureCode = System.Text.RegularExpressions.Regex.IsMatch(exception.Message, "\\AHOST_NATIVE_[A-Z0-9_]{1,96}\\z") ? exception.Message : "HOST_NATIVE_INSTALL_FAILED_DATA_PRESERVED",
                        nativeExecutable = (exception as NativeProcessException)?.ExecutableName,
                        nativeExitCode = (exception as NativeProcessException)?.ExitCode,
                        sqlState = (exception as NativeProcessException)?.SqlState
                    }), []);
            }
            catch { }
            throw;
        }
    }

    private static async Task InitializeClusterAsync(string password)
    {
        if ((await RunAsync(Pg("postgres.exe"), ["--version"])).Trim() != "postgres (PostgreSQL) 16.16")
            throw Failure("POSTGRES_VERSION_UNSUPPORTED");
        var name = "Ventio.Initdb." + Guid.NewGuid().ToString("N");
        using var pipe = new NamedPipeServerStream(name, PipeDirection.Out, 1, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var start = StartInfo(Pg("initdb.exe"), ["-D", Data, "-U", "ventio_bootstrap", "--pwfile=\\\\.\\pipe\\" + name,
            "--auth-local=scram-sha-256", "--auth-host=scram-sha-256", "--encoding=UTF8", "--no-locale"]);
        using var process = Process.Start(start) ?? throw Failure("POSTGRES_INITIALIZER_UNAVAILABLE");
        using var job = Fence(process);
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        try
        {
            await pipe.WaitForConnectionAsync(timeout.Token);
            // PostgreSQL 16 initdb re-executes itself with a restricted token on
            // Windows. Bind that peer to this owned job and the pinned initdb
            // image instead of assuming the launcher PID reads the password.
            if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var pid) || !IsInitializerPeer(pid, job))
                throw Failure("POSTGRES_PASSWORD_PIPE_PEER_INVALID");
            var bytes = Encoding.ASCII.GetBytes(password + "\n");
            try { await pipe.WriteAsync(bytes, timeout.Token); await pipe.FlushAsync(timeout.Token); }
            finally { CryptographicOperations.ZeroMemory(bytes); }
            pipe.Dispose();
            await process.WaitForExitAsync(timeout.Token);
            await Task.WhenAll(output, error);
            if (process.ExitCode != 0) throw new NativeProcessException(start.FileName, process.ExitCode, await error);
        }
        finally { if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); } }
    }

    private static async Task InitializeDatabaseAsync(string bootstrap, string runtime, string identity, string migrator)
    {
        if (!SamePath(await SqlAsync(bootstrap, "ventio_bootstrap", "postgres", "SHOW data_directory"), Data))
            throw Failure("DATABASE_DATA_DIRECTORY_MISMATCH");
        if (await SqlAsync(bootstrap, "ventio_bootstrap", "postgres", "SELECT count(*) FROM pg_database WHERE datname='ventio_host'") != "0")
            throw Failure("DATABASE_ALREADY_INITIALIZED");
        await SqlAsync(bootstrap, "ventio_bootstrap", "postgres", string.Join('\n',
            new[] { "ventio_owner", "ventio_runtime", "ventio_identity_admin", "ventio_identity_api", "ventio_migrator" }
                .Select(role => $"CREATE ROLE {role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;")));
        await RunAsync(Pg("createdb.exe"), ["-w", "-h", "127.0.0.1", "-p", "54329", "-U", "ventio_bootstrap", "-O", "ventio_owner", "-E", "UTF8", "-T", "template0", "ventio_host"], password: bootstrap);
        await RunAsync(Path.Combine(Payload, "ventio_migrate.exe"), [], environment: new()
        {
            ["VENTIO_DATABASE_URL"] = DatabaseUrl("ventio_bootstrap", bootstrap),
            ["VENTIO_MIGRATIONS_DIR"] = Path.Combine(Payload, "migrations")
        }, timeoutSeconds: 300);
        await RunAsync(Pg("psql.exe"), ["-X", "-w", "-h", "127.0.0.1", "-p", "54329", "-U", "ventio_bootstrap", "-d", "ventio_host", "-v", "ON_ERROR_STOP=1", "-v", "expected_database=ventio_host", "-f", Path.Combine(Payload, "security", "bootstrap.sql")], password: bootstrap);
        var sql = "BEGIN;\n";
        foreach (var pair in new[] { ("ventio_runtime_app", "ventio_runtime", runtime), ("ventio_identity_api_app", "ventio_identity_api", identity), ("ventio_migrator_app", "ventio_migrator", migrator) })
        {
            if (!System.Text.RegularExpressions.Regex.IsMatch(pair.Item3, "\\A[A-Za-z0-9_-]{43,48}\\z")) throw Failure("DATABASE_CREDENTIAL_INVALID");
            sql += $"CREATE ROLE {pair.Item1} LOGIN PASSWORD '{pair.Item3}' INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS; GRANT {pair.Item2} TO {pair.Item1};\n";
        }
        await SqlAsync(bootstrap, "ventio_bootstrap", "ventio_host", sql + "COMMIT;");
        foreach (var pair in new[] { ("ventio_runtime_app", "ventio_runtime", runtime), ("ventio_identity_api_app", "ventio_identity_api", identity), ("ventio_migrator_app", "ventio_migrator", migrator) })
        {
            var result = await SqlAsync(pair.Item3, pair.Item1, "ventio_host", $"SELECT current_user || ':' || rolsuper::text || ':' || rolcreatedb::text || ':' || rolcreaterole::text || ':' || rolreplication::text || ':' || rolbypassrls::text || ':' || pg_has_role(current_user,'{pair.Item2}','MEMBER')::text FROM pg_roles WHERE rolname=current_user");
            if (result != pair.Item1 + ":false:false:false:false:false:true") throw Failure("DATABASE_LOGIN_PROFILE_INVALID");
        }
        var count = await SqlAsync(bootstrap, "ventio_bootstrap", "ventio_host", "SELECT count(*) FROM public.ventio_schema_migrations");
        if (count != Directory.GetFiles(Path.Combine(Payload, "migrations"), "*.sql").Length.ToString(System.Globalization.CultureInfo.InvariantCulture))
            throw Failure("DATABASE_MIGRATION_LEDGER_INVALID");
        await SqlAsync(bootstrap, "ventio_bootstrap", "postgres", "ALTER ROLE ventio_bootstrap NOLOGIN PASSWORD NULL");
        var rejected = false;
        try { await SqlAsync(bootstrap, "ventio_bootstrap", "postgres", "SELECT 1"); }
        catch (InvalidOperationException e) when (e.Message == "HOST_NATIVE_PROCESS_FAILED") { rejected = true; }
        if (!rejected) throw Failure("DATABASE_BOOTSTRAP_LOGIN_STILL_ALLOWED");
    }

    private static Task<string> SqlAsync(string password, string user, string database, string sql) =>
        RunAsync(Pg("psql.exe"), ["-X", "-q", "-w", "-h", "127.0.0.1", "-p", "54329", "-U", user, "-d", database, "-At", "-v", "ON_ERROR_STOP=1"], input: sql + "\n", password: password);

    private static ProcessStartInfo StartInfo(string executable, string[] args)
    {
        if (!SamePath(executable, Sc) && (!Path.GetFullPath(executable).StartsWith(Payload + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || Path.GetExtension(executable) != ".exe"))
            throw Failure("EXECUTABLE_PATH_INVALID");
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Payload, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true };
        foreach (var key in info.Environment.Keys.ToArray())
            if (key.StartsWith("PG", StringComparison.OrdinalIgnoreCase) || key.StartsWith("VENTIO_", StringComparison.OrdinalIgnoreCase)) info.Environment.Remove(key);
        info.Environment["PATH"] = Environment.GetFolderPath(Environment.SpecialFolder.System);
        foreach (var argument in args) info.ArgumentList.Add(argument);
        return info;
    }

    private static async Task<string> RunAsync(string executable, string[] args, string? input = null, string? password = null, Dictionary<string, string>? environment = null, int timeoutSeconds = 120)
    {
        var start = StartInfo(executable, args);
        if (password is not null) start.Environment["PGPASSWORD"] = password;
        if (environment is not null) foreach (var pair in environment) start.Environment[pair.Key] = pair.Value;
        using var process = Process.Start(start) ?? throw Failure("PROCESS_START_FAILED");
        using var job = Fence(process);
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
        try
        {
            if (input is not null) await process.StandardInput.WriteAsync(input.AsMemory(), timeout.Token);
            process.StandardInput.Close();
            await process.WaitForExitAsync(timeout.Token);
            await Task.WhenAll(output, error);
            if (process.ExitCode != 0) throw new NativeProcessException(executable, process.ExitCode, await error);
            return (await output).Trim();
        }
        finally
        {
            if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); }
            start.Environment.Remove("PGPASSWORD");
            if (environment is not null) foreach (var key in environment.Keys) start.Environment.Remove(key);
        }
    }

    private static Task<string> ScAsync(params string[] args) => RunAsync(Sc, args);
    private static async Task RecoveryActionsAsync(string service)
    {
        await ScAsync("failure", service, "reset=", "86400", "actions=", "restart/5000/restart/30000/restart/60000");
        await ScAsync("failureflag", service, "1");
    }
    private static async Task WaitServiceAsync(string service, uint desired)
    {
        var deadline = DateTime.UtcNow.AddSeconds(120);
        while (ServiceState(service) != desired)
        {
            if (DateTime.UtcNow >= deadline || (desired == 4 && ServiceState(service) == 1)) throw Failure("SERVICE_READINESS_FAILED");
            await Task.Delay(250);
        }
    }

    internal static void AssertFreshInstallation()
    {
        if (ServiceState(PgService) is not null || ServiceState(HostService) is not null) throw Failure("EXISTING_SERVICES_REQUIRE_RECOVERY");
        foreach (var path in new[] { Product, Data, HostDirectory, Path.Combine(Product, "Backups"), Installer }) AssertNoReparseAncestors(path);
        if (Directory.Exists(Product)) AssertPrivateAcl(Product);
        foreach (var path in new[] { Data, HostDirectory, Path.Combine(Product, "Backups") })
            if (Path.Exists(path)) throw Failure("EXISTING_DATA_REQUIRES_REPAIR");
        if (Directory.Exists(Installer))
        {
            foreach (var entry in Directory.EnumerateFileSystemEntries(Installer))
            {
                if (Path.GetFileName(entry) != "ProvisioningDiagnostics" || !Directory.Exists(entry)) throw Failure("EXISTING_DATA_REQUIRES_REPAIR");
                AssertPrivateAcl(entry);
                foreach (var record in Directory.EnumerateFileSystemEntries(entry))
                {
                    if (Path.GetExtension(record) != ".json" || !File.Exists(record)) throw Failure("EXISTING_DATA_REQUIRES_REPAIR");
                    AssertNoReparseAncestors(record);
                    AssertPrivateAcl(record);
                }
            }
        }
    }

    internal static IDisposable PinPayload(string payload)
    {
        if (!SamePath(payload, Payload)) throw Failure("PAYLOAD_PATH_INVALID");
        var pins = new FilePins();
        try
        {
            AssertNoReparseAncestors(payload);
            AssertTrustedPayloadAcl(Path.GetDirectoryName(payload)!);
            AssertTrustedPayloadAcl(payload);
            var manifestPath = Path.Combine(payload, "payload-manifest.json");
            AssertTrustedPayloadAcl(manifestPath);
            var manifestStream = pins.Open(manifestPath);
            using var document = JsonDocument.Parse(manifestStream);
            var root = document.RootElement;
            if (root.GetProperty("formatVersion").GetInt32() != 1 || root.GetProperty("postgresVersion").GetString() != "16.16" ||
                root.GetProperty("credentialsIncluded").GetBoolean() || root.GetProperty("databaseIncluded").GetBoolean()) throw Failure("PAYLOAD_MANIFEST_INVALID");
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in root.GetProperty("verifiedFiles").EnumerateArray())
            {
                var relative = entry.GetProperty("path").GetString() ?? throw Failure("PAYLOAD_MANIFEST_INVALID");
                if (!SafeRelativePath(relative) || !seen.Add(relative)) throw Failure("PAYLOAD_MANIFEST_INVALID");
                var path = Path.Combine(payload, relative.Replace('/', Path.DirectorySeparatorChar));
                AssertNoReparseAncestors(path);
                AssertTrustedPayloadAcl(path);
                var stream = pins.Open(path);
                if (stream.Length != entry.GetProperty("length").GetInt64() || Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant() != entry.GetProperty("sha256").GetString()) throw Failure("PAYLOAD_HASH_INVALID");
            }
            foreach (var required in new[] { "VentioSetupBroker.exe", "VentioHostService.exe", "ventio_host.exe", "ventio_migrate.exe", "ventio_identity_bootstrap.exe", "security/bootstrap.sql", "postgresql/bin/pg_ctl.exe", "postgresql/bin/initdb.exe", "postgresql/bin/psql.exe", "postgresql/bin/createdb.exe", "postgresql/bin/postgres.exe" })
                if (!seen.Contains(required)) throw Failure("PAYLOAD_INCOMPLETE");
            var pending = new Stack<string>(); pending.Push(payload);
            while (pending.TryPop(out var directory))
            {
                AssertTrustedPayloadAcl(directory);
                foreach (var file in Directory.EnumerateFileSystemEntries(directory))
                {
                    AssertNoReparseAncestors(file);
                    if (Directory.Exists(file)) pending.Push(file);
                    else if (!SamePath(file, manifestPath) && !seen.Contains(Path.GetRelativePath(payload, file).Replace('\\', '/'))) throw Failure("PAYLOAD_UNLISTED_FILE");
                }
            }
            return pins;
        }
        catch { pins.Dispose(); throw; }
    }
    internal static bool SafeRelativePath(string path) => path.Length is > 0 and < 240 && !path.Contains('\\') && !path.Contains(':') && !Path.IsPathRooted(path) && path.Split('/').All(part => part.Length > 0 && part != "." && part != ".." && part.TrimEnd(' ', '.') == part && part.IndexOfAny(Path.GetInvalidFileNameChars()) < 0 && !System.Text.RegularExpressions.Regex.IsMatch(part, "\\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\.|\\z)", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant));
    private sealed class FilePins : IDisposable
    {
        private readonly List<FileStream> streams = [];
        internal FileStream Open(string path) { var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read); streams.Add(stream); return stream; }
        public void Dispose() { foreach (var stream in streams) stream.Dispose(); }
    }

    internal static void AssertNoReparseAncestors(string path)
    {
        for (var current = Path.GetFullPath(path); current is not null; current = Path.GetDirectoryName(current))
            if (Path.Exists(current) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw Failure("REPARSE_POINT_REJECTED");
    }
    private static void AssertTrustedPayloadAcl(string path)
    {
        AssertNoReparseAncestors(path);
        FileSystemSecurity acl = Directory.Exists(path) ? new DirectoryInfo(path).GetAccessControl() : new FileInfo(path).GetAccessControl();
        if (acl.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner || !new[] { Administrators.Value, SystemSid.Value, "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464" }.Contains(owner.Value))
            throw Failure("PAYLOAD_UNTRUSTED_OWNER");
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            if (rule.AccessControlType == AccessControlType.Allow && (rule.PropagationFlags & PropagationFlags.InheritOnly) == 0 && Program.HasWriteCapability(rule.FileSystemRights) && rule.IdentityReference.Value != Administrators.Value && rule.IdentityReference.Value != SystemSid.Value && rule.IdentityReference.Value != "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464")
                throw Failure("PAYLOAD_UNTRUSTED_WRITE_ACCESS");
    }
    private static void AssertPrivateAcl(string path, SecurityIdentifier[]? readers = null)
    {
        FileSystemSecurity acl = Directory.Exists(path) ? new DirectoryInfo(path).GetAccessControl() : new FileInfo(path).GetAccessControl();
        var rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        readers ??= [];
        var expected = new HashSet<string>(readers.Select(s => s.Value)) { Administrators.Value, SystemSid.Value };
        if (!acl.AreAccessRulesProtected || acl.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner || owner.Value != Administrators.Value || rules.Length != expected.Count ||
            !rules.Select(r => r.IdentityReference.Value).ToHashSet().SetEquals(expected) || rules.Any(r => r.AccessControlType != AccessControlType.Allow ||
                r.FileSystemRights != (r.IdentityReference.Value == Administrators.Value || r.IdentityReference.Value == SystemSid.Value ? FileSystemRights.FullControl : FileSystemRights.Read | FileSystemRights.Synchronize))) throw Failure("PRIVATE_ACL_INVALID");
    }
    private static void SetDirectoryAcl(string path, SecurityIdentifier owner, SecurityIdentifier[] services, bool root = false)
    {
        AssertNoReparseAncestors(path);
        var acl = new DirectorySecurity();
        acl.SetAccessRuleProtection(true, false);
        acl.SetOwner(owner);
        var inheritance = root ? InheritanceFlags.None : InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        foreach (var sid in new[] { Administrators, SystemSid }) acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, inheritance, PropagationFlags.None, AccessControlType.Allow));
        foreach (var sid in services.DistinctBy(s => s.Value)) acl.AddAccessRule(new FileSystemAccessRule(sid, root ? FileSystemRights.ReadAndExecute : FileSystemRights.FullControl, inheritance, PropagationFlags.None, AccessControlType.Allow));
        WithRestorePrivilege(() =>
        {
            var directory = new DirectoryInfo(path);
            directory.Create(acl);
            AssertNoReparseAncestors(path);
            directory.SetAccessControl(acl);
        });
    }
    private static void SetFileAcl(string path, SecurityIdentifier[] readers)
    {
        AssertNoReparseAncestors(path);
        var acl = new FileSecurity(); acl.SetAccessRuleProtection(true, false); acl.SetOwner(Administrators);
        foreach (var sid in new[] { Administrators, SystemSid }) acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
        foreach (var sid in readers) acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.Read | FileSystemRights.Synchronize, AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(acl);
    }
    private static void WritePrivate(string path, byte[] bytes, SecurityIdentifier[] readers, bool replace = false)
    {
        AssertNoReparseAncestors(path);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) { stream.Write(bytes); stream.Flush(true); }
            SetFileAcl(temp, readers);
            if (replace) File.Move(temp, path, true); else File.Move(temp, path);
        }
        finally { CryptographicOperations.ZeroMemory(bytes); if (File.Exists(temp)) File.Delete(temp); }
    }
    private static void ProtectFile(string path, byte[] plain, SecurityIdentifier[] readers, bool replace = false)
        => WritePrivate(path, Program.ProtectForLocalMachine(plain, []), readers, replace);
    private static byte[] ConfigurationBytes(Dictionary<string, string> settings) => Encoding.UTF8.GetBytes(string.Join('\n', settings.Select(pair => pair.Key + "=" + pair.Value)));
    private static string DatabaseUrl(string user, string password) => $"postgresql://{user}:{Uri.EscapeDataString(password)}@127.0.0.1:54329/ventio_host?sslmode=disable";
    private static string Secret(int count) { var bytes = RandomNumberGenerator.GetBytes(count); try { return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_'); } finally { CryptographicOperations.ZeroMemory(bytes); } }
    private static string Pg(string file) => Path.Combine(Payload, "postgresql", "bin", file);
    private static bool SamePath(string a, string b) => Path.GetFullPath(a).TrimEnd('\\').Equals(Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
    private static string Quote(string value) => "\"" + value + "\"";
    private static SecurityIdentifier ServiceSid(string name) => (SecurityIdentifier)new NTAccount("NT SERVICE", name).Translate(typeof(SecurityIdentifier));
    private static InvalidOperationException Failure(string code) => new NativeInstallationException(code);
    private sealed class NativeInstallationException(string code) : InvalidOperationException("HOST_NATIVE_" + code);
    internal static string? SafeFailureCode(Exception exception) => exception is NativeInstallationException or NativeProcessException ? exception.Message : null;
    private sealed class NativeProcessException : InvalidOperationException
    {
        internal string ExecutableName { get; }
        internal int ExitCode { get; }
        internal string? SqlState { get; }
        internal NativeProcessException(string executable, int exitCode, string error) : base("HOST_NATIVE_PROCESS_FAILED")
        {
            ExecutableName = Path.GetFileName(executable); ExitCode = exitCode;
            var match = System.Text.RegularExpressions.Regex.Match(error, "(?:SQLSTATE|code)\\s*[:= ]\\s*([0-9A-Z]{5})", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant);
            SqlState = match.Success ? match.Groups[1].Value.ToUpperInvariant() : null;
        }
    }
    private static void RequireAdministrator() { using var identity = WindowsIdentity.GetCurrent(); if (!OperatingSystem.IsWindows() || !new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) throw Failure("ADMIN_ELEVATION_REQUIRED"); }
    private static void AssertFreePort(int port) { var listener = new TcpListener(IPAddress.Any, port); try { listener.Start(); } catch (SocketException) { throw Failure("PORT_IN_USE"); } finally { listener.Stop(); } }

    private static int TrustedFirewallProfiles(bool allowExisting = false)
    {
        dynamic policy = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2", true)!)!;
        try
        {
            if ((int)policy.LocalPolicyModifyState != 0) throw Failure("FIREWALL_EFFECTIVE_POLICY_BLOCKED");
            foreach (var profile in new[] { 1, 2, 4 })
                if (!(bool)policy.FirewallEnabled[profile] || (int)policy.DefaultInboundAction[profile] != 0) throw Failure("FIREWALL_BASELINE_UNSAFE");
            var profiles = (int)policy.CurrentProfileTypes & 3;
            if (profiles == 0) throw Failure("LAN_TRUSTED_NETWORK_REQUIRED");
            foreach (var profile in new[] { 1, 2 })
                if ((profiles & profile) != 0 && (bool)policy.BlockAllInboundTraffic[profile]) throw Failure("FIREWALL_EFFECTIVE_POLICY_BLOCKED");
            var count = 0;
            foreach (dynamic rule in policy.Rules)
            {
                try
                {
                    if ((string)rule.Name == FirewallName)
                    {
                        if (!allowExisting || ++count > 1) throw Failure("FIREWALL_RULE_CONFLICT");
                        AssertFirewallRule(rule, (int)rule.Profiles);
                    }
                }
                finally { Marshal.FinalReleaseComObject(rule); }
            }
            return profiles;
        }
        finally { Marshal.FinalReleaseComObject(policy); }
    }
    private static void EnsureFirewallRule(int profiles, bool allowExisting = false)
    {
        // Recheck before mutation; never widen an existing or centrally governed rule.
        if (TrustedFirewallProfiles(allowExisting) != profiles) throw Failure("FIREWALL_PROFILE_CHANGED");
        dynamic policy = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2", true)!)!;
        dynamic rule = Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FWRule", true)!)!;
        try
        {
            if (allowExisting)
            {
                foreach (dynamic candidate in policy.Rules)
                {
                    try
                    {
                        if ((string)candidate.Name == FirewallName)
                        {
                            AssertFirewallRule(candidate, (int)candidate.Profiles);
                            candidate.Profiles = profiles;
                            AssertFirewallRule(candidate, profiles);
                            return;
                        }
                    }
                    finally { Marshal.FinalReleaseComObject(candidate); }
                }
            }
            rule.Name = FirewallName; rule.Description = "Ventio Host HTTPS on the local subnet"; rule.Grouping = "Ventio Host";
            rule.Protocol = 6; rule.LocalPorts = "8443"; rule.Direction = 1; rule.Action = 1;
            rule.ApplicationName = Path.Combine(Payload, "ventio_host.exe"); rule.RemoteAddresses = "LocalSubnet";
            rule.Profiles = profiles; rule.EdgeTraversal = false; rule.Enabled = true;
            policy.Rules.Add(rule);
            dynamic actual = policy.Rules.Item(FirewallName);
            try
            {
                AssertFirewallRule(actual, profiles);
            }
            finally { Marshal.FinalReleaseComObject(actual); }
        }
        finally { Marshal.FinalReleaseComObject(rule); Marshal.FinalReleaseComObject(policy); }
    }

    private static void AssertFirewallRule(dynamic rule, int profiles)
    {
        if (profiles == 0 || (profiles & ~3) != 0 || (int)rule.Protocol != 6 || (string)rule.LocalPorts != "8443" || (int)rule.Direction != 1 || (int)rule.Action != 1 ||
            !(bool)rule.Enabled || (bool)rule.EdgeTraversal || (int)rule.Profiles != profiles || !SamePath((string)rule.ApplicationName, Path.Combine(Payload, "ventio_host.exe"))) throw Failure("FIREWALL_READBACK_INVALID");
        var addresses = ((string)rule.RemoteAddresses).Split(',', StringSplitOptions.TrimEntries);
        if (addresses.Length == 0 || addresses.Any(address => !new[] { "LocalSubnet", "LocalSubnet4", "LocalSubnet6" }.Contains(address, StringComparer.OrdinalIgnoreCase))) throw Failure("FIREWALL_READBACK_INVALID");
    }

    private static SafeFileHandle Fence(Process process)
    {
        var job = CreateJobObjectW(IntPtr.Zero, null);
        if (job.IsInvalid) { process.Kill(true); throw Failure("CHILD_JOB_CREATE_FAILED"); }
        var limits = new JobLimits { BasicLimitInformation = new BasicLimits { LimitFlags = 0x2000 } };
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<JobLimits>()) || !AssignProcessToJobObject(job, process.Handle)) { job.Dispose(); if (!process.HasExited) process.Kill(true); throw Failure("CHILD_JOB_FENCE_FAILED"); }
        return job;
    }
    private static bool IsInitializerPeer(int pid, SafeFileHandle job)
    {
        using var peer = OpenProcess(0x1000, false, pid);
        if (peer.IsInvalid || !IsProcessInJob(peer, job, out var owned) || !owned) return false;
        var image = new StringBuilder(32768); var length = image.Capacity;
        return QueryFullProcessImageNameW(peer, 0, image, ref length) && SamePath(image.ToString(), Pg("initdb.exe"));
    }

    private static uint? ServiceState(string name)
    {
        var manager = OpenSCManagerW(null, null, 1); if (manager == IntPtr.Zero) throw Failure("SCM_OPEN_FAILED");
        try
        {
            var service = OpenServiceW(manager, name, 4);
            if (service == IntPtr.Zero) { if (Marshal.GetLastWin32Error() == 1060) return null; throw Failure("SERVICE_OPEN_FAILED"); }
            try { if (!QueryServiceStatusEx(service, 0, out var status, Marshal.SizeOf<ServiceStatus>(), out _)) throw Failure("SERVICE_QUERY_FAILED"); return status.CurrentState; }
            finally { CloseServiceHandle(service); }
        }
        finally { CloseServiceHandle(manager); }
    }
    private static void VerifyService(string name, string executable, string? data)
    {
        var manager = OpenSCManagerW(null, null, 1); if (manager == IntPtr.Zero) throw Failure("SCM_OPEN_FAILED");
        try
        {
            var service = OpenServiceW(manager, name, 1); if (service == IntPtr.Zero) throw Failure("SERVICE_OPEN_FAILED");
            try
            {
                QueryServiceConfigW(service, IntPtr.Zero, 0, out var required);
                if (required is < 1 or > 8192) throw Failure("SERVICE_CONFIG_INVALID");
                var buffer = Marshal.AllocHGlobal((int)required);
                try
                {
                    if (!QueryServiceConfigW(service, buffer, required, out _)) throw Failure("SERVICE_QUERY_FAILED");
                    var config = Marshal.PtrToStructure<ServiceConfig>(buffer);
                    if (config.ServiceType != 16 || Marshal.PtrToStringUni(config.StartName) != "NT SERVICE\\" + name) throw Failure("SERVICE_IDENTITY_CONFLICT");
                    var command = Marshal.PtrToStringUni(config.BinaryPath) ?? throw Failure("SERVICE_COMMAND_INVALID");
                    var argv = CommandLineToArgvW(command, out var argc); if (argv == IntPtr.Zero) throw Failure("SERVICE_COMMAND_INVALID");
                    try
                    {
                        var args = Enumerable.Range(0, argc).Select(i => Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size))!).ToArray();
                        if (!SamePath(args[0], executable)) throw Failure("SERVICE_COMMAND_INVALID");
                        if (data is null) { if (args.Length != 1) throw Failure("SERVICE_COMMAND_INVALID"); }
                        else if (args.Length != 7 || args[1] != "runservice" || args[2] != "-N" || args[3] != name || args[4] != "-D" || !SamePath(args[5], data) || args[6] != "-w") throw Failure("SERVICE_COMMAND_INVALID");
                    }
                    finally { LocalFree(argv); }
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            finally { CloseServiceHandle(service); }
        }
        finally { CloseServiceHandle(manager); }
    }

    private static void WithRestorePrivilege(Action action)
    {
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out var token)) throw Failure("OWNERSHIP_TOKEN_UNAVAILABLE");
        using (token)
        {
            if (!LookupPrivilegeValueW(null, "SeRestorePrivilege", out var luid)) throw Failure("OWNERSHIP_PRIVILEGE_UNAVAILABLE");
            var requested = new Privileges { Count = 1, Luid = luid, Attributes = 2 };
            if (!AdjustTokenPrivileges(token, false, ref requested, (uint)Marshal.SizeOf<Privileges>(), out var previous, out _) || Marshal.GetLastWin32Error() == 1300) throw Failure("OWNERSHIP_PRIVILEGE_REQUIRED");
            try { action(); }
            finally { if (!AdjustTokenPrivileges(token, false, ref previous, 0, out _, out _)) throw Failure("OWNERSHIP_PRIVILEGE_RESTORE_FAILED"); }
        }
    }

    [StructLayout(LayoutKind.Sequential)] private struct ServiceStatus { public uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint, ProcessId, ServiceFlags; }
    [StructLayout(LayoutKind.Sequential)] private struct ServiceConfig { public uint ServiceType, StartType, ErrorControl; public IntPtr BinaryPath, LoadOrderGroup; public uint TagId; public IntPtr Dependencies, StartName, DisplayName; }
    [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] private struct Privileges { public uint Count; public Luid Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimits { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)] private struct JobLimits { public BasicLimits BasicLimitInformation; public IoCounters IoInfo; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr OpenSCManagerW(string? machine, string? database, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr OpenServiceW(IntPtr manager, string name, uint access);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool CloseServiceHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool QueryServiceStatusEx(IntPtr service, int level, out ServiceStatus status, int size, out int required);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool QueryServiceConfigW(IntPtr service, IntPtr buffer, uint size, out uint required);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out int pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool IsProcessInJob(SafeProcessHandle process, SafeFileHandle job, out bool result);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool QueryFullProcessImageNameW(SafeProcessHandle process, uint flags, StringBuilder image, ref int length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateJobObjectW(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(SafeFileHandle job, int type, ref JobLimits limits, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool LookupPrivilegeValueW(string? system, string name, out Luid luid);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool AdjustTokenPrivileges(SafeAccessTokenHandle token, bool disableAll, ref Privileges state, uint length, out Privileges previous, out uint returned);
}
