[CmdletBinding()]
param([switch] $ScmIntegration)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$modulePath = Join-Path $PSScriptRoot 'HostServiceRecoveryPolicy.psm1'
$upgradePath = Join-Path $PSScriptRoot 'upgrade-host-database.ps1'
$stopPath = Join-Path $PSScriptRoot 'stop-host-services.ps1'
$installerPath = Join-Path $repoRoot 'installer\windows\ventio.iss'
Import-Module $modulePath -Force

function Assert-RecoveryTest([bool] $Condition, [string] $Name) {
  if (-not $Condition) { throw ('HOST_SERVICE_RECOVERY_TEST_FAILED_' + $Name) }
  Write-Output ('PASS: ' + $Name)
}

function Invoke-SimulatedRestartRace {
  $state = @{ Start = [DateTime]::UtcNow; Status = 'Stopped'; RestartDelivered = $false; StopCount = 0; AutoRestartEnabled = $true }
  $statusProvider = {
    if ($state.AutoRestartEnabled -and -not $state.RestartDelivered -and
        [DateTime]::UtcNow -ge $state.Start.AddSeconds(1)) {
      $state.RestartDelivered = $true
      $state.Status = 'Running'
    }
    return $state.Status
  }.GetNewClosure()
  $stopProvider = {
    $state.StopCount++
    $state.Status = 'Stopped'
    $state.AutoRestartEnabled = $false
  }.GetNewClosure()

  $firstCheck = [string](& $statusProvider 'VentioHost')
  if ($firstCheck -ne 'Stopped') { throw 'SIMULATED_INITIAL_STOP_EXPECTATION_FAILED' }
  Start-Sleep -Milliseconds 1250
  $legacyCheck = [string](& $statusProvider 'VentioHost')
  Assert-RecoveryTest ($legacyCheck -eq 'Running') 'legacy_stop_check_race_reproduced'

  $state.Status = 'Stopped'
  $state.RestartDelivered = $false
  $state.Start = [DateTime]::UtcNow
  $state.AutoRestartEnabled = $true
  Wait-VentioServiceStoppedStable 'VentioHost' 3 8 $statusProvider $stopProvider
  Assert-RecoveryTest ($state.RestartDelivered -and $state.StopCount -ge 1 -and $state.Status -eq 'Stopped') 'maintenance_hold_drains_already_queued_restart'
  Start-Sleep -Milliseconds 1250
  [void](& $statusProvider 'VentioHost')
  Assert-RecoveryTest ($state.Status -eq 'Stopped') 'suppressed_recovery_does_not_restart_service_again'
}

function Invoke-ContractChecks {
  $upgrade = Get-Content -LiteralPath $upgradePath -Raw
  $stop = Get-Content -LiteralPath $stopPath -Raw
  $policy = Get-Content -LiteralPath $modulePath -Raw
  $installer = Get-Content -LiteralPath $installerPath -Raw
  Assert-RecoveryTest ($upgrade.Contains("Set-HostBackupStage 'PRE_DATABASE_UPGRADE_HOST_SERVICE_STATE'") -and
    $upgrade.Contains("Set-HostBackupStage 'RECOVERY_AUTHORITY_SERVICE_PRECONDITION_STATE'") -and
    $upgrade.Contains("Set-HostBackupStage 'RECOVERY_AUTHORITY_SERVICE_RECHECK_STATE'")) 'both_upgrade_service_state_failures_have_distinct_safe_stages'
  Assert-RecoveryTest ($installer.Contains('IsSafeHostDatabaseUpgradeFailureStage') -and $installer.Contains(' Stage: ')) 'installer_displays_only_validated_safe_stage_metadata'
  Assert-RecoveryTest ($stop.Contains('[string] $FailureCodePath') -and $stop.Contains("'Code=' + `$Code") -and $stop.Contains("'Stage=' + `$Stage") -and
    $installer.Contains('-FailureCodePath "') -and $installer.Contains('IsSafePreinstallFailureStage')) 'preinstall_failure_code_and_stage_are_safely_exposed'
  Assert-RecoveryTest ($policy.Contains('Add-Type -AssemblyName System.Security') -and
    $policy.Contains('RECOVERY_JOURNAL_DPAPI_PROTECT') -and $policy.Contains('SERVICE_RECOVERY_POLICY_SUPPRESS')) 'windows_powershell_51_dpapi_and_suppression_stages_are_instrumented'
  Assert-RecoveryTest ($policy.Contains('access |= ServiceStart') -and
    $policy.Contains('SC_ACTION_NONE') -and $policy.Contains('ServiceStart = 0x0010')) 'scm_restart_restore_uses_required_narrow_service_rights'
  Assert-RecoveryTest ($stop.Contains('Start-VentioHostServiceMaintenance $hostService') -and
    $installer.Contains('-KeepHostRecoveryPolicySuppressed') -and $installer.Contains('-RestoreHostFailureActions')) 'installer_holds_and_restores_scm_policy'
  Assert-RecoveryTest ($upgrade.Contains('Assert-VentioHostServiceMaintenance') -and
    $upgrade.Contains('HOST_DATABASE_UPGRADE_HOST_SERVICE_IDENTITY_INVALID')) 'host_service_account_and_executable_checks_remain_authoritative'
  Assert-RecoveryTest ($upgrade.IndexOf('Assert-VentioHostServiceMaintenance $hostService', [StringComparison]::Ordinal) -lt
    $upgrade.IndexOf('$request = New-HostSchemaUpgradeRequest', [StringComparison]::Ordinal)) 'service_maintenance_precondition_precedes_recovery_request_creation'
  Assert-RecoveryTest ($upgrade.Contains('RECOVERY_AUTHORITY_SERVICE_RECHECK_STATE') -and
    $upgrade.Contains('Start-Service -Name $hostServiceName')) 'recovery_authority_helper_starts_host_only_after_stable_stop_check'
}

