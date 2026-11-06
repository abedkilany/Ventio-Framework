using System.Buffers;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

internal sealed record BootstrapCommand(
    string Operation,
    string? TenantId = null,
    string? CompanyId = null,
    string? BranchId = null,
    string? RequestId = null,
    string? OperatorCredentialDigest = null,
    string? OperatorActorId = null,
    string? TargetActorId = null,
    string? PermissionsCsv = null);

internal sealed record TrustedPairingResult(
    string PairingId,
    string ActorId,
    string CompanyId,
    string BranchId,
    string[] Permissions,
    string Code,
    string ExpiresAtUtc);

internal sealed class TrustedPairingOperationException(string failureCode) : Exception
{
    internal string FailureCode { get; } = failureCode;
}

internal sealed record BootstrapReply(
    bool Success,
    string Status,
    string? RequestId = null,
    string? ActorId = null,
    string? Token = null,
    string? ExpiresAt = null,
    string? FailureCode = null,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] BootstrapScope? Scope = null,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] TrustedPairingResult? Pairing = null);

internal sealed record BootstrapScope(string TenantId, string CompanyId, string BranchId);

internal sealed record BootstrapReceipt(
    int FormatVersion,
    string State,
    string CallerSid,
    string RequestId,
    string TenantId,
    string CompanyId,
    string BranchId,
    string? ActorId,
    string? DeviceId,
    string? CredentialId,
    string? Token,
    string? ExpiresAt);

internal sealed class FirstAdminBootstrapBroker
{
    internal const string PipeName = "Ventio.Host.FirstAdmin.v1";
    internal static readonly TimeSpan RequestReadTimeout = TimeSpan.FromSeconds(30);
    internal static readonly TimeSpan BootstrapOperationTimeout = TimeSpan.FromSeconds(90);
    private const int MaximumRequestBytes = 8192;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly BootstrapReceiptCoordinator _coordinator;
    private readonly Func<BootstrapReceipt, CancellationToken, Task> _executeBootstrap;
    private readonly Func<BootstrapCommand, string, CancellationToken, Task<TrustedPairingResult>> _executeTrustedPairing;

    internal FirstAdminBootstrapBroker(
        BootstrapReceiptCoordinator coordinator,
        Func<BootstrapReceipt, CancellationToken, Task> executeBootstrap,
        Func<BootstrapCommand, string, CancellationToken, Task<TrustedPairingResult>> executeTrustedPairing)
    {
        _coordinator = coordinator;
        _executeBootstrap = executeBootstrap;
        _executeTrustedPairing = executeTrustedPairing;
    }

