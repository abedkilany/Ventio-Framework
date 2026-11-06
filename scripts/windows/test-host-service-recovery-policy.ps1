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
  $installer = Get-Content -LiteralPath $installerPath -Raw
  Assert-RecoveryTest ($upgrade.Contains("Set-HostBackupStage 'PRE_DATABASE_UPGRADE_HOST_SERVICE_STATE'") -and
    $upgrade.Contains("Set-HostBackupStage 'RECOVERY_AUTHORITY_SERVICE_START_PRECONDITION'") -and
    $upgrade.Contains("Set-HostBackupStage 'RECOVERY_AUTHORITY_SERVICE_START_STATE'")) 'both_upgrade_service_state_failures_have_distinct_safe_stages'
  Assert-RecoveryTest ($installer.Contains('IsSafeHostDatabaseUpgradeFailureStage') -and $installer.Contains(' Stage: ')) 'installer_displays_only_validated_safe_stage_metadata'
  Assert-RecoveryTest ($stop.Contains('Start-VentioHostServiceMaintenance $hostService') -and
    $installer.Contains('-KeepHostRecoveryPolicySuppressed') -and $installer.Contains('-RestoreHostFailureActions')) 'installer_holds_and_restores_scm_policy'
  Assert-RecoveryTest ($upgrade.Contains('Assert-VentioHostServiceMaintenance') -and
    $upgrade.Contains('HOST_DATABASE_UPGRADE_HOST_SERVICE_IDENTITY_INVALID')) 'host_service_account_and_executable_checks_remain_authoritative'
  Assert-RecoveryTest ($upgrade.IndexOf('Assert-VentioHostServiceMaintenance $hostService', [StringComparison]::Ordinal) -lt
    $upgrade.IndexOf('$request = New-HostSchemaUpgradeRequest', [StringComparison]::Ordinal)) 'service_maintenance_precondition_precedes_recovery_request_creation'
  Assert-RecoveryTest ($upgrade.Contains('RECOVERY_AUTHORITY_SERVICE_START_STATE') -and
    $upgrade.Contains('Start-Service -Name $hostServiceName')) 'recovery_authority_helper_starts_host_only_after_stable_stop_check'
}

try {
  Invoke-ContractChecks
  Invoke-SimulatedRestartRace
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

    $serviceBinPath = '"' + $serviceExe + '"'
    & sc.exe create $serviceName "binPath= $serviceBinPath" 'start= demand' 'obj= LocalSystem' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'HOST_SERVICE_RECOVERY_SCM_FIXTURE_CREATE_FAILED' }
    $serviceInstalled = $true
    $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
    $original = [Ventio.Setup.ServiceRecovery.PolicyValue]::new(86400, $null, $null,
      [Ventio.Setup.ServiceRecovery.ActionValue[]]@(
        [Ventio.Setup.ServiceRecovery.ActionValue]::new(1, 1000),
        [Ventio.Setup.ServiceRecovery.ActionValue]::new(1, 3000),
        [Ventio.Setup.ServiceRecovery.ActionValue]::new(1, 6000)), $true)
    Set-VentioServiceFailurePolicy $serviceName $original
    Start-Service -Name $serviceName
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline) {
      if ((Test-Path -LiteralPath $logPath) -and (Get-Content -LiteralPath $logPath).Count -ge 2) { break }
      Start-Sleep -Milliseconds 250
    }
    Assert-RecoveryTest ((Test-Path -LiteralPath $logPath) -and (Get-Content -LiteralPath $logPath).Count -ge 2) 'scm_restarts_disposable_failed_service'

    $before = Get-VentioServiceFailurePolicy $serviceName
    $maintained = [pscustomobject]@{ Name=$service.Name; StartName=$service.StartName; PathName=$service.PathName }
    $result = Start-VentioHostServiceMaintenance $maintained $stateDirectory -TestMode -ServiceName $serviceName -ExpectedStartName 'LocalSystem'
    Assert-RecoveryTest ($result.QuietSeconds -ge 9) 'scm_restart_delay_drained_before_maintenance'
    Assert-VentioHostServiceMaintenance $maintained 'Stopped' $stateDirectory -TestMode -ServiceName $serviceName
    $countAtHold = (Get-Content -LiteralPath $logPath).Count
    Start-Sleep -Seconds 7
    Assert-RecoveryTest ((Get-Service -Name $serviceName).Status -eq 'Stopped' -and (Get-Content -LiteralPath $logPath).Count -eq $countAtHold) 'scm_has_no_restart_after_policy_suppression_and_drain'

    Restore-VentioHostServiceFailureActions $maintained $stateDirectory -TestMode -ServiceName $serviceName
    $restored = Get-VentioServiceFailurePolicy $serviceName
    Assert-RecoveryTest (Test-VentioServiceFailurePolicyEqual $before $restored) 'scm_recovery_policy_exactly_restored'
    Assert-RecoveryTest (-not (Test-Path -LiteralPath (Join-Path $stateDirectory ('host-service-recovery-policy.' + $serviceName + '.v1.dpapi')))) 'scm_recovery_journal_removed_after_verified_restore'
  } finally {
    if ($serviceInstalled) {
      try {
        $empty = [Ventio.Setup.ServiceRecovery.PolicyValue]::new(0, $null, $null,
          [Ventio.Setup.ServiceRecovery.ActionValue[]]@(), $false)
        Set-VentioServiceFailurePolicy $serviceName $empty
        if ((Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status -ne 'Stopped') {
          Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        }
        & sc.exe delete $serviceName | Out-Null
      } catch { }
      $deleteDeadline = [DateTime]::UtcNow.AddSeconds(10)
      while ([DateTime]::UtcNow -lt $deleteDeadline -and (Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 250
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
