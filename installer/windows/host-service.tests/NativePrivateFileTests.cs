using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

internal static class NativePrivateFileTests
{
    internal static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "ventio-native-private-test-" + Guid.NewGuid().ToString("N"));
        var user = WindowsIdentity.GetCurrent().User!;
        var system = new SecurityIdentifier("S-1-5-18");
        var admins = new SecurityIdentifier("S-1-5-32-544");
        var authenticated = new SecurityIdentifier("S-1-5-11");
        DirectorySecurity PrivateDirectory()
        {
            var acl = new DirectorySecurity(); acl.SetOwner(user); acl.SetAccessRuleProtection(true, false);
            foreach (var sid in new[] { user, system, admins })
                acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            return acl;
        }
        new DirectoryInfo(root).Create(PrivateDirectory());
        var file = Path.Combine(root, "literal.json");
        const string literal = "'; Start-Process powershell.exe; SELECT password FROM pg_authid; #";
        (int Code, string Output, string Diagnostic) Invoke(string operation, string path, string data = "", string? owner = null, string? reader = null)
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(new { operation, path, data, ownerSid = owner, readerSid = reader });
            using var input = new MemoryStream(bytes); using var output = new MemoryStream(); using var diagnostic = new StringWriter();
            var code = WindowsPrivateFileOperation.Run(input, output, diagnostic);
            return (code, Encoding.ASCII.GetString(output.ToArray()), diagnostic.ToString());
        }
        void Require(bool value, string reason) { if (!value) throw new InvalidOperationException(reason); }
        try
        {
            Require(Invoke("create", file, literal).Code == 0, "Native private create failed.");
            Require(Encoding.UTF8.GetString(Convert.FromBase64String(Invoke("read", file).Output)) == literal, "Private data was interpreted or corrupted.");
            Require(Invoke("create", file, "overwrite").Code == 2 && File.ReadAllText(file) == literal, "Duplicate private create overwrote data.");
            Require(Invoke("replace", file, "replacement").Code == 0 && File.ReadAllText(file) == "replacement", "Native private replacement failed.");
            Require(Invoke("verify", file).Code == 0, "Native private verification failed.");
            // Hold the actual native reader inside its output flush so the
            // writer must replace a file with a live reader, without timing races.
            using (var snapshotOutput = new PausedReadOutput())
            using (var readRequest = new MemoryStream(JsonSerializer.SerializeToUtf8Bytes(new {
                operation = "read", path = file, data = "", ownerSid = (string?)null, readerSid = (string?)null
            })))
            using (var readDiagnostic = new StringWriter())
            {
                var reading = Task.Run(() => WindowsPrivateFileOperation.Run(readRequest, snapshotOutput, readDiagnostic));
                try
                {
                    Require(snapshotOutput.Opened.Wait(TimeSpan.FromSeconds(10)), "Native snapshot reader did not open.");
                    Require(Invoke("replace", file, "concurrent replacement").Code == 0,
                        "An authorized atomic replacement was blocked by a native reader.");
                    Require(File.ReadAllText(file) == "concurrent replacement", "Concurrent replacement was not published.");
                }
                finally { snapshotOutput.Continue.Set(); }
                Require(reading.GetAwaiter().GetResult() == 0 &&
                    Encoding.UTF8.GetString(Convert.FromBase64String(Encoding.ASCII.GetString(snapshotOutput.ToArray()))) == "replacement",
                    "Atomic replacement corrupted the existing reader's snapshot.");
            }
            Require(Invoke("replace", file, "replacement").Code == 0, "Could not restore the concurrent test fixture.");
            var original = new FileInfo(file).GetAccessControl();
            var broad = new FileInfo(file).GetAccessControl();
            broad.AddAccessRule(new FileSystemAccessRule(authenticated, FileSystemRights.Read, AccessControlType.Allow));
            new FileInfo(file).SetAccessControl(broad);
            Require(Invoke("read", file).Code == 2 && Invoke("replace", file, "forbidden").Code == 2 && File.ReadAllText(file) == "replacement", "Broad private file access was accepted.");
            new FileInfo(file).SetAccessControl(original);
            Require(Invoke("witness-read-owner", file, owner: admins.Value, reader: user.Value).Code == 2, "An administrator pretended to be an independent witness owner.");
            Require(Invoke("read", file + ":alternate").Code == 2 && Invoke("create", @"\\server\share\secret", "forbidden").Code == 2, "Nonlocal or alternate-stream private path was accepted.");
            Require(Invoke("powershell.exe", file).Code == 2, "Arbitrary private-file operation was accepted.");
            var child = Path.Combine(root, "protected-child");
            new DirectoryInfo(child).Create(PrivateDirectory());
            var unsafeParent = PrivateDirectory();
            unsafeParent.AddAccessRule(new FileSystemAccessRule(authenticated, FileSystemRights.DeleteSubdirectoriesAndFiles, AccessControlType.Allow));
            new DirectoryInfo(root).SetAccessControl(unsafeParent);
            var refused = Path.Combine(child, "must-not-exist.json");
            Require(Invoke("create", refused, "forbidden").Code == 2 && !File.Exists(refused), "An untrusted ancestor could replace private storage.");
            new DirectoryInfo(root).SetAccessControl(PrivateDirectory());
            var link = Path.Combine(root, "linked-directory");
            Directory.CreateSymbolicLink(link, child);
            try { Require(Invoke("create", Path.Combine(link, "must-not-exist.json"), "forbidden").Code == 2 && !File.Exists(refused), "A private-file reparse path was accepted."); }
            finally { Directory.Delete(link); }
            var denial = Invoke("read", Path.Combine(root, "missing-secret-file.json"));
            Require(denial.Code == 2 && !denial.Diagnostic.Contains(root) && !denial.Diagnostic.Contains(literal) && denial.Output.Length == 0, "Private-file denial exposed sensitive data.");
            Console.WriteLine("Native private-file tests passed: literal data, atomic replacement with an active snapshot reader, create-only, private ownership, reader/ancestor/reparse/ADS/network denials and redacted failures.");
        }
        finally
        {
            new DirectoryInfo(root).SetAccessControl(PrivateDirectory());
            if (Path.GetDirectoryName(root) != Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar) ||
                !Path.GetFileName(root).StartsWith("ventio-native-private-test-", StringComparison.Ordinal)) throw new InvalidOperationException("Unsafe fixture cleanup.");
            Directory.Delete(root, recursive: true);
        }
    }

    private sealed class PausedReadOutput : MemoryStream
    {
        internal readonly ManualResetEventSlim Opened = new(false);
        internal readonly ManualResetEventSlim Continue = new(false);
        public override void Flush()
        {
            Opened.Set();
            if (!Continue.Wait(TimeSpan.FromSeconds(15))) throw new TimeoutException();
            base.Flush();
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing) { Continue.Set(); Opened.Dispose(); Continue.Dispose(); }
            base.Dispose(disposing);
        }
    }
}
