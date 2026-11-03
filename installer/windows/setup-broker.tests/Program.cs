using BrokerProgram = Ventio.HostSetupBroker.Program;

var secret = System.Text.Encoding.UTF8.GetBytes("isolated-bootstrap-handoff-test");
var expectedSecret = secret.ToArray();
var entropy = System.Text.Encoding.UTF8.GetBytes("0123456789abcdef0123456789abcdef");
var encrypted = BrokerProgram.ProtectForCurrentUser(secret, entropy);
var decrypted = BrokerProgram.UnprotectForCurrentUser(encrypted, System.Text.Encoding.UTF8.GetBytes("0123456789abcdef0123456789abcdef"));
if (!decrypted.SequenceEqual(expectedSecret) || encrypted.SequenceEqual(expectedSecret))
    throw new InvalidOperationException("Bootstrap handoff DPAPI round-trip failed.");
var incorrectEntropyRejected = false;
try { _ = BrokerProgram.UnprotectForCurrentUser(encrypted, System.Text.Encoding.UTF8.GetBytes("different-operation")); }
catch (InvalidOperationException) { incorrectEntropyRejected = true; }
if (!incorrectEntropyRejected) throw new InvalidOperationException("Another setup operation could decrypt the handoff.");
System.Security.Cryptography.CryptographicOperations.ZeroMemory(expectedSecret);
System.Security.Cryptography.CryptographicOperations.ZeroMemory(decrypted);
System.Security.Cryptography.CryptographicOperations.ZeroMemory(encrypted);

if (!BrokerProgram.IsAllowedBootstrapPeerState(2) || !BrokerProgram.IsAllowedBootstrapPeerState(4) ||
    BrokerProgram.IsAllowedBootstrapPeerState(1) || BrokerProgram.IsAllowedBootstrapPeerState(3) || BrokerProgram.IsAllowedBootstrapPeerState(7))
    throw new InvalidOperationException("Bootstrap acknowledgement did not handle only live startup and running service states.");

if (!BrokerProgram.IsSafeFailureCode("HOST_DATABASE_MIGRATION_LEDGER_INVALID") ||
    !BrokerProgram.IsSafeFailureCode("HOST_FIRST_ADMIN_DATABASE_CONNECTION_FAILED") ||
    !BrokerProgram.IsSafeFailureCode("HOST_FIRST_ADMIN_HELPER_TIMEOUT") ||
    BrokerProgram.IsSafeFailureCode("postgresql://user:secret@127.0.0.1/database") ||
    BrokerProgram.IsSafeFailureCode("Exception: permission denied"))
    throw new InvalidOperationException("Setup broker accepted an unsafe first-administrator diagnostic.");

var statusJson = BrokerProgram.SerializeSetupStatus(
    1,
    "0123456789abcdef0123456789abcdef",
    "running",
    "PAYLOAD_VALIDATION",
    null,
    DateTimeOffset.Parse("2026-10-31T09:00:00Z"));
using (var statusDocument = System.Text.Json.JsonDocument.Parse(statusJson))
{
    var statusKeys = statusDocument.RootElement.EnumerateObject()
        .Select(property => property.Name)
        .ToHashSet(StringComparer.Ordinal);
    if (!statusKeys.SetEquals([
        "formatVersion", "operationId", "state", "phase", "failureCode", "updatedAtUtc"
    ]))
        throw new InvalidOperationException("Setup status JSON field casing differs from the Flutter contract.");
}

var readOnlyRights = new[]
{
    System.Security.AccessControl.FileSystemRights.ReadAndExecute,
    (System.Security.AccessControl.FileSystemRights)unchecked((int)0xA0000000)
};
foreach (var rights in readOnlyRights)
{
    if (BrokerProgram.HasWriteCapability(rights))
        throw new InvalidOperationException($"Read-only ACL rights were rejected as write-capable: {rights}.");
}

var writeCapableRights = new[]
{
    System.Security.AccessControl.FileSystemRights.Write,
    System.Security.AccessControl.FileSystemRights.Modify,
    System.Security.AccessControl.FileSystemRights.Delete,
    System.Security.AccessControl.FileSystemRights.ChangePermissions,
    System.Security.AccessControl.FileSystemRights.TakeOwnership,
    System.Security.AccessControl.FileSystemRights.FullControl,
    (System.Security.AccessControl.FileSystemRights)0x40000000,
    (System.Security.AccessControl.FileSystemRights)0x10000000
};
foreach (var rights in writeCapableRights)
{
    if (!BrokerProgram.HasWriteCapability(rights))
        throw new InvalidOperationException($"Write-capable ACL rights were not detected: {rights}.");
}

var validId = "0123456789abcdef0123456789abcdef";
var currentSid = System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value;
var parsed = BrokerProgram.Request.Parse([
    "--setup-new-host", validId, "tenant-a", "company-a", "branch-a", currentSid
]);
if (parsed.OperationId != validId || parsed.TenantId != "tenant-a" || parsed.RequesterSid != currentSid)
    throw new InvalidOperationException("Setup request values were not validated and preserved.");
var resume = BrokerProgram.Request.Parse(["--resume-first-administrator", validId, "tenant-a", "company-a", "branch-a", currentSid]);
if (!resume.ResumeFirstAdministrator || parsed.ResumeFirstAdministrator || resume.OperationId != validId)
    throw new InvalidOperationException("Resume-first-administrator request lost its restricted operation mode.");

var rejected = new[]
{
    Array.Empty<string>(),
    new[] { "--recover-existing-host", validId, "tenant-a", "company-a", "branch-a", currentSid },
    new[] { "--setup-new-host", validId, "tenant-a", "company-a", "branch-a", currentSid, "--script", "C:\\temp\\setup.ps1" },
    new[] { "--setup-new-host", "..\\Ventio", "tenant-a", "company-a", "branch-a", currentSid },
    new[] { "--setup-new-host", "0123456789abcdef0123456789abcdeZ", "tenant-a", "company-a", "branch-a", currentSid },
    new[] { "--setup-new-host", validId, "tenant-a;Remove-Item", "company-a", "branch-a", currentSid },
    new[] { "--setup-new-host", validId, "tenant-a", "company-a", "branch-a", "not-a-sid" }
};
foreach (var request in rejected)
{
    try
    {
        _ = BrokerProgram.Request.Parse(request);
        throw new InvalidOperationException("Unsupported request was accepted.");
    }
    catch (ArgumentException)
    {
    }
}

Console.WriteLine("Host setup broker validation passed: read-only and write-capable ACL rights, fixed new-host operation, scope allowlist, caller SID, GUID operation ID, and arbitrary argument rejection.");
