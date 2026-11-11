using System.Reflection;
using System.IO.Pipes;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;

if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Host service configuration tests require Windows.");

var serviceProgram = Assembly.Load("VentioHostService").GetType("Program")
    ?? throw new InvalidOperationException("Host service entry point was not found.");
var helperTimeoutField = serviceProgram.GetField(
    "FirstAdministratorHelperTimeoutSeconds", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("First-administrator helper timeout was not found.");
var helperTimeoutSeconds = (int)helperTimeoutField.GetRawConstantValue()!;
if (FirstAdminBootstrapBroker.BootstrapOperationTimeout <= TimeSpan.FromSeconds(helperTimeoutSeconds))
    throw new Exception("The first-administrator pipe timeout must exceed the helper execution timeout.");
var parse = serviceProgram.GetMethod(
    "ReadAndValidateConfiguration", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("Host service validator was not found.");
var readinessMarker = serviceProgram.GetMethod(
    "IsHostReadyMessage", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("Host readiness marker validator was not found.");
var failureCodeValidator = serviceProgram.GetMethod(
    "ValidateFirstAdministratorFailureCode", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("First-administrator failure-code validator was not found.");
if ((string?)failureCodeValidator.Invoke(null, ["HOST_FIRST_ADMIN_DATABASE_CONNECTION_FAILED"]) !=
        "HOST_FIRST_ADMIN_DATABASE_CONNECTION_FAILED" ||
    (string?)failureCodeValidator.Invoke(null, ["HOST_FIRST_ADMIN_HELPER_TIMEOUT"]) !=
        "HOST_FIRST_ADMIN_HELPER_TIMEOUT" ||
    failureCodeValidator.Invoke(null, ["postgresql://user:secret@127.0.0.1/database"]) is not null ||
    failureCodeValidator.Invoke(null, ["Exception: password authentication failed"]) is not null)
    throw new Exception("First-administrator diagnostics accepted raw or unrecognized details.");
if (!(bool)readinessMarker.Invoke(null, ["VENTIO_HOST_READY"])! ||
    (bool)readinessMarker.Invoke(null, ["Persistent Host listening on http://127.0.0.1:8080"])! ||
    (bool)readinessMarker.Invoke(null, [null])!)
    throw new Exception("Host service accepted an invalid startup readiness marker.");
var requiresBootstrap = serviceProgram.GetMethod(
    "RequiresFirstAdministratorBootstrap", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("Host bootstrap-state validator was not found.");
if (!(bool)requiresBootstrap.Invoke(null, [false, null])! ||
    !(bool)requiresBootstrap.Invoke(null, [true, "pending"])! ||
    (bool)requiresBootstrap.Invoke(null, [true, null])! ||
    (bool)requiresBootstrap.Invoke(null, [true, "acknowledged"])! ||
    (bool)requiresBootstrap.Invoke(null, [false, "acknowledged"])!)
    throw new Exception("Host service selected an invalid first-administrator startup state.");
var waitForReady = serviceProgram.GetMethod(
    "WaitForHostReadiness", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("Host readiness waiter was not found.");
var readySignal = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
readySignal.SetResult();
var unusedProcessExit = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var unusedBrokerExit = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
if (!(bool)waitForReady.Invoke(null,
        [readySignal.Task, unusedProcessExit.Task, unusedBrokerExit.Task, CancellationToken.None])!)
    throw new Exception("Host service rejected the explicit readiness marker.");
if ((bool)waitForReady.Invoke(null,
        [Task.Delay(Timeout.Infinite), Task.CompletedTask, unusedBrokerExit.Task, CancellationToken.None])!)
    throw new Exception("Host service accepted a process that exited before readiness.");
var waitForAnyOrStop = serviceProgram.GetMethod(
    "WaitForAnyOrStop", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("Host service stop-aware wait was not found.");
var pendingBootstrap = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var pendingBroker = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var stopSignal = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var interruptedSetup = (Task<Task>)waitForAnyOrStop.Invoke(null,
    [pendingBootstrap.Task, pendingBroker.Task, stopSignal.Task])!;
stopSignal.SetResult();
if (await interruptedSetup != stopSignal.Task)
    throw new Exception("Host service did not leave the pending first-administrator wait after a stop request.");
var completedBootstrap = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var runningBroker = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var unusedStop = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var successfulSetup = (Task<Task>)waitForAnyOrStop.Invoke(null,
    [completedBootstrap.Task, runningBroker.Task, unusedStop.Task])!;
completedBootstrap.SetResult();
if (await successfulSetup != completedBootstrap.Task)
    throw new Exception("Host service stop-aware wait did not preserve successful first-administrator setup.");
Console.WriteLine("Host service startup tests passed: readiness, pre-readiness process exit, bootstrap state, stop during bootstrap, and successful bootstrap completion.");

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

var lanConfig = Mutate(Mutate(baseConfig, "VENTIO_HOST_LAN_BIND_ADDRESS", "0.0.0.0"), "VENTIO_HOST_LAN_PORT", "8443");
lanConfig["VENTIO_HOST_TLS_CERTIFICATE_FILE"] = "C:\\ProgramData\\Ventio\\Host\\host-lan-certificate.pem";
lanConfig["VENTIO_HOST_TLS_PRIVATE_KEY_FILE"] = "C:\\ProgramData\\Ventio\\Host\\host-lan-private-key.pem";
_ = Invoke(parse, lanConfig);
ExpectRejected(parse, Mutate(baseConfig, "VENTIO_HOST_LAN_BIND_ADDRESS", "0.0.0.0"));
ExpectRejected(parse, Mutate(lanConfig, "VENTIO_HOST_LAN_PORT", "8080"));
ExpectRejected(parse, Mutate(lanConfig, "VENTIO_HOST_LAN_BIND_ADDRESS", "127.0.0.1"));
ExpectRejected(parse, Mutate(lanConfig, "VENTIO_HOST_TLS_PRIVATE_KEY_FILE", "C:\\Users\\Public\\key.pem"));

Console.WriteLine("Host service configuration tests passed: safe defaults, setting allowlist, identity-admin credential rejection, invalid port, TLS path, external TLS requirement, and broad ACL rejection.");
TestLanCertificateProvisioning();
TestLanCertificateServiceOwnerProvisioning();

TestBootstrapPipeAcl();
TestBootstrapProtocol();
await TestBootstrapReceiptLifecycleAsync();
await TestBootstrapReplyDeliveryAsync();

static async Task TestBootstrapReplyDeliveryAsync()
{
    var name = "Ventio.Test.Reply." + Guid.NewGuid().ToString("N");
    using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
    using var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
    var connected = server.WaitForConnectionAsync(timeout.Token);
    await client.ConnectAsync(timeout.Token);
    await connected;
    var delivery = FirstAdminBootstrapBroker.WriteReplyAndAwaitClientCloseAsync(
        server, Encoding.UTF8.GetBytes("{\"success\":true}"), timeout.Token);
    await Task.Delay(150, timeout.Token);
    if (delivery.IsCompleted) throw new Exception("Bootstrap server ended reply delivery before the client read it.");
    using var reader = new StreamReader(client, Encoding.UTF8, false, 1024, leaveOpen: true);
    if (await reader.ReadLineAsync(timeout.Token) != "{\"success\":true}")
        throw new Exception("A delayed bootstrap client lost its reply.");
    client.Dispose();
    await delivery;
    Console.WriteLine("Host first-administrator reply delivery passed: delayed client reads before server disconnect.");
}
Console.WriteLine("Host first-administrator broker tests passed: protected local pipe ACL, strict protocol validation, operation timeout exceeds helper timeout, safe failure-code validation, durable same-caller retries, caller/request binding, acknowledgement redaction, and DPAPI receipt confidentiality.");

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

static void TestLanCertificateProvisioning()
{
    var type = Assembly.Load("VentioHostService").GetType("HostLanCertificateProvisioner")
        ?? throw new InvalidOperationException("LAN certificate provisioner was not found.");
    var provision = type.GetMethod("Provision", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("LAN certificate provision method was not found.");
    var writePublicInfo = type.GetMethod("WritePublicInfo", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("LAN public-info writer was not found.");
    var directory = Path.Combine(Path.GetTempPath(), "ventio-lan-cert-test-" + Guid.NewGuid().ToString("N"));
    var sid = WindowsIdentity.GetCurrent().User!.Value;
    var serviceSid = new SecurityIdentifier(sid);
    Directory.CreateDirectory(directory);
    var directorySecurity = new DirectorySecurity();
    directorySecurity.SetAccessRuleProtection(true, false);
    directorySecurity.SetOwner(serviceSid);
    foreach (var allowed in new[] { serviceSid, new SecurityIdentifier("S-1-5-18"), new SecurityIdentifier("S-1-5-32-544") })
        directorySecurity.AddAccessRule(new FileSystemAccessRule(allowed, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
    var applyProtectedSecurity = Assembly.Load("VentioHostService").GetType("HostLanCertificateProvisioner")!
        .GetMethod("ApplyProtectedSecurity", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("Protected ACL writer was not found.");
    applyProtectedSecurity.Invoke(null, [new DirectoryInfo(directory), directorySecurity]);
    try
    {
        var address = IPAddress.Parse("192.168.33.20");
        var result = (int)provision.Invoke(null, [directory, sid, "VENTIO-TEST-HOST", new[] { address }])!;
        if (result != 0) throw new Exception("LAN certificate provisioning fixture failed.");
        var certificatePath = Path.Combine(directory, "host-lan-certificate.pem");
        var privateKeyPath = Path.Combine(directory, "host-lan-private-key.pem");
        var publicInfoPath = Path.Combine(directory, "host-lan-info.json");
        using var certificate = X509Certificate2.CreateFromPemFile(certificatePath, privateKeyPath);
        var san = certificate.Extensions.OfType<X509SubjectAlternativeNameExtension>().Single();
        if (!san.EnumerateDnsNames().Contains("VENTIO-TEST-HOST", StringComparer.OrdinalIgnoreCase) ||
            !san.EnumerateIPAddresses().Contains(address))
            throw new Exception("LAN certificate omitted its Host DNS name or private IPv4 address.");
        var firstThumbprint = certificate.GetCertHashString(HashAlgorithmName.SHA256);
        var info = System.Text.Json.JsonDocument.Parse(File.ReadAllText(publicInfoPath));
        if (info.RootElement.GetProperty("endpoint").GetString() != "https://VENTIO-TEST-HOST:8443" ||
            info.RootElement.GetProperty("certificateSha256").GetString() != firstThumbprint.ToLowerInvariant())
            throw new Exception("LAN public endpoint metadata does not match the generated certificate.");
        var keyAcl = new FileInfo(privateKeyPath).GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access);
        var keyRules = keyAcl.GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        if (!keyAcl.AreAccessRulesProtected || keyRules.Length != 3 ||
            keyRules.Any(rule => rule.IdentityReference.Value == "S-1-5-11"))
            throw new Exception("LAN private key ACL exposes it to ordinary users.");
        var publicCertAcl = new FileInfo(certificatePath).GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access);
        var publicCertRules = publicCertAcl.GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        if (publicCertRules.Length != 4 || !publicCertRules.Any(rule =>
                rule.IdentityReference.Value == "S-1-5-11" &&
                rule.FileSystemRights == (FileSystemRights.Read | FileSystemRights.Synchronize)))
            throw new Exception("The public certificate is not readable without write access.");
        writePublicInfo.Invoke(null, [directory, sid, true, "VENTIO-TEST-HOST",
            new[] { "https://192.168.33.20:8443" }, firstThumbprint.ToLowerInvariant(), certificatePath]);
        using (var enabledInfo = System.Text.Json.JsonDocument.Parse(File.ReadAllText(publicInfoPath)))
        {
            if (!enabledInfo.RootElement.GetProperty("listenerEnabled").GetBoolean())
                throw new Exception("The LAN endpoint status was not marked ready after verification.");
        }
        var changedAddress = IPAddress.Parse("192.168.33.21");
        var secondResult = (int)provision.Invoke(null, [directory, sid, "VENTIO-TEST-HOST", new[] { changedAddress }])!;
        using var secondCertificate = X509Certificate2.CreateFromPemFile(certificatePath, privateKeyPath);
        if (secondResult != 0 || secondCertificate.GetCertHashString(HashAlgorithmName.SHA256) != firstThumbprint)
            throw new Exception("LAN certificate retry unexpectedly rotated the certificate.");
        using var refreshedInfo = System.Text.Json.JsonDocument.Parse(File.ReadAllText(publicInfoPath));
        if (refreshedInfo.RootElement.GetProperty("alternativeEndpoints").GetArrayLength() != 0)
            throw new Exception("LAN metadata advertised an IP address not authenticated by its stable certificate.");
    }
    finally { Directory.Delete(directory, recursive: true); }
    Console.WriteLine("Host LAN certificate tests passed: DNS/IP SAN, stable retry, public endpoint metadata, and restrictive private-key ACL.");
}

static void TestLanCertificateServiceOwnerProvisioning()
{
    using var identity = WindowsIdentity.GetCurrent();
    if (!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
    {
        Console.WriteLine("Host LAN service-owner integration test skipped: run this focused suite elevated to validate the actual VentioHost SID.");
        return;
    }

    var type = Assembly.Load("VentioHostService").GetType("HostLanCertificateProvisioner")
        ?? throw new InvalidOperationException("LAN certificate provisioner was not found.");
    var provision = type.GetMethod("Provision", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("LAN certificate provision method was not found.");
    var applyProtectedSecurity = type.GetMethod("ApplyProtectedSecurity", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("Protected ACL writer was not found.");
    var directory = Path.Combine(Path.GetTempPath(), "ventio-lan-service-owner-test-" + Guid.NewGuid().ToString("N"));
    var serviceSid = new NTAccount("NT SERVICE", "VentioHost")
        .Translate(typeof(SecurityIdentifier)) as SecurityIdentifier
        ?? throw new InvalidOperationException("VentioHost service SID could not be resolved.");
    Directory.CreateDirectory(directory);
    try
    {
        var directorySecurity = new DirectorySecurity();
        directorySecurity.SetAccessRuleProtection(true, false);
        directorySecurity.SetOwner(serviceSid);
        foreach (var allowed in new[]
                 {
                     serviceSid,
                     new SecurityIdentifier("S-1-5-18"),
                     new SecurityIdentifier("S-1-5-32-544"),
                 })
            directorySecurity.AddAccessRule(new FileSystemAccessRule(allowed, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None, AccessControlType.Allow));
        applyProtectedSecurity.Invoke(null, [new DirectoryInfo(directory), directorySecurity]);

        var result = (int)provision.Invoke(null,
            [directory, serviceSid.Value, "VENTIO-SERVICE-OWNER-TEST", new[] { IPAddress.Parse("192.168.33.20") }])!;
        if (result != 0) throw new Exception("LAN certificate provisioning failed for the VentioHost service SID.");

        var privateKeyPath = Path.Combine(directory, "host-lan-private-key.pem");
        var keyAcl = new FileInfo(privateKeyPath).GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access);
        var keyRules = keyAcl.GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        var owner = keyAcl.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        var expectedSids = new HashSet<string>(StringComparer.Ordinal)
        {
            serviceSid.Value, "S-1-5-18", "S-1-5-32-544",
        };
        if (!keyAcl.AreAccessRulesProtected || owner?.Value != serviceSid.Value || keyRules.Length != expectedSids.Count ||
            keyRules.Any(rule => rule.AccessControlType != AccessControlType.Allow ||
                rule.FileSystemRights != FileSystemRights.FullControl ||
                !expectedSids.Remove(((SecurityIdentifier)rule.IdentityReference).Value)) ||
            expectedSids.Count != 0)
            throw new Exception("LAN private key owner or ACL did not match the exact VentioHost security policy.");
    }
    finally
    {
        Directory.Delete(directory, recursive: true);
    }
    Console.WriteLine("Host LAN service-owner test passed: elevated SeRestorePrivilege was scoped to ACL writes, and the private key owner/DACL matched the VentioHost policy.");
}

static void TestBootstrapProtocol()
{
    var valid = Encoding.UTF8.GetBytes("{\"operation\":\"bootstrap\",\"tenantId\":\"tenant-a\",\"companyId\":\"company-a\",\"branchId\":\"branch-a\"}");
    var command = FirstAdminBootstrapBroker.ParseCommand(valid);
    if (FirstAdminBootstrapBroker.ParseCommand(Encoding.UTF8.GetBytes("{\"operation\":\"status\"}")).Operation != "status")
        throw new Exception("Read-only bootstrap status request was rejected.");
    ExpectProtocolRejected(Encoding.UTF8.GetBytes("{\"operation\":\"status\",\"tenantId\":\"other\"}"));
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
    var inspection = coordinator.InspectStatus(currentSid);
    if (inspection.Scope != new BootstrapScope("tenant-a", "company-a", "branch-a") ||
        inspection.Token is not null || inspection.ActorId is not null || inspection.RequestId is not null || executions != 2)
        throw new Exception("Bootstrap status exposed a credential or changed bootstrap state.");
    await ExpectUnauthorizedAsync(() => Task.FromResult(coordinator.InspectStatus("S-1-5-21-999-1001")));
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
