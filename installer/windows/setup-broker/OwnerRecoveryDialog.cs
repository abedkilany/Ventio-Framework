using System.IO.Pipes;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;

namespace Ventio.HostSetupBroker;

// Elevated local-only wizard. Organization passwords never enter argv or files.
internal sealed class OwnerRecoveryDialog : Form
{
    private readonly ComboBox mode = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 430 };
    private readonly TextBox tenant = new(), company = new(), branch = new(), actor = new(), username = new();
    private readonly TextBox password = new() { UseSystemPasswordChar = true }, confirm = new() { UseSystemPasswordChar = true };
    private readonly TextBox result = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Height = 180, Width = 520 };
    private readonly Button submit = new() { Text = "Apply Owner operation", AutoSize = true };

    internal OwnerRecoveryDialog()
    {
        Text = "Ventio Organization Owner setup and recovery";
        Width = 590; Height = 790; StartPosition = FormStartPosition.CenterScreen;
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(16) };
        Controls.Add(panel);
        panel.Controls.Add(new Label { Text = "INITIALIZE: new organization. BOOTSTRAP: new Owner in an existing unowned organization. MIGRATE: make a named existing account Owner. RECOVER: reset the existing Owner. Existing data is retained; recovery revokes prior Owner credentials.", Width = 520, Height = 75 });
        mode.Items.AddRange(["INITIALIZE", "BOOTSTRAP", "MIGRATE", "RECOVER"]); mode.SelectedIndex = 2;
        Add(panel, "Operation", mode); Add(panel, "Organization ID", tenant);
        Add(panel, "Company ID (required for initialization; optional otherwise)", company);
        Add(panel, "Branch ID (required for initialization; optional otherwise)", branch);
        Add(panel, "Existing actor ID (required for migration)", actor);
        Add(panel, "Owner username", username); Add(panel, "New Owner password (at least 15 characters)", password);
        Add(panel, "Confirm Owner password", confirm); panel.Controls.Add(submit); panel.Controls.Add(result);
        submit.Click += async (_, _) => await ApplyAsync();
    }

    private static void Add(FlowLayoutPanel panel, string label, Control control)
    {
        panel.Controls.Add(new Label { Text = label, AutoSize = true }); control.Width = 520; panel.Controls.Add(control);
    }

    private async Task ApplyAsync()
    {
        if (password.Text.Length < 15 || password.Text != confirm.Text || tenant.Text.Trim().Length == 0)
        { result.Text = "Check the organization and password confirmation."; return; }
        if (MessageBox.Show(this, "Apply this Owner operation to organization " + tenant.Text.Trim() + "?", "Confirm local Owner operation", MessageBoxButtons.OKCancel) != DialogResult.OK) return;
        submit.Enabled = false;
        byte[]? requestBytes = null;
        try
        {
            // The pipe rejects network callers and independently verifies the
            // elevated Windows identity. Validate its server process as well.
            using var pipe = new NamedPipeClientStream(".", "Ventio.Host.FirstAdmin.v1", PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Identification);
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(90));
            await pipe.ConnectAsync(timeout.Token);
            ValidateServer(pipe);
            requestBytes = JsonSerializer.SerializeToUtf8Bytes(new {
                operation = "owner-recovery", tenantId = tenant.Text.Trim(), companyId = company.Text.Trim(),
                branchId = branch.Text.Trim(), actorId = actor.Text.Trim(), mode = mode.SelectedItem!.ToString(),
                username = username.Text.Trim(), password = password.Text, requestId = Guid.NewGuid().ToString("N")
            });
            await pipe.WriteAsync(requestBytes, timeout.Token); await pipe.WriteAsync(new byte[] { 10 }, timeout.Token); await pipe.FlushAsync(timeout.Token);
            using var reader = new StreamReader(pipe);
            var line = await reader.ReadLineAsync(timeout.Token);
            if (line is null || line.Length > 16384) throw new InvalidDataException();
            using var response = JsonDocument.Parse(line);
            if (!response.RootElement.GetProperty("success").GetBoolean())
            { result.Text = "Owner operation denied or unavailable. Verify the explicit account and installed Host version. No automatic account selection is performed."; return; }
            var owner = response.RootElement.GetProperty("ownerRecovery");
            result.Text = "Owner updated for " + owner.GetProperty("tenantId").GetString() + ".\r\nActor: " + owner.GetProperty("actorId").GetString() +
                "\r\nEnroll Ventio through Connect Client using this one-time code (valid five minutes), then sign in with the chosen username/password:\r\n" + owner.GetProperty("code").GetString();
            var infoPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Ventio", "Host", "host-lan-info.json");
            if (File.Exists(infoPath)) {
                using var info = JsonDocument.Parse(File.ReadAllText(infoPath));
                result.AppendText("\r\nHost: " + info.RootElement.GetProperty("endpoint").GetString() + "\r\nCertificate SHA-256: " + info.RootElement.GetProperty("certificateSha256").GetString());
            }
        }
        catch { result.Text = "Owner operation could not be confirmed. Check Host availability. Inspect the organization identity audit before retrying a migration or initialization."; }
        finally { if (requestBytes is not null) CryptographicOperations.ZeroMemory(requestBytes); password.Clear(); confirm.Clear(); submit.Enabled = true; }
    }

    private static void ValidateServer(NamedPipeClientStream pipe)
    {
        if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var pid)) throw new InvalidDataException();
        using var process = System.Diagnostics.Process.GetProcessById((int)pid);
        var path = process.MainModule?.FileName;
        var expected = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "VentioHostService.exe"));
        if (path is null || !Path.GetFullPath(path).Equals(expected, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException();
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool GetNamedPipeServerProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint processId);
}
