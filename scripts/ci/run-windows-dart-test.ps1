param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$DartArguments
)
$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_ACTIONS -or $env:RUNNER_OS -ne 'Windows') {
    throw 'This launcher is only for GitHub-hosted Windows CI tests.'
}
if ($env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Private-file CI tests require a GitHub-hosted runner.'
}

# Elevated hosted runners default new object ownership to Administrators.
# Scope the default owner to the existing current user while tests and their
# subprocesses run. Do not change privileges, groups, ACL policy or trusted SIDs.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

public sealed class VentioTestObjectOwner : IDisposable
{
    private IntPtr token;
    private SecurityIdentifier previousOwner;
    private const int TokenOwner = 4;

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(
        IntPtr handle, int type, IntPtr buffer, int size, out int needed);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetTokenInformation(
        IntPtr handle, int type, IntPtr buffer, int size);

    private SecurityIdentifier ReadOwner()
    {
        int size;
        GetTokenInformation(token, TokenOwner, IntPtr.Zero, 0, out size);
        if (size <= 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            if (!GetTokenInformation(token, TokenOwner, buffer, size, out size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return new SecurityIdentifier(Marshal.ReadIntPtr(buffer));
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private void SetOwner(SecurityIdentifier owner)
    {
        byte[] bytes = new byte[owner.BinaryLength];
        owner.GetBinaryForm(bytes, 0);
        IntPtr sid = Marshal.AllocHGlobal(bytes.Length);
        IntPtr buffer = Marshal.AllocHGlobal(IntPtr.Size);
        try
        {
            Marshal.Copy(bytes, 0, sid, bytes.Length);
            Marshal.WriteIntPtr(buffer, sid);
            if (!SetTokenInformation(token, TokenOwner, buffer, IntPtr.Size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
            Marshal.FreeHGlobal(sid);
        }
    }

    public VentioTestObjectOwner()
    {
        // TOKEN_QUERY | TOKEN_ADJUST_DEFAULT; no privilege/group changes.
        if (!OpenProcessToken(GetCurrentProcess(), 0x0008 | 0x0080, out token))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            previousOwner = ReadOwner();
            SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
            SetOwner(user);
            if (!ReadOwner().Equals(user))
                throw new InvalidOperationException("CI default object owner did not persist.");
            Console.WriteLine("VENTIO_TEST_OBJECT_OWNER: previous=" +
                previousOwner.Value + " current=" + user.Value);
        }
        catch
        {
            try
            {
                if (previousOwner != null) SetOwner(previousOwner);
            }
            finally
            {
                CloseHandle(token);
                token = IntPtr.Zero;
            }
            throw;
        }
    }

    public void Dispose()
    {
        if (token == IntPtr.Zero) return;
        try
        {
            SetOwner(previousOwner);
            if (!ReadOwner().Equals(previousOwner))
                throw new InvalidOperationException("CI default object owner was not restored.");
            Console.WriteLine("VENTIO_TEST_OBJECT_OWNER: restored=" + previousOwner.Value);
        }
        finally
        {
            CloseHandle(token);
            token = IntPtr.Zero;
        }
    }
}
'@

$scope = [VentioTestObjectOwner]::new()
try {
    & dart @DartArguments
    $testExitCode = $LASTEXITCODE
}
finally {
    $scope.Dispose()
}
exit $testExitCode
