using System.Reflection;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Host service configuration tests require Windows.");

var parse = Assembly.Load("VentioHostService").GetType("Program")?.GetMethod(
    "ReadAndValidateConfiguration", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("Host service validator was not found.");
var readinessMarker = Assembly.Load("VentioHostService").GetType("Program")?.GetMethod(
    "IsHostReadyMessage", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("Host readiness marker validator was not found.");
if (!(bool)readinessMarker.Invoke(null, ["VENTIO_HOST_READY"])! ||
    (bool)readinessMarker.Invoke(null, ["Persistent Host listening on http://127.0.0.1:8080"])! ||
    (bool)readinessMarker.Invoke(null, [null])!)
    throw new Exception("Host service accepted an invalid startup readiness marker.");

if (args.Length == 2 && args[0] == "--validate-file")
{
    _ = InvokeFile(parse, args[1], WindowsIdentity.GetCurrent().User!.Value);
    Console.WriteLine("DPAPI-protected Host configuration passed service validation.");
    return;
}

var baseConfig = new Dictionary<string, string>(StringComparer.Ordinal)
{
    ["VENTIO_HOST_DATABASE_URL"] = "postgresql://runtime:secret@127.0.0.1:54329/ventio?sslmode=disable",
    ["VENTIO_HOST_IDENTITY_API_DATABASE_URL"] = "postgresql://identity:secret@127.0.0.1:54329/ventio?sslmode=disable",
    ["VENTIO_RECOVERY_AUTHORITY_FILE"] = "C:\\ProgramData\\Ventio\\Host\\recovery.witness",
    ["VENTIO_RECOVERY_AUTHORITY_HOST_WRITES"] = "yes",
    ["VENTIO_RECOVERY_AUTHORITY_OWNER_SID"] = WindowsIdentity.GetCurrent().User!.Value,
    ["VENTIO_RECOVERY_AUTHORITY_READER_SID"] = WindowsIdentity.GetCurrent().User!.Value,
    ["VENTIO_HOST_DIAGNOSTICS_FILE"] = "C:\\ProgramData\\Ventio\\Host\\diagnostics.jsonl",
};

var valid = Invoke(parse, baseConfig);
if (valid["VENTIO_HOST_BIND_ADDRESS"] != "127.0.0.1" || valid["VENTIO_HOST_PORT"] != "8080")
    throw new Exception("Safe listener defaults were not applied.");

ExpectRejected(parse, Mutate(baseConfig, "VENTIO_HOST_DATABASE_PASSWORD", "secret"));
ExpectRejected(parse, Mutate(baseConfig, "VENTIO_HOST_IDENTITY_ADMIN_DATABASE_URL", "postgresql://identity-admin@127.0.0.1/ventio"));
ExpectRejected(parse, Mutate(baseConfig, "VENTIO_HOST_PORT", "0"));
ExpectRejected(parse, Mutate(baseConfig, "VENTIO_HOST_BIND_ADDRESS", "0.0.0.0"));
ExpectRejected(parse, Mutate(baseConfig, "VENTIO_HOST_TLS_CERTIFICATE_FILE", "relative.pem"));
ExpectAclRejected(parse, baseConfig);

Console.WriteLine("Host service configuration tests passed: safe defaults, setting allowlist, identity-admin credential rejection, invalid port, TLS path, external TLS requirement, and broad ACL rejection.");

TestBootstrapPipeAcl();
TestBootstrapProtocol();
await TestBootstrapReceiptLifecycleAsync();
Console.WriteLine("Host first-administrator broker tests passed: protected local pipe ACL, strict protocol validation, durable same-caller retries, caller/request binding, acknowledgement redaction, and DPAPI receipt confidentiality.");

static void TestBootstrapPipeAcl()
{
    var security = FirstAdminBootstrapBroker.CreatePipeSecurity(WindowsIdentity.GetCurrent().User!.Value);
    var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<PipeAccessRule>().ToArray();
    var network = new SecurityIdentifier("S-1-5-2");
    var administrators = new SecurityIdentifier("S-1-5-32-544");
    if (!security.AreAccessRulesProtected ||
        !rules.Any(rule => rule.IdentityReference == network && rule.AccessControlType == AccessControlType.Deny) ||
        !rules.Any(rule => rule.IdentityReference == administrators && rule.AccessControlType == AccessControlType.Allow) ||
        rules.Any(rule => rule.IdentityReference.Value == "S-1-5-32-545" && rule.AccessControlType == AccessControlType.Allow))
        throw new Exception("First-administrator pipe ACL does not enforce the local administrator boundary.");
}

static void TestBootstrapProtocol()
{
    var valid = Encoding.UTF8.GetBytes("{\"operation\":\"bootstrap\",\"tenantId\":\"tenant-a\",\"companyId\":\"company-a\",\"branchId\":\"branch-a\"}");
    var command = FirstAdminBootstrapBroker.ParseCommand(valid);
    if (command.Operation != "bootstrap" || command.TenantId != "tenant-a")
        throw new Exception("Valid first-administrator request was not parsed.");
    ExpectProtocolRejected(Encoding.UTF8.GetBytes("{\"operation\":\"bootstrap\",\"operation\":\"bootstrap\",\"tenantId\":\"t\",\"companyId\":\"c\",\"branchId\":\"b\"}"));
    ExpectProtocolRejected(Encoding.UTF8.GetBytes("{\"operation\":\"bootstrap\",\"tenantId\":\"t\",\"companyId\":\"c\",\"branchId\":\"b\",\"token\":\"secret\"}"));
    ExpectProtocolRejected(Encoding.UTF8.GetBytes("{\"operation\":\"bootstrap\",\"tenantId\":\" \",\"companyId\":\"c\",\"branchId\":\"b\"}"));
    ExpectProtocolRejected(Encoding.UTF8.GetBytes("{\"operation\":\"acknowledge\",\"requestId\":\"short\"}"));
}

static void ExpectProtocolRejected(byte[] request)
{
    try
    {
        _ = FirstAdminBootstrapBroker.ParseCommand(request);
        throw new Exception("Invalid first-administrator broker request was accepted.");
    }
    catch (System.Text.Json.JsonException) { }
    catch (InvalidDataException) { }
}

static async Task TestBootstrapReceiptLifecycleAsync()
{
    using var fixture = new ReceiptFixture();
    var currentSid = WindowsIdentity.GetCurrent().User!.Value;
    var store = new ProtectedBootstrapReceiptStore(fixture.Path, currentSid);
    var coordinator = new BootstrapReceiptCoordinator(store);
    var command = new BootstrapCommand("bootstrap", "tenant-a", "company-a", "branch-a");
    var executions = 0;
    Task Execute(BootstrapReceipt receipt, CancellationToken _) { executions++; return Task.CompletedTask; }

    var first = await coordinator.BootstrapAsync(command, currentSid, Execute, CancellationToken.None);
    if (!first.Success || first.Status != "pending" || first.Token is null || first.RequestId is null || executions != 1)
        throw new Exception("First administrator bootstrap receipt was not created and executed.");
    var raw = File.ReadAllBytes(fixture.Path);
    try
    {
        var text = Encoding.UTF8.GetString(raw);
        if (text.Contains(first.Token, StringComparison.Ordinal))
            throw new Exception("First administrator credential was stored in plaintext.");
    }
    finally { CryptographicOperations.ZeroMemory(raw); }

    var retry = await coordinator.BootstrapAsync(command, currentSid, Execute, CancellationToken.None);
    if (retry.RequestId != first.RequestId || retry.Token != first.Token || executions != 2)
        throw new Exception("Same-caller bootstrap retry did not reuse its durable receipt.");
    await ExpectUnauthorizedAsync(() => coordinator.BootstrapAsync(command, "S-1-5-21-999-1001", Execute, CancellationToken.None));
    await ExpectUnauthorizedAsync(() => coordinator.BootstrapAsync(
        command with { BranchId = "branch-b" }, currentSid, Execute, CancellationToken.None));
    await ExpectUnauthorizedAsync(() => Task.FromResult(coordinator.Acknowledge(
        new BootstrapCommand("acknowledge", RequestId: first.RequestId), "S-1-5-21-999-1001")));

    var acknowledged = coordinator.Acknowledge(new BootstrapCommand("acknowledge", RequestId: first.RequestId), currentSid);
    if (!acknowledged.Success || acknowledged.Status != "acknowledged" || acknowledged.Token is not null)
        throw new Exception("Bootstrap acknowledgement did not clear the recoverable credential.");
    var stored = store.Read() ?? throw new Exception("Acknowledged receipt was not durable.");
    if (stored.State != "acknowledged" || stored.Token is not null || stored.ActorId is not null)
        throw new Exception("Acknowledged receipt retained first-administrator credentials.");
    raw = File.ReadAllBytes(fixture.Path);
    try
    {
        if (Encoding.UTF8.GetString(raw).Contains(first.Token, StringComparison.Ordinal))
            throw new Exception("Acknowledged credential remained in the protected receipt file.");
    }
    finally { CryptographicOperations.ZeroMemory(raw); }
    var afterAck = await coordinator.BootstrapAsync(command, currentSid, Execute, CancellationToken.None);
    if (afterAck.Status != "acknowledged" || afterAck.Token is not null || executions != 2)
        throw new Exception("Acknowledged bootstrap was replayed or exposed its credential again.");
}

static async Task ExpectUnauthorizedAsync(Func<Task> operation)
{
    try
    {
        await operation();
        throw new Exception("Unauthorized first-administrator receipt operation was accepted.");
    }
    catch (UnauthorizedAccessException) { }
}

static Dictionary<string, string> Mutate(Dictionary<string, string> source, string key, string value)
{
    var result = new Dictionary<string, string>(source, StringComparer.Ordinal);
    result[key] = value;
    return result;
}

static Dictionary<string, string> Invoke(MethodInfo validator, Dictionary<string, string> values)
{
    using var fixture = new ConfigFixture(values);
    try
    {
        return InvokeFile(validator, fixture.Path, WindowsIdentity.GetCurrent().User!.Value);
    }
    catch (TargetInvocationException exception) when (exception.InnerException is InvalidOperationException)
    {
        throw exception.InnerException;
    }
}

static Dictionary<string, string> InvokeFile(MethodInfo validator, string path, string testServiceSid)
{
    try
    {
        return (Dictionary<string, string>)validator.Invoke(null, [path, testServiceSid])!;
    }
    catch (TargetInvocationException exception) when (exception.InnerException is InvalidOperationException)
    {
        throw exception.InnerException;
    }
}

static void ExpectRejected(MethodInfo validator, Dictionary<string, string> values)
{
    try
    {
        _ = Invoke(validator, values);
        throw new Exception("Invalid Host service configuration was accepted.");
    }
    catch (InvalidOperationException) { }
}

static void ExpectAclRejected(MethodInfo validator, Dictionary<string, string> values)
{
    using var fixture = new ConfigFixture(values, exposeToUsers: true);
    try
    {
        _ = validator.Invoke(null, [fixture.Path, WindowsIdentity.GetCurrent().User!.Value]);
        throw new Exception("Broad Host config ACL was accepted.");
    }
    catch (TargetInvocationException exception) when (exception.InnerException is InvalidOperationException) { }
}

sealed class ConfigFixture : IDisposable
{
    private readonly string _directory = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ventio-service-test-" + Guid.NewGuid().ToString("N"));
    public string Path => System.IO.Path.Combine(_directory, "service-config.dpapi");

    public ConfigFixture(Dictionary<string, string> values, bool exposeToUsers = false)
    {
        var currentSid = WindowsIdentity.GetCurrent().User!;
        var systemSid = new SecurityIdentifier("S-1-5-18");
        var adminsSid = new SecurityIdentifier("S-1-5-32-544");
        var folderSecurity = new DirectorySecurity();
        folderSecurity.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sid in new[] { currentSid, systemSid, adminsSid })
            folderSecurity.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        if (exposeToUsers)
            folderSecurity.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-32-545"), FileSystemRights.ReadAndExecute,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        Directory.CreateDirectory(_directory);
        new DirectoryInfo(_directory).SetAccessControl(folderSecurity);

        var plaintext = Encoding.UTF8.GetBytes(string.Join("\n", values.Select(pair => $"{pair.Key}={pair.Value}")));
        try
        {
            var encrypted = ProtectLocalMachine(plaintext);
            try { File.WriteAllBytes(Path, encrypted); }
            finally { CryptographicOperations.ZeroMemory(encrypted); }
        }
        finally { CryptographicOperations.ZeroMemory(plaintext); }

        var fileSecurity = new FileSecurity();
        fileSecurity.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sid in new[] { currentSid, systemSid, adminsSid })
            fileSecurity.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
        if (exposeToUsers)
            fileSecurity.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-32-545"), FileSystemRights.Read,
                AccessControlType.Allow));
        new FileInfo(Path).SetAccessControl(fileSecurity);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }

    private static byte[] ProtectLocalMachine(byte[] plaintext)
    {
        var inputPointer = Marshal.AllocHGlobal(plaintext.Length);
        try
        {
            Marshal.Copy(plaintext, 0, inputPointer, plaintext.Length);
            var input = new DataBlob { Size = plaintext.Length, Data = inputPointer };
            if (!CryptProtectData(ref input, "Ventio service configuration test", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    0x00000004 | 0x00000001, out var output))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                var bytes = new byte[output.Size];
                Marshal.Copy(output.Data, bytes, 0, bytes.Length);
                return bytes;
            }
            finally { LocalFree(output.Data); }
        }
        finally { Marshal.FreeHGlobal(inputPointer); }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob { public int Size; public IntPtr Data; }

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob input, string description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);
}

sealed class ReceiptFixture : IDisposable
{
    private readonly string _directory = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ventio-bootstrap-test-" + Guid.NewGuid().ToString("N"));
    public string Path => System.IO.Path.Combine(_directory, "bootstrap-receipt.dpapi");

    public ReceiptFixture()
    {
        var currentSid = WindowsIdentity.GetCurrent().User!;
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sid in new[] { currentSid, new SecurityIdentifier("S-1-5-18"), new SecurityIdentifier("S-1-5-32-544") })
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        Directory.CreateDirectory(_directory);
        new DirectoryInfo(_directory).SetAccessControl(security);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
