using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using RecoveryNative = Ventio.Setup.ServiceRecovery.Native;
using RecoveryPolicy = Ventio.Setup.ServiceRecovery.PolicyValue;
using RecoveryAction = Ventio.Setup.ServiceRecovery.ActionValue;

namespace Ventio.HostSetupBroker;

internal static partial class NativeHostInstallation
{
    internal static void AssertInstallerHelperPath()
    {
        RequireAdministrator();
        var executable = Path.GetFullPath(Environment.ProcessPath ?? throw Failure("INSTALLER_HELPER_PATH_INVALID"));
        if (SamePath(executable, Path.Combine(Payload, "VentioSetupBroker.exe"))) Program.ValidateBrokerManifest(Payload, executable);
        var installed = Path.Combine(Payload, "VentioSetupBroker.exe");
        if (!SamePath(executable, installed))
        {
            var directory = Path.GetDirectoryName(executable)!;
            var parent = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            var name = Path.GetFileName(directory);
            if (Path.GetFileName(executable) != "VentioSetupBroker.exe" || !SamePath(Path.GetDirectoryName(directory)!, parent) || !name.StartsWith("Ventio-Setup-", StringComparison.Ordinal) || !Guid.TryParseExact(name[13..], "N", out _)) throw Failure("INSTALLER_HELPER_PATH_INVALID");
            AssertPrivateAcl(directory); AssertPrivateAcl(executable);
        }
        AssertNoReparseAncestors(executable);
        AssertTrustedPayloadAcl(Path.GetDirectoryName(executable)!);
        AssertTrustedPayloadAcl(executable);
    }
    private static readonly string PolicyPath = Path.Combine(Installer, "host-service-recovery-policy.VentioHost.v1.dpapi");
    private static readonly string PreviousPayloadManifestPath = Path.Combine(Installer, "host-payload-previous.manifest.json");
    internal readonly record struct PayloadMember(long Length, string Sha256);
    // Verified 7218c1c / PostgreSQL 16.15 package members left by an interrupted
    // in-place 16.16 upgrade. These are the only unlisted files repair may retire.
    // See docs/wave2/evidence/20261118-7218c1c/SHA256SUMS.txt.
    internal static readonly IReadOnlyDictionary<string, PayloadMember> LegacyPg1615Residue =
        new Dictionary<string, PayloadMember>(StringComparer.OrdinalIgnoreCase)
        {
            ["postgresql/bin/libwinpthread-1.dll"] = new(52736, "ffe2d56375bb4e8bdee9037df6befc5016ddd8871d0d85027314dd5792f8fdc9"),
            ["postgresql/bin/wxbase3211u_net_vc_x64_custom.dll"] = new(257024, "f707ee1d13ed5d3264a6b95dbb6cc4cd79e5d663180a91dca80704b1d97783eb"),
            ["postgresql/bin/wxbase3211u_vc_x64_custom.dll"] = new(2985472, "cc6b32bb8cbc1ecd798a8e08144671bb0542e75217ee5b0f9a76fab9146b88be"),
            ["postgresql/bin/wxbase3211u_xml_vc_x64_custom.dll"] = new(193024, "4c716cb9407ed90331d677b55e82b3e31a16ff6f5adf9493321594d01fa200d3"),
            ["postgresql/bin/wxmsw3211u_adv_vc_x64_custom.dll"] = new(11264, "e9b0906ec69d7656228f564596ae882a8d68f37b5021f490ebcf2aae289eb742"),
            ["postgresql/bin/wxmsw3211u_aui_vc_x64_custom.dll"] = new(594944, "ded33cdf2455389eaef3e9c2bd6bca04d3edfbea9e7f53393ee6f8bab2ae124c"),
            ["postgresql/bin/wxmsw3211u_core_vc_x64_custom.dll"] = new(8352768, "d658d50d6820d17ac4de22bd66b93799595d63c7469ca6a1d99f479a838b67b8"),
            ["postgresql/bin/wxmsw3211u_html_vc_x64_custom.dll"] = new(708096, "74b2e9f9f4b690b554733f1be1e4412c27ea5e0b0a6cd67d05e3895eafb2946e"),
            ["postgresql/bin/wxmsw3211u_xrc_vc_x64_custom.dll"] = new(886784, "24bb563eaed37c5b87d238fab8183eac8f66dbf4c67b06c2b9fa54a1234e020f")
        };

