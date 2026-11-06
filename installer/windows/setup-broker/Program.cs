using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Ventio.HostSetupBroker;

internal static class Program
{
    private const string FirstAdminPipeName = "Ventio.Host.FirstAdmin.v1";
    private static readonly JsonSerializerOptions PipeJsonOptions = new(JsonSerializerDefaults.Web);
    private static readonly HashSet<string> AllowedPhases = new(StringComparer.Ordinal)
    {
        "PAYLOAD_VALIDATION",
        "POSTGRES_SERVICE_PROVISIONING",
        "DATABASE_INITIALIZATION",
        "MIGRATION_CREDENTIAL_PROTECTION",
        "HOST_SERVICE_REGISTRATION",
        "HOST_CONFIGURATION_PROTECTION",
        "HOST_LAN_CONFIGURATION",
        "HOST_SERVICE_STARTUP",
        "HOST_READINESS",
        "FIRST_ADMINISTRATOR_BOOTSTRAP",
        "BOOTSTRAP_CREDENTIAL_PROTECTION"
    };

    private static readonly string[] SafeFailureCodes =
    {
        "HOST_EXISTING_SERVICES_REQUIRE_RECOVERY",
        "HOST_EXISTING_DATA_REQUIRES_REPAIR",
        "HOST_PARTIAL_SERVICE_INSTALLATION",
        "HOST_SERVICE_IDENTITY_CONFLICT",
        "HOST_DATABASE_MIGRATION_LEDGER_INVALID",
        "HOST_INSTALL_ADMIN_ELEVATION_REQUIRED",
        "HOST_SETUP_REQUESTER_IDENTITY_MISMATCH",
        "HOST_SETUP_SCRIPT_HASH_INVALID",
        "HOST_SETUP_PAYLOAD_MANIFEST_INVALID",
        "HOST_FIRST_ADMINISTRATOR_FAILED",
        "HOST_FIRST_ADMIN_REQUEST_INVALID",
        "HOST_FIRST_ADMIN_DATABASE_CONNECTION_FAILED",
        "HOST_FIRST_ADMIN_RECOVERY_AUTHORITY_FAILED",
        "HOST_FIRST_ADMIN_IDENTITY_BOOTSTRAP_FAILED",
        "HOST_FIRST_ADMIN_HELPER_TIMEOUT",
        "HOST_FIRST_ADMIN_RESULT_INVALID",
        "HOST_FIRST_ADMIN_PIPE_CONNECT_FAILED",
        "HOST_FIRST_ADMIN_PIPE_SERVER_INVALID",
        "HOST_FIRST_ADMIN_PIPE_RESPONSE_INVALID",
        "HOST_BOOTSTRAP_RESULT_PROTECTION_FAILED",
        "HOST_BOOTSTRAP_ACKNOWLEDGEMENT_FAILED",
        "HOST_TRUSTED_PAIRING_PERMISSION_NOT_GRANTED",
        "HOST_TRUSTED_PAIRING_TARGET_UNAVAILABLE",
        "HOST_TRUSTED_PAIRING_CODE_UNAVAILABLE",
        "HOST_TRUSTED_PAIRING_RATE_LIMITED",
        "HOST_TRUSTED_PAIRING_RECOVERY_UNAVAILABLE",
        "HOST_TRUSTED_PAIRING_RECOVERY_BUSY",
        "HOST_TRUSTED_PAIRING_OUTCOME_UNKNOWN",
        "HOST_TRUSTED_PAIRING_REQUEST_USED",
        "HOST_TRUSTED_PAIRING_FAILED",
        "HOST_TRUSTED_PAIRING_REQUEST_INVALID",
        "HOST_TRUSTED_PAIRING_CONFIGURATION_INVALID",
        "HOST_TRUSTED_PAIRING_RESULT_INVALID",
        "HOST_TRUSTED_REISSUE_PERMISSION_NOT_GRANTED",
        "HOST_TRUSTED_REISSUE_TARGET_UNAVAILABLE",
        "HOST_TRUSTED_REISSUE_REFERENCE_CONFLICT",
        "HOST_TRUSTED_REISSUE_ALREADY_PENDING",
        "HOST_TRUSTED_REISSUE_RECOVERY_UNAVAILABLE",
        "HOST_TRUSTED_REISSUE_RECOVERY_BUSY",
        "HOST_TRUSTED_REISSUE_OUTCOME_UNKNOWN",
        "HOST_TRUSTED_REISSUE_FAILED",
        "HOST_TRUSTED_REISSUE_REQUEST_INVALID",
        "HOST_TRUSTED_REISSUE_UAC_CANCELLED",
        "HOST_TRUSTED_REISSUE_CONFIGURATION_INVALID",
        "HOST_TRUSTED_REISSUE_RESULT_INVALID"
    };

    [STAThread]
    private static int Main(string[] args)
    {
        Request request;
        try
        {
            request = Request.Parse(args);
        }
        catch (ArgumentException)
        {
            return 2;
        }

        try
        {
            using var mutex = new Mutex(false, @"Global\Ventio.HostSetup.v1");
            var ownsMutex = false;
            try
            {
                try { ownsMutex = mutex.WaitOne(0); }
                catch (AbandonedMutexException) { ownsMutex = true; }
                if (!ownsMutex)
                {
                    TryWriteStatus(request, "failed", "HOST_SETUP_ALREADY_RUNNING", null);
                    return 6;
                }
                return RunAsync(request).GetAwaiter().GetResult();
            }
            finally
            {
                if (ownsMutex) mutex.ReleaseMutex();
            }
        }
        catch
        {
            TryWriteStatus(request, "failed", "HOST_SETUP_PROVISIONING_FAILED", null);
            return 5;
        }
    }

    private static async Task<int> RunAsync(Request request)
    {
        if (!IsAdministrator())
        {
            TryWriteStatus(request, "failed", "HOST_SETUP_ADMIN_ELEVATION_REQUIRED", null);
            return 3;
        }

        using (var identity = WindowsIdentity.GetCurrent())
        {
            if (!StringComparer.Ordinal.Equals(identity.User?.Value, request.RequesterSid))
            {
                TryWriteStatus(request, "failed", "HOST_SETUP_REQUESTER_IDENTITY_MISMATCH", null);
                return 9;
            }
        }

        WriteStatus(request, "running", null, "PAYLOAD_VALIDATION");
        var paths = GetValidatedPaths();
        if (request.TrustedCredentialReissue)
            return CompleteTrustedCredentialReissue(request);
        if (request.TrustedPairing)
            return CompleteTrustedPairing(request);
        if (request.ResumeFirstAdministrator)
            return CompleteFirstAdministrator(request);

        var startInfo = new ProcessStartInfo
        {
            FileName = paths.PowerShell,
            WorkingDirectory = paths.PayloadDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(paths.ProvisioningScript);
        startInfo.ArgumentList.Add("-PayloadDirectory");
        startInfo.ArgumentList.Add(paths.PayloadDirectory);
        startInfo.ArgumentList.Add("-Apply");
        startInfo.ArgumentList.Add("-NewHostOnly");
        startInfo.Environment["PATH"] = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System));

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        if (!process.Start())
        {
            WriteStatus(request, "failed", "HOST_SETUP_PROCESS_START_FAILED", null);
            return 4;
        }