    internal async Task RunAsync(CancellationToken cancellationToken, TaskCompletionSource ready)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        while (!cancellationToken.IsCancellationRequested)
        {
            using var pipe = CreateServerPipe();
            ready.TrySetResult();
            try
            {
                await pipe.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
                using var requestTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                requestTimeout.CancelAfter(RequestReadTimeout);
                BootstrapReply reply;
                try
                {
                    var requestBytes = await ReadRequestLineAsync(pipe, requestTimeout.Token).ConfigureAwait(false);
                    BootstrapCommand command;
                    try { command = ParseCommand(requestBytes); }
                    finally { CryptographicOperations.ZeroMemory(requestBytes); }
                    var callerSid = GetAuthorizedClientSid(pipe);
                    using var operationTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                    operationTimeout.CancelAfter(BootstrapOperationTimeout);
                    reply = command.Operation switch
                    {
                        "bootstrap" => await _coordinator.BootstrapAsync(
                            command, callerSid, _executeBootstrap, operationTimeout.Token).ConfigureAwait(false),
                        "trusted-pairing" => new BootstrapReply(
                            true,
                            "created",
                            Pairing: await _executeTrustedPairing(
                                command, callerSid, operationTimeout.Token).ConfigureAwait(false)),
                        "acknowledge" => _coordinator.Acknowledge(command, callerSid),
                        "status" => _coordinator.InspectStatus(callerSid),
                        _ => throw new InvalidDataException(),
                    };
                }
                catch (FirstAdministratorBootstrapFailureException exception)
                {
                    reply = new BootstrapReply(false, "failed", FailureCode: exception.FailureCode);
                }
                catch (TrustedPairingOperationException exception)
                {
                    reply = new BootstrapReply(false, "failed", FailureCode: exception.FailureCode);
                }
                catch
                {
                    reply = new BootstrapReply(false, "failed");
                }

                var responseBytes = JsonSerializer.SerializeToUtf8Bytes(reply, JsonOptions);
                try
                {
                    await WriteReplyAndAwaitClientCloseAsync(pipe, responseBytes, cancellationToken).ConfigureAwait(false);
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(responseBytes);
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch
            {
                if (cancellationToken.IsCancellationRequested) break;
            }
        }
    }

    internal static BootstrapCommand ParseCommand(byte[] requestBytes)
    {
        if (requestBytes.Length is <= 0 or > MaximumRequestBytes) throw new InvalidDataException();
        using var document = JsonDocument.Parse(requestBytes, new JsonDocumentOptions { MaxDepth = 4 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new InvalidDataException();
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var property in root.EnumerateObject())
        {
            if (fields.ContainsKey(property.Name) || property.Value.ValueKind != JsonValueKind.String)
                throw new InvalidDataException();
            var value = property.Value.GetString();
            var maximumFieldLength = property.Name == "permissions" ? 4096 : 256;
            if (value is null || value.Length > maximumFieldLength) throw new InvalidDataException();
            fields.Add(property.Name, value);
        }

        if (!fields.TryGetValue("operation", out var operation)) throw new InvalidDataException();
        if (operation == "status" && fields.Count == 1) return new BootstrapCommand(operation);
        if (operation == "bootstrap" &&
            fields.Count == 4 &&
            fields.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(["operation", "tenantId", "companyId", "branchId"]))
        {
            return new BootstrapCommand(
                operation,
                ValidateIdentifier(fields["tenantId"]),
                ValidateIdentifier(fields["companyId"]),
                ValidateIdentifier(fields["branchId"]));
        }
        if (operation == "acknowledge" &&
            fields.Count == 2 &&
            fields.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(["operation", "requestId"]) &&
            IsOpaqueToken(fields["requestId"]))
        {
            return new BootstrapCommand(operation, RequestId: fields["requestId"]);
        }
        if (operation == "trusted-pairing" &&
            fields.Count == 9 &&
            fields.Keys.ToHashSet(StringComparer.Ordinal).SetEquals([
                "operation", "tenantId", "companyId", "branchId", "requestId",
                "operatorCredentialDigest", "operatorActorId", "targetActorId",
                "permissions"
            ]) &&
            Regex.IsMatch(fields["requestId"], "^[0-9a-f]{32}$", RegexOptions.CultureInvariant) &&
            Regex.IsMatch(fields["operatorCredentialDigest"], "^[0-9a-f]{64}$", RegexOptions.CultureInvariant) &&
            fields["permissions"].Split(',').Length is > 0 and <= 64 &&
            fields["permissions"].Split(',').All(permission =>
                Regex.IsMatch(permission, "^[a-z][a-z0-9_.]{0,255}$", RegexOptions.CultureInvariant) &&
                !Regex.IsMatch(permission, "^(identity|host|system|security|recovery|authorization)\\.", RegexOptions.CultureInvariant)))
        {
            return new BootstrapCommand(
                operation,
                ValidateIdentifier(fields["tenantId"]),
                ValidateIdentifier(fields["companyId"]),
                ValidateIdentifier(fields["branchId"]),
                fields["requestId"],
                fields["operatorCredentialDigest"],
                ValidateIdentifier(fields["operatorActorId"]),
                ValidateIdentifier(fields["targetActorId"]),
                fields["permissions"]);
        }
        throw new InvalidDataException();
    }

    internal static async Task WriteReplyAndAwaitClientCloseAsync(
        Stream pipe, byte[] responseBytes, CancellationToken cancellationToken)
    {
        await pipe.WriteAsync(responseBytes, cancellationToken).ConfigureAwait(false);
        await pipe.WriteAsync("\n"u8.ToArray(), cancellationToken).ConfigureAwait(false);
        await pipe.FlushAsync(cancellationToken).ConfigureAwait(false);
        // Disconnect discards unread Windows pipe data. Existing clients close
        // the connection after consuming one reply, which also bounds delivery.
        using var deliveryTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deliveryTimeout.CancelAfter(TimeSpan.FromSeconds(10));
        try { _ = await pipe.ReadAsync(new byte[1], deliveryTimeout.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { }
    }

    internal static PipeSecurity CreatePipeSecurity(string serviceSid)
    {
        if (!Regex.IsMatch(serviceSid, @"^S-1-\d+(?:-\d+)+$", RegexOptions.CultureInvariant))
            throw new InvalidOperationException("Host service SID is invalid.");
        var security = new PipeSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        var administrators = new SecurityIdentifier("S-1-5-32-544");
        var system = new SecurityIdentifier("S-1-5-18");
        var network = new SecurityIdentifier("S-1-5-2");
        var service = new SecurityIdentifier(serviceSid);
        security.AddAccessRule(new PipeAccessRule(network, PipeAccessRights.FullControl, AccessControlType.Deny));
        security.AddAccessRule(new PipeAccessRule(administrators,
            PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(system,
            PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(service,
            PipeAccessRights.FullControl, AccessControlType.Allow));
        return security;
    }

    internal static string ValidateIdentifier(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 256 || value.Any(char.IsControl))
            throw new InvalidDataException();
        return value;
    }

    private static NamedPipeServerStream CreateServerPipe()
    {
        var serviceSid = new NTAccount("NT SERVICE", "VentioHost")
            .Translate(typeof(SecurityIdentifier)).Value;
        var security = CreatePipeSecurity(serviceSid);
        return NamedPipeServerStreamAcl.Create(
            PipeName,
            PipeDirection.InOut,
            maxNumberOfServerInstances: 1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.FirstPipeInstance,
            inBufferSize: MaximumRequestBytes,
            outBufferSize: MaximumRequestBytes,
            security);
    }

    private static async Task<byte[]> ReadRequestLineAsync(Stream stream, CancellationToken cancellationToken)
    {
        using var request = new MemoryStream();
        var buffer = ArrayPool<byte>.Shared.Rent(1024);
        try
        {
            while (request.Length <= MaximumRequestBytes)
            {
                var read = await stream.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken).ConfigureAwait(false);
                if (read == 0) throw new EndOfStreamException();
                var newline = Array.IndexOf(buffer, (byte)'\n', 0, read);
                if (newline >= 0)
                {
                    if (request.Length + newline > MaximumRequestBytes || newline + 1 != read)
                        throw new InvalidDataException();
                    request.Write(buffer, 0, newline);
                    var bytes = request.ToArray();
                    if (bytes.Length > 0 && bytes[^1] == (byte)'\r') Array.Resize(ref bytes, bytes.Length - 1);
                    return bytes;
                }
                if (request.Length + read > MaximumRequestBytes) throw new InvalidDataException();
                request.Write(buffer, 0, read);
            }
            throw new InvalidDataException();
        }
        finally
        {
            CryptographicOperations.ZeroMemory(buffer);
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    private static string GetAuthorizedClientSid(NamedPipeServerStream pipe)
    {
        string? callerSid = null;
        var authorized = false;
        pipe.RunAsClient(() =>
        {
            using var identity = WindowsIdentity.GetCurrent();
            callerSid = identity.User?.Value;
            var networkSid = new SecurityIdentifier("S-1-5-2");
            var isRemote = identity.Groups?.OfType<SecurityIdentifier>().Any(group => group == networkSid) == true;
            authorized = !isRemote && callerSid is not null &&
                new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        });
        if (!authorized || callerSid is null) throw new UnauthorizedAccessException();
        return callerSid;
    }

    private static bool IsOpaqueToken(string value) => Regex.IsMatch(
        value, @"^[A-Za-z0-9_-]{43}$", RegexOptions.CultureInvariant);
}

internal sealed class BootstrapReceiptCoordinator
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly ProtectedBootstrapReceiptStore _store;
    private readonly SemaphoreSlim _gate = new(1, 1);

    internal BootstrapReceiptCoordinator(ProtectedBootstrapReceiptStore store) => _store = store;

    internal BootstrapReply InspectStatus(string callerSid)
    {
        _gate.Wait();
        try
        {
            var receipt = _store.Read();
            if (receipt is null) return new BootstrapReply(true, "not-started");
            if (!StringComparer.Ordinal.Equals(receipt.CallerSid, callerSid)) throw new UnauthorizedAccessException();
            return new BootstrapReply(true, receipt.State, Scope: new BootstrapScope(
                receipt.TenantId, receipt.CompanyId, receipt.BranchId));
        }
        finally { _gate.Release(); }
    }

    internal async Task<BootstrapReply> BootstrapAsync(
        BootstrapCommand command,
        string callerSid,
        Func<BootstrapReceipt, CancellationToken, Task> executeBootstrap,
        CancellationToken cancellationToken)
    {
        if (command.Operation != "bootstrap" || command.TenantId is null ||
            command.CompanyId is null || command.BranchId is null)
            throw new InvalidDataException();
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var receipt = _store.Read();
            if (receipt is not null)
            {
                if (!StringComparer.Ordinal.Equals(receipt.CallerSid, callerSid) ||
                    !MatchesInput(receipt, command)) throw new UnauthorizedAccessException();
                if (receipt.State == "acknowledged")
                    return new BootstrapReply(true, "acknowledged", receipt.RequestId);
                await executeBootstrap(receipt, cancellationToken).ConfigureAwait(false);
                return ToReply(receipt);
            }

            var requestId = GenerateOpaqueToken();
            var receiptToPersist = new BootstrapReceipt(
                1,
                "pending",
                callerSid,
                requestId,
                command.TenantId,
                command.CompanyId,
                command.BranchId,
                "usr_" + GenerateOpaqueToken(),
                "dev_" + GenerateOpaqueToken(),
                "cred_" + GenerateOpaqueToken(),
                GenerateOpaqueToken(),
                DateTimeOffset.UtcNow.AddDays(1).ToString("O"));
            _store.Write(receiptToPersist);
            await executeBootstrap(receiptToPersist, cancellationToken).ConfigureAwait(false);
            return ToReply(receiptToPersist);
        }
        finally
        {
            _gate.Release();
        }
    }

    internal BootstrapReply Acknowledge(BootstrapCommand command, string callerSid)
    {
        if (command.Operation != "acknowledge" || command.RequestId is null)
            throw new InvalidDataException();
        _gate.Wait();
        try
        {
            var receipt = _store.Read() ?? throw new InvalidOperationException();
            if (!StringComparer.Ordinal.Equals(receipt.CallerSid, callerSid) ||
                !StringComparer.Ordinal.Equals(receipt.RequestId, command.RequestId))
                throw new UnauthorizedAccessException();
            if (receipt.State == "pending")
            {
                receipt = receipt with
                {
                    State = "acknowledged",
                    ActorId = null,
                    DeviceId = null,
                    CredentialId = null,
                    Token = null,
                    ExpiresAt = null,
                };
                _store.Write(receipt);
            }
            return new BootstrapReply(true, "acknowledged", receipt.RequestId);
        }
        finally
        {
            _gate.Release();
        }
    }

    private static bool MatchesInput(BootstrapReceipt receipt, BootstrapCommand command) =>
        StringComparer.Ordinal.Equals(receipt.TenantId, command.TenantId) &&
        StringComparer.Ordinal.Equals(receipt.CompanyId, command.CompanyId) &&
        StringComparer.Ordinal.Equals(receipt.BranchId, command.BranchId);

    private static BootstrapReply ToReply(BootstrapReceipt receipt) => new(
        true, "pending", receipt.RequestId, receipt.ActorId, receipt.Token, receipt.ExpiresAt);

    private static string GenerateOpaqueToken() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
        .TrimEnd('=')
        .Replace('+', '-')
        .Replace('/', '_');
}

internal sealed class ProtectedBootstrapReceiptStore
{
    private const int MaximumReceiptBytes = 64 * 1024;
    private readonly string _path;
    private readonly string _serviceSid;

    internal ProtectedBootstrapReceiptStore(string path, string serviceSid)
    {
        _path = Path.GetFullPath(path);
        _serviceSid = serviceSid;
    }

    internal BootstrapReceipt? Read()
    {
        if (!File.Exists(_path)) return null;
        var file = new FileInfo(_path);
        ValidatePrivatePath(file);
        if (file.Length is <= 0 or > MaximumReceiptBytes) throw new InvalidDataException();
        var encrypted = File.ReadAllBytes(_path);
        byte[]? plaintext = null;
        try
        {
            plaintext = Unprotect(encrypted);
            var receipt = JsonSerializer.Deserialize<BootstrapReceipt>(plaintext)
                ?? throw new InvalidDataException();
            ValidateReceipt(receipt);
            return receipt;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encrypted);
            if (plaintext is not null) CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    internal void Write(BootstrapReceipt receipt)
    {
        ValidateReceipt(receipt);
        var directory = Path.GetDirectoryName(_path) ?? throw new InvalidOperationException();
        var directoryInfo = new DirectoryInfo(directory);
        if (!directoryInfo.Exists || (directoryInfo.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException("Protected Host data directory is unavailable.");
        ValidatePrivateDirectory(directoryInfo);
        if (File.Exists(_path)) ValidatePrivatePath(new FileInfo(_path));

        var plaintext = JsonSerializer.SerializeToUtf8Bytes(receipt);
        byte[]? encrypted = null;
        var temporaryPath = Path.Combine(directory, ".bootstrap-receipt-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            encrypted = Protect(plaintext);
            using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(encrypted);
                stream.Flush(flushToDisk: true);
            }
            ApplyPrivateFileAcl(temporaryPath);
            File.Move(temporaryPath, _path, overwrite: true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            if (encrypted is not null) CryptographicOperations.ZeroMemory(encrypted);
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    private void ValidatePrivatePath(FileInfo file)
    {
        if ((file.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException();
        ValidatePrivateDirectory(file.Directory ?? throw new InvalidDataException());
        ValidateAcl(file.GetAccessControl(AccessControlSections.Access));
    }

    private void ValidatePrivateDirectory(DirectoryInfo directory)
    {
        if ((directory.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException();
        ValidateAcl(directory.GetAccessControl(AccessControlSections.Access));
    }

    private void ValidateAcl(FileSystemSecurity security)
    {
        var permitted = new HashSet<string>(StringComparer.Ordinal)
        {
            _serviceSid, "S-1-5-18", "S-1-5-32-544",
        };
        var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier));
        foreach (FileSystemAccessRule rule in rules)
        {
            if (rule.AccessControlType == AccessControlType.Allow && rule.FileSystemRights != 0 &&
                rule.IdentityReference is SecurityIdentifier sid && !permitted.Contains(sid.Value))
                throw new InvalidDataException();
        }
    }

    private void ApplyPrivateFileAcl(string path)
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sidValue in new[] { _serviceSid, "S-1-5-18", "S-1-5-32-544" })
        {
            security.AddAccessRule(new FileSystemAccessRule(
                new SecurityIdentifier(sidValue), FileSystemRights.FullControl, AccessControlType.Allow));
        }
        new FileInfo(path).SetAccessControl(security);
    }

    private static void ValidateReceipt(BootstrapReceipt receipt)
    {
        if (receipt.FormatVersion != 1 ||
            !Regex.IsMatch(receipt.CallerSid, @"^S-1-\d+(?:-\d+)+$", RegexOptions.CultureInvariant) ||
            !Regex.IsMatch(receipt.RequestId, @"^[A-Za-z0-9_-]{43}$", RegexOptions.CultureInvariant) ||
            string.IsNullOrWhiteSpace(receipt.TenantId) || receipt.TenantId.Length > 256 ||
            string.IsNullOrWhiteSpace(receipt.CompanyId) || receipt.CompanyId.Length > 256 ||
            string.IsNullOrWhiteSpace(receipt.BranchId) || receipt.BranchId.Length > 256)
            throw new InvalidDataException();
        if (receipt.State == "pending")
        {
            if (receipt.ActorId is null || receipt.DeviceId is null || receipt.CredentialId is null ||
                receipt.Token is null || !Regex.IsMatch(receipt.Token, @"^[A-Za-z0-9_-]{43}$", RegexOptions.CultureInvariant) ||
                receipt.ExpiresAt is null || !DateTimeOffset.TryParse(receipt.ExpiresAt, out _))
                throw new InvalidDataException();
            return;
        }
        if (receipt.State == "acknowledged" && receipt.ActorId is null && receipt.DeviceId is null &&
            receipt.CredentialId is null && receipt.Token is null && receipt.ExpiresAt is null)
            return;
        throw new InvalidDataException();
    }

    private static byte[] Protect(byte[] plaintext) => Transform(plaintext, protect: true);
    private static byte[] Unprotect(byte[] encrypted) => Transform(encrypted, protect: false);

    private static byte[] Transform(byte[] input, bool protect)
    {
        var inputPointer = Marshal.AllocHGlobal(input.Length);
        try
        {
            Marshal.Copy(input, 0, inputPointer, input.Length);
            var data = new DataBlob { Size = input.Length, Data = inputPointer };
            var succeeded = protect
                ? CryptProtectData(ref data, "Ventio Host bootstrap receipt", IntPtr.Zero, IntPtr.Zero,
                    IntPtr.Zero, 0x00000004 | 0x00000001, out var output)
                : CryptUnprotectData(ref data, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    IntPtr.Zero, 0x00000004, out output);
            if (!succeeded) throw new InvalidOperationException("Protected Host bootstrap receipt is unavailable.");
            try
            {
                var bytes = new byte[output.Size];
                Marshal.Copy(output.Data, bytes, 0, bytes.Length);
                return bytes;
            }
            finally
            {
                var zeroes = new byte[output.Size];
                Marshal.Copy(zeroes, 0, output.Data, zeroes.Length);
                CryptographicOperations.ZeroMemory(zeroes);
                LocalFree(output.Data);
            }
        }
        finally
        {
            var zeroes = new byte[input.Length];
            Marshal.Copy(zeroes, 0, inputPointer, zeroes.Length);
            CryptographicOperations.ZeroMemory(zeroes);
            Marshal.FreeHGlobal(inputPointer);
        }
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct DataBlob { internal int Size; internal IntPtr Data; }

    [System.Runtime.InteropServices.DllImport("crypt32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob input, string description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);

    [System.Runtime.InteropServices.DllImport("crypt32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, IntPtr description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);
}