    internal static Dictionary<string, PayloadMember> SelectPinnedResidue(string root,
        IReadOnlySet<string> listed, IReadOnlyDictionary<string, PayloadMember> pins)
    {
        var selected = new Dictionary<string, PayloadMember>(StringComparer.OrdinalIgnoreCase);
        foreach (var (relative, member) in pins)
        {
            if (!SafeRelativePath(relative)) throw Failure("PAYLOAD_MANIFEST_INVALID");
            if (listed.Contains(relative)) continue;
            var path = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
            if (!path.StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar,
                    StringComparison.OrdinalIgnoreCase)) throw Failure("PAYLOAD_MANIFEST_INVALID");
            AssertNoReparseAncestors(path);
            if (!File.Exists(path)) continue;
            using var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length != member.Length || Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant() != member.Sha256)
                throw Failure("PAYLOAD_OBSOLETE_HASH_INVALID");
            selected.Add(relative, member);
        }
        return selected;
    }

    private static Dictionary<string, PayloadMember> PresentLegacyResidue(IEnumerable<string>? alreadyApproved = null)
    {
        var manifestPath = Path.Combine(Payload, "payload-manifest.json");
        AssertNoReparseAncestors(manifestPath);
        AssertTrustedPayloadAcl(manifestPath);
        using var manifest = JsonDocument.Parse(File.ReadAllBytes(manifestPath));
        var listed = manifest.RootElement.GetProperty("verifiedFiles").EnumerateArray()
            .Select(entry => entry.GetProperty("path").GetString() ?? throw Failure("PAYLOAD_MANIFEST_INVALID"))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (alreadyApproved is not null) listed.UnionWith(alreadyApproved);
        return SelectPinnedResidue(Payload, listed, LegacyPg1615Residue);
    }
    internal static void RecordMaintenanceFailure(string operation, Exception exception)
    {
        try
        {
            if (!Directory.Exists(Installer)) return;
            AssertNoReparseAncestors(Installer); AssertPrivateAcl(Installer);
            var directory = Path.Combine(Installer, "ProvisioningDiagnostics");
            SetDirectoryAcl(directory, Administrators, []);
            WritePrivate(Path.Combine(directory, "native-maintenance-" + Guid.NewGuid().ToString("N") + ".json"),
                JsonSerializer.SerializeToUtf8Bytes(new { timestampUtc = DateTimeOffset.UtcNow, operation,
                    failureCode = System.Text.RegularExpressions.Regex.IsMatch(exception.Message, "\\AHOST_NATIVE_[A-Z0-9_]{1,96}\\z") ? exception.Message : "HOST_NATIVE_MAINTENANCE_FAILED",
                    nativeExecutable = (exception as NativeProcessException)?.ExecutableName,
                    nativeExitCode = (exception as NativeProcessException)?.ExitCode,
                    sqlState = (exception as NativeProcessException)?.SqlState,
                    win32Error = (exception as System.ComponentModel.Win32Exception)?.NativeErrorCode }), []);
        }
        catch { }
    }
    private const string PolicyEntropy = "Ventio Host service recovery policy snapshot v1";
    private sealed record PolicySnapshot(int formatVersion, string operationId, string serviceName, string serviceStartName, string servicePathName, string createdAtUtc, RecoveryPolicy originalPolicy);
    private sealed record BackupMember(string path, long bytes, string sha256);

    internal static async Task PrepareUpgradeAsync()
    {
        ValidateInstalledServices(requireHost: true);
        using var maintenance = MaintenanceLock();
        // Preserve the verified installed inventory before Inno replaces its
        // manifest. Known 16.15 residue is pinned independently above.
        using (var installedPayload = PinPayload(Payload, PresentLegacyResidue(), allowPreviousPostgres: true))
        {
            if (File.Exists(PreviousPayloadManifestPath)) throw Failure("PAYLOAD_PREVIOUS_MANIFEST_PENDING");
            var bytes = File.ReadAllBytes(Path.Combine(Payload, "payload-manifest.json"));
            if (bytes.Length is < 1 or > 1_048_576) throw Failure("PAYLOAD_MANIFEST_INVALID");
            SetDirectoryAcl(Installer, Administrators, []);
            WritePrivate(PreviousPayloadManifestPath, bytes, []);
        }
        var snapshot = ReadPolicySnapshot();
        if (snapshot is null)
        {
            var original = RecoveryNative.Query(HostService);
            ValidateRecoveryPolicy(original);
            snapshot = new(1, Guid.NewGuid().ToString("N"), HostService, "NT SERVICE\\" + HostService,
                Quote(Path.Combine(Payload, "VentioHostService.exe")), DateTimeOffset.UtcNow.ToString("O"), original);
            SetDirectoryAcl(Installer, Administrators, []);
            var bytes = Program.ProtectForLocalMachine(JsonSerializer.SerializeToUtf8Bytes(snapshot), Encoding.UTF8.GetBytes(PolicyEntropy));
            WritePrivate(PolicyPath, bytes, []);
        }
        var current = RecoveryNative.Query(HostService);
        if (!PolicyEqual(current, snapshot.originalPolicy) && !Suppressed(current)) throw Failure("SERVICE_RECOVERY_POLICY_CONFLICT");
        var disabled = new RecoveryPolicy(snapshot.originalPolicy.ResetPeriod, snapshot.originalPolicy.RebootMessage,
            snapshot.originalPolicy.Command, [new RecoveryAction(0, 0)], false);
        RecoveryNative.Change(HostService, disabled);
        if (!Suppressed(RecoveryNative.Query(HostService))) throw Failure("SERVICE_RECOVERY_SUPPRESSION_FAILED");
        try
        {
            var quietSeconds = Math.Max(2, snapshot.originalPolicy.Actions.Where(a => a.Type == 1).Select(a => (int)Math.Ceiling(a.Delay / 1000.0) + 3).DefaultIfEmpty(2).Max());
            var deadline = DateTime.UtcNow.AddSeconds(Math.Max(120, (quietSeconds + 2) * 4));
            DateTime? stable = null;
            while (true)
            {
                var state = ServiceState(HostService);
                if (state == 4) { await ScAsync("stop", HostService); stable = null; }
                else if (state == 1) { stable ??= DateTime.UtcNow.AddSeconds(quietSeconds); if (DateTime.UtcNow >= stable) break; }
                else if (state is null or > 7) throw Failure("SERVICE_RECOVERY_STATE_INVALID");
                else stable = null;
                if (DateTime.UtcNow >= deadline) throw Failure("SERVICE_RECOVERY_DRAIN_TIMEOUT");
                await Task.Delay(250);
            }
            await StopServiceAsync(PgService);
        }
        catch { RestoreRecoveryPolicy(); throw; }
    }

    internal static async Task ResumeUpgradeAsync(bool includeHost)
    {
        ValidateInstalledServices(requireHost: true);
        using var maintenance = MaintenanceLock();
        await StartServiceAsync(PgService);
        if (includeHost)
        {
            // An ambiguous schema request can only be reconciled by the upgrade
            // coordinator. Never restart Host from an installer-abort fallback.
            if (File.Exists(Path.Combine(HostDirectory, "schema-upgrade.request.dpapi"))) throw Failure("SCHEMA_UPGRADE_RECONCILIATION_REQUIRED");
            await StartServiceAsync(HostService);
        }
        RestoreRecoveryPolicy();
        if (includeHost && File.Exists(PreviousPayloadManifestPath))
        {
            AssertNoReparseAncestors(PreviousPayloadManifestPath);
            AssertPrivateAcl(PreviousPayloadManifestPath);
            File.Delete(PreviousPayloadManifestPath);
        }
    }

    internal static async Task CompleteUpgradeAsync()
    {
        ValidateInstalledServices(requireHost: true);
        using var maintenance = MaintenanceLock();
        var snapshot = ReadPolicySnapshot() ?? throw Failure("SERVICE_RECOVERY_SNAPSHOT_MISSING");
        if (!Suppressed(RecoveryNative.Query(HostService)) || ServiceState(HostService) != 1 || ServiceState(PgService) != 1)
            throw Failure("UPGRADE_SERVICES_MUST_BE_STOPPED");
        var obsolete = ReadObsoletePayloadMembers();
        // The previous manifest may approve a different 16.15 build of the
        // same file; its own verified hash takes precedence over this residue list.
        foreach (var (relative, member) in PresentLegacyResidue(obsolete.Keys))
            if (!obsolete.TryAdd(relative, member) && obsolete[relative] != member)
                throw Failure("PAYLOAD_OBSOLETE_HASH_INVALID");
        // Verify every new member and every old-only member before changing
        // anything. An unknown or modified file remains a hard failure.
        using (var verifiedBeforeCleanup = PinPayload(Payload, obsolete)) { }
        foreach (var (relative, member) in obsolete)
        {
            var path = Path.Combine(Payload, relative.Replace('/', Path.DirectorySeparatorChar));
            AssertNoReparseAncestors(path);
            AssertTrustedPayloadAcl(path);
            using (var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                if (stream.Length != member.Length || Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant() != member.Sha256)
                    throw Failure("PAYLOAD_OBSOLETE_HASH_INVALID");
            File.Delete(path);
        }
        using var verified = PinPayload(Payload);
        var password = ReadMigratorPassword();
        // Back up a stopped cluster before any schema/configuration mutation.
        // The authority witness deliberately stays in its original Host storage.
        CreateStoppedBackup("upgrade");
        var postgresConfig = Path.Combine(Data, "postgresql.conf");
        AssertNoReparseAncestors(postgresConfig);
        var configuration = File.ReadAllText(postgresConfig);
        if (!configuration.Contains("# Ventio Recovery Authority upgrade coordinator v1", StringComparison.Ordinal))
        {
            var temp = postgresConfig + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllText(temp, configuration + "\n# Ventio Recovery Authority upgrade coordinator v1\nmax_prepared_transactions = 1\n", new UTF8Encoding(false));
                new FileInfo(temp).SetAccessControl(new FileInfo(postgresConfig).GetAccessControl());
                File.Move(temp, postgresConfig, true);
            }
            finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        await StartServiceAsync(PgService);
        var profile = await SqlAsync(password, "ventio_migrator_app", "ventio_host", "SELECT pg_has_role(session_user,'ventio_migrator','MEMBER')::text || ':' || rolsuper::text || ':' || rolcreatedb::text || ':' || rolcreaterole::text FROM pg_roles WHERE rolname=current_user");
        if (profile != "true:false:false:false") throw Failure("DATABASE_MIGRATOR_PROFILE_INVALID");
        var requestPath = Path.Combine(HostDirectory, "schema-upgrade.request.dpapi");
        var resultPath = Path.Combine(HostDirectory, "schema-upgrade.result.json");
        var operationId = "upgrade_" + Guid.NewGuid().ToString("N");
        var url = DatabaseUrl("ventio_migrator_app", password);
        if (File.Exists(requestPath))
        {
            var prior = ReadProtectedJson(requestPath, [ServiceSid(HostService)]);
            using (prior)
            {
                var value = prior.RootElement;
                if (value.GetProperty("formatVersion").GetInt32() != 1 || value.GetProperty("databaseUrl").GetString() != url ||
                    !System.Text.RegularExpressions.Regex.IsMatch(value.GetProperty("operationId").GetString() ?? "", "\\Aupgrade_[0-9a-f]{32}\\z")) throw Failure("SCHEMA_UPGRADE_REQUEST_PENDING");
                operationId = value.GetProperty("operationId").GetString()!;
            }
        }
        var hostSid = ServiceSid(HostService);
        ProtectFile(requestPath, JsonSerializer.SerializeToUtf8Bytes(new { formatVersion = 1, operationId, databaseUrl = url, createdAtUtc = DateTimeOffset.UtcNow.ToString("O") }), [hostSid], replace: File.Exists(requestPath));
        AssertNoReparseAncestors(resultPath);
        if (File.Exists(resultPath)) File.Delete(resultPath);
        try
        {
            await ScAsync("start", HostService);
            var deadline = DateTime.UtcNow.AddMinutes(20);
            var completed = false;
            while (DateTime.UtcNow < deadline)
            {
                if (File.Exists(resultPath))
                {
                    AssertNoReparseAncestors(resultPath);
                    using var result = JsonDocument.Parse(File.ReadAllBytes(resultPath));
                    var r = result.RootElement;
                    if (r.GetProperty("operationId").GetString() != operationId) throw Failure("SCHEMA_UPGRADE_RESULT_INVALID");
                    if (r.GetProperty("status").GetString() is "failed" or "unknown") throw Failure("SCHEMA_UPGRADE_FAILED_OR_UNKNOWN");
                    completed = r.GetProperty("status").GetString() == "complete" && !File.Exists(requestPath);
                }
                if (completed && ServiceState(HostService) == 4) break;
                if (ServiceState(HostService) == 1) throw Failure("SCHEMA_UPGRADE_SERVICE_FAILED");
                await Task.Delay(500);
            }
            if (!completed || ServiceState(HostService) != 4) throw Failure("SCHEMA_UPGRADE_TIMEOUT");
            var ledger = await SqlAsync(password, "ventio_migrator_app", "ventio_host", "SET ROLE ventio_owner; SELECT count(*) FROM public.ventio_schema_migrations");
            var count = ledger.Split('\n').Last().Trim();
            if (count != Directory.GetFiles(Path.Combine(Payload, "migrations"), "*.sql").Length.ToString(System.Globalization.CultureInfo.InvariantCulture)) throw Failure("DATABASE_MIGRATION_LEDGER_INVALID");
            await StopServiceAsync(HostService);
            await ConfigureUpgradedLanAsync();
            await StartServiceAsync(HostService);
            RestoreRecoveryPolicy();
            File.Delete(resultPath);
            AssertNoReparseAncestors(PreviousPayloadManifestPath);
            AssertPrivateAcl(PreviousPayloadManifestPath);
            File.Delete(PreviousPayloadManifestPath);
        }
        catch
        {
            // Preserve pending request/result and policy snapshot for explicit
            // reconciliation. Host must remain stopped after an unknown result.
            await StopServiceAsync(HostService);
            throw;
        }
    }

    private static Dictionary<string, PayloadMember> ReadObsoletePayloadMembers()
    {
        AssertNoReparseAncestors(PreviousPayloadManifestPath);
        AssertPrivateAcl(PreviousPayloadManifestPath);
        if (new FileInfo(PreviousPayloadManifestPath).Length is < 1 or > 1_048_576) throw Failure("PAYLOAD_MANIFEST_INVALID");
        using var previous = JsonDocument.Parse(File.ReadAllBytes(PreviousPayloadManifestPath));
        var currentPath = Path.Combine(Payload, "payload-manifest.json");
        AssertNoReparseAncestors(currentPath);
        AssertTrustedPayloadAcl(currentPath);
        using var current = JsonDocument.Parse(File.ReadAllBytes(currentPath));
        return ComputeObsoletePayloadMembers(previous.RootElement, current.RootElement);
    }

    internal static Dictionary<string, PayloadMember> ComputeObsoletePayloadMembers(JsonElement previous, JsonElement current)
    {
        static Dictionary<string, PayloadMember> Index(JsonElement root)
        {
            if (root.GetProperty("formatVersion").GetInt32() != 1 ||
                root.GetProperty("credentialsIncluded").GetBoolean() || root.GetProperty("databaseIncluded").GetBoolean())
                throw Failure("PAYLOAD_MANIFEST_INVALID");
            var files = new Dictionary<string, PayloadMember>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in root.GetProperty("verifiedFiles").EnumerateArray())
            {
                var relative = entry.GetProperty("path").GetString() ?? "";
                var length = entry.GetProperty("length").GetInt64();
                var sha256 = entry.GetProperty("sha256").GetString() ?? "";
                if (!SafeRelativePath(relative) || relative.Equals("payload-manifest.json", StringComparison.OrdinalIgnoreCase) ||
                    length < 0 || !System.Text.RegularExpressions.Regex.IsMatch(sha256, "\\A[0-9a-f]{64}\\z") ||
                    !files.TryAdd(relative, new PayloadMember(length, sha256))) throw Failure("PAYLOAD_MANIFEST_INVALID");
            }
            if (files.Count < 1 || files.Count > 20_000 || files.Count != root.GetProperty("payloadFileCount").GetInt32())
                throw Failure("PAYLOAD_MANIFEST_INVALID");
            return files;
        }
        var oldFiles = Index(previous);
        var newFiles = Index(current);
        foreach (var required in new[] { "VentioSetupBroker.exe", "VentioHostService.exe", "ventio_host.exe", "ventio_migrate.exe", "postgresql/bin/postgres.exe" })
            if (!newFiles.ContainsKey(required)) throw Failure("PAYLOAD_INCOMPLETE");
        return oldFiles.Where(pair => !newFiles.ContainsKey(pair.Key)).ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
    }

    private static async Task ConfigureUpgradedLanAsync()
    {
        if (ServiceState(HostService) != 1) throw Failure("LAN_HOST_SERVICE_MUST_BE_STOPPED");
        var hostSid = ServiceSid(HostService);
        var path = Path.Combine(HostDirectory, "service-config.dpapi");
        AssertNoReparseAncestors(path); AssertPrivateAcl(path, [hostSid]);
        var encrypted = File.ReadAllBytes(path); byte[]? clear = null;
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            clear = Program.UnprotectForCurrentUser(encrypted, []);
            foreach (var line in Encoding.UTF8.GetString(clear).Split('\n'))
            {
                var clean = line.TrimEnd('\r'); if (clean.Length == 0) continue;
                var separator = clean.IndexOf('=');
                if (separator < 1 || !values.TryAdd(clean[..separator], clean[(separator + 1)..]) || clean.Contains('\r')) throw Failure("LAN_CONFIGURATION_INVALID");
            }
        }
        finally { CryptographicOperations.ZeroMemory(encrypted); if (clear is not null) CryptographicOperations.ZeroMemory(clear); }
        var allowed = new HashSet<string>(["VENTIO_HOST_DATABASE_URL", "VENTIO_HOST_IDENTITY_API_DATABASE_URL", "VENTIO_RECOVERY_AUTHORITY_FILE", "VENTIO_RECOVERY_AUTHORITY_HOST_WRITES", "VENTIO_RECOVERY_AUTHORITY_OWNER_SID", "VENTIO_RECOVERY_AUTHORITY_READER_SID", "VENTIO_HOST_DIAGNOSTICS_FILE", "VENTIO_HOST_BIND_ADDRESS", "VENTIO_HOST_PORT", "VENTIO_HOST_LAN_BIND_ADDRESS", "VENTIO_HOST_LAN_PORT", "VENTIO_HOST_TLS_CERTIFICATE_FILE", "VENTIO_HOST_TLS_PRIVATE_KEY_FILE"]);
        if (values.Keys.Any(key => !allowed.Contains(key)) || values.GetValueOrDefault("VENTIO_HOST_BIND_ADDRESS") != "127.0.0.1" || values.GetValueOrDefault("VENTIO_HOST_PORT") != "8080" ||
            values.GetValueOrDefault("VENTIO_RECOVERY_AUTHORITY_HOST_WRITES") != "yes" || values.GetValueOrDefault("VENTIO_RECOVERY_AUTHORITY_OWNER_SID") != hostSid.Value || values.GetValueOrDefault("VENTIO_RECOVERY_AUTHORITY_READER_SID") != hostSid.Value ||
            values.GetValueOrDefault("VENTIO_RECOVERY_AUTHORITY_FILE") != Path.Combine(HostDirectory, "recovery.witness")) throw Failure("LAN_CONFIGURATION_INVALID");
        if (values.ContainsKey("VENTIO_HOST_LAN_BIND_ADDRESS") && (values["VENTIO_HOST_LAN_BIND_ADDRESS"] != "0.0.0.0" || values.GetValueOrDefault("VENTIO_HOST_LAN_PORT") != "8443")) throw Failure("LAN_CONFIGURATION_CONFLICT");
        var profiles = TrustedFirewallProfiles(allowExisting: true);
        await RunAsync(Path.Combine(Payload, "VentioHostService.exe"), ["--provision-lan-certificate"]);
        EnsureFirewallRule(profiles, allowExisting: true);
        values["VENTIO_HOST_LAN_BIND_ADDRESS"] = "0.0.0.0"; values["VENTIO_HOST_LAN_PORT"] = "8443";
        values["VENTIO_HOST_TLS_CERTIFICATE_FILE"] = Path.Combine(HostDirectory, "host-lan-certificate.pem");
        values["VENTIO_HOST_TLS_PRIVATE_KEY_FILE"] = Path.Combine(HostDirectory, "host-lan-private-key.pem");
        ProtectFile(path, ConfigurationBytes(values), [hostSid], replace: true);
        values.Clear();
    }

    private static string CreateStoppedBackup(string kind)
    {
        if (ServiceState(PgService) != 1 || ServiceState(HostService) != 1) throw Failure("BACKUP_SERVICES_MUST_BE_STOPPED");
        var backupDirectory = Path.Combine(Product, "Backups");
        if (Directory.Exists(backupDirectory)) AssertPrivateAcl(backupDirectory);
        else SetDirectoryAcl(backupDirectory, Administrators, []);
        var name = "ventio-postgresql-before-upgrade-" + DateTime.UtcNow.ToString("yyyyMMddTHHmmssfffZ", System.Globalization.CultureInfo.InvariantCulture) + "-" + Guid.NewGuid().ToString("N");
        var partial = Path.Combine(backupDirectory, name + ".partial");
        var destination = Path.Combine(backupDirectory, name);
        SetDirectoryAcl(partial, Administrators, []);
        var files = Inventory(Data);
        if (new DriveInfo(Path.GetPathRoot(backupDirectory)!).AvailableFreeSpace < files.Sum(x => x.bytes) + 67108864) throw Failure("BACKUP_DISK_SPACE_INSUFFICIENT");
        var target = Path.Combine(partial, "data");
        SetDirectoryAcl(target, Administrators, []);
        foreach (var member in files)
        {
            var source = Path.Combine(Data, member.path.Replace('/', Path.DirectorySeparatorChar));
            var file = Path.Combine(target, member.path.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            using var input = File.Open(source, FileMode.Open, FileAccess.Read, FileShare.Read);
            using var output = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.WriteThrough);
            input.CopyTo(output); output.Flush(true);
        }
        var actual = Inventory(target);
        if (!files.SequenceEqual(actual)) throw Failure("BACKUP_CONTENT_MISMATCH");
        using var machineKey = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography");
        var manifest = JsonSerializer.SerializeToUtf8Bytes(new {
            formatVersion = 2, integrityAlgorithm = "SHA-256", backupKind = kind,
            machineId = machineKey?.GetValue("MachineGuid") as string ?? throw Failure("MACHINE_ID_UNAVAILABLE"),
            schemaProfileSha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Path.Combine(Payload, "security", "schema_profile.sql")))).ToLowerInvariant(),
            files, recoveryAuthorityIncluded = false, createdAtUtc = DateTimeOffset.UtcNow.ToString("O"),
            postgresVersion = "16.16", dataDirectory = "data", fileCount = files.Length, bytes = files.Sum(x => x.bytes)
        });
        WritePrivate(Path.Combine(partial, "backup-manifest.json"), manifest, []);
        Directory.Move(partial, destination);
        return destination;
    }
    private static BackupMember[] Inventory(string root)
    {
        AssertNoReparseAncestors(root);
        var pending = new Stack<string>(); pending.Push(root);
        var files = new List<BackupMember>();
        while (pending.TryPop(out var directory))
        {
            foreach (var path in Directory.EnumerateFileSystemEntries(directory))
            {
                AssertNoReparseAncestors(path);
                if (Directory.Exists(path)) pending.Push(path);
                else
                {
                    if (files.Count >= 500000) throw Failure("BACKUP_FILE_LIMIT");
                    using var input = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read);
                    files.Add(new(Path.GetRelativePath(root, path).Replace('\\', '/'), input.Length, Convert.ToHexString(SHA256.HashData(input)).ToLowerInvariant()));
                }
            }
        }
        return files.OrderBy(f => f.path, StringComparer.Ordinal).ToArray();
    }

    private static void ValidateInstalledServices(bool requireHost)
    {
        RequireAdministrator();
        AssertNoReparseAncestors(Data); AssertNoReparseAncestors(HostDirectory); AssertNoReparseAncestors(Installer);
        VerifyService(PgService, Pg("pg_ctl.exe"), Data);
        if (requireHost) VerifyService(HostService, Path.Combine(Payload, "VentioHostService.exe"), null);
        if (File.ReadAllText(Path.Combine(Data, "PG_VERSION")).Trim() != "16") throw Failure("CLUSTER_VERSION_INVALID");
    }
    private static async Task StopServiceAsync(string name)
    {
        var deadline = DateTime.UtcNow.AddSeconds(120);
        while (ServiceState(name) != 1)
        {
            if (ServiceState(name) == 4) await ScAsync("stop", name);
            if (DateTime.UtcNow >= deadline) throw Failure("SERVICE_STOP_TIMEOUT");
            await Task.Delay(250);
        }
    }
    private static async Task StartServiceAsync(string name)
    {
        if (ServiceState(name) == 1) await ScAsync("start", name);
        await WaitServiceAsync(name, 4);
    }
    private static string ReadMigratorPassword()
    {
        using var document = ReadProtectedJson(Path.Combine(Installer, "migration-credential.dpapi"));
        var root = document.RootElement;
        var password = root.GetProperty("password").GetString() ?? "";
        if (root.EnumerateObject().Count() != 3 || root.GetProperty("formatVersion").GetInt32() != 1 || root.GetProperty("username").GetString() != "ventio_migrator_app" || !System.Text.RegularExpressions.Regex.IsMatch(password, "\\A[A-Za-z0-9_-]{43}\\z")) throw Failure("MIGRATION_CREDENTIAL_INVALID");
        return password;
    }
    private static JsonDocument ReadProtectedJson(string path, SecurityIdentifier[]? readers = null)
    {
        AssertNoReparseAncestors(path); AssertPrivateAcl(path, readers);
        var encrypted = File.ReadAllBytes(path); byte[]? plain = null;
        try
        {
            plain = Program.UnprotectForCurrentUser(encrypted, []);
            using var stream = new MemoryStream(plain, writable: false);
            return JsonDocument.Parse(stream);
        }
        finally { CryptographicOperations.ZeroMemory(encrypted); if (plain is not null) CryptographicOperations.ZeroMemory(plain); }
    }
    private static PolicySnapshot? ReadPolicySnapshot()
    {
        AssertNoReparseAncestors(PolicyPath);
        if (!File.Exists(PolicyPath)) return null;
        AssertPrivateAcl(PolicyPath);
        var bytes = File.ReadAllBytes(PolicyPath); var entropy = Encoding.UTF8.GetBytes(PolicyEntropy); byte[]? plain = null;
        try
        {
            plain = Program.UnprotectForCurrentUser(bytes, entropy);
            var snapshot = JsonSerializer.Deserialize<PolicySnapshot>(plain) ?? throw Failure("SERVICE_RECOVERY_SNAPSHOT_INVALID");
            if (snapshot.formatVersion != 1 || snapshot.serviceName != HostService || snapshot.serviceStartName != "NT SERVICE\\" + HostService || snapshot.servicePathName != Quote(Path.Combine(Payload, "VentioHostService.exe")) || !Guid.TryParseExact(snapshot.operationId, "N", out _)) throw Failure("SERVICE_RECOVERY_IDENTITY_CONFLICT");
            ValidateRecoveryPolicy(snapshot.originalPolicy);
            return snapshot;
        }
        finally { CryptographicOperations.ZeroMemory(bytes); CryptographicOperations.ZeroMemory(entropy); if (plain is not null) CryptographicOperations.ZeroMemory(plain); }
    }
    private static void RestoreRecoveryPolicy()
    {
        var snapshot = ReadPolicySnapshot(); if (snapshot is null) return;
        var current = RecoveryNative.Query(HostService);
        if (Suppressed(current)) RecoveryNative.Change(HostService, snapshot.originalPolicy);
        else if (!PolicyEqual(current, snapshot.originalPolicy)) throw Failure("SERVICE_RECOVERY_POLICY_CONFLICT");
        if (!PolicyEqual(RecoveryNative.Query(HostService), snapshot.originalPolicy)) throw Failure("SERVICE_RECOVERY_RESTORE_FAILED");
        File.Delete(PolicyPath);
    }
    private static void ValidateRecoveryPolicy(RecoveryPolicy policy)
    {
        if (policy.Actions is null || policy.Actions.Length > 64 || policy.Actions.Any(a => a.Type is not (0 or 1) || a.Delay > 300000)) throw Failure("SERVICE_RECOVERY_POLICY_UNSUPPORTED");
    }
    private static bool Suppressed(RecoveryPolicy policy) => !policy.FailureActionsOnNonCrashFailures && policy.Actions.All(a => a.Type == 0);
    private static bool PolicyEqual(RecoveryPolicy a, RecoveryPolicy b) => a.ResetPeriod == b.ResetPeriod && (a.Command ?? "") == (b.Command ?? "") && (a.RebootMessage ?? "") == (b.RebootMessage ?? "") && a.FailureActionsOnNonCrashFailures == b.FailureActionsOnNonCrashFailures && a.Actions.Select(x => (x.Type, x.Delay)).SequenceEqual(b.Actions.Select(x => (x.Type, x.Delay)));
    private static IDisposable MaintenanceLock()
    {
        return new MaintenanceLease();
    }
    // Windows mutex ownership is thread-affine. A dedicated thread holds the
    // existing maintenance mutex while asynchronous SQL/service waits continue.
    private sealed class MaintenanceLease : IDisposable
    {
        private readonly ManualResetEventSlim ready = new();
        private readonly ManualResetEventSlim release = new();
        private readonly Thread thread;
        private Exception? error;
        internal MaintenanceLease()
        {
            thread = new Thread(Hold) { IsBackground = true, Name = "Ventio native maintenance lease" };
            thread.Start(); ready.Wait();
            if (error is not null) { Dispose(); throw Failure("MAINTENANCE_BUSY_OR_UNAVAILABLE"); }
        }
        private void Hold()
        {
            try
            {
                if (!ConvertStringSecurityDescriptorToSecurityDescriptorW("O:BAG:BAD:P(A;;GA;;;BA)(A;;GA;;;SY)", 1, out var descriptor, out _)) throw Failure("MAINTENANCE_ACL_INVALID");
                Microsoft.Win32.SafeHandles.SafeWaitHandle handle;
                try
                {
                    var attributes = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Descriptor = descriptor };
                    handle = CreateMutexW(ref attributes, false, @"Global\VentioHostDatabaseMaintenance");
                }
                finally { LocalFree(descriptor); }
                if (handle.IsInvalid) { handle.Dispose(); throw Failure("MAINTENANCE_MUTEX_UNAVAILABLE"); }
                using var mutex = new Mutex(false);
                mutex.SafeWaitHandle.Dispose(); mutex.SafeWaitHandle = handle;
                bool held; try { held = mutex.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
                if (!held) throw Failure("MAINTENANCE_BUSY");
                ready.Set();
                try { release.Wait(); }
                finally { mutex.ReleaseMutex(); }
            }
            catch (Exception exception) { error = exception; ready.Set(); }
        }
        public void Dispose() { release.Set(); thread.Join(); release.Dispose(); ready.Dispose(); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { public int Length; public IntPtr Descriptor; public int InheritHandle; }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string value, uint revision, out IntPtr descriptor, out uint size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern Microsoft.Win32.SafeHandles.SafeWaitHandle CreateMutexW(ref SecurityAttributes attributes, bool initialOwner, string name);
}
