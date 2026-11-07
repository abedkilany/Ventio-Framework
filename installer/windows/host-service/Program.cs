using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

internal static class Program
{
    private const string ServiceName = "VentioHost";
    internal const string HostReadyMessage = "VENTIO_HOST_READY";
    internal const int FirstAdministratorHelperTimeoutSeconds = 60;
    internal const int TrustedPairingHelperTimeoutSeconds = 90;
    internal const int TrustedSchemaUpgradeHelperTimeoutSeconds = 900;
    private static readonly TimeSpan HostStartupTimeout = TimeSpan.FromSeconds(90);
    private const int ServiceWin32OwnProcess = 0x00000010;
    private const int ServiceStartPending = 2;
    private const int ServiceRunning = 4;
    private const int ServiceStopPending = 3;
    private const int ServiceStopped = 1;
    private const int ServiceAcceptStop = 1;
    private const int ServiceAcceptShutdown = 4;
    private const int ControlStop = 1;
    private const int ControlShutdown = 5;
    private const int DpapiLocalMachine = 4;
    private const uint MaximumConfigBytes = 64 * 1024;
    private static readonly HashSet<string> FirstAdminFailureCodes = new(StringComparer.Ordinal)
    {
        "HOST_FIRST_ADMIN_REQUEST_INVALID",
        "HOST_FIRST_ADMIN_DATABASE_CONNECTION_FAILED",
        "HOST_FIRST_ADMIN_RECOVERY_AUTHORITY_FAILED",
        "HOST_FIRST_ADMIN_IDENTITY_BOOTSTRAP_FAILED",
        "HOST_FIRST_ADMIN_HELPER_TIMEOUT",
        "HOST_FIRST_ADMIN_RESULT_INVALID",
    };

