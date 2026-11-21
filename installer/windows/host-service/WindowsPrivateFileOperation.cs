using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

// Runs as the invoking identity, without elevation, impersonation or a service
// control connection. This is the fixed stdin protocol used by the Dart Host's
// existing private-file store. It cannot execute code, SQL or another process.
internal static class WindowsPrivateFileOperation
{
    private const int MaximumBytes = 1048576;
    private static readonly SecurityIdentifier SystemSid = new("S-1-5-18");
    private static readonly SecurityIdentifier Administrators = new("S-1-5-32-544");
    private const string TrustedInstaller = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";
    private static readonly HashSet<string> Operations = new(StringComparer.Ordinal)
    {
        "read", "verify", "create", "replace", "witness-read", "witness-read-runtime",
        "witness-read-owner", "witness-create", "witness-replace", "witness-lock"
    };

    internal static int Run(Stream input, Stream output, TextWriter diagnostics)
    {
        var phase = "read_request";
        byte[]? request = null;
        try
        {
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
            using var buffer = new MemoryStream();
            var block = new byte[8192];
            int count;
            while ((count = input.Read(block)) != 0)
            {
                if (buffer.Length + count > MaximumBytes * 8 + 4096) throw new InvalidDataException();
                buffer.Write(block, 0, count);
            }
            request = buffer.ToArray();
            CryptographicOperations.ZeroMemory(block);
            using var json = JsonDocument.Parse(request, new JsonDocumentOptions { MaxDepth = 4 });
            var root = json.RootElement;
            var keys = new HashSet<string>(["operation", "path", "data", "ownerSid", "readerSid"], StringComparer.Ordinal);
            if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Count() != keys.Count ||
                root.EnumerateObject().Any(p => !keys.Remove(p.Name)) || keys.Count != 0) throw new InvalidDataException();
            var operation = root.GetProperty("operation").GetString() ?? "";
            if (!Operations.Contains(operation)) throw new InvalidDataException();
            phase = "validate_target_path";
            var rawPath = root.GetProperty("path").GetString() ?? "";
            if (!Path.IsPathFullyQualified(rawPath)) throw new InvalidDataException();
            var path = Path.GetFullPath(rawPath);
            if (path.Length < 4 || path[1] != ':' || path[2] != '\\' || !char.IsAsciiLetter(path[0]) ||
                path.IndexOf(':', 2) >= 0 || new DriveInfo(Path.GetPathRoot(path)!).DriveType != DriveType.Fixed)
                throw new InvalidDataException();
            using var identity = WindowsIdentity.GetCurrent();
            var current = identity.User ?? throw new InvalidOperationException();
            var runtime = operation == "witness-read-runtime";
            var ownerRead = operation == "witness-read-owner";
            var owner = runtime || ownerRead
                ? new SecurityIdentifier(root.GetProperty("ownerSid").GetString() ?? throw new InvalidDataException())
                : current;
            var readerValue = root.GetProperty("readerSid").GetString();
            var reader = string.IsNullOrWhiteSpace(readerValue) ? null : new SecurityIdentifier(readerValue);
            if (ownerRead && !owner.Equals(current)) throw new UnauthorizedAccessException();
            if (runtime && (owner.Equals(current) || reader is null ||
                (!reader.Equals(current) && identity.Groups?.Contains(reader) != true))) throw new UnauthorizedAccessException();
            var action = runtime || ownerRead ? "read" : operation.Replace("witness-", "", StringComparison.Ordinal);
            if (operation.StartsWith("witness-", StringComparison.Ordinal) && action != "lock" && reader is null)
                throw new InvalidDataException();
            var fileReader = action == "lock" || Path.GetFileName(path).EndsWith(".lock", StringComparison.Ordinal) ? null : reader;
            var parent = Path.GetDirectoryName(path) ?? throw new InvalidDataException();
            phase = "validate_parent_path";
            NoReparseChain(parent);
            phase = "validate_ancestor_acl";
            AssertAncestors(parent, owner, current);
            phase = "validate_parent_acl";
            AssertAcl(new DirectoryInfo(parent), owner, reader);
            if (action is "read" or "verify")
            {
                phase = "validate_target_acl";
                NoReparseChain(path);
                AssertAcl(new FileInfo(path), owner, fileReader);
                // Readers keep a stable, ACL-validated snapshot while another
                // authorized process atomically replaces the directory entry.
                // Without delete sharing, normal runtime admission reads can
                // reject an independent witness update with ERROR_SHARING_VIOLATION.
                using var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
                if (file.Length > MaximumBytes) throw new InvalidDataException();
                if (action == "read")
                {
                    var bytes = new byte[(int)file.Length];
                    try
                    {
                        file.ReadExactly(bytes);
                        var encoded = Encoding.ASCII.GetBytes(Convert.ToBase64String(bytes));
                        try { output.Write(encoded); output.Flush(); }
                        finally { CryptographicOperations.ZeroMemory(encoded); }
                    }
                    finally { CryptographicOperations.ZeroMemory(bytes); }
                }
                return 0;
            }
            phase = "prepare_write";
            var data = Encoding.UTF8.GetBytes(root.GetProperty("data").GetString() ?? throw new InvalidDataException());
            try
            {
                if (data.Length > MaximumBytes) throw new InvalidDataException();
                if (action == "replace") { NoReparseChain(path); AssertAcl(new FileInfo(path), owner, fileReader); }
                var writePath = action == "replace" ? Path.Combine(parent, ".ventio-" + Guid.NewGuid().ToString("N")) : path;
                try
                {
                    phase = "create_file";
                    var security = FileSecurity(current, fileReader);
                    using (var file = new FileInfo(writePath).Create(FileMode.CreateNew, FileSystemRights.Write,
                        FileShare.ReadWrite, 4096, FileOptions.WriteThrough, security))
                    {
                        file.Write(data); file.Flush(true);
                    }
                    if (action == "replace")
                    {
                        phase = "replace_file";
                        File.Replace(writePath, path, null);
                    }
                    phase = "verify_file_acl";
                    AssertAcl(new FileInfo(path), owner, fileReader);
                }
                finally
                {
                    if (action == "replace" && File.Exists(writePath)) File.Delete(writePath);
                }
            }
            finally { CryptographicOperations.ZeroMemory(data); }
            return 0;
        }
        catch (Exception error)
        {
            // No exception message: it can contain a path, file data or a secret.
            var type = error.GetType().Name;
            if (!System.Text.RegularExpressions.Regex.IsMatch(type, "\\A[A-Za-z]{1,64}\\z")) type = "Unknown";
            diagnostics.WriteLine($"VENTIO_PRIVATE_HELPER_FAILURE:{phase}:{type}:0x{error.HResult:X8}");
            return 2;
        }
        finally { if (request is not null) CryptographicOperations.ZeroMemory(request); }
    }

    private static FileSecurity FileSecurity(SecurityIdentifier owner, SecurityIdentifier? reader)
    {
        var security = new FileSecurity(); security.SetAccessRuleProtection(true, false); security.SetOwner(owner);
        foreach (var sid in new[] { owner, SystemSid, Administrators }.DistinctBy(s => s.Value))
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
        if (reader is not null && !new[] { owner.Value, SystemSid.Value, Administrators.Value }.Contains(reader.Value))
            security.AddAccessRule(new FileSystemAccessRule(reader, FileSystemRights.Read | FileSystemRights.Synchronize, AccessControlType.Allow));
        return security;
    }

    private static void AssertAcl(FileSystemInfo target, SecurityIdentifier owner, SecurityIdentifier? reader)
    {
        target.Refresh();
        if (!target.Exists || (target.Attributes & FileAttributes.ReparsePoint) != 0) throw new UnauthorizedAccessException();
        FileSystemSecurity security = target switch
        {
            DirectoryInfo directory => directory.GetAccessControl(),
            FileInfo file when (file.Attributes & FileAttributes.Directory) == 0 => file.GetAccessControl(),
            _ => throw new UnauthorizedAccessException()
        };
        if (!security.AreAccessRulesProtected || !owner.Equals(security.GetOwner(typeof(SecurityIdentifier)))) throw new UnauthorizedAccessException();
        var required = new HashSet<string>([owner.Value, SystemSid.Value, Administrators.Value], StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        if (reader is not null) required.Add(reader.Value);
        var readRights = target is DirectoryInfo ? FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize : FileSystemRights.Read | FileSystemRights.Synchronize;
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            var sid = rule.IdentityReference.Value;
            var full = sid == owner.Value || sid == SystemSid.Value || sid == Administrators.Value;
            if (rule.IsInherited || rule.AccessControlType != AccessControlType.Allow || !required.Contains(sid) ||
                rule.FileSystemRights != (full ? FileSystemRights.FullControl : readRights)) throw new UnauthorizedAccessException();
            seen.Add(sid);
        }
        if (!required.SetEquals(seen)) throw new UnauthorizedAccessException();
    }

    private static void NoReparseChain(string path)
    {
        for (var current = Path.GetFullPath(path); current is not null; current = Path.GetDirectoryName(current))
            if (!Path.Exists(current) || (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new UnauthorizedAccessException();
    }

    private static void AssertAncestors(string directory, SecurityIdentifier owner, SecurityIdentifier current)
    {
        var trusted = new HashSet<string>([owner.Value, current.Value, SystemSid.Value, Administrators.Value, TrustedInstaller], StringComparer.Ordinal);
        for (var parent = Directory.GetParent(directory); parent is not null; parent = parent.Parent)
        {
            var security = parent.GetAccessControl();
            if (security.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier sid || !trusted.Contains(sid.Value)) throw new UnauthorizedAccessException();
            foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            {
                const FileSystemRights destructive = FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
                if (rule.AccessControlType == AccessControlType.Allow && (rule.PropagationFlags & PropagationFlags.InheritOnly) == 0 &&
                    (((int)rule.FileSystemRights & 0x10000000) != 0 || (rule.FileSystemRights & destructive) != 0) &&
                    !trusted.Contains(rule.IdentityReference.Value)) throw new UnauthorizedAccessException();
            }
        }
    }
}