function Invoke-PreinstallFailureDiagnosticTest {
  $testRoot = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) ('ventio-preinstall-diagnostic-test-' + [guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($testRoot)
  $failurePath = Join-Path $testRoot 'failure.txt'
  $stdoutPath = Join-Path $testRoot 'stdout.txt'
  $stderrPath = Join-Path $testRoot 'stderr.txt'
  $invalidPayload = Join-Path $testRoot 'intentionally-invalid-payload'
  $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $stopPath + '" -PayloadDirectory "' + $invalidPayload + '" -FailureCodePath "' + $failurePath + '"'
  try {
    $process = Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    Assert-RecoveryTest ($process.ExitCode -ne 0) 'windows_powershell_51_helper_failure_exit_is_nonzero'
    $failureLines = @(Get-Content -LiteralPath $failurePath -ErrorAction Stop)
    Assert-RecoveryTest ($failureLines.Count -eq 2 -and
      $failureLines[0] -ceq 'Code=HOST_PAYLOAD_PATH_INVALID' -and
      $failureLines[1] -ceq 'Stage=PAYLOAD_PATH_VALIDATION') 'windows_powershell_51_writes_safe_specific_failure_metadata'
  } finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

try {
  Invoke-ContractChecks
  Invoke-SimulatedRestartRace
  Invoke-PreinstallFailureDiagnosticTest
  if (-not $ScmIntegration) {
    Write-Output 'HOST_SERVICE_RECOVERY_POLICY_TEST_PASS'
    return
  }

  $serviceName = 'VentioSvcRace_' + [guid]::NewGuid().ToString('N').Substring(0, 20)
  $testRoot = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) ('ventio-service-policy-test-' + [guid]::NewGuid().ToString('N'))
  $stateDirectory = Join-Path $testRoot 'state'
  $projectDirectory = Join-Path $testRoot 'service-project'
  $publishDirectory = Join-Path $testRoot 'service-bin'
  $logPath = Join-Path $testRoot 'service-starts.log'
  $serviceInstalled = $false
  $service = $null
  $serviceExe = Join-Path $publishDirectory 'VentioScmFailureFixture.exe'
  try {
    [void][IO.Directory]::CreateDirectory($projectDirectory)
    [void][IO.Directory]::CreateDirectory($stateDirectory)
    $identitySid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $protected = [Security.AccessControl.DirectorySecurity]::new()
    $protected.SetAccessRuleProtection($true, $false)
    $protected.SetOwner($identitySid)
    foreach ($sid in @($identitySid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
      $protected.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit,
        [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $testRoot -AclObject $protected
    Set-Acl -LiteralPath $stateDirectory -AclObject $protected

    # Match the physical installer's stated installer-folder profile exactly:
    # Administrators owns it; inheritance is disabled; only Administrators
    # and SYSTEM receive FullControl.
    $physicalAclDirectory = Join-Path $testRoot 'physical-installer-acl'
    [void][IO.Directory]::CreateDirectory($physicalAclDirectory)
    $adminSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $physicalAcl = [Security.AccessControl.DirectorySecurity]::new()
    $physicalAcl.SetAccessRuleProtection($true, $false)
    $physicalAcl.SetOwner($adminSid)
    foreach ($sid in @($adminSid, $systemSid)) {
      $physicalAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit,
        [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $physicalAclDirectory -AclObject $physicalAcl
    Assert-VentioRecoveryStateAcl $physicalAclDirectory -Directory -TestMode
    Assert-RecoveryTest $true 'physical_administrators_owner_and_system_admin_acl_is_accepted'

    $source = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
class VentioScmFailureFixture {
  const uint SERVICE_WIN32_OWN_PROCESS = 0x10, SERVICE_START_PENDING = 2, SERVICE_RUNNING = 4, SERVICE_STOPPED = 1, SERVICE_ACCEPT_STOP = 1;
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct SERVICE_TABLE_ENTRY { [MarshalAs(UnmanagedType.LPWStr)] public string Name; public ServiceMainDelegate Proc; }
  [StructLayout(LayoutKind.Sequential)] struct SERVICE_STATUS { public uint Type, State, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint; }
  [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate void ServiceMainDelegate(uint argc, IntPtr argv);
  [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate uint HandlerEx(uint control, uint eventType, IntPtr eventData, IntPtr context);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool StartServiceCtrlDispatcher([In] SERVICE_TABLE_ENTRY[] table);
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr RegisterServiceCtrlHandlerEx(string name, HandlerEx handler, IntPtr context);
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool SetServiceStatus(IntPtr handle, ref SERVICE_STATUS status);
  static readonly string Name = "__SERVICE__", Log = "__LOG__";
  static ServiceMainDelegate MainCallback = ServiceMain;
  static HandlerEx HandlerCallback = Handler;
  static IntPtr StatusHandle;
  static bool StopRequested;
  static uint Handler(uint control, uint eventType, IntPtr data, IntPtr context) {
    if (control == 1) { StopRequested = true; Report(SERVICE_STOPPED, 0); }
    return 0;
  }
  static void Report(uint state, uint exitCode) {
    SERVICE_STATUS status = new SERVICE_STATUS { Type=SERVICE_WIN32_OWN_PROCESS, State=state,
      ControlsAccepted=(state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP : 0), Win32ExitCode=exitCode, WaitHint=3000 };
    SetServiceStatus(StatusHandle, ref status);
  }
  static void ServiceMain(uint argc, IntPtr argv) {
    StatusHandle = RegisterServiceCtrlHandlerEx(Name, HandlerCallback, IntPtr.Zero);
    if (StatusHandle == IntPtr.Zero) return;
    Report(SERVICE_START_PENDING, 0);
    Report(SERVICE_RUNNING, 0);
    File.AppendAllText(Log, DateTime.UtcNow.ToString("O") + Environment.NewLine);
    for (int i=0; i<20 && !StopRequested; i++) Thread.Sleep(50);
    if (!StopRequested) Environment.Exit(73);
  }
  static int Main() {
    SERVICE_TABLE_ENTRY[] table = new SERVICE_TABLE_ENTRY[] {
      new SERVICE_TABLE_ENTRY { Name=Name, Proc=MainCallback }, new SERVICE_TABLE_ENTRY { Name=null, Proc=null }
    };
    return StartServiceCtrlDispatcher(table) ? 0 : Marshal.GetLastWin32Error();
  }
}
'@
    $source = $source.Replace('__SERVICE__', $serviceName).Replace('__LOG__', $logPath.Replace('\', '\\'))
    $project = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><RuntimeIdentifier>win-x64</RuntimeIdentifier><SelfContained>true</SelfContained><PublishSingleFile>true</PublishSingleFile><ImplicitUsings>disable</ImplicitUsings><Nullable>disable</Nullable></PropertyGroup>
</Project>
'@
    [IO.File]::WriteAllText((Join-Path $projectDirectory 'Program.cs'), $source, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $projectDirectory 'VentioScmFailureFixture.csproj'), $project, [Text.UTF8Encoding]::new($false))
    & dotnet publish (Join-Path $projectDirectory 'VentioScmFailureFixture.csproj') -c Release -o $publishDirectory --nologo
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) { throw 'HOST_SERVICE_RECOVERY_SCM_FIXTURE_BUILD_FAILED' }

    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
      throw 'HOST_SERVICE_RECOVERY_SCM_TEST_BLOCKED_NOT_ELEVATED'
    }

    # New-Service calls CreateServiceW directly.  Invoking sc.exe through
    # Windows PowerShell 5.1 mangles the quoted binPath argument for paths
    # containing spaces, which made the previous elevated integration test
    # fail before it reached the service recovery code under test.
    $serviceBinPath = '"' + $serviceExe + '"'
    New-Service -Name $serviceName -BinaryPathName $serviceBinPath -StartupType Manual -ErrorAction Stop | Out-Null
    $serviceInstalled = $true
    $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
    $original = [Ventio.Setup.ServiceRecovery.PolicyValue]::new(86400, $null, $null,
      [Ventio.Setup.ServiceRecovery.ActionValue[]]@(
        [Ventio.Setup.ServiceRecovery.ActionValue]::new(1, 5000),
        [Ventio.Setup.ServiceRecovery.ActionValue]::new(1, 30000),
        [Ventio.Setup.ServiceRecovery.ActionValue]::new(1, 60000)), $true)
    Set-VentioServiceFailurePolicy $serviceName $original
    $before = Get-VentioServiceFailurePolicy $serviceName
    Assert-RecoveryTest (Test-VentioServiceFailurePolicyEqual $original $before) 'scm_native_policy_query_and_update_succeed'
    Start-Service -Name $serviceName
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline) {
      if ((Test-Path -LiteralPath $logPath) -and @(Get-Content -LiteralPath $logPath).Count -ge 2) { break }
      Start-Sleep -Milliseconds 250
    }
    Assert-RecoveryTest ((Test-Path -LiteralPath $logPath) -and @(Get-Content -LiteralPath $logPath).Count -ge 2) 'scm_restarts_disposable_failed_service'

    $maintained = [pscustomobject]@{ Name=$service.Name; StartName=$service.StartName; PathName=$service.PathName }
    $result = Start-VentioHostServiceMaintenance $maintained $stateDirectory -TestMode -ServiceName $serviceName -ExpectedStartName 'LocalSystem'
    Assert-RecoveryTest (Test-Path -LiteralPath $result.StatePath -PathType Leaf) 'windows_powershell_51_dpapi_journal_is_durably_created'
    Assert-RecoveryTest ($result.QuietSeconds -ge 63) 'scm_5_30_60_second_restart_delay_drained_before_maintenance'
    Assert-VentioHostServiceMaintenance $maintained 'Stopped' $stateDirectory -TestMode -ServiceName $serviceName
    Assert-RecoveryTest $true 'windows_powershell_51_dpapi_journal_acl_and_unprotect_round_trip'
    $countAtHold = @(Get-Content -LiteralPath $logPath).Count
    Start-Sleep -Seconds 7
    Assert-RecoveryTest ((Get-Service -Name $serviceName).Status -eq 'Stopped' -and @(Get-Content -LiteralPath $logPath).Count -eq $countAtHold) 'scm_has_no_restart_after_policy_suppression_and_drain'

    Restore-VentioHostServiceFailureActions $maintained $stateDirectory -TestMode -ServiceName $serviceName
    $restored = Get-VentioServiceFailurePolicy $serviceName
    Assert-RecoveryTest (Test-VentioServiceFailurePolicyEqual $before $restored) 'scm_recovery_policy_exactly_restored'
    Assert-RecoveryTest (-not (Test-Path -LiteralPath (Join-Path $stateDirectory ('host-service-recovery-policy.' + $serviceName + '.v1.dpapi')))) 'scm_recovery_journal_removed_after_verified_restore'
  } finally {
    if ($serviceInstalled) {
      try {
        $noRestart = [Ventio.Setup.ServiceRecovery.PolicyValue]::new(0, $null, $null,
          [Ventio.Setup.ServiceRecovery.ActionValue[]]@([Ventio.Setup.ServiceRecovery.ActionValue]::new(0, 0)), $false)
        Set-VentioServiceFailurePolicy $serviceName $noRestart
      } catch { }
      try { Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue } catch { }
      try { & sc.exe delete $serviceName | Out-Null } catch { }
      $deleteDeadline = [DateTime]::UtcNow.AddSeconds(10)
      while ([DateTime]::UtcNow -lt $deleteDeadline -and (Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 250
      }
      if (Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue) {
        throw 'HOST_SERVICE_RECOVERY_SCM_FIXTURE_CLEANUP_FAILED'
      }
    }
    if (Test-Path -LiteralPath $testRoot) {
      Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
  }
  Write-Output 'HOST_SERVICE_RECOVERY_SCM_TEST_PASS'
} catch {
  if ($_.Exception.Message -eq 'HOST_SERVICE_RECOVERY_SCM_TEST_BLOCKED_NOT_ELEVATED') {
    Write-Output 'HOST_SERVICE_RECOVERY_SCM_TEST_BLOCKED_NOT_ELEVATED'
    exit 2
  }
  Write-Error ($_.Exception.Message)
  exit 1
}
