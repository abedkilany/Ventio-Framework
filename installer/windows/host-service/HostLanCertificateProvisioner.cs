using System.ComponentModel;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

internal static class HostLanCertificateProvisioner
{
    internal const string CertificateFileName = "host-lan-certificate.pem";
    internal const string PrivateKeyFileName = "host-lan-private-key.pem";
    internal const string PublicInfoFileName = "host-lan-info.json";
    private const string HostDirectorySuffix = @"Ventio\Host";
    private const uint TokenAdjustPrivileges = 0x0020;
    private const uint TokenQuery = 0x0008;
    private const uint SePrivilegeEnabled = 0x00000002;
    private const int ErrorNotAllAssigned = 1300;
    private static readonly object RestorePrivilegeLock = new();

    [StructLayout(LayoutKind.Sequential)]
    private struct Luid
    {
        internal uint LowPart;
        internal int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TokenPrivileges
    {
        internal uint PrivilegeCount;
        internal Luid Luid;
        internal uint Attributes;
    }

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess,
        out SafeAccessTokenHandle tokenHandle);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool LookupPrivilegeValue(string? systemName, string name, out Luid luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(SafeAccessTokenHandle tokenHandle,
        bool disableAllPrivileges, ref TokenPrivileges newState, uint bufferLength,
        out TokenPrivileges previousState, out uint returnLength);

    internal static int Run()
    {
        try
        {
            if (!OperatingSystem.IsWindows() || !IsAdministrator()) return 3;
            var hostSid = new NTAccount("NT SERVICE", "VentioHost")
                .Translate(typeof(SecurityIdentifier)).Value;
            var programData = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData));
            var directory = Path.GetFullPath(Path.Combine(programData, HostDirectorySuffix));
            if (!StringComparer.OrdinalIgnoreCase.Equals(
                    Path.GetDirectoryName(Path.GetDirectoryName(directory)), programData)) return 5;
            EnsureNoReparseAncestors(directory, programData);
            return Provision(directory, hostSid, Environment.MachineName, GetPrivateIpv4Addresses());
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception is Win32Exception { NativeErrorCode: ErrorNotAllAssigned }
                ? "HOST_LAN_RESTORE_PRIVILEGE_REQUIRED"
                : "HOST_LAN_CERTIFICATE_PROVISIONING_FAILED");
            return 6;
        }
    }

    internal static int SetListenerStatus(bool enabled) => UpdateListenerStatus(enabled, null);

    internal static int PublishStartedListenerStatus(string certificatePath) =>
        UpdateListenerStatus(true, certificatePath);

    private static int UpdateListenerStatus(bool enabled, string? startedCertificatePath)
    {
        try
        {
            if (!OperatingSystem.IsWindows()) return 3;
            var serviceSid = new NTAccount("NT SERVICE", "VentioHost")
                .Translate(typeof(SecurityIdentifier));
            if (startedCertificatePath is null)
            {
                if (!IsAdministrator()) return 3;
            }
            else
            {
                using var identity = WindowsIdentity.GetCurrent();
                if (!serviceSid.Equals(identity.User)) return 3;
            }
            var programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            var directory = Path.Combine(programData, HostDirectorySuffix);
            var infoPath = Path.Combine(directory, PublicInfoFileName);
            EnsureNoReparseAncestors(directory, programData);
            AssertProtectedDirectory(directory, serviceSid.Value);
            AssertProtectedFile(infoPath, serviceSid.Value, allowUsersRead: true);
            var raw = File.ReadAllBytes(infoPath);
            try
            {
                using var document = JsonDocument.Parse(raw, new JsonDocumentOptions { MaxDepth = 4 });
                var root = document.RootElement;
                if (root.GetProperty("formatVersion").GetInt32() != 1 || root.GetProperty("port").GetInt32() != 8443)
                    throw new InvalidOperationException("LAN listener metadata is invalid.");
                var hostname = root.GetProperty("hostname").GetString();
                var fingerprint = root.GetProperty("certificateSha256").GetString();
                var certificatePath = root.GetProperty("certificatePath").GetString();
                var endpoint = root.GetProperty("endpoint").GetString();
                var alternatives = root.GetProperty("alternativeEndpoints").EnumerateArray()
                    .Select(item => item.GetString()).Where(item => item is not null).ToArray();
                if (hostname is null || fingerprint is null || certificatePath is null || endpoint is null ||
                    !RegexHostName(hostname) ||
                    !StringComparer.OrdinalIgnoreCase.Equals(endpoint, $"https://{hostname}:8443") ||
                    !System.Text.RegularExpressions.Regex.IsMatch(fingerprint, "^[0-9a-f]{64}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant) ||
                    !StringComparer.OrdinalIgnoreCase.Equals(certificatePath, Path.Combine(directory, CertificateFileName)))
                    throw new InvalidOperationException("LAN listener metadata is invalid.");
                if (startedCertificatePath is not null)
                {
                    if (!StringComparer.OrdinalIgnoreCase.Equals(Path.GetFullPath(startedCertificatePath), certificatePath))
                        throw new InvalidOperationException("Started LAN certificate path differs from the published path.");
                    AssertProtectedFile(certificatePath, serviceSid.Value, allowUsersRead: true);
                    using var certificate = X509Certificate2.CreateFromPem(File.ReadAllText(certificatePath));
                    if (!StringComparer.OrdinalIgnoreCase.Equals(
                        certificate.GetCertHashString(HashAlgorithmName.SHA256), fingerprint))
                        throw new InvalidOperationException("Started LAN certificate differs from the published fingerprint.");
                }
                if (root.GetProperty("listenerEnabled").GetBoolean() != enabled)
                    WritePublicInfo(directory, serviceSid.Value, enabled, hostname, alternatives, fingerprint, certificatePath);
            }
            finally { CryptographicOperations.ZeroMemory(raw); }
            return 0;
        }
        catch
        {
            Console.Error.WriteLine("HOST_LAN_STATUS_UPDATE_FAILED");
            return 6;
        }
    }

    internal static int Provision(string directory, string serviceSid, string hostName, IReadOnlyCollection<IPAddress> addresses)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        if (!RegexHostName(hostName)) throw new InvalidOperationException("Invalid Host name.");
        var root = Path.GetFullPath(directory);
        Directory.CreateDirectory(root);
        EnsureNoReparsePoint(root);
        AssertProtectedDirectory(root, serviceSid);

        var certificatePath = Path.Combine(root, CertificateFileName);
        var privateKeyPath = Path.Combine(root, PrivateKeyFileName);
        var hasCertificate = File.Exists(certificatePath);
        var hasPrivateKey = File.Exists(privateKeyPath);
        if (hasCertificate != hasPrivateKey)
            throw new InvalidOperationException("LAN certificate files are incomplete.");
        if (hasCertificate)
        {
            AssertProtectedFile(certificatePath, serviceSid, allowUsersRead: true);
            AssertProtectedFile(privateKeyPath, serviceSid, allowUsersRead: false);
        }

        X509Certificate2 certificate;
        if (hasCertificate)
        {
            certificate = X509Certificate2.CreateFromPemFile(certificatePath, privateKeyPath);
            if (certificate.NotAfter.ToUniversalTime() <= DateTime.UtcNow.AddDays(14) ||
                !certificate.HasPrivateKey || !HasRequiredDnsName(certificate, hostName))
            {
                certificate.Dispose();
                throw new InvalidOperationException("Existing LAN certificate is invalid or near expiry.");
            }
        }
        else
        {
            certificate = CreateCertificate(hostName, addresses, out var keyPem);
            try
            {
                WriteProtectedFile(privateKeyPath, keyPem, serviceSid, allowUsersRead: false);
                WriteProtectedFile(certificatePath, certificate.ExportCertificatePem(), serviceSid, allowUsersRead: true);
            }
            catch
            {
                certificate.Dispose();
                throw;
            }
        }

        try
        {
            // The certificate stays stable across retries. Only publish IP
            // endpoints that this exact certificate authenticates; DHCP may
            // have changed since it was first created.
            var certificateAddresses = certificate.Extensions
                .OfType<X509SubjectAlternativeNameExtension>()
                .SelectMany(extension => extension.EnumerateIPAddresses())
                .ToHashSet();
            var alternativeEndpoints = addresses
                .Where(address => IsPrivateIpv4(address) && certificateAddresses.Contains(address))
                .Select(address => $"https://{address}:8443")
                .OrderBy(value => value, StringComparer.Ordinal)
                .ToArray();
            WritePublicInfo(root, serviceSid, false, hostName, alternativeEndpoints,
                certificate.GetCertHashString(HashAlgorithmName.SHA256).ToLowerInvariant(), certificatePath);
            Console.WriteLine($"HOST_LAN_CERTIFICATE_READY {certificate.GetCertHashString(HashAlgorithmName.SHA256)}");
            return 0;
        }
        finally
        {
            certificate.Dispose();
        }
    }

    private static void WritePublicInfo(string directory, string serviceSid, bool enabled, string hostname,
        IReadOnlyCollection<string?> alternativeEndpoints, string certificateSha256, string certificatePath)
    {
        var publicInfo = new
        {
            formatVersion = 1,
            hostname,
            endpoint = $"https://{hostname}:8443",
            alternativeEndpoints = alternativeEndpoints.Where(value => value is not null).ToArray(),
            port = 8443,
            certificateSha256,
            certificatePath,
            trust = "self-signed; clients must verify and explicitly trust this certificate",
            listenerEnabled = enabled,
        };
        WriteProtectedFile(Path.Combine(directory, PublicInfoFileName), JsonSerializer.Serialize(publicInfo),
            serviceSid, allowUsersRead: true);
    }

    private static X509Certificate2 CreateCertificate(string hostName, IReadOnlyCollection<IPAddress> addresses, out string privateKeyPem)
    {
        using var key = RSA.Create(3072);
        var request = new CertificateRequest($"CN={hostName}", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        var serverAuthentication = new Oid("1.3.6.1.5.5.7.3.1");
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { serverAuthentication }, true));
        var names = new SubjectAlternativeNameBuilder();
        names.AddDnsName(hostName);
        foreach (var address in addresses.Where(IsPrivateIpv4).Distinct()) names.AddIpAddress(address);
        request.CertificateExtensions.Add(names.Build());
        var now = DateTimeOffset.UtcNow;
        var certificate = request.CreateSelfSigned(now.AddMinutes(-5), now.AddYears(3));
        privateKeyPem = key.ExportPkcs8PrivateKeyPem();
        return certificate;
    }

    private static IReadOnlyCollection<IPAddress> GetPrivateIpv4Addresses()
    {
        var result = new HashSet<IPAddress>();
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up || adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var address in adapter.GetIPProperties().UnicastAddresses.Select(item => item.Address))
                if (IsPrivateIpv4(address)) result.Add(address);
        }
        return result.ToArray();
    }

    private static bool IsPrivateIpv4(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork) return false;
        var bytes = address.GetAddressBytes();
        return bytes[0] == 10 ||
            (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
            (bytes[0] == 192 && bytes[1] == 168);
    }

    private static bool HasRequiredDnsName(X509Certificate2 certificate, string hostName)
    {
        var san = certificate.Extensions.OfType<X509SubjectAlternativeNameExtension>().FirstOrDefault();
        if (san is null) return false;
        return san.EnumerateDnsNames().Any(name => StringComparer.OrdinalIgnoreCase.Equals(name, hostName));
    }

    private static void AssertProtectedFile(string path, string serviceSid, bool allowUsersRead)
    {
        var info = new FileInfo(path);
        if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException("Host certificate file is missing or redirected.");
        var security = info.GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access);
        if (!security.AreAccessRulesProtected ||
            security.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner || owner.Value != serviceSid)
            throw new InvalidOperationException("Host certificate file ACL is invalid.");
        var allowed = new HashSet<string>(StringComparer.Ordinal)
        {
            "S-1-5-18", "S-1-5-32-544", serviceSid
        };
        var rules = security.GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        var expectedRuleCount = allowUsersRead ? 4 : 3;
        if (rules.Length != expectedRuleCount)
            throw new InvalidOperationException("Host certificate file ACL is invalid.");
        foreach (var rule in rules)
        {
            var sid = ((SecurityIdentifier)rule.IdentityReference).Value;
            var publicReadRights = FileSystemRights.Read | FileSystemRights.Synchronize;
            if (rule.AccessControlType != AccessControlType.Allow ||
                (sid == "S-1-5-11" && (!allowUsersRead || rule.FileSystemRights != publicReadRights)) ||
                (sid != "S-1-5-11" && (!allowed.Contains(sid) || rule.FileSystemRights != FileSystemRights.FullControl)))
                throw new InvalidOperationException("Host certificate file ACL is invalid.");
        }
    }

    private static void AssertProtectedDirectory(string path, string serviceSid)
    {
        var info = new DirectoryInfo(path);
        var security = info.GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access);
        if (!security.AreAccessRulesProtected ||
            security.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner || owner.Value != serviceSid)
            throw new InvalidOperationException("Host certificate directory ACL is invalid.");
        var expected = new HashSet<string>(StringComparer.Ordinal)
        {
            "S-1-5-18", "S-1-5-32-544", serviceSid
        };
        var rules = security.GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        if (rules.Length != 3 || rules.Any(rule => !expected.Contains(((SecurityIdentifier)rule.IdentityReference).Value) ||
                rule.AccessControlType != AccessControlType.Allow || rule.FileSystemRights != FileSystemRights.FullControl ||
                rule.InheritanceFlags != (InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit)))
            throw new InvalidOperationException("Host certificate directory ACL is invalid.");
    }

    private static void EnsureNoReparseAncestors(string path, string boundary)
    {
        var current = Path.GetFullPath(path);
        var root = Path.GetFullPath(boundary).TrimEnd(Path.DirectorySeparatorChar);
        while (current.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        {
            if (Directory.Exists(current) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Host certificate path is redirected.");
            var parent = Directory.GetParent(current);
            if (parent is null || parent.FullName == current) break;
            current = parent.FullName;
        }
    }

    private static bool RegexHostName(string value) => value.Length is > 0 and <= 253 &&
        value.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '.');

    private static void EnsureNoReparsePoint(string path)
    {
        var info = new DirectoryInfo(path);
        if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException("Host certificate directory is missing or redirected.");
    }

    private static void WriteProtectedFile(string path, string value, string serviceSid, bool allowUsersRead)
    {
        var tempPath = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        var bytes = new UTF8Encoding(false).GetBytes(value);
        try
        {
            using (var stream = new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                       4096, FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(true);
            }
            var security = new FileSecurity();
            security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
            var host = new SecurityIdentifier(serviceSid);
            security.SetOwner(host);
            foreach (var sid in new[]
                     {
                         new SecurityIdentifier("S-1-5-18"),
                         new SecurityIdentifier("S-1-5-32-544"),
                         host
                     })
                security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
            if (allowUsersRead)
                security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-11"),
                    FileSystemRights.Read, AccessControlType.Allow));
            ApplyProtectedSecurity(new FileInfo(tempPath), security);
            if (File.Exists(path))
            {
                var existing = new FileInfo(path);
                if ((existing.Attributes & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidOperationException("Host certificate path is redirected.");
                File.Replace(tempPath, path, null, ignoreMetadataErrors: true);
            }
            else File.Move(tempPath, path);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
            if (File.Exists(tempPath)) File.Delete(tempPath);
        }
    }

    internal static void ApplyProtectedSecurity(FileSystemInfo target, FileSystemSecurity security)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(security);
        var requestedOwner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier
            ?? throw new InvalidOperationException("A SID owner is required for protected Host files.");
        using var identity = WindowsIdentity.GetCurrent();
        if (identity.User is null)
            throw new InvalidOperationException("The setup process has no user identity.");

        void Apply()
        {
            switch (target)
            {
                case FileInfo file:
                    file.SetAccessControl((FileSecurity)security);
                    break;
                case DirectoryInfo directory:
                    directory.SetAccessControl((DirectorySecurity)security);
                    break;
                default:
                    throw new ArgumentException("Only files and directories can receive Host ACLs.", nameof(target));
            }
        }

        // Setting the current user as owner needs no extra privilege. The
        // elevated setup command enables SeRestorePrivilege only for the
        // single ACL write that assigns the Host service SID, then restores
        // the token's previous privilege state immediately.
        if (requestedOwner.Equals(identity.User))
        {
            Apply();
            return;
        }

        lock (RestorePrivilegeLock)
        {
            using var restorePrivilege = EnableRestorePrivilege();
            Apply();
        }
    }

    private static RestorePrivilegeScope EnableRestorePrivilege()
    {
        if (!OpenProcessToken(GetCurrentProcess(), TokenAdjustPrivileges | TokenQuery, out var token))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to open the setup process token.");

        try
        {
            if (!LookupPrivilegeValue(null, "SeRestorePrivilege", out var luid))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to resolve SeRestorePrivilege.");

            var requested = new TokenPrivileges
            {
                PrivilegeCount = 1,
                Luid = luid,
                Attributes = SePrivilegeEnabled,
            };
            if (!AdjustTokenPrivileges(token, false, ref requested, (uint)Marshal.SizeOf<TokenPrivileges>(),
                    out var previous, out _))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to enable SeRestorePrivilege.");

            var error = Marshal.GetLastWin32Error();
            if (error == ErrorNotAllAssigned)
            {
                if (previous.PrivilegeCount > 0)
                    _ = AdjustTokenPrivileges(token, false, ref previous,
                        (uint)Marshal.SizeOf<TokenPrivileges>(), out _, out _);
                throw new Win32Exception(error, "The elevated setup token does not contain SeRestorePrivilege.");
            }
            if (error != 0)
            {
                if (previous.PrivilegeCount > 0)
                    _ = AdjustTokenPrivileges(token, false, ref previous,
                        (uint)Marshal.SizeOf<TokenPrivileges>(), out _, out _);
                throw new Win32Exception(error, "Unable to enable SeRestorePrivilege.");
            }

            return new RestorePrivilegeScope(token, previous);
        }
        catch
        {
            token.Dispose();
            throw;
        }
    }

    private sealed class RestorePrivilegeScope(SafeAccessTokenHandle token, TokenPrivileges previous) : IDisposable
    {
        private bool _disposed;

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            try
            {
                if (previous.PrivilegeCount == 0) return;
                var stateToRestore = previous;
                if (!AdjustTokenPrivileges(token, false, ref stateToRestore,
                        (uint)Marshal.SizeOf<TokenPrivileges>(), out _, out _))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to restore the setup token privilege state.");
                var error = Marshal.GetLastWin32Error();
                if (error == ErrorNotAllAssigned)
                    throw new Win32Exception(error, "Unable to restore the setup token privilege state.");
            }
            finally
            {
                token.Dispose();
            }
        }
    }

    private static bool IsAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }
}