        var stderrTask = process.StandardError.ReadToEndAsync();
        var progress = new SetupProgress();
        var stdoutTask = ReadProgressAsync(process.StandardOutput, request, progress);
        var processExit = process.WaitForExitAsync();
        while (!processExit.IsCompleted)
        {
            var completed = await Task.WhenAny(processExit, Task.Delay(TimeSpan.FromSeconds(5))).ConfigureAwait(false);
            if (completed == processExit) break;
            WriteStatus(request, "running", null, progress.CurrentPhase);
        }
        await processExit.ConfigureAwait(false);
        await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);

        if (process.ExitCode == 0)
        {
            return CompleteFirstAdministrator(request);
        }

        var safeFailure = SafeFailureCodes.FirstOrDefault(code =>
            stderr.Contains(code, StringComparison.Ordinal));
        WriteStatus(request, "failed", safeFailure ?? "HOST_SETUP_PROVISIONING_FAILED", progress.CurrentPhase);
        return 5;
    }

    private static int CompleteFirstAdministrator(Request request)
    {
            WriteStatus(request, "running", null, "FIRST_ADMINISTRATOR_BOOTSTRAP");
            var reply = RequestFirstAdministrator(request);
            var existing = ReadProtectedBootstrapResult(request);
            if (reply is { Success: true, Status: "acknowledged", FailureCode: null } &&
                existing is not null && reply.RequestId == existing.RequestId)
            {
                WriteStatus(request, "complete", null, "HOST_READINESS");
                return 0;
            }
            if (reply is null || !reply.Success || reply.FailureCode is not null || reply.Status != "pending" ||
                reply.RequestId is null || reply.ActorId is null || reply.Token is null || reply.ExpiresAt is null ||
                !Regex.IsMatch(reply.RequestId, "^[A-Za-z0-9_-]{43}$", RegexOptions.CultureInvariant) ||
                !Regex.IsMatch(reply.ActorId, "^usr_[A-Za-z0-9_-]{43}$", RegexOptions.CultureInvariant) ||
                !Regex.IsMatch(reply.Token, "^[A-Za-z0-9_-]{43,128}$", RegexOptions.CultureInvariant) ||
                !DateTimeOffset.TryParse(reply.ExpiresAt, out _))
            {
                var failureCode = reply?.FailureCode is { } safeCode && IsSafeFailureCode(safeCode)
                    ? safeCode
                    : "HOST_FIRST_ADMINISTRATOR_FAILED";
                WriteStatus(request, "failed", failureCode, "FIRST_ADMINISTRATOR_BOOTSTRAP");
                return 7;
            }

            WriteStatus(request, "running", null, "BOOTSTRAP_CREDENTIAL_PROTECTION");
            if (existing is null) WriteProtectedBootstrapResult(request, reply);
            else if (existing.RequestId != reply.RequestId || existing.ActorId != reply.ActorId ||
                existing.Token != reply.Token || existing.ExpiresAt != reply.ExpiresAt)
                throw new InvalidOperationException("Protected bootstrap result differs from the service receipt.");
            if (!AcknowledgeFirstAdministrator(reply.RequestId))
            {
                WriteStatus(request, "failed", "HOST_BOOTSTRAP_ACKNOWLEDGEMENT_FAILED", "FIRST_ADMINISTRATOR_BOOTSTRAP");
                return 8;
            }

            WriteStatus(request, "complete", null, "HOST_READINESS");
            return 0;
    }

    private static async Task ReadProgressAsync(StreamReader output, Request request, SetupProgress progress)
    {
        while (await output.ReadLineAsync().ConfigureAwait(false) is { } line)
        {
            const string prefix = "HOST_SETUP_PHASE:";
            if (!line.StartsWith(prefix, StringComparison.Ordinal)) continue;
            var phase = line[prefix.Length..];
            if (AllowedPhases.Contains(phase))
            {
                progress.Update(phase);
                WriteStatus(request, "running", null, phase);
            }
        }
    }

    private static BootstrapReply? RequestFirstAdministrator(Request request)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new
        {
            operation = "bootstrap",
            tenantId = request.TenantId,
            companyId = request.CompanyId,
            branchId = request.BranchId
        }, PipeJsonOptions);
        return ExchangeFirstAdminPipe(bytes);
    }

    private static int CompleteTrustedPairing(Request request)
    {
        var safeFailure = "HOST_TRUSTED_PAIRING_FAILED";
        try
        {
            var input = ReadTrustedPairingRequest(request);
            var reply = RequestTrustedPairing(request, input);
            if (reply is not { Success: true, Status: "created", Pairing: not null } ||
                !MatchesTrustedPairingRequest(request, input, reply.Pairing))
            {
                safeFailure = reply?.FailureCode is { } code && IsSafeFailureCode(code)
                    ? code
                    : "HOST_TRUSTED_PAIRING_RESULT_INVALID";
                WriteProtectedTrustedPairingResult(request, null, safeFailure);
                WriteStatus(request, "failed", safeFailure, "PAYLOAD_VALIDATION");
                return 12;
            }

            WriteProtectedTrustedPairingResult(request, reply.Pairing, null);
            WriteStatus(request, "complete", null, "PAYLOAD_VALIDATION");
            return 0;
        }
        catch (TrustedPairingBrokerException exception)
        {
            safeFailure = exception.FailureCode;
        }
        catch
        {
            safeFailure = "HOST_TRUSTED_PAIRING_FAILED";
        }

        try
        {
            WriteProtectedTrustedPairingResult(request, null, safeFailure);
            WriteStatus(request, "failed", safeFailure, "PAYLOAD_VALIDATION");
        }
        catch { }
        return 12;
    }

    private static int CompleteTrustedCredentialReissue(Request request)
    {
        var failure = "HOST_TRUSTED_REISSUE_FAILED";
        try
        {
            var input = ReadTrustedCredentialReissueRequest(request);
            if (!ConfirmTrustedCredentialReissue(input))
            {
                failure = "HOST_TRUSTED_REISSUE_UAC_CANCELLED";
                WriteProtectedTrustedCredentialReissueResult(request, null, failure);
                WriteStatus(request, "failed", failure, "PAYLOAD_VALIDATION");
                return 12;
            }
            var reply = RequestTrustedCredentialReissue(request, input);
            if (reply is not { Success: true, Status: "created", CredentialReissue: not null } ||
                !MatchesTrustedCredentialReissueRequest(request, input, reply.CredentialReissue))
            {
                failure = reply?.FailureCode is { } code && IsSafeFailureCode(code)
                    ? code : "HOST_TRUSTED_REISSUE_RESULT_INVALID";
                WriteProtectedTrustedCredentialReissueResult(request, null, failure);
                WriteStatus(request, "failed", failure, "PAYLOAD_VALIDATION");
                return 12;
            }
            WriteProtectedTrustedCredentialReissueResult(request, reply.CredentialReissue, null);
            WriteStatus(request, "complete", null, "PAYLOAD_VALIDATION");
            return 0;
        }
        catch (TrustedPairingBrokerException exception) { failure = exception.FailureCode; }
        catch { failure = "HOST_TRUSTED_REISSUE_FAILED"; }
        try
        {
            WriteProtectedTrustedCredentialReissueResult(request, null, failure);
            WriteStatus(request, "failed", failure, "PAYLOAD_VALIDATION");
        }
        catch { }
        return 12;
    }

    private static bool ConfirmTrustedCredentialReissue(TrustedCredentialReissueRequestData input)
    {
        var permissions = string.Join("\r\n  ", input.Permissions);
        var removals = input.ApprovedRemovals.Length == 0
            ? "None"
            : string.Join("\r\n  ", input.ApprovedRemovals);
        var message = "Approve a same-device Host credential update?\r\n\r\n" +
            $"Tenant: {input.TenantId}\r\nUser: {input.TargetActorId}\r\n" +
            $"Company: {input.CompanyId}\r\nBranch: {input.BranchId}\r\n" +
            $"Device: {input.DeviceId}\r\nSource credential: {input.SourceCredentialId}\r\n\r\n" +
            $"Complete resulting permission ceiling:\r\n  {permissions}\r\n\r\n" +
            $"Permissions to remove:\r\n  {removals}\r\n\r\n" +
            "The old credential remains active until this same device acknowledges the replacement. " +
            "The device ID and local Client data are preserved. Approve only if this exact scope is intended.";
        return MessageBoxW(IntPtr.Zero, message, "Ventio trusted credential update",
            0x00000004 | 0x00000030 | 0x00000100) == 6;
    }

    private static TrustedCredentialReissueRequestData ReadTrustedCredentialReissueRequest(Request request)
    {
        if (request.RequestFilePath is null)
            throw new TrustedPairingBrokerException("HOST_TRUSTED_REISSUE_REQUEST_INVALID");
        var expectedDirectory = TrustedOperatorDirectoryForSid(request.RequesterSid);
        var path = Path.GetFullPath(request.RequestFilePath);
        if (!StringComparer.OrdinalIgnoreCase.Equals(Path.GetDirectoryName(path), expectedDirectory) ||
            !StringComparer.OrdinalIgnoreCase.Equals(Path.GetFileName(path), request.OperationId + ".request.json"))
            throw new TrustedPairingBrokerException("HOST_TRUSTED_REISSUE_REQUEST_INVALID");
        var file = new FileInfo(path);
        if (!file.Exists || file.Length is <= 0 or > 65536 ||
            (file.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new TrustedPairingBrokerException("HOST_TRUSTED_REISSUE_REQUEST_INVALID");
        var acl = file.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner);
        if (acl.GetOwner(typeof(SecurityIdentifier))?.Value != request.RequesterSid)
            throw new TrustedPairingBrokerException("HOST_TRUSTED_REISSUE_REQUEST_INVALID");
        var allowed = new HashSet<string>(StringComparer.Ordinal) { request.RequesterSid, "S-1-5-18", "S-1-5-32-544" };
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            if (rule.AccessControlType == AccessControlType.Allow && !allowed.Contains(rule.IdentityReference.Value))
                throw new TrustedPairingBrokerException("HOST_TRUSTED_REISSUE_REQUEST_INVALID");
        byte[] bytes = [];
        try
        {
            bytes = File.ReadAllBytes(path);
            using var doc = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 4 });
            var root = doc.RootElement;
            var names = root.EnumerateObject().Select(x => x.Name).ToArray();
            if (root.ValueKind != JsonValueKind.Object || names.Length != 12 ||
                !names.ToHashSet(StringComparer.Ordinal).SetEquals([
                    "formatVersion", "operationId", "tenantId", "operatorActorId", "targetActorId",
                    "companyId", "branchId", "deviceId", "sourceCredentialId", "permissions",
                    "approvedRemovals", "operatorCredentialDigest"]) ||
                root.GetProperty("formatVersion").GetInt32() != 1 ||
                root.GetProperty("operationId").GetString() != request.OperationId ||
                root.GetProperty("tenantId").GetString() != request.TenantId ||
                root.GetProperty("companyId").GetString() != request.CompanyId ||
                root.GetProperty("branchId").GetString() != request.BranchId)
                throw new TrustedPairingBrokerException("HOST_TRUSTED_REISSUE_REQUEST_INVALID");
            static string Id(JsonElement json, string name)
            {
                var value = json.GetProperty(name).GetString();
                if (value is null || !Regex.IsMatch(value, "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$", RegexOptions.CultureInvariant))
                    throw new TrustedPairingBrokerException("HOST_TRUSTED_REISSUE_REQUEST_INVALID");
                return value;
            }
            static string[] Permissions(JsonElement value, int max, bool allowEmpty)
            {
                if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > max || (!allowEmpty && value.GetArrayLength() == 0))
                    throw new TrustedPairingBrokerException("HOST_TRUSTED_REISSUE_REQUEST_INVALID");
                var items = value.EnumerateArray().Select(item => item.ValueKind == JsonValueKind.String ? item.GetString() : null).ToArray();
                if (items.Any(item => item is null || !Regex.IsMatch(item, "^[a-z][a-z0-9_.]{0,255}$", RegexOptions.CultureInvariant)) ||
                    items.Cast<string>().Distinct(StringComparer.Ordinal).Count() != items.Length)
                    throw new TrustedPairingBrokerException("HOST_TRUSTED_REISSUE_REQUEST_INVALID");
                return items.Cast<string>().ToArray();
            }
            var digest = root.GetProperty("operatorCredentialDigest").GetString();
            if (digest is null || !Regex.IsMatch(digest, "^[0-9a-f]{64}$", RegexOptions.CultureInvariant))
                throw new TrustedPairingBrokerException("HOST_TRUSTED_REISSUE_REQUEST_INVALID");
            return new TrustedCredentialReissueRequestData(
                Id(root, "tenantId"), Id(root, "operatorActorId"), Id(root, "targetActorId"),
                Id(root, "companyId"), Id(root, "branchId"), Id(root, "deviceId"),
                Id(root, "sourceCredentialId"), digest,
                Permissions(root.GetProperty("permissions"), 64, false),
                Permissions(root.GetProperty("approvedRemovals"), 64, true));
        }
        catch (TrustedPairingBrokerException) { throw; }
        catch { throw new TrustedPairingBrokerException("HOST_TRUSTED_REISSUE_REQUEST_INVALID"); }
        finally { if (bytes.Length > 0) CryptographicOperations.ZeroMemory(bytes); try { File.Delete(path); } catch { } }
    }

    private static TrustedPairingRequestData ReadTrustedPairingRequest(Request request)
    {
        if (request.RequestFilePath is null)
            throw new TrustedPairingBrokerException("HOST_TRUSTED_PAIRING_REQUEST_INVALID");
        var expectedDirectory = TrustedOperatorDirectoryForSid(request.RequesterSid);
        var requestPath = Path.GetFullPath(request.RequestFilePath);
        if (!StringComparer.OrdinalIgnoreCase.Equals(Path.GetDirectoryName(requestPath), expectedDirectory) ||
            !StringComparer.OrdinalIgnoreCase.Equals(Path.GetFileName(requestPath), request.OperationId + ".request.json"))
            throw new TrustedPairingBrokerException("HOST_TRUSTED_PAIRING_REQUEST_INVALID");
        var file = new FileInfo(requestPath);
        if (!file.Exists || file.Length is <= 0 or > 16384 ||
            (file.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new TrustedPairingBrokerException("HOST_TRUSTED_PAIRING_REQUEST_INVALID");
        var acl = file.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner);
        if (acl.GetOwner(typeof(SecurityIdentifier))?.Value != request.RequesterSid)
            throw new TrustedPairingBrokerException("HOST_TRUSTED_PAIRING_REQUEST_INVALID");
        var allowedSids = new HashSet<string>(StringComparer.Ordinal)
        {
            request.RequesterSid, "S-1-5-18", "S-1-5-32-544"
        };
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType == AccessControlType.Allow &&
                !allowedSids.Contains(rule.IdentityReference.Value))
                throw new TrustedPairingBrokerException("HOST_TRUSTED_PAIRING_REQUEST_INVALID");
        }

        byte[] bytes = [];
        try
        {
            bytes = File.ReadAllBytes(requestPath);
            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            var names = root.EnumerateObject().Select(property => property.Name).ToArray();
            if (root.ValueKind != JsonValueKind.Object || names.Length != 9 ||
                !names.ToHashSet(StringComparer.Ordinal).SetEquals([
                    "formatVersion", "operationId", "tenantId", "operatorActorId",
                    "targetActorId", "companyId", "branchId", "permissions",
                    "operatorCredentialDigest"
                ]) ||
                root.GetProperty("formatVersion").GetInt32() != 1 ||
                root.GetProperty("operationId").GetString() != request.OperationId ||
                root.GetProperty("tenantId").GetString() != request.TenantId ||
                root.GetProperty("companyId").GetString() != request.CompanyId ||
                root.GetProperty("branchId").GetString() != request.BranchId)
                throw new TrustedPairingBrokerException("HOST_TRUSTED_PAIRING_REQUEST_INVALID");

            static string ReadIdentifier(JsonElement root, string name)
            {
                var value = root.GetProperty(name).GetString();
                if (value is null || !Regex.IsMatch(value,
                    "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$", RegexOptions.CultureInvariant))
                    throw new TrustedPairingBrokerException("HOST_TRUSTED_PAIRING_REQUEST_INVALID");
                return value;
            }

            var digest = root.GetProperty("operatorCredentialDigest").GetString();
            var rawPermissions = root.GetProperty("permissions");
            if (digest is null || !Regex.IsMatch(digest, "^[0-9a-f]{64}$", RegexOptions.CultureInvariant) ||
                rawPermissions.ValueKind != JsonValueKind.Array || rawPermissions.GetArrayLength() is < 1 or > 64)
                throw new TrustedPairingBrokerException("HOST_TRUSTED_PAIRING_REQUEST_INVALID");
            var permissions = rawPermissions.EnumerateArray().Select(value =>
            {
                var permission = value.ValueKind == JsonValueKind.String ? value.GetString() : null;
                if (permission is null ||
                    !Regex.IsMatch(permission, "^[a-z][a-z0-9_.]{0,255}$", RegexOptions.CultureInvariant) ||
                    Regex.IsMatch(permission, "^(identity|host|system|security|recovery|authorization)\\.", RegexOptions.CultureInvariant))
                    throw new TrustedPairingBrokerException("HOST_TRUSTED_PAIRING_REQUEST_INVALID");
                return permission;
            }).ToArray();
            if (permissions.Distinct(StringComparer.Ordinal).Count() != permissions.Length)
                throw new TrustedPairingBrokerException("HOST_TRUSTED_PAIRING_REQUEST_INVALID");
            return new TrustedPairingRequestData(
                ReadIdentifier(root, "tenantId"),
                ReadIdentifier(root, "operatorActorId"),
                ReadIdentifier(root, "targetActorId"),
                ReadIdentifier(root, "companyId"),
                ReadIdentifier(root, "branchId"),
                digest,
                permissions);
        }
        catch (TrustedPairingBrokerException)
        {
            throw;
        }
        catch
        {
            throw new TrustedPairingBrokerException("HOST_TRUSTED_PAIRING_REQUEST_INVALID");
        }
        finally
        {
            if (bytes.Length > 0) CryptographicOperations.ZeroMemory(bytes);
            try { File.Delete(requestPath); } catch { }
        }
    }

    internal static string TrustedOperatorDirectoryForSid(string userSid)
    {
        if (!Regex.IsMatch(userSid, "^S-1-\\d+(?:-\\d+)+$", RegexOptions.CultureInvariant))
            throw new ArgumentException("User SID is invalid.", nameof(userSid));
        _ = new SecurityIdentifier(userSid);
        using var profileKey = Registry.LocalMachine.OpenSubKey(
            @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\" + userSid);
        var profileValue = profileKey?.GetValue(
            "ProfileImagePath", null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
        if (string.IsNullOrWhiteSpace(profileValue)) throw new InvalidOperationException();
        var systemDrive = Path.GetPathRoot(Environment.SystemDirectory);
        if (string.IsNullOrWhiteSpace(systemDrive)) throw new InvalidOperationException();
        var profilePath = profileValue.Replace("%SystemDrive%", systemDrive, StringComparison.OrdinalIgnoreCase);
        if (!Path.IsPathFullyQualified(profilePath) || Regex.IsMatch(profilePath, "%[^%]+%", RegexOptions.CultureInvariant))
            throw new InvalidOperationException();
        return Path.GetFullPath(Path.Combine(profilePath, "AppData", "Local", "VentioFramework", "TrustedOperator"));
    }

    private static BootstrapReply? RequestTrustedPairing(Request request, TrustedPairingRequestData input)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new
        {
            operation = "trusted-pairing",
            tenantId = input.TenantId,
            operatorActorId = input.OperatorActorId,
            targetActorId = input.TargetActorId,
            companyId = input.CompanyId,
            branchId = input.BranchId,
            requestId = request.OperationId,
            operatorCredentialDigest = input.OperatorCredentialDigest,
            permissions = string.Join(',', input.Permissions),
        }, PipeJsonOptions);
        var reply = ExchangeFirstAdminPipe(bytes);
        return reply;
    }

    private static BootstrapReply? RequestTrustedCredentialReissue(
        Request request, TrustedCredentialReissueRequestData input)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new
        {
            operation = "trusted-credential-reissue",
            tenantId = input.TenantId,
            operatorActorId = input.OperatorActorId,
            companyId = input.CompanyId,
            branchId = input.BranchId,
            requestId = request.OperationId,
            operatorCredentialDigest = input.OperatorCredentialDigest,
            deviceId = input.DeviceId,
            sourceCredentialId = input.SourceCredentialId,
            targetActorId = input.TargetActorId,
            permissions = string.Join(',', input.Permissions),
            approvedRemovals = string.Join(',', input.ApprovedRemovals),
        }, PipeJsonOptions);
        return ExchangeFirstAdminPipe(bytes);
    }

    private static bool MatchesTrustedCredentialReissueRequest(
        Request request,
        TrustedCredentialReissueRequestData input,
        TrustedCredentialReissueResult? reissue) =>
        reissue is not null && reissue.OperationId == "reissue_" + request.OperationId &&
        reissue.State is "PREPARED" or "FINALIZED" or "EXPIRED" or "REJECTED" &&
        reissue.TenantId == input.TenantId &&
        reissue.ActorId == input.TargetActorId && reissue.DeviceId == input.DeviceId &&
        reissue.CompanyId == input.CompanyId && reissue.BranchId == input.BranchId &&
        Regex.IsMatch(reissue.CredentialId, "^cred_[0-9a-f]{32}$", RegexOptions.CultureInvariant) &&
        reissue.Permissions.Order(StringComparer.Ordinal)
            .SequenceEqual(input.Permissions.Order(StringComparer.Ordinal), StringComparer.Ordinal) &&
        DateTimeOffset.TryParse(reissue.ExpiresAtUtc, out var expiry) &&
        expiry <= DateTimeOffset.UtcNow.AddMinutes(16) &&
        (reissue.State != "PREPARED" || expiry > DateTimeOffset.UtcNow);

    private static void WriteProtectedTrustedCredentialReissueResult(
        Request request, TrustedCredentialReissueResult? reissue, string? failureCode)
    {
        var statusDirectory = GetStatusDirectory();
        var destination = Path.Combine(statusDirectory, request.OperationId + ".reissue.dpapi");
        var temporary = Path.Combine(statusDirectory, request.OperationId + ".reissue.tmp");
        var resultBytes = JsonSerializer.SerializeToUtf8Bytes(new ProtectedTrustedCredentialReissueResult(
            1, request.OperationId, reissue is null ? "failed" : "completed", reissue, failureCode), PipeJsonOptions);
        var entropy = Encoding.UTF8.GetBytes(request.OperationId);
        var protectedBytes = ProtectForLocalMachine(resultBytes, entropy);
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(protectedBytes);
                stream.Flush(true);
            }
            var administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            var requester = new SecurityIdentifier(request.RequesterSid);
            var security = new FileSecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(administrators);
            security.AddAccessRule(new FileSystemAccessRule(administrators, FileSystemRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(system, FileSystemRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(requester, FileSystemRights.Read | FileSystemRights.Delete, AccessControlType.Allow));
            new FileInfo(temporary).SetAccessControl(security);
            File.Move(temporary, destination, false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(resultBytes);
            CryptographicOperations.ZeroMemory(entropy);
            CryptographicOperations.ZeroMemory(protectedBytes);
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static bool MatchesTrustedPairingRequest(
        Request request,
        TrustedPairingRequestData input,
        TrustedPairingResult? pairing) =>
        pairing is not null && pairing.PairingId == "pair_" + request.OperationId &&
        pairing.ActorId == input.TargetActorId && pairing.CompanyId == input.CompanyId &&
        pairing.BranchId == input.BranchId &&
        Regex.IsMatch(pairing.Code, "^[A-Za-z0-9_-]{43}$", RegexOptions.CultureInvariant) &&
        pairing.Permissions.Order(StringComparer.Ordinal)
            .SequenceEqual(input.Permissions.Order(StringComparer.Ordinal), StringComparer.Ordinal) &&
        DateTimeOffset.TryParse(pairing.ExpiresAtUtc, out var expiry) &&
        expiry > DateTimeOffset.UtcNow && expiry <= DateTimeOffset.UtcNow.AddMinutes(5);

    private static void WriteProtectedTrustedPairingResult(
        Request request,
        TrustedPairingResult? pairing,
        string? failureCode)
    {
        var statusDirectory = GetStatusDirectory();
        var destination = Path.Combine(statusDirectory, request.OperationId + ".pairing.dpapi");
        var temporary = Path.Combine(statusDirectory, request.OperationId + ".pairing.tmp");
        var resultBytes = JsonSerializer.SerializeToUtf8Bytes(new ProtectedTrustedPairingResult(
            1,
            request.OperationId,
            pairing is null ? "failed" : "created",
            pairing?.PairingId,
            pairing?.ActorId,
            pairing?.CompanyId,
            pairing?.BranchId,
            pairing?.Permissions,
            pairing?.Code,
            pairing?.ExpiresAtUtc,
            failureCode), PipeJsonOptions);
        var entropy = Encoding.UTF8.GetBytes(request.OperationId);
        // The UAC consent prompt can run under a different administrator
        // account than the signed-in Ventio operator. Machine-scope DPAPI keeps
        // the result decryptable for that operator while the file DACL below
        // limits which local principals can read it.
        var protectedBytes = ProtectForLocalMachine(resultBytes, entropy);
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(protectedBytes);
                stream.Flush(true);
            }
            var administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            var requester = new SecurityIdentifier(request.RequesterSid);
            var security = new FileSecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(administrators);
            security.AddAccessRule(new FileSystemAccessRule(administrators, FileSystemRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(system, FileSystemRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(requester, FileSystemRights.Read | FileSystemRights.Delete, AccessControlType.Allow));
            new FileInfo(temporary).SetAccessControl(security);
            File.Move(temporary, destination, false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(resultBytes);
            CryptographicOperations.ZeroMemory(entropy);
            CryptographicOperations.ZeroMemory(protectedBytes);
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static bool AcknowledgeFirstAdministrator(string requestId)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new
        {
            operation = "acknowledge",
            requestId
        }, PipeJsonOptions);
        var reply = ExchangeFirstAdminPipe(bytes);
        return reply is { Success: true, Status: "acknowledged" } &&
            reply.RequestId == requestId && reply.Token is null;
    }

    private static BootstrapReply? ExchangeFirstAdminPipe(byte[] requestBytes)
    {
        var failureCode = "HOST_FIRST_ADMIN_PIPE_CONNECT_FAILED";
        try
        {
            using var pipe = new NamedPipeClientStream(
                ".",
                FirstAdminPipeName,
                PipeDirection.InOut,
                PipeOptions.None,
                TokenImpersonationLevel.Impersonation);
            pipe.Connect(30000);
            failureCode = "HOST_FIRST_ADMIN_PIPE_SERVER_INVALID";
            ValidateFirstAdministratorPipeServer(pipe);
            failureCode = "HOST_FIRST_ADMIN_PIPE_RESPONSE_INVALID";
            pipe.Write(requestBytes, 0, requestBytes.Length);
            pipe.WriteByte((byte)'\n');
            pipe.Flush();

            using var response = new MemoryStream();
            while (response.Length <= 8192)
            {
                var value = pipe.ReadByte();
                if (value < 0) return null;
                if (value == '\n') break;
                response.WriteByte((byte)value);
            }
            if (response.Length is <= 0 or > 8192) return null;

            var responseBytes = response.ToArray();
            try
            {
            using var document = JsonDocument.Parse(responseBytes, new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            var allowed = new HashSet<string>(StringComparer.Ordinal)
            {
                "success", "status", "requestId", "actorId", "token", "expiresAt", "failureCode", "pairing", "credentialReissue"
            };
            var seen = new HashSet<string>(StringComparer.Ordinal);
            if (root.EnumerateObject().Any(property =>
                    !allowed.Contains(property.Name) || !seen.Add(property.Name)) ||
                !root.TryGetProperty("success", out var success) ||
                (success.ValueKind != JsonValueKind.True && success.ValueKind != JsonValueKind.False) ||
                !root.TryGetProperty("status", out var status) || status.ValueKind != JsonValueKind.String)
            {
                return null;
            }

            static string? OptionalString(JsonElement value, string name)
            {
                if (!value.TryGetProperty(name, out var property) || property.ValueKind == JsonValueKind.Null) return null;
                return property.ValueKind == JsonValueKind.String ? property.GetString() : null;
            }

            var responseFailureCode = OptionalString(root, "failureCode");
            if (responseFailureCode is not null && !IsSafeFailureCode(responseFailureCode)) return null;

            TrustedPairingResult? pairing = null;
            if (root.TryGetProperty("pairing", out var rawPairing) && rawPairing.ValueKind != JsonValueKind.Null)
            {
                if (rawPairing.ValueKind != JsonValueKind.Object) return null;
                var pairingNames = rawPairing.EnumerateObject().Select(property => property.Name).ToArray();
                if (pairingNames.Length != 7 || !pairingNames.ToHashSet(StringComparer.Ordinal).SetEquals([
                    "pairingId", "actorId", "companyId", "branchId", "permissions", "code", "expiresAtUtc"
                ])) return null;
                var rawPermissions = rawPairing.GetProperty("permissions");
                if (rawPermissions.ValueKind != JsonValueKind.Array) return null;
                var permissions = rawPermissions.EnumerateArray().Select(value =>
                    value.ValueKind == JsonValueKind.String ? value.GetString() : null).ToArray();
                if (permissions.Any(value => value is null)) return null;
                pairing = new TrustedPairingResult(
                    rawPairing.GetProperty("pairingId").GetString() ?? "",
                    rawPairing.GetProperty("actorId").GetString() ?? "",
                    rawPairing.GetProperty("companyId").GetString() ?? "",
                    rawPairing.GetProperty("branchId").GetString() ?? "",
                    permissions.Cast<string>().ToArray(),
                    rawPairing.GetProperty("code").GetString() ?? "",
                    rawPairing.GetProperty("expiresAtUtc").GetString() ?? "");
            }

            TrustedCredentialReissueResult? credentialReissue = null;
            if (root.TryGetProperty("credentialReissue", out var rawReissue) && rawReissue.ValueKind != JsonValueKind.Null)
            {
                if (rawReissue.ValueKind != JsonValueKind.Object) return null;
                var names = rawReissue.EnumerateObject().Select(property => property.Name).ToArray();
                if (names.Length != 10 || !names.ToHashSet(StringComparer.Ordinal).SetEquals([
                    "operationId", "state", "tenantId", "actorId", "deviceId",
                    "companyId", "branchId", "credentialId", "permissions", "expiresAtUtc"
                ])) return null;
                var rawPermissions = rawReissue.GetProperty("permissions");
                if (rawPermissions.ValueKind != JsonValueKind.Array) return null;
                var permissions = rawPermissions.EnumerateArray().Select(value =>
                    value.ValueKind == JsonValueKind.String ? value.GetString() : null).ToArray();
                if (permissions.Any(value => value is null)) return null;
                credentialReissue = new TrustedCredentialReissueResult(
                    rawReissue.GetProperty("operationId").GetString() ?? "",
                    rawReissue.GetProperty("state").GetString() ?? "",
                    rawReissue.GetProperty("tenantId").GetString() ?? "",
                    rawReissue.GetProperty("actorId").GetString() ?? "",
                    rawReissue.GetProperty("deviceId").GetString() ?? "",
                    rawReissue.GetProperty("companyId").GetString() ?? "",
                    rawReissue.GetProperty("branchId").GetString() ?? "",
                    rawReissue.GetProperty("credentialId").GetString() ?? "",
                    permissions.Cast<string>().ToArray(),
                    rawReissue.GetProperty("expiresAtUtc").GetString() ?? "");
            }

            return new BootstrapReply(
                success.GetBoolean(),
                status.GetString()!,
                OptionalString(root, "requestId"),
                OptionalString(root, "actorId"),
                OptionalString(root, "token"),
                OptionalString(root, "expiresAt"),
                responseFailureCode,
                pairing,
                credentialReissue);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(responseBytes);
            }
        }
        catch
        {
            return new BootstrapReply(false, "failed", null, null, null, null, failureCode);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(requestBytes);
        }
    }

    internal static bool IsSafeFailureCode(string? failureCode) =>
        failureCode is not null && SafeFailureCodes.Contains(failureCode, StringComparer.Ordinal);

    private static void ValidateFirstAdministratorPipeServer(NamedPipeClientStream pipe)
    {
        if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var serverPid)) throw new InvalidOperationException();
        var manager = OpenSCManager(null, null, 1);
        if (manager == IntPtr.Zero) throw new InvalidOperationException();
        try
        {
            var service = OpenService(manager, "VentioHost", 4);
            if (service == IntPtr.Zero) throw new InvalidOperationException();
            try
            {
                if (!QueryServiceStatusEx(service, 0, out var status, Marshal.SizeOf<ServiceStatusProcess>(), out _) ||
                    status.ProcessId != serverPid || !IsAllowedBootstrapPeerState(status.CurrentState)) throw new InvalidOperationException();
            }
            finally { _ = CloseServiceHandle(service); }
        }
        finally { _ = CloseServiceHandle(manager); }
        var process = OpenProcess(0x1000, false, serverPid);
        if (process == IntPtr.Zero) throw new InvalidOperationException();
        try
        {
            if (!OpenProcessToken(process, 8, out var token)) throw new InvalidOperationException();
            try
            {
                using var identity = new WindowsIdentity(token);
                var expectedSid = new NTAccount("NT SERVICE", "VentioHost").Translate(typeof(SecurityIdentifier)).Value;
                if (!StringComparer.Ordinal.Equals(identity.User?.Value, expectedSid)) throw new InvalidOperationException();
            }
            finally { _ = CloseHandle(token); }
            var image = new StringBuilder(32768);
            var length = image.Capacity;
            var expected = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Ventio", "host-payload", "VentioHostService.exe");
            if (!QueryFullProcessImageName(process, 0, image, ref length) ||
                !StringComparer.OrdinalIgnoreCase.Equals(image.ToString(), expected)) throw new InvalidOperationException();
            AssertNoReparsePoint(expected);
            AssertNoUntrustedWriteAccess(expected);
            ValidateBrokerManifest(Path.GetDirectoryName(expected)!, expected, "VentioHostService.exe");
        }
        finally { _ = CloseHandle(process); }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatusProcess
    {
        public uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint, ProcessId, ServiceFlags;
    }
    internal static bool IsAllowedBootstrapPeerState(uint state) => state is 2 or 4;
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint serverProcessId);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenSCManager(string? machine, string? database, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenService(IntPtr manager, string name, uint access);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceStatusEx(IntPtr service, int level, out ServiceStatusProcess status, int size, out int required);
    [DllImport("advapi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref int size);

    private static void WriteProtectedBootstrapResult(Request request, BootstrapReply reply)
    {
        var statusDirectory = GetStatusDirectory();
        var destination = Path.Combine(statusDirectory, request.OperationId + ".credential.dpapi");
        var temporary = Path.Combine(statusDirectory, request.OperationId + ".credential.tmp");
        var resultBytes = JsonSerializer.SerializeToUtf8Bytes(new ProtectedBootstrapResult(
            1,
            request.OperationId,
            reply.RequestId!,
            reply.ActorId!,
            reply.Token!,
            reply.ExpiresAt!), PipeJsonOptions);
        var entropy = Encoding.UTF8.GetBytes(request.OperationId);
        var protectedBytes = ProtectForCurrentUser(resultBytes, entropy);
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(protectedBytes);
                stream.Flush(true);
            }
            var administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            var requester = new SecurityIdentifier(request.RequesterSid);
            var security = new FileSecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(administrators);
            security.AddAccessRule(new FileSystemAccessRule(
                administrators,
                FileSystemRights.FullControl,
                AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(
                system,
                FileSystemRights.FullControl,
                AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(
                requester,
                FileSystemRights.Read | FileSystemRights.Delete,
                AccessControlType.Allow));
            new FileInfo(temporary).SetAccessControl(security);
            File.Move(temporary, destination, false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(resultBytes);
            CryptographicOperations.ZeroMemory(entropy);
            CryptographicOperations.ZeroMemory(protectedBytes);
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static ProtectedBootstrapResult? ReadProtectedBootstrapResult(Request request)
    {
        var path = Path.Combine(GetStatusDirectory(), request.OperationId + ".credential.dpapi");
        if (!File.Exists(path)) return null;
        AssertNoReparsePoint(path);
        var file = new FileInfo(path);
        if (file.Length is <= 0 or > 16384) throw new InvalidOperationException();
        var acl = file.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner);
        if (!acl.AreAccessRulesProtected || acl.GetOwner(typeof(SecurityIdentifier))?.Value != "S-1-5-32-544")
            throw new InvalidOperationException();
        const FileSystemRights write = FileSystemRights.WriteData | FileSystemRights.AppendData |
            FileSystemRights.WriteAttributes | FileSystemRights.WriteExtendedAttributes |
            FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            if (rule.AccessControlType == AccessControlType.Allow && (rule.FileSystemRights & write) != 0 &&
                rule.IdentityReference.Value is not ("S-1-5-18" or "S-1-5-32-544"))
                throw new InvalidOperationException();
        var encrypted = File.ReadAllBytes(path);
        var entropy = Encoding.UTF8.GetBytes(request.OperationId);
        byte[]? plaintext = null;
        try
        {
            plaintext = UnprotectForCurrentUser(encrypted, entropy);
            using var document = JsonDocument.Parse(plaintext);
            var names = document.RootElement.EnumerateObject().Select(property => property.Name).ToArray();
            if (names.Length != 6 || !names.ToHashSet(StringComparer.Ordinal).SetEquals(
                ["formatVersion", "operationId", "requestId", "actorId", "token", "expiresAt"])) throw new InvalidOperationException();
            var result = JsonSerializer.Deserialize<ProtectedBootstrapResult>(plaintext, PipeJsonOptions);
            if (result is null || result.FormatVersion != 1 || result.OperationId != request.OperationId ||
                !Regex.IsMatch(result.RequestId, "^[A-Za-z0-9_-]{43}$") ||
                !Regex.IsMatch(result.ActorId, "^usr_[A-Za-z0-9_-]{43}$") ||
                !Regex.IsMatch(result.Token, "^[A-Za-z0-9_-]{43,128}$") ||
                !DateTimeOffset.TryParse(result.ExpiresAt, out var expiresAt) || expiresAt <= DateTimeOffset.UtcNow)
                throw new InvalidOperationException();
            return result;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encrypted);
            CryptographicOperations.ZeroMemory(entropy);
            if (plaintext is not null) CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    internal static byte[] ProtectForCurrentUser(byte[] plaintext, byte[] entropy)
        => ProtectData(plaintext, entropy, flags: 1);

    internal static byte[] ProtectForLocalMachine(byte[] plaintext, byte[] entropy)
        => ProtectData(plaintext, entropy, flags: 5);

    private static byte[] ProtectData(byte[] plaintext, byte[] entropy, int flags)
    {
        var inputPointer = Marshal.AllocHGlobal(plaintext.Length);
        var entropyPointer = Marshal.AllocHGlobal(entropy.Length);
        try
        {
            Marshal.Copy(plaintext, 0, inputPointer, plaintext.Length);
            Marshal.Copy(entropy, 0, entropyPointer, entropy.Length);
            var input = new DataBlob(plaintext.Length, inputPointer);
            var optionalEntropy = new DataBlob(entropy.Length, entropyPointer);
            if (!CryptProtectData(
                ref input,
                "Ventio Host setup result",
                ref optionalEntropy,
                IntPtr.Zero,
                IntPtr.Zero,
                flags,
                out var output))
            {
                throw new InvalidOperationException();
            }
            try
            {
                var protectedBytes = new byte[output.Length];
                Marshal.Copy(output.Data, protectedBytes, 0, output.Length);
                return protectedBytes;
            }
            finally
            {
                _ = LocalFree(output.Data);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            CryptographicOperations.ZeroMemory(entropy);
            Marshal.FreeHGlobal(inputPointer);
            Marshal.FreeHGlobal(entropyPointer);
        }
    }

    internal static byte[] UnprotectForCurrentUser(byte[] encrypted, byte[] entropy)
    {
        var inputPointer = Marshal.AllocHGlobal(encrypted.Length);
        var entropyPointer = Marshal.AllocHGlobal(entropy.Length);
        var description = IntPtr.Zero;
        try
        {
            Marshal.Copy(encrypted, 0, inputPointer, encrypted.Length);
            Marshal.Copy(entropy, 0, entropyPointer, entropy.Length);
            var input = new DataBlob(encrypted.Length, inputPointer);
            var optionalEntropy = new DataBlob(entropy.Length, entropyPointer);
            if (!CryptUnprotectData(ref input, out description, ref optionalEntropy, IntPtr.Zero, IntPtr.Zero, 1, out var output))
                throw new InvalidOperationException("Protected bootstrap result could not be read.");
            try
            {
                if (output.Length is <= 0 or > 8192) throw new InvalidOperationException();
                var plaintext = new byte[output.Length];
                Marshal.Copy(output.Data, plaintext, 0, output.Length);
                for (var i = 0; i < output.Length; i++) Marshal.WriteByte(output.Data, i, 0);
                return plaintext;
            }
            finally { _ = LocalFree(output.Data); }
        }
        finally
        {
            if (description != IntPtr.Zero) _ = LocalFree(description);
            Marshal.FreeHGlobal(inputPointer);
            Marshal.FreeHGlobal(entropyPointer);
        }
    }

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, out IntPtr description, ref DataBlob entropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "MessageBoxW")]
    private static extern int MessageBoxW(IntPtr owner, string text, string caption, uint type);

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(
        ref DataBlob dataIn,
        string dataDescription,
        ref DataBlob optionalEntropy,
        IntPtr reserved,
        IntPtr promptStruct,
        int flags,
        out DataBlob dataOut);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob(int length, IntPtr data)
    {
        public int Length = length;
        public IntPtr Data = data;
    }

    private static bool IsAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static Paths GetValidatedPaths()
    {
        if (!OperatingSystem.IsWindows()) throw new InvalidOperationException();
        var programFiles = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles));
        var productDirectory = Path.Combine(programFiles, "Ventio");
        var payloadDirectory = Path.Combine(productDirectory, "host-payload");
        var executablePath = Path.GetFullPath(Environment.ProcessPath ?? throw new InvalidOperationException());
        var expectedExecutable = Path.Combine(payloadDirectory, "VentioSetupBroker.exe");
        if (!executablePath.Equals(expectedExecutable, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException();

        AssertNoReparsePoint(productDirectory);
        AssertNoReparsePoint(payloadDirectory);
        AssertNoReparsePoint(executablePath);
        AssertNoUntrustedWriteAccess(productDirectory);
        AssertNoUntrustedWriteAccess(payloadDirectory);
        AssertNoUntrustedWriteAccess(executablePath);

        var scriptPath = Path.Combine(payloadDirectory, "setup", "provision-host-installation.ps1");
        AssertNoReparsePoint(Path.Combine(payloadDirectory, "setup"));
        AssertNoReparsePoint(scriptPath);
        AssertNoUntrustedWriteAccess(Path.Combine(payloadDirectory, "setup"));
        AssertNoUntrustedWriteAccess(scriptPath);
        if (!File.Exists(scriptPath)) throw new InvalidOperationException();

        ValidateBrokerManifest(payloadDirectory, executablePath);

        var systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var powerShell = Path.Combine(systemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(powerShell)) throw new InvalidOperationException();

        return new Paths(payloadDirectory, scriptPath, powerShell);
    }

    private static void AssertNoReparsePoint(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException();
    }

    private static void AssertNoUntrustedWriteAccess(string path)
    {
        AuthorizationRuleCollection rules = Directory.Exists(path)
            ? new DirectoryInfo(path).GetAccessControl(AccessControlSections.Access)
                .GetAccessRules(true, true, typeof(SecurityIdentifier))
            : new FileInfo(path).GetAccessControl(AccessControlSections.Access)
                .GetAccessRules(true, true, typeof(SecurityIdentifier));
        var untrustedSids = new HashSet<string>(StringComparer.Ordinal)
        {
            "S-1-1-0",
            "S-1-5-11",
            "S-1-5-32-545"
        };
        using (var identity = WindowsIdentity.GetCurrent())
        {
            if (identity.User is not null) untrustedSids.Add(identity.User.Value);
        }
        foreach (FileSystemAccessRule rule in rules)
        {
            if (rule.AccessControlType == AccessControlType.Allow &&
                rule.IdentityReference is SecurityIdentifier sid &&
                untrustedSids.Contains(sid.Value) && HasWriteCapability(rule.FileSystemRights))
            {
                throw new InvalidOperationException();
            }
        }
    }

    internal static bool HasWriteCapability(FileSystemRights rights)
    {
        const int GenericWrite = 0x40000000;
        const int GenericAll = 0x10000000;
        const FileSystemRights writeAccess =
            FileSystemRights.WriteData |
            FileSystemRights.AppendData |
            FileSystemRights.WriteExtendedAttributes |
            FileSystemRights.WriteAttributes |
            FileSystemRights.DeleteSubdirectoriesAndFiles |
            FileSystemRights.Delete |
            FileSystemRights.ChangePermissions |
            FileSystemRights.TakeOwnership;

        var value = (int)rights;
        return (value & (GenericWrite | GenericAll)) != 0 ||
            (rights & writeAccess) != 0;
    }

    private static void ValidateBrokerManifest(string payloadDirectory, string executablePath, string expectedName = "VentioSetupBroker.exe")
    {
        var manifestPath = Path.Combine(payloadDirectory, "payload-manifest.json");
        AssertNoReparsePoint(manifestPath);
        AssertNoUntrustedWriteAccess(manifestPath);
        using var manifest = JsonDocument.Parse(File.ReadAllText(manifestPath));
        var root = manifest.RootElement;
        if (!root.TryGetProperty("formatVersion", out var formatVersion) || formatVersion.GetInt32() != 1 ||
            !root.TryGetProperty("setupBrokerExecutable", out var brokerName) || brokerName.GetString() != "VentioSetupBroker.exe" ||
            !root.TryGetProperty("postgresVersion", out var postgresVersion) || postgresVersion.GetString() != "16.15" ||
            !root.TryGetProperty("credentialsIncluded", out var credentialsIncluded) || credentialsIncluded.GetBoolean() ||
            !root.TryGetProperty("databaseIncluded", out var databaseIncluded) || databaseIncluded.GetBoolean() ||
            !root.TryGetProperty("verifiedFiles", out var files) || files.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException();
        }

        var entries = files.EnumerateArray()
            .Where(file => file.TryGetProperty("path", out var path) && path.GetString() == expectedName)
            .ToArray();
        var executableLength = new FileInfo(executablePath).Length;
        using var hashAlgorithm = SHA256.Create();
        using var executable = File.OpenRead(executablePath);
        var executableHash = Convert.ToHexString(hashAlgorithm.ComputeHash(executable)).ToLowerInvariant();
        if (entries.Length != 1 ||
            entries[0].GetProperty("length").GetInt64() != executableLength ||
            entries[0].GetProperty("sha256").GetString() != executableHash)
        {
            throw new InvalidOperationException();
        }
    }

    private static void WriteStatus(Request request, string state, string? failureCode, string? phase)
    {
        var directory = GetStatusDirectory();
        var destination = Path.Combine(directory, request.OperationId + ".json");
        var temporary = Path.Combine(directory, request.OperationId + ".tmp");
        var document = SerializeSetupStatus(
            1,
            request.OperationId,
            state,
            phase,
            failureCode,
            DateTimeOffset.UtcNow);
        File.WriteAllText(temporary, document, new System.Text.UTF8Encoding(false));
        File.Move(temporary, destination, true);
    }

    internal static string SerializeSetupStatus(
        int formatVersion,
        string operationId,
        string state,
        string? phase,
        string? failureCode,
        DateTimeOffset updatedAtUtc) =>
        JsonSerializer.Serialize(
            new SetupStatus(formatVersion, operationId, state, phase, failureCode, updatedAtUtc),
            PipeJsonOptions);

    private static string GetStatusDirectory()
    {
        var programFiles = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles));
        var productDirectory = Path.Combine(programFiles, "Ventio");
        var statusDirectory = Path.Combine(productDirectory, "SetupStatus");
        if (!Directory.Exists(productDirectory)) throw new InvalidOperationException();
        AssertNoReparsePoint(productDirectory);
        AssertNoUntrustedWriteAccess(productDirectory);
        if (!Directory.Exists(statusDirectory))
        {
            Directory.CreateDirectory(statusDirectory);
            SetProtectedDirectoryAcl(statusDirectory);
        }
        AssertNoReparsePoint(productDirectory);
        AssertNoReparsePoint(statusDirectory);
        AssertNoUntrustedWriteAccess(productDirectory);
        AssertNoUntrustedWriteAccess(statusDirectory);
        return statusDirectory;
    }

    private static void SetProtectedDirectoryAcl(string path)
    {
        var administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        var users = new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null);
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(administrators);
        security.AddAccessRule(new FileSystemAccessRule(
            administrators,
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            system,
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            users,
            FileSystemRights.ReadAndExecute,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(security);
    }

    private static void TryWriteStatus(Request request, string state, string failureCode, string? phase)
    {
        try { WriteStatus(request, state, failureCode, phase); }
        catch { }
    }

    internal sealed record Request(
        string OperationId,
        string TenantId,
        string CompanyId,
        string BranchId,
        string RequesterSid,
        bool ResumeFirstAdministrator = false,
        bool TrustedPairing = false,
        bool TrustedCredentialReissue = false,
        string? RequestFilePath = null)
    {
        internal static Request Parse(IReadOnlyList<string> args)
        {
            if (args.Count == 7 && args[0] == "--trusted-credential-reissue" &&
                args[1].Length == 32 && Guid.TryParseExact(args[1], "N", out var reissueOperationId) &&
                IsValidIdentifier(args[2]) && IsValidIdentifier(args[3]) && IsValidIdentifier(args[4]) &&
                Regex.IsMatch(args[5], "^S-1-\\d+(?:-\\d+)+$", RegexOptions.CultureInvariant) &&
                Path.IsPathFullyQualified(args[6]))
            {
                _ = new SecurityIdentifier(args[5]);
                return new Request(reissueOperationId.ToString("N"), args[2], args[3], args[4], args[5],
                    TrustedCredentialReissue: true, RequestFilePath: args[6]);
            }
            if (args.Count == 7 && args[0] == "--trusted-pairing" &&
                args[1].Length == 32 && Guid.TryParseExact(args[1], "N", out var pairingOperationId) &&
                IsValidIdentifier(args[2]) && IsValidIdentifier(args[3]) && IsValidIdentifier(args[4]) &&
                Regex.IsMatch(args[5], "^S-1-\\d+(?:-\\d+)+$", RegexOptions.CultureInvariant) &&
                Path.IsPathFullyQualified(args[6]))
            {
                _ = new SecurityIdentifier(args[5]);
                return new Request(pairingOperationId.ToString("N"), args[2], args[3], args[4], args[5],
                    TrustedPairing: true, RequestFilePath: args[6]);
            }
            if (args.Count != 6 || (args[0] != "--setup-new-host" && args[0] != "--resume-first-administrator") ||
                args[1].Length != 32 || !Guid.TryParseExact(args[1], "N", out var operationId) ||
                !IsValidIdentifier(args[2]) || !IsValidIdentifier(args[3]) || !IsValidIdentifier(args[4]) ||
                !Regex.IsMatch(args[5], "^S-1-\\d+(?:-\\d+)+$", RegexOptions.CultureInvariant))
            {
                throw new ArgumentException("Unsupported setup request.");
            }
            _ = new SecurityIdentifier(args[5]);
            return new Request(operationId.ToString("N"), args[2], args[3], args[4], args[5], args[0] == "--resume-first-administrator");
        }

        private static bool IsValidIdentifier(string value) =>
            value.Length is > 0 and <= 256 &&
            Regex.IsMatch(value, "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$", RegexOptions.CultureInvariant);
    }

    private sealed record Paths(string PayloadDirectory, string ProvisioningScript, string PowerShell);

    private sealed record BootstrapReply(
        bool Success,
        string Status,
        string? RequestId,
        string? ActorId,
        string? Token,
        string? ExpiresAt,
        string? FailureCode,
        TrustedPairingResult? Pairing = null,
        TrustedCredentialReissueResult? CredentialReissue = null);

    private sealed record TrustedPairingResult(
        string PairingId,
        string ActorId,
        string CompanyId,
        string BranchId,
        string[] Permissions,
        string Code,
        string ExpiresAtUtc);

    private sealed record TrustedCredentialReissueResult(
        string OperationId,
        string State,
        string TenantId,
        string ActorId,
        string DeviceId,
        string CompanyId,
        string BranchId,
        string CredentialId,
        string[] Permissions,
        string ExpiresAtUtc);

    private sealed record TrustedPairingRequestData(
        string TenantId,
        string OperatorActorId,
        string TargetActorId,
        string CompanyId,
        string BranchId,
        string OperatorCredentialDigest,
        string[] Permissions);

    private sealed record TrustedCredentialReissueRequestData(
        string TenantId,
        string OperatorActorId,
        string TargetActorId,
        string CompanyId,
        string BranchId,
        string DeviceId,
        string SourceCredentialId,
        string OperatorCredentialDigest,
        string[] Permissions,
        string[] ApprovedRemovals);

    private sealed record ProtectedTrustedPairingResult(
        int FormatVersion,
        string OperationId,
        string Status,
        string? PairingId,
        string? ActorId,
        string? CompanyId,
        string? BranchId,
        string[]? Permissions,
        string? Code,
        string? ExpiresAtUtc,
        string? FailureCode);

    private sealed record ProtectedTrustedCredentialReissueResult(
        int FormatVersion,
        string OperationId,
        string Status,
        TrustedCredentialReissueResult? Reissue,
        string? FailureCode);

    private sealed class TrustedPairingBrokerException(string failureCode) : Exception
    {
        internal string FailureCode { get; } = failureCode;
    }

    private sealed record ProtectedBootstrapResult(
        int FormatVersion,
        string OperationId,
        string RequestId,
        string ActorId,
        string Token,
        string ExpiresAt);

    private sealed record SetupStatus(
        int FormatVersion,
        string OperationId,
        string State,
        string? Phase,
        string? FailureCode,
        DateTimeOffset UpdatedAtUtc);

    private sealed class SetupProgress
    {
        private readonly object _gate = new();
        private string _currentPhase = "PAYLOAD_VALIDATION";

        internal string CurrentPhase
        {
            get { lock (_gate) return _currentPhase; }
        }

        internal void Update(string phase)
        {
            lock (_gate) _currentPhase = phase;
        }
    }
}