    private static readonly string ConfigPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "Ventio", "Host", "service-config.dpapi");

    private static readonly ManualResetEventSlim StopRequested = new(false);
    private static readonly TaskCompletionSource StopSignal = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static readonly object Sync = new();
    private static readonly ServiceMainCallback ServiceMainThunk = ServiceMain;
    private static readonly HandlerCallback HandlerThunk = HandleControl;
    private static IntPtr _statusHandle;
    private static Process? _hostProcess;
    private static ServiceStatus _status;
    private static int _serviceExitCode;
    private static int _startupCheckpoint;

    private static int Main(string[] args)
    {
        if (args.Length > 0)
        {
            if (args.Length == 1 && args[0] == "--provision-lan-certificate")
                return HostLanCertificateProvisioner.Run();
            if (args.Length == 2 && args[0] == "--set-lan-listener-status" &&
                args[1] is "enabled" or "disabled")
                return HostLanCertificateProvisioner.SetListenerStatus(args[1] == "enabled");
            return 2;
        }

        var table = new[]
        {
            new ServiceTableEntry { ServiceName = ServiceName, ServiceMain = ServiceMainThunk },
            new ServiceTableEntry { ServiceName = null, ServiceMain = null },
        };
        if (!StartServiceCtrlDispatcher(table))
        {
            // SCM error details can include machine state. Keep console output generic.
            var error = Marshal.GetLastWin32Error();
            Console.Error.WriteLine($"Ventio Host service must be started by Windows Service Control Manager (Win32 {error}).");
            return error == 1063 ? 2 : 3;
        }
        return _serviceExitCode;
    }

    private static void ServiceMain(int argc, IntPtr argv)
    {
        _statusHandle = RegisterServiceCtrlHandlerEx(ServiceName, HandlerThunk, IntPtr.Zero);
        if (_statusHandle == IntPtr.Zero)
        {
            _serviceExitCode = 3;
            return;
        }

        _startupCheckpoint = 1;
        SetStatus(ServiceStartPending, checkpoint: 1, waitHintMs: 15000);
        CancellationTokenSource? brokerCancellation = null;
        Task? brokerTask = null;
        Dictionary<string, string>? bootstrapEnvironment = null;
        try
        {
            var environment = ReadAndValidateConfiguration(ConfigPath);
            var serviceSid = new NTAccount("NT SERVICE", ServiceName)
                .Translate(typeof(SecurityIdentifier)).Value;
            bootstrapEnvironment = CreateBootstrapEnvironment(environment);
            var hostReady = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var bootstrapCompleted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var receiptPath = Path.Combine(Path.GetDirectoryName(ConfigPath)!, "bootstrap-receipt.dpapi");
            var receiptStore = new ProtectedBootstrapReceiptStore(receiptPath, serviceSid);
            var coordinator = new BootstrapReceiptCoordinator(receiptStore);
            var broker = new FirstAdminBootstrapBroker(coordinator, async (receipt, cancellationToken) =>
            {
                await ExecuteFirstAdministratorBootstrapAsync(
                    receipt, bootstrapEnvironment, cancellationToken).ConfigureAwait(false);
                bootstrapCompleted.TrySetResult();
            }, (command, callerSid, cancellationToken) =>
                ExecuteTrustedPairingAsync(command, callerSid, bootstrapEnvironment, cancellationToken),
                (command, callerSid, cancellationToken) =>
                    ExecuteTrustedCredentialReissueAsync(command, callerSid, bootstrapEnvironment, cancellationToken));
            brokerCancellation = new CancellationTokenSource();
            var brokerReady = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            brokerTask = Task.Run(() => broker.RunAsync(brokerCancellation.Token, brokerReady));
            var startup = Task.WhenAny(brokerReady.Task, brokerTask, Task.Delay(TimeSpan.FromSeconds(10)))
                .GetAwaiter().GetResult();
            if (startup == brokerTask)
                brokerTask.GetAwaiter().GetResult();
            if (startup != brokerReady.Task && startup != brokerTask)
                throw new InvalidOperationException("Local bootstrap broker did not become ready.");
            brokerReady.Task.GetAwaiter().GetResult();

            var upgradeRequestPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "Ventio", "Host", "schema-upgrade.request.dpapi");
            if (File.Exists(upgradeRequestPath))
            {
                var request = ReadHostSchemaUpgradeRequest(upgradeRequestPath, serviceSid);
                var resultPath = Path.Combine(Path.GetDirectoryName(upgradeRequestPath)!, "schema-upgrade.result.json");
                try
                {
                    using var upgradeProgressCancellation = new CancellationTokenSource();
                    var upgradeProgress = Task.Run(async () =>
                    {
                        while (!upgradeProgressCancellation.IsCancellationRequested)
                        {
                            SetStatus(ServiceStartPending, checkpoint: NextStartupCheckpoint(), waitHintMs: 15000);
                            try { await Task.Delay(TimeSpan.FromSeconds(8), upgradeProgressCancellation.Token).ConfigureAwait(false); }
                            catch (OperationCanceledException) { break; }
                        }
                    });
                    try
                    {
                    ExecuteHostSchemaUpgradeAsync(request, bootstrapEnvironment)
                        .GetAwaiter().GetResult();
                    WriteHostSchemaUpgradeResult(resultPath, request.OperationId, "complete", null, null);
                    File.Delete(upgradeRequestPath);
                    }
                    finally
                    {
                        upgradeProgressCancellation.Cancel();
                        try { upgradeProgress.GetAwaiter().GetResult(); } catch { }
                    }
                }
                catch (HostSchemaUpgradeFailureException exception)
                {
                    WriteHostSchemaUpgradeResult(
                        resultPath, request.OperationId,
                        exception.FailureCode == "OUTCOME_UNKNOWN" ? "unknown" : "failed",
                        exception.FailureCode, exception.FailureStage);
                    throw;
                }
            }

            var recoveryAuthorityPath = bootstrapEnvironment["VENTIO_RECOVERY_AUTHORITY_FILE"];
            var recoveryAuthorityExists = File.Exists(recoveryAuthorityPath);
            var savedReceipt = receiptStore.Read();
            var setupPending = RequiresFirstAdministratorBootstrap(
                recoveryAuthorityExists, savedReceipt?.State);
            if (!setupPending && !recoveryAuthorityExists)
            {
                throw new InvalidOperationException("Recovery Authority is missing for an initialized Host.");
            }

            if (setupPending)
            {
                // A new installation, or a pending recovery witness, needs the
                // authenticated bootstrap broker before the Host API can start.
                lock (Sync)
                {
                    SetStatus(ServiceRunning, checkpoint: 0, waitHintMs: 0,
                        controlsAccepted: ServiceAcceptStop | ServiceAcceptShutdown);
                }
                var setup = WaitForAnyOrStop(bootstrapCompleted.Task, brokerTask, StopSignal.Task)
                    .GetAwaiter().GetResult();
                if (StopRequested.IsSet) return;
                if (setup == brokerTask) brokerTask.GetAwaiter().GetResult();
                bootstrapCompleted.Task.GetAwaiter().GetResult();
            }

            if (StopRequested.IsSet) return;
            SetStatus(ServiceStartPending, checkpoint: NextStartupCheckpoint(), waitHintMs: 15000);
            var process = StartHostProcess(environment, hostReady);
            var processExit = process.WaitForExitAsync();
            if (!WaitForHostReadiness(
                hostReady.Task, processExit, brokerTask, brokerCancellation.Token))
            {
                if (StopRequested.IsSet) return;
                throw new InvalidOperationException("Host did not become ready after startup checks.");
            }
            lock (Sync)
            {
                SetStatus(ServiceRunning, checkpoint: 0, waitHintMs: 0,
                    controlsAccepted: ServiceAcceptStop | ServiceAcceptShutdown);
            }

            var completed = WaitForAnyOrStop(processExit!, brokerTask, StopSignal.Task)
                .GetAwaiter().GetResult();
            if (StopRequested.IsSet) return;
            if (completed == brokerTask && !StopRequested.IsSet)
                brokerTask.GetAwaiter().GetResult();
            processExit!.GetAwaiter().GetResult();
            _serviceExitCode = StopRequested.IsSet ? 0 : (process!.ExitCode == 0 ? 2 : process.ExitCode);
        }
        catch
        {
            // Do not write exceptions: they may contain database URLs or local paths.
            _serviceExitCode = StopRequested.IsSet ? 0 : 2;
        }
        finally
        {
            brokerCancellation?.Cancel();
            if (brokerTask is not null)
            {
                try { _ = brokerTask.Wait(TimeSpan.FromSeconds(5)); } catch { }
            }
            brokerCancellation?.Dispose();
            bootstrapEnvironment?.Clear();
            lock (Sync)
            {
                if (_hostProcess is { HasExited: false } process)
                {
                    try { process.Kill(entireProcessTree: true); } catch { }
                }
                _hostProcess?.Dispose();
                _hostProcess = null;
            }
            SetStatus(ServiceStopped, checkpoint: 0, waitHintMs: 0, win32ExitCode: _serviceExitCode);
        }
    }

    internal static bool IsHostReadyMessage(string? message) =>
        StringComparer.Ordinal.Equals(message, HostReadyMessage);

    internal static Task<Task> WaitForAnyOrStop(Task primary, Task secondary, Task stopRequested) =>
        Task.WhenAny(primary, secondary, stopRequested);

    internal static bool RequiresFirstAdministratorBootstrap(
        bool recoveryAuthorityExists,
        string? receiptState) =>
        StringComparer.Ordinal.Equals(receiptState, "pending") ||
        (!recoveryAuthorityExists && receiptState is null);

    private static bool WaitForHostReadiness(
        Task hostReady,
        Task processExit,
        Task brokerTask,
        CancellationToken cancellationToken)
    {
        var timer = Stopwatch.StartNew();
        while (timer.Elapsed < HostStartupTimeout)
        {
            if (StopRequested.IsSet) return false;
            var poll = Task.Delay(TimeSpan.FromSeconds(10), cancellationToken);
            var completed = Task.WhenAny(hostReady, processExit, brokerTask, poll)
                .GetAwaiter().GetResult();
            if (completed == hostReady) return true;
            if (completed == processExit)
            {
                processExit.GetAwaiter().GetResult();
                return false;
            }
            if (completed == brokerTask)
            {
                brokerTask.GetAwaiter().GetResult();
                throw new InvalidOperationException("Host bootstrap broker exited before readiness.");
            }
            cancellationToken.ThrowIfCancellationRequested();
            SetStatus(ServiceStartPending, checkpoint: NextStartupCheckpoint(), waitHintMs: 15000);
        }
        return false;
    }

    private static Process StartHostProcess(
        Dictionary<string, string> environment,
        TaskCompletionSource hostReady)
    {
        var hostExecutable = Path.Combine(AppContext.BaseDirectory, "ventio_host.exe");
        if (!File.Exists(hostExecutable))
            throw new InvalidOperationException("Host payload executable is missing.");

        var start = new ProcessStartInfo
        {
            FileName = hostExecutable,
            WorkingDirectory = AppContext.BaseDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.Environment.Clear();
        CopyRequiredSystemEnvironment(start.Environment);
        start.Environment["PATH"] = Path.Combine(AppContext.BaseDirectory, "postgresql", "bin");
        start.Environment["VENTIO_ENABLE_LOCAL_HOST"] = "yes";
        foreach (var pair in environment) start.Environment[pair.Key] = pair.Value;

        var process = new Process { StartInfo = start, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, eventArgs) =>
        {
            if (IsHostReadyMessage(eventArgs.Data)) hostReady.TrySetResult();
        }; // Deliberately discard process output; never persist secrets.
        process.ErrorDataReceived += (_, _) => { };
        lock (Sync)
        {
            if (StopRequested.IsSet) throw new InvalidOperationException("Host service start was cancelled.");
            if (!process.Start()) throw new InvalidOperationException("Host process could not start.");
            _hostProcess = process;
        }
        start.Environment.Clear();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return process;
    }

    private static Dictionary<string, string> CreateBootstrapEnvironment(Dictionary<string, string> configuration)
    {
        var names = new[]
        {
            "VENTIO_HOST_IDENTITY_API_DATABASE_URL",
            "VENTIO_RECOVERY_AUTHORITY_FILE",
            "VENTIO_RECOVERY_AUTHORITY_HOST_WRITES",
            "VENTIO_RECOVERY_AUTHORITY_OWNER_SID",
            "VENTIO_RECOVERY_AUTHORITY_READER_SID",
        };
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var name in names)
        {
            if (!configuration.TryGetValue(name, out var value) || string.IsNullOrWhiteSpace(value))
                throw new InvalidOperationException("Host bootstrap configuration is incomplete.");
            result.Add(name, value);
        }
        return result;
    }

    private static async Task ExecuteFirstAdministratorBootstrapAsync(
        BootstrapReceipt receipt,
        Dictionary<string, string>? protectedEnvironment,
        CancellationToken cancellationToken)
    {
        var executable = Path.Combine(AppContext.BaseDirectory, "ventio_identity_bootstrap.exe");
        if (!File.Exists(executable) || protectedEnvironment is null)
            throw new InvalidOperationException("Host bootstrap payload is incomplete.");
        var start = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = AppContext.BaseDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.Environment.Clear();
        CopyRequiredSystemEnvironment(start.Environment);
        start.Environment["PATH"] = Path.Combine(AppContext.BaseDirectory, "postgresql", "bin");
        foreach (var pair in protectedEnvironment) start.Environment[pair.Key] = pair.Value;

        var request = new
        {
            formatVersion = 1,
            requestId = receipt.RequestId,
            tenantId = receipt.TenantId,
            companyId = receipt.CompanyId,
            branchId = receipt.BranchId,
            operatorLabel = CreateOperatorLabel(receipt.CallerSid),
            actorId = receipt.ActorId,
            deviceId = receipt.DeviceId,
            credentialId = receipt.CredentialId,
            token = receipt.Token,
            expiresAt = receipt.ExpiresAt,
        };
        var requestBytes = JsonSerializer.SerializeToUtf8Bytes(request, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        using var process = new Process { StartInfo = start };
        byte[]? output = null;
        try
        {
            if (!process.Start()) throw new InvalidOperationException("Host bootstrap operation could not start.");
            start.Environment.Clear();
            var failureCodeTask = ReadSanitizedBootstrapFailureCodeAsync(
                process.StandardError.BaseStream, cancellationToken);
            var stdoutTask = ReadBoundedAsync(process.StandardOutput.BaseStream, 2048, cancellationToken);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(FirstAdministratorHelperTimeoutSeconds));
            await process.StandardInput.BaseStream.WriteAsync(requestBytes, timeout.Token).ConfigureAwait(false);
            await process.StandardInput.BaseStream.FlushAsync(timeout.Token).ConfigureAwait(false);
            process.StandardInput.Close();
            try
            {
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                throw new FirstAdministratorBootstrapFailureException("HOST_FIRST_ADMIN_HELPER_TIMEOUT");
            }
            catch
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                throw;
            }
            output = await stdoutTask.ConfigureAwait(false);
            var failureCode = await failureCodeTask.ConfigureAwait(false);
            if (process.ExitCode != 0)
                throw new FirstAdministratorBootstrapFailureException(
                    failureCode ?? "HOST_FIRST_ADMIN_HELPER_FAILED");
            if (!BootstrapHelperSucceeded(output, receipt.ActorId))
                throw new FirstAdministratorBootstrapFailureException("HOST_FIRST_ADMIN_RESULT_INVALID");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(requestBytes);
            if (output is not null) CryptographicOperations.ZeroMemory(output);
            start.Environment.Clear();
        }
    }

    private static bool BootstrapHelperSucceeded(byte[] output, string? expectedActorId)
    {
        try
        {
            using var document = JsonDocument.Parse(output);
            var root = document.RootElement;
            return root.ValueKind == JsonValueKind.Object &&
                root.EnumerateObject().Count() == 2 &&
                root.TryGetProperty("success", out var success) && success.ValueKind == JsonValueKind.True &&
                root.TryGetProperty("actorId", out var actor) && actor.GetString() == expectedActorId;
        }
        catch { return false; }
    }

    private static async Task<TrustedPairingResult> ExecuteTrustedPairingAsync(
        BootstrapCommand command,
        string callerSid,
        Dictionary<string, string>? protectedEnvironment,
        CancellationToken cancellationToken)
    {
        var executable = Path.Combine(AppContext.BaseDirectory, "ventio_trusted_pairing.exe");
        if (!File.Exists(executable) || protectedEnvironment is null ||
            command.Operation != "trusted-pairing" || command.TenantId is null ||
            command.CompanyId is null || command.BranchId is null ||
            command.RequestId is null || command.OperatorCredentialDigest is null ||
            command.OperatorActorId is null || command.TargetActorId is null ||
            command.PermissionsCsv is null)
            throw new TrustedPairingOperationException("HOST_TRUSTED_PAIRING_CONFIGURATION_INVALID");

        var permissions = command.PermissionsCsv.Split(',', StringSplitOptions.None);
        if (permissions.Length is < 1 or > 64)
            throw new TrustedPairingOperationException("HOST_TRUSTED_PAIRING_REQUEST_INVALID");
        var request = new
        {
            tenantId = command.TenantId,
            operatorActorId = command.OperatorActorId,
            targetActorId = command.TargetActorId,
            companyId = command.CompanyId,
            branchId = command.BranchId,
            requestId = command.RequestId,
            permissions,
            operatorCredentialDigest = command.OperatorCredentialDigest,
            windowsAdminTag = CreateWindowsAdminTag(callerSid, command.RequestId),
        };
        var requestBytes = JsonSerializer.SerializeToUtf8Bytes(
            request, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        var start = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = AppContext.BaseDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.Environment.Clear();
        CopyRequiredSystemEnvironment(start.Environment);
        start.Environment["PATH"] = Path.Combine(AppContext.BaseDirectory, "postgresql", "bin");
        foreach (var pair in protectedEnvironment) start.Environment[pair.Key] = pair.Value;
        using var process = new Process { StartInfo = start };
        byte[]? output = null;
        try
        {
            if (!process.Start())
                throw new TrustedPairingOperationException("HOST_TRUSTED_PAIRING_HELPER_FAILED");
            start.Environment.Clear();
            var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
            var stdoutTask = ReadBoundedAsync(process.StandardOutput.BaseStream, 8192, cancellationToken);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(TrustedPairingHelperTimeoutSeconds));
            await process.StandardInput.BaseStream.WriteAsync(requestBytes, timeout.Token).ConfigureAwait(false);
            await process.StandardInput.BaseStream.FlushAsync(timeout.Token).ConfigureAwait(false);
            process.StandardInput.Close();
            try
            {
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                throw new TrustedPairingOperationException("HOST_TRUSTED_PAIRING_OUTCOME_UNKNOWN");
            }
            catch
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                throw;
            }
            output = await stdoutTask.ConfigureAwait(false);
            _ = await stderrTask.ConfigureAwait(false);
            return ParseTrustedPairingResult(output, command, permissions, process.ExitCode);
        }
        catch (TrustedPairingOperationException)
        {
            throw;
        }
        catch
        {
            throw new TrustedPairingOperationException("HOST_TRUSTED_PAIRING_OUTCOME_UNKNOWN");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(requestBytes);
            if (output is not null) CryptographicOperations.ZeroMemory(output);
            start.Environment.Clear();
        }
    }

    private static async Task<TrustedCredentialReissueResult> ExecuteTrustedCredentialReissueAsync(
        BootstrapCommand command,
        string callerSid,
        Dictionary<string, string>? protectedEnvironment,
        CancellationToken cancellationToken)
    {
        var executable = Path.Combine(AppContext.BaseDirectory, "ventio_trusted_credential_reissue.exe");
        if (!File.Exists(executable) || protectedEnvironment is null ||
            command.Operation != "trusted-credential-reissue" || command.TenantId is null ||
            command.CompanyId is null || command.BranchId is null || command.RequestId is null ||
            command.OperatorCredentialDigest is null || command.OperatorActorId is null ||
            command.DeviceId is null || command.SourceCredentialId is null ||
            command.TargetActorId is null ||
            command.PermissionsCsv is null || command.ApprovedRemovalsCsv is null)
            throw new TrustedPairingOperationException("HOST_TRUSTED_REISSUE_CONFIGURATION_INVALID");

        var permissions = command.PermissionsCsv.Split(',', StringSplitOptions.None);
        var approvedRemovals = command.ApprovedRemovalsCsv.Length == 0
            ? Array.Empty<string>()
            : command.ApprovedRemovalsCsv.Split(',', StringSplitOptions.None);
        if (permissions.Length is < 1 or > 64 || approvedRemovals.Length > 64 ||
            permissions.Distinct(StringComparer.Ordinal).Count() != permissions.Length ||
            approvedRemovals.Distinct(StringComparer.Ordinal).Count() != approvedRemovals.Length)
            throw new TrustedPairingOperationException("HOST_TRUSTED_REISSUE_REQUEST_INVALID");
        var request = new
        {
            tenantId = command.TenantId,
            operatorActorId = command.OperatorActorId,
            companyId = command.CompanyId,
            branchId = command.BranchId,
            deviceId = command.DeviceId,
            sourceCredentialId = command.SourceCredentialId,
            targetActorId = command.TargetActorId,
            operationId = "reissue_" + command.RequestId,
            permissions,
            approvedRemovals,
            operatorCredentialDigest = command.OperatorCredentialDigest,
            windowsAdminTag = CreateWindowsAdminTag(callerSid, command.RequestId),
        };
        var requestBytes = JsonSerializer.SerializeToUtf8Bytes(
            request, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        var start = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = AppContext.BaseDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.Environment.Clear();
        CopyRequiredSystemEnvironment(start.Environment);
        start.Environment["PATH"] = Path.Combine(AppContext.BaseDirectory, "postgresql", "bin");
        foreach (var pair in protectedEnvironment) start.Environment[pair.Key] = pair.Value;
        using var process = new Process { StartInfo = start };
        byte[]? output = null;
        try
        {
            if (!process.Start())
                throw new TrustedPairingOperationException("HOST_TRUSTED_REISSUE_HELPER_FAILED");
            start.Environment.Clear();
            var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
            var stdoutTask = ReadBoundedAsync(process.StandardOutput.BaseStream, 8192, cancellationToken);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(TrustedPairingHelperTimeoutSeconds));
            await process.StandardInput.BaseStream.WriteAsync(requestBytes, timeout.Token).ConfigureAwait(false);
            await process.StandardInput.BaseStream.FlushAsync(timeout.Token).ConfigureAwait(false);
            process.StandardInput.Close();
            try
            {
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                throw new TrustedPairingOperationException("HOST_TRUSTED_REISSUE_OUTCOME_UNKNOWN");
            }
            catch
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                throw;
            }
            output = await stdoutTask.ConfigureAwait(false);
            _ = await stderrTask.ConfigureAwait(false);
            return ParseTrustedCredentialReissueResult(output, command, permissions, process.ExitCode);
        }
        catch (TrustedPairingOperationException)
        {
            throw;
        }
        catch
        {
            throw new TrustedPairingOperationException("HOST_TRUSTED_REISSUE_OUTCOME_UNKNOWN");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(requestBytes);
            if (output is not null) CryptographicOperations.ZeroMemory(output);
            start.Environment.Clear();
        }
    }

    private static TrustedCredentialReissueResult ParseTrustedCredentialReissueResult(
        byte[] output,
        BootstrapCommand command,
        string[] requestedPermissions,
        int exitCode)
    {
        try
        {
            using var document = JsonDocument.Parse(output, new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("status", out var status) || status.ValueKind != JsonValueKind.String)
                throw new InvalidDataException();
            if (status.GetString() == "failed")
            {
                if (exitCode == 0 || !root.TryGetProperty("failureCode", out var failure) ||
                    failure.ValueKind != JsonValueKind.String)
                    throw new InvalidDataException();
                var safeFailure = failure.GetString() switch
                {
                    "PERMISSION_OR_GRANT_DENIED" => "HOST_TRUSTED_REISSUE_PERMISSION_NOT_GRANTED",
                    "TARGET_UNAVAILABLE" => "HOST_TRUSTED_REISSUE_TARGET_UNAVAILABLE",
                    "OPERATION_REFERENCE_CONFLICT" => "HOST_TRUSTED_REISSUE_REFERENCE_CONFLICT",
                    "REISSUE_ALREADY_PENDING" => "HOST_TRUSTED_REISSUE_ALREADY_PENDING",
                    "RECOVERY_AUTHORITY_UNAVAILABLE" => "HOST_TRUSTED_REISSUE_RECOVERY_UNAVAILABLE",
                    "RECOVERY_AUTHORITY_BUSY" => "HOST_TRUSTED_REISSUE_RECOVERY_BUSY",
                    "OUTCOME_UNKNOWN" => "HOST_TRUSTED_REISSUE_OUTCOME_UNKNOWN",
                    _ => "HOST_TRUSTED_REISSUE_FAILED",
                };
                throw new TrustedPairingOperationException(safeFailure);
            }
            if (exitCode != 0 || status.GetString() != "created" ||
                command.RequestId is null || command.TenantId is null || command.TargetActorId is null ||
                command.DeviceId is null || command.CompanyId is null || command.BranchId is null ||
                !root.TryGetProperty("operationId", out var operationId) ||
                !root.TryGetProperty("state", out var state) ||
                !root.TryGetProperty("tenantId", out var tenantId) ||
                !root.TryGetProperty("actorId", out var actorId) ||
                !root.TryGetProperty("deviceId", out var deviceId) ||
                !root.TryGetProperty("companyId", out var companyId) ||
                !root.TryGetProperty("branchId", out var branchId) ||
                !root.TryGetProperty("credentialId", out var credentialId) ||
                !root.TryGetProperty("permissions", out var permissionValues) ||
                permissionValues.ValueKind != JsonValueKind.Array ||
                !root.TryGetProperty("expiresAtUtc", out var expiresText))
                throw new InvalidDataException();
            if (operationId.GetString() != "reissue_" + command.RequestId ||
                state.GetString() is not ("PREPARED" or "FINALIZED" or "EXPIRED" or "REJECTED") ||
                tenantId.GetString() != command.TenantId ||
                deviceId.GetString() != command.DeviceId || companyId.GetString() != command.CompanyId ||
                branchId.GetString() != command.BranchId || actorId.GetString() != command.TargetActorId ||
                credentialId.ValueKind != JsonValueKind.String ||
                !Regex.IsMatch(credentialId.GetString()!, "^cred_[0-9a-f]{32}$", RegexOptions.CultureInvariant) ||
                expiresText.ValueKind != JsonValueKind.String ||
                !DateTimeOffset.TryParse(expiresText.GetString(), out var expiry) ||
                expiry > DateTimeOffset.UtcNow.AddMinutes(16) ||
                (state.GetString() == "PREPARED" && expiry <= DateTimeOffset.UtcNow))
                throw new InvalidDataException();
            var actualPermissions = permissionValues.EnumerateArray()
                .Select(value => value.ValueKind == JsonValueKind.String ? value.GetString() : null)
                .ToArray();
            if (actualPermissions.Any(value => value is null) ||
                !actualPermissions.Cast<string>().Order(StringComparer.Ordinal)
                    .SequenceEqual(requestedPermissions.Order(StringComparer.Ordinal)))
                throw new InvalidDataException();
            return new TrustedCredentialReissueResult(
                operationId.GetString()!, state.GetString()!, tenantId.GetString()!,
                actorId.GetString()!, deviceId.GetString()!, companyId.GetString()!,
                branchId.GetString()!, credentialId.GetString()!,
                actualPermissions.Cast<string>().ToArray(), expiry.ToUniversalTime().ToString("O"));
        }
        catch (TrustedPairingOperationException)
        {
            throw;
        }
        catch
        {
            throw new TrustedPairingOperationException("HOST_TRUSTED_REISSUE_RESULT_INVALID");
        }
    }

    private static TrustedPairingResult ParseTrustedPairingResult(
        byte[] output,
        BootstrapCommand command,
        string[] requestedPermissions,
        int exitCode)
    {
        try
        {
            using var document = JsonDocument.Parse(output, new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("status", out var status) || status.ValueKind != JsonValueKind.String)
                throw new InvalidDataException();
            if (status.GetString() == "failed")
            {
                if (exitCode == 0 || !root.TryGetProperty("failureCode", out var failure) ||
                    failure.ValueKind != JsonValueKind.String)
                    throw new InvalidDataException();
                var safeFailure = failure.GetString() switch
                {
                    "OPERATOR_OR_PERMISSION_DENIED" => "HOST_TRUSTED_PAIRING_PERMISSION_NOT_GRANTED",
                    "TARGET_UNAVAILABLE" => "HOST_TRUSTED_PAIRING_TARGET_UNAVAILABLE",
                    "PAIRING_CODE_UNAVAILABLE" => "HOST_TRUSTED_PAIRING_CODE_UNAVAILABLE",
                    "PAIRING_RATE_LIMITED" => "HOST_TRUSTED_PAIRING_RATE_LIMITED",
                    "RECOVERY_AUTHORITY_UNAVAILABLE" => "HOST_TRUSTED_PAIRING_RECOVERY_UNAVAILABLE",
                    "RECOVERY_AUTHORITY_BUSY" => "HOST_TRUSTED_PAIRING_RECOVERY_BUSY",
                    "OUTCOME_UNKNOWN" => "HOST_TRUSTED_PAIRING_OUTCOME_UNKNOWN",
                    "REQUEST_ALREADY_USED" => "HOST_TRUSTED_PAIRING_REQUEST_USED",
                    _ => "HOST_TRUSTED_PAIRING_FAILED",
                };
                throw new TrustedPairingOperationException(safeFailure);
            }
            if (exitCode != 0 || status.GetString() != "created" ||
                command.RequestId is null || command.TargetActorId is null ||
                command.CompanyId is null || command.BranchId is null ||
                !root.TryGetProperty("pairingId", out var pairingId) ||
                !root.TryGetProperty("actorId", out var actorId) ||
                !root.TryGetProperty("companyId", out var companyId) ||
                !root.TryGetProperty("branchId", out var branchId) ||
                !root.TryGetProperty("permissions", out var permissionValues) ||
                permissionValues.ValueKind != JsonValueKind.Array ||
                !root.TryGetProperty("code", out var code) ||
                !root.TryGetProperty("expiresAtUtc", out var expiresText))
                throw new InvalidDataException();
            if (pairingId.ValueKind != JsonValueKind.String ||
                actorId.ValueKind != JsonValueKind.String ||
                companyId.ValueKind != JsonValueKind.String ||
                branchId.ValueKind != JsonValueKind.String ||
                code.ValueKind != JsonValueKind.String ||
                expiresText.ValueKind != JsonValueKind.String ||
                pairingId.GetString() != "pair_" + command.RequestId ||
                actorId.GetString() != command.TargetActorId ||
                companyId.GetString() != command.CompanyId ||
                branchId.GetString() != command.BranchId ||
                !Regex.IsMatch(code.GetString()!, "^[A-Za-z0-9_-]{43}$", RegexOptions.CultureInvariant) ||
                !DateTimeOffset.TryParse(expiresText.GetString(), out var expiry) ||
                expiry <= DateTimeOffset.UtcNow || expiry > DateTimeOffset.UtcNow.AddMinutes(5))
                throw new InvalidDataException();
            var actualPermissions = permissionValues.EnumerateArray()
                .Select(value => value.ValueKind == JsonValueKind.String ? value.GetString() : null)
                .ToArray();
            if (actualPermissions.Any(value => value is null) ||
                !actualPermissions.Cast<string>().Order(StringComparer.Ordinal)
                    .SequenceEqual(requestedPermissions.Order(StringComparer.Ordinal)))
                throw new InvalidDataException();
            return new TrustedPairingResult(
                pairingId.GetString()!, actorId.GetString()!, companyId.GetString()!,
                branchId.GetString()!, actualPermissions.Cast<string>().ToArray(),
                code.GetString()!, expiry.ToUniversalTime().ToString("O"));
        }
        catch (TrustedPairingOperationException)
        {
            throw;
        }
        catch
        {
            throw new TrustedPairingOperationException("HOST_TRUSTED_PAIRING_RESULT_INVALID");
        }
    }

    private static string CreateWindowsAdminTag(string callerSid, string? operationId = null)
    {
        var input = Encoding.UTF8.GetBytes(operationId is null ? callerSid : callerSid + ":" + operationId);
        try
        {
            var digest = SHA256.HashData(input);
            try { return Convert.ToHexString(digest.AsSpan(0, 8)).ToLowerInvariant(); }
            finally { CryptographicOperations.ZeroMemory(digest); }
        }
        finally { CryptographicOperations.ZeroMemory(input); }
    }

    private static string CreateOperatorLabel(string callerSid)
    {
        var input = Encoding.UTF8.GetBytes(callerSid);
        try
        {
            var digest = SHA256.HashData(input);
            try { return "first-admin-setup-" + Convert.ToHexString(digest.AsSpan(0, 12)).ToLowerInvariant(); }
            finally { CryptographicOperations.ZeroMemory(digest); }
        }
        finally { CryptographicOperations.ZeroMemory(input); }
    }

    private static async Task<byte[]> ReadBoundedAsync(Stream stream, int maximumBytes, CancellationToken cancellationToken)
    {
        using var output = new MemoryStream();
        var buffer = new byte[512];
        try
        {
            while (true)
            {
                var read = await stream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                if (read == 0) return output.ToArray();
                if (output.Length + read > maximumBytes) throw new InvalidDataException();
                output.Write(buffer, 0, read);
            }
        }
        finally { CryptographicOperations.ZeroMemory(buffer); }
    }

    internal static string? ValidateFirstAdministratorFailureCode(string? failureCode) =>
        failureCode is not null && FirstAdminFailureCodes.Contains(failureCode)
            ? failureCode
            : null;

    private static async Task<string?> ReadSanitizedBootstrapFailureCodeAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[512];
        using var output = new MemoryStream();
        var oversized = false;
        try
        {
            while (true)
            {
                var read = await stream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                if (read == 0) break;
                if (output.Length + read > 256)
                {
                    oversized = true;
                    continue;
                }
                if (!oversized) output.Write(buffer, 0, read);
            }
            if (oversized) return null;
            var bytes = output.ToArray();
            try
            {
                var candidate = new UTF8Encoding(false, true).GetString(bytes).TrimEnd('\r', '\n');
                return ValidateFirstAdministratorFailureCode(candidate);
            }
            catch (DecoderFallbackException)
            {
                return null;
            }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        finally { CryptographicOperations.ZeroMemory(buffer); }
    }

    private static int HandleControl(int control, int eventType, IntPtr eventData, IntPtr context)
    {
        if (control is not (ControlStop or ControlShutdown)) return 0;
        StopRequested.Set();
        StopSignal.TrySetResult();
        lock (Sync) SetStatus(ServiceStopPending, checkpoint: 1, waitHintMs: 20000);
        _ = Task.Run(() =>
        {
            try
            {
                lock (Sync)
                {
                    if (_hostProcess is { HasExited: false } process)
                    {
                        // Host has no Windows service-control endpoint yet. Termination closes
                        // connections; PostgreSQL rolls back incomplete transactions on exit.
                        process.Kill(entireProcessTree: true);
                    }
                }
            }
            catch { _serviceExitCode = 2; }
        });
        return 0;
    }

    private static Dictionary<string, string> ReadAndValidateConfiguration(string path, string? testServiceSid = null)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length is <= 0 or > MaximumConfigBytes)
            throw new InvalidOperationException("Protected Host configuration is missing or invalid.");
        ValidatePrivateConfigurationAcl(info, testServiceSid);

        var encrypted = File.ReadAllBytes(path);
        try
        {
            var plaintext = UnprotectMachineData(encrypted);
            try
            {
                var text = new UTF8Encoding(false, true).GetString(plaintext);
                var allowed = new HashSet<string>(StringComparer.Ordinal)
                {
                    "VENTIO_HOST_DATABASE_URL",
                    "VENTIO_HOST_IDENTITY_API_DATABASE_URL",
                    "VENTIO_RECOVERY_AUTHORITY_FILE",
                    "VENTIO_RECOVERY_AUTHORITY_HOST_WRITES",
                    "VENTIO_RECOVERY_AUTHORITY_OWNER_SID",
                    "VENTIO_RECOVERY_AUTHORITY_READER_SID",
                    "VENTIO_HOST_DIAGNOSTICS_FILE",
                    "VENTIO_HOST_BIND_ADDRESS",
                    "VENTIO_HOST_PORT",
                    "VENTIO_HOST_TLS_CERTIFICATE_FILE",
                    "VENTIO_HOST_TLS_PRIVATE_KEY_FILE",
                    "VENTIO_HOST_LAN_BIND_ADDRESS",
                    "VENTIO_HOST_LAN_PORT",
                };
                var values = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
                {
                    var valueLine = line.TrimEnd('\r');
                    var separator = valueLine.IndexOf('=');
                    if (separator <= 0) throw new InvalidOperationException("Protected Host configuration is malformed.");
                    var key = valueLine[..separator];
                    var value = valueLine[(separator + 1)..];
                    if (!allowed.Contains(key) || value.Contains('\r') || value.Contains('\n') || !values.TryAdd(key, value))
                        throw new InvalidOperationException("Protected Host configuration contains an unsupported setting.");
                }

                Require(values, "VENTIO_HOST_DATABASE_URL");
                Require(values, "VENTIO_HOST_IDENTITY_API_DATABASE_URL");
                Require(values, "VENTIO_RECOVERY_AUTHORITY_FILE");
                Require(values, "VENTIO_RECOVERY_AUTHORITY_OWNER_SID");
                Require(values, "VENTIO_RECOVERY_AUTHORITY_READER_SID");
                Require(values, "VENTIO_HOST_DIAGNOSTICS_FILE");
                values["VENTIO_RECOVERY_AUTHORITY_HOST_WRITES"] = Require(values, "VENTIO_RECOVERY_AUTHORITY_HOST_WRITES");
                if (values["VENTIO_RECOVERY_AUTHORITY_HOST_WRITES"] != "yes")
                    throw new InvalidOperationException("Invalid Host write-authority setting.");
                if (!values.TryGetValue("VENTIO_HOST_BIND_ADDRESS", out var address) || string.IsNullOrWhiteSpace(address))
                    values["VENTIO_HOST_BIND_ADDRESS"] = "127.0.0.1";
                if (!values.TryGetValue("VENTIO_HOST_PORT", out var port))
                    values["VENTIO_HOST_PORT"] = "8080";
                else if (!int.TryParse(port, out var portNumber) || portNumber is < 1 or > 65535)
                    throw new InvalidOperationException("Host listener port is invalid.");
                if (values.ContainsKey("VENTIO_HOST_TLS_PRIVATE_KEY_FILE") != values.ContainsKey("VENTIO_HOST_TLS_CERTIFICATE_FILE"))
                    throw new InvalidOperationException("Both TLS certificate and private key are required together.");
                foreach (var tlsPath in new[] { "VENTIO_HOST_TLS_PRIVATE_KEY_FILE", "VENTIO_HOST_TLS_CERTIFICATE_FILE" })
                {
                    if (values.TryGetValue(tlsPath, out var configuredPath) && !Path.IsPathFullyQualified(configuredPath))
                        throw new InvalidOperationException("TLS paths must be absolute.");
                }
                if (values["VENTIO_HOST_BIND_ADDRESS"] != "127.0.0.1" &&
                    (!values.ContainsKey("VENTIO_HOST_TLS_PRIVATE_KEY_FILE") || !values.ContainsKey("VENTIO_HOST_TLS_CERTIFICATE_FILE")))
                    throw new InvalidOperationException("External Host listeners require TLS.");
                if (values.ContainsKey("VENTIO_HOST_LAN_BIND_ADDRESS") != values.ContainsKey("VENTIO_HOST_LAN_PORT"))
                    throw new InvalidOperationException("Both LAN listener settings are required together.");
                if (values.TryGetValue("VENTIO_HOST_LAN_BIND_ADDRESS", out var lanAddress))
                {
                    if (lanAddress != IPAddress.Any.ToString() ||
                        !int.TryParse(values["VENTIO_HOST_LAN_PORT"], out var lanPort) || lanPort != 8443 ||
                        values["VENTIO_HOST_BIND_ADDRESS"] != "127.0.0.1" ||
                        !values.ContainsKey("VENTIO_HOST_TLS_PRIVATE_KEY_FILE") ||
                        !values.ContainsKey("VENTIO_HOST_TLS_CERTIFICATE_FILE"))
                        throw new InvalidOperationException("Protected LAN listener configuration is invalid.");
                    var hostDirectory = Path.GetFullPath(Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Ventio", "Host"));
                    foreach (var tlsPath in new[] { values["VENTIO_HOST_TLS_PRIVATE_KEY_FILE"], values["VENTIO_HOST_TLS_CERTIFICATE_FILE"] })
                    {
                        var fullTlsPath = Path.GetFullPath(tlsPath);
                        if (!fullTlsPath.StartsWith(hostDirectory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidOperationException("LAN TLS files must stay in protected Host storage.");
                    }
                }

                ValidateSid(values["VENTIO_RECOVERY_AUTHORITY_OWNER_SID"]);
                ValidateSid(values["VENTIO_RECOVERY_AUTHORITY_READER_SID"]);
                var serviceSid = testServiceSid ?? new NTAccount("NT SERVICE", ServiceName)
                    .Translate(typeof(SecurityIdentifier)).Value;
                if (values["VENTIO_RECOVERY_AUTHORITY_OWNER_SID"] != serviceSid ||
                    values["VENTIO_RECOVERY_AUTHORITY_READER_SID"] != serviceSid)
                    throw new InvalidOperationException("Recovery Authority must be owned by the dedicated Host service identity.");
                return values;
            }
            finally { CryptographicOperations.ZeroMemory(plaintext); }
        }
        finally { CryptographicOperations.ZeroMemory(encrypted); }
    }

    private static string Require(Dictionary<string, string> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || string.IsNullOrWhiteSpace(value))
            throw new InvalidOperationException("Required Host configuration setting is missing.");
        return value;
    }

    private static void ValidateSid(string sid)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(sid, @"^S-1-\d+(?:-\d+)+$", System.Text.RegularExpressions.RegexOptions.CultureInvariant))
            throw new InvalidOperationException("Recovery Authority Windows SID is invalid.");
    }

    private static HostSchemaUpgradeRequest ReadHostSchemaUpgradeRequest(
        string path, string serviceSid)
    {
        var file = new FileInfo(path);
        if (!file.Exists || file.Length is <= 0 or > 16384 ||
            (file.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException("Host schema upgrade request is missing or invalid.");
        ValidatePrivateConfigurationAcl(file, serviceSid);
        var encrypted = File.ReadAllBytes(path);
        byte[]? plaintext = null;
        try
        {
            plaintext = UnprotectMachineData(encrypted);
            using var document = JsonDocument.Parse(plaintext, new JsonDocumentOptions { MaxDepth = 3 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Count() != 4 ||
                !root.TryGetProperty("formatVersion", out var version) || version.GetInt32() != 1 ||
                !root.TryGetProperty("operationId", out var operation) || operation.ValueKind != JsonValueKind.String ||
                !root.TryGetProperty("databaseUrl", out var databaseUrlElement) || databaseUrlElement.ValueKind != JsonValueKind.String ||
                !root.TryGetProperty("createdAtUtc", out var createdAtElement) || createdAtElement.ValueKind != JsonValueKind.String)
                throw new InvalidOperationException("Host schema upgrade request is malformed.");

            var operationId = operation.GetString()!;
            var databaseUrl = databaseUrlElement.GetString()!;
            if (!Regex.IsMatch(operationId, "^upgrade_[0-9a-f]{32}$", RegexOptions.CultureInvariant) ||
                databaseUrl.Length is <= 0 or > 4096 ||
                !Uri.TryCreate(databaseUrl, UriKind.Absolute, out var uri) ||
                uri.Scheme != "postgresql" || uri.Host != "127.0.0.1" || uri.Port != 54329 ||
                uri.AbsolutePath != "/ventio_host" || uri.Query != "?sslmode=disable" ||
                uri.UserInfo.Split(':').Length != 2 ||
                Uri.UnescapeDataString(uri.UserInfo.Split(':')[0]) != "ventio_migrator_app" ||
                string.IsNullOrEmpty(Uri.UnescapeDataString(uri.UserInfo.Split(':')[1])))
                throw new InvalidOperationException("Host schema upgrade request is out of scope.");

            if (!DateTimeOffset.TryParse(createdAtElement.GetString(), out var createdAt) ||
                createdAt > DateTimeOffset.UtcNow.AddMinutes(5) ||
                createdAt < DateTimeOffset.UtcNow.AddHours(-24))
                throw new InvalidOperationException("Host schema upgrade request has expired.");
            return new HostSchemaUpgradeRequest(operationId, databaseUrl);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encrypted);
            if (plaintext is not null) CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    private static async Task ExecuteHostSchemaUpgradeAsync(
        HostSchemaUpgradeRequest request,
        Dictionary<string, string>? protectedEnvironment)
    {
        var stage = "HELPER_PAYLOAD_VALIDATION";
        var executable = Path.Combine(AppContext.BaseDirectory, "ventio_trusted_host_upgrade.exe");
        if (protectedEnvironment is null || !File.Exists(executable))
            throw new HostSchemaUpgradeFailureException("PAYLOAD_INCOMPLETE", stage);
        var requestBytes = JsonSerializer.SerializeToUtf8Bytes(new
        {
            operationId = request.OperationId,
            databaseUrl = request.DatabaseUrl,
        }, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        var start = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = AppContext.BaseDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.Environment.Clear();
        CopyRequiredSystemEnvironment(start.Environment);
        start.Environment["PATH"] = Path.Combine(AppContext.BaseDirectory, "postgresql", "bin");
        start.Environment["VENTIO_MIGRATIONS_DIR"] = Path.Combine(AppContext.BaseDirectory, "migrations");
        start.Environment["VENTIO_SECURITY_DIR"] = Path.Combine(AppContext.BaseDirectory, "security");
        foreach (var pair in protectedEnvironment) start.Environment[pair.Key] = pair.Value;
        using var process = new Process { StartInfo = start };
        byte[]? output = null;
        try
        {
            stage = "HELPER_START";
            if (!process.Start()) throw new HostSchemaUpgradeFailureException("HELPER_START_FAILED", stage);
            start.Environment.Clear();
            var stdoutTask = ReadBoundedAsync(process.StandardOutput.BaseStream, 8192, CancellationToken.None);
            var stderrTask = process.StandardError.BaseStream.CopyToAsync(Stream.Null);
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(TrustedSchemaUpgradeHelperTimeoutSeconds));
            await process.StandardInput.BaseStream.WriteAsync(requestBytes, timeout.Token).ConfigureAwait(false);
            await process.StandardInput.BaseStream.FlushAsync(timeout.Token).ConfigureAwait(false);
            process.StandardInput.Close();
            try
            {
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                throw new HostSchemaUpgradeFailureException("OUTCOME_UNKNOWN", "HELPER_TIMEOUT");
            }
            output = await stdoutTask.ConfigureAwait(false);
            await stderrTask.ConfigureAwait(false);
            stage = "HELPER_RESULT_VALIDATION";
            var result = ReadHostSchemaUpgradeResult(output, request.OperationId, process.ExitCode);
            if (result.FailureCode is not null)
                throw new HostSchemaUpgradeFailureException(result.FailureCode, result.FailureStage);
        }
        catch (HostSchemaUpgradeFailureException) { throw; }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
            throw new HostSchemaUpgradeFailureException("OUTCOME_UNKNOWN", stage);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(requestBytes);
            if (output is not null) CryptographicOperations.ZeroMemory(output);
            start.Environment.Clear();
        }
    }

    private static HostSchemaUpgradeResult ReadHostSchemaUpgradeResult(
        byte[] output, string expectedOperationId, int exitCode)
    {
        try
        {
            using var document = JsonDocument.Parse(output);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("status", out var statusElement) || statusElement.ValueKind != JsonValueKind.String)
                return new HostSchemaUpgradeResult("OUTCOME_UNKNOWN", "HELPER_RESULT_UNCLASSIFIED");
            var status = statusElement.GetString();
            if (status == "complete" && exitCode == 0 &&
                root.TryGetProperty("operationId", out var operation) &&
                operation.GetString() == expectedOperationId)
                return new HostSchemaUpgradeResult(null, "COMPLETE");
            var code = root.TryGetProperty("failureCode", out var failure) &&
                failure.ValueKind == JsonValueKind.String &&
                Regex.IsMatch(failure.GetString() ?? "", "^[A-Z][A-Z0-9_]{0,63}$", RegexOptions.CultureInvariant)
                ? failure.GetString()!
                : status == "unknown" ? "OUTCOME_UNKNOWN" : "UPGRADE_FAILED";
            var failureStage = root.TryGetProperty("failureStage", out var stage) &&
                stage.ValueKind == JsonValueKind.String &&
                Regex.IsMatch(stage.GetString() ?? "", "^[A-Z][A-Z0-9_]{0,63}$", RegexOptions.CultureInvariant)
                ? stage.GetString()!
                : "HELPER_RESULT_UNCLASSIFIED";
            return new HostSchemaUpgradeResult(code, failureStage);
        }
        catch { return new HostSchemaUpgradeResult("OUTCOME_UNKNOWN", "HELPER_RESULT_PARSE"); }
    }

    private static void WriteHostSchemaUpgradeResult(
        string path, string operationId, string status, string? failureCode, string? failureStage)
    {
        var value = JsonSerializer.Serialize(new { operationId, status, failureCode, failureStage });
        var tempPath = path + ".tmp";
        File.WriteAllText(tempPath, value, new UTF8Encoding(false));
        if (File.Exists(path)) File.Replace(tempPath, path, null, true);
        else File.Move(tempPath, path);
    }

    private static byte[] UnprotectMachineData(byte[] encrypted)
    {
        var inputPointer = Marshal.AllocHGlobal(encrypted.Length);
        try
        {
            Marshal.Copy(encrypted, 0, inputPointer, encrypted.Length);
            var input = new DataBlob { Size = encrypted.Length, Data = inputPointer };
            if (!CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    DpapiLocalMachine, out var output))
                throw new InvalidOperationException("Protected Host configuration could not be opened.");
            try
            {
                var plaintext = new byte[output.Size];
                Marshal.Copy(output.Data, plaintext, 0, output.Size);
                return plaintext;
            }
            finally
            {
                var zeroes = new byte[output.Size];
                Marshal.Copy(zeroes, 0, output.Data, zeroes.Length);
                CryptographicOperations.ZeroMemory(zeroes);
                LocalFree(output.Data);
            }
        }
        finally { Marshal.FreeHGlobal(inputPointer); }
    }

    private static void ValidatePrivateConfigurationAcl(FileInfo file, string? testServiceSid = null)
    {
        if ((file.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException("Protected Host configuration path is invalid.");
        var directory = file.Directory ?? throw new InvalidOperationException("Protected Host configuration directory is missing.");
        if ((directory.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException("Protected Host configuration directory is invalid.");

        var serviceSid = testServiceSid;
        if (serviceSid is null)
        {
            serviceSid = new NTAccount("NT SERVICE", ServiceName)
                .Translate(typeof(SecurityIdentifier)).Value;
            var identity = WindowsIdentity.GetCurrent();
            if (identity.User?.Value != serviceSid &&
                (identity.Groups is null || !identity.Groups.OfType<SecurityIdentifier>().Any(group => group.Value == serviceSid)))
                throw new InvalidOperationException("Host service SID is not enabled in the service token.");
        }
        var permitted = new HashSet<string>(StringComparer.Ordinal)
        {
            serviceSid, "S-1-5-18", "S-1-5-32-544", // service SID, SYSTEM, Administrators
        };
        FileSystemSecurity[] securityDescriptors =
        [directory.GetAccessControl(AccessControlSections.Access), file.GetAccessControl(AccessControlSections.Access)];
        foreach (var security in securityDescriptors)
        {
            var rules = security.GetAccessRules(includeExplicit: true, includeInherited: true, targetType: typeof(SecurityIdentifier));
            foreach (FileSystemAccessRule rule in rules)
            {
                if (rule.AccessControlType == AccessControlType.Allow &&
                    rule.FileSystemRights != 0 &&
                    (rule.IdentityReference as SecurityIdentifier)?.Value is { } sid &&
                    !permitted.Contains(sid))
                    throw new InvalidOperationException("Protected Host configuration ACL grants access to an unsupported identity.");
            }
        }
    }

    private static void CopyRequiredSystemEnvironment(IDictionary<string, string?> environment)
    {
        foreach (var name in new[] { "SystemRoot", "WINDIR", "SystemDrive", "TEMP", "TMP", "USERPROFILE" })
        {
            var value = Environment.GetEnvironmentVariable(name);
            if (!string.IsNullOrWhiteSpace(value)) environment[name] = value;
        }
    }

    private static void SetStatus(int state, int checkpoint, int waitHintMs,
        int controlsAccepted = 0, int win32ExitCode = 0)
    {
        if (_statusHandle == IntPtr.Zero) return;
        _status = new ServiceStatus
        {
            ServiceType = ServiceWin32OwnProcess,
            CurrentState = state,
            ControlsAccepted = controlsAccepted,
            Win32ExitCode = win32ExitCode,
            ServiceSpecificExitCode = 0,
            CheckPoint = checkpoint,
            WaitHint = waitHintMs,
        };
        _ = SetServiceStatus(_statusHandle, ref _status);
    }

    private static int NextStartupCheckpoint() => Interlocked.Increment(ref _startupCheckpoint);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ServiceTableEntry
    {
        [MarshalAs(UnmanagedType.LPWStr)] public string? ServiceName;
        public ServiceMainCallback? ServiceMain;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatus
    {
        public int ServiceType;
        public int CurrentState;
        public int ControlsAccepted;
        public int Win32ExitCode;
        public int ServiceSpecificExitCode;
        public int CheckPoint;
        public int WaitHint;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void ServiceMainCallback(int argc, IntPtr argv);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int HandlerCallback(int control, int eventType, IntPtr eventData, IntPtr context);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool StartServiceCtrlDispatcher([In] ServiceTableEntry[] serviceTable);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr RegisterServiceCtrlHandlerEx(string serviceName, HandlerCallback callback, IntPtr context);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetServiceStatus(IntPtr serviceStatusHandle, ref ServiceStatus serviceStatus);
    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, IntPtr description, IntPtr optionalEntropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);
}

internal sealed record HostSchemaUpgradeRequest(string OperationId, string DatabaseUrl);
internal sealed record HostSchemaUpgradeResult(string? FailureCode, string FailureStage);

internal sealed class HostSchemaUpgradeFailureException(string failureCode, string failureStage = "HOST_HELPER")
    : Exception("Host schema upgrade did not complete.")
{
    internal string FailureCode { get; } = Regex.IsMatch(
        failureCode, "^[A-Z][A-Z0-9_]{0,63}$", RegexOptions.CultureInvariant)
        ? failureCode
        : "UPGRADE_FAILED";
    internal string FailureStage { get; } = Regex.IsMatch(
        failureStage, "^[A-Z][A-Z0-9_]{0,63}$", RegexOptions.CultureInvariant)
        ? failureStage
        : "HOST_HELPER";
}

internal sealed class FirstAdministratorBootstrapFailureException : Exception
{
    internal FirstAdministratorBootstrapFailureException(string failureCode)
        : base("Host first-administrator bootstrap did not complete.")
    {
        FailureCode = Program.ValidateFirstAdministratorFailureCode(failureCode)
            ?? "HOST_FIRST_ADMIN_HELPER_FAILED";
    }

    internal string FailureCode { get; }
}
