using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Host service configuration tests require Windows.");

var parse = Assembly.Load("VentioHostService").GetType("Program")?.GetMethod(
    "ReadAndValidateConfiguration", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("Host service validator was not found.");

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
