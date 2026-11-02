$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$installerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'installer\windows\ventio.iss') -Raw
$postgresProvisioner = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'provision-postgres-service.ps1') -Raw
$hostRegistration = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'register-host-service.ps1') -Raw
$hostConfigWriter = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'write-host-service-config.ps1') -Raw
$hostLanListener = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'enable-host-lan-listener.ps1') -Raw
$hostProvisioning = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'provision-host-installation.ps1') -Raw
$hostServiceStop = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'stop-host-services.ps1') -Raw
$hostRemoval = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'remove-host-installation.ps1') -Raw
$databaseUpgrade = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'upgrade-host-database.ps1') -Raw
$setupBroker = Get-Content -LiteralPath (Join-Path $repoRoot 'installer\windows\setup-broker\Program.cs') -Raw
$setupBrokerProject = Get-Content -LiteralPath (Join-Path $repoRoot 'installer\windows\setup-broker\VentioSetupBroker.csproj') -Raw
$setupBrokerManifest = Get-Content -LiteralPath (Join-Path $repoRoot 'installer\windows\setup-broker\VentioSetupBroker.manifest') -Raw
$runnerManifest = Get-Content -LiteralPath (Join-Path $repoRoot 'packages\ventio_native_client\windows\runner\runner.exe.manifest') -Raw
$hostSetupCoordinator = Get-Content -LiteralPath (Join-Path $repoRoot 'packages\ventio_native_client\lib\src\host_setup.dart') -Raw
$firstRunPage = Get-Content -LiteralPath (Join-Path $repoRoot 'packages\ventio_native_client\lib\src\first_run_setup_page.dart') -Raw
$nativeApp = Get-Content -LiteralPath (Join-Path $repoRoot 'packages\ventio_native_client\lib\main.dart') -Raw
$nativeHostSetup = Get-Content -LiteralPath (Join-Path $repoRoot 'packages\ventio_native_client\lib\src\host_setup_windows.dart') -Raw
$payloadBuilder = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build-host-payload.ps1') -Raw

function Assert-Contract([bool] $Condition, [string] $Code) {
  if (-not $Condition) { throw $Code }
}

Assert-Contract ($installerSource -match '(?m)^DefaultDirName=\{autopf\}\\Ventio\s*$') 'INSTALLER_DEFAULT_MUST_FOLLOW_INSTALL_MODE'
Assert-Contract ($installerSource -match '(?m)^PrivilegesRequired=admin\s*$') 'INSTALLER_HOST_MUST_SUPPORT_ELEVATION'
Assert-Contract ($installerSource -notmatch '(?m)^PrivilegesRequiredOverridesAllowed=') 'INSTALLER_MUST_NOT_ALLOW_UNPROTECTED_PER_USER_HOST_HELPER'
Assert-Contract ($installerSource -match '(?m)^DisableDirPage=yes\s*$') 'INSTALLER_MUST_USE_THE_PROTECTED_MACHINE_WIDE_PRODUCT_DIRECTORY'
Assert-Contract ($installerSource -match '(?m)^Source: "\{#HostPayload\}\\\*"; DestDir: "\{app\}\\host-payload"; Flags:') 'HOST_RUNTIME_MUST_BE_AVAILABLE_AFTER_EITHER_FIRST_RUN_CHOICE'
Assert-Contract ($firstRunPage.Contains('native.ui.first_run_host_title') -and $firstRunPage.Contains('native.ui.first_run_client_title') -and $firstRunPage.Contains('onSetUpHost') -and $firstRunPage.Contains('onConnectClient')) 'FLUTTER_FIRST_RUN_MUST_OFFER_HOST_SETUP_AND_CLIENT_CONNECTION'
Assert-Contract ($nativeApp.Contains('FirstRunSetupPage(') -and $nativeApp.Contains('onSetUpHost: _beginHostSetup') -and $nativeApp.Contains('onConnectClient: _connectClient')) 'FLUTTER_APP_MUST_WIRE_BOTH_FIRST_RUN_MODES'
Assert-Contract ($installerSource -match 'runasoriginaluser') 'FLUTTER_APP_MUST_NOT_LAUNCH_ELEVATED'
Assert-Contract ($installerSource -match '(?m)^Filename: "\{app\}\\\{#AppExeName\}"; Description: "Launch Ventio".*?runasoriginaluser') 'INSTALLER_MUST_LAUNCH_THE_SHARED_UNELEVATED_APP'
Assert-Contract ($runnerManifest -match '<requestedExecutionLevel\s+level="asInvoker"\s+uiAccess="false"\s*/>') 'FLUTTER_APPLICATION_MUST_DECLARE_AS_INVOKER_EXECUTION_LEVEL'
Assert-Contract ($setupBrokerManifest -match '<requestedExecutionLevel\s+level="requireAdministrator"\s+uiAccess="false"\s*/>' -and $setupBrokerProject.Contains('<ApplicationManifest>VentioSetupBroker.manifest</ApplicationManifest>')) 'SETUP_BROKER_MUST_DECLARE_ITS_ADMINISTRATOR_BOUNDARY'
Assert-Contract ($hostSetupCoordinator.Contains('currentProcessIsElevated') -and $hostSetupCoordinator.Contains('HOST_SETUP_APPLICATION_ELEVATED')) 'HOST_SETUP_MUST_REFUSE_TO_RUN_INSIDE_AN_ELEVATED_FLUTTER_PROCESS'
Assert-Contract ($installerSource -match '(?s)function PrepareToInstall.*?stop-host-services\.ps1.*?Exec\(PowerShell, Parameters') 'HOST_UPGRADE_MUST_STOP_SERVICES_BEFORE_REPLACING_PAYLOAD'
Assert-Contract ($installerSource.Contains("ExtractTemporaryFile('stop-host-services.ps1')")) 'HOST_PREINSTALL_STOP_HELPER_MUST_USE_THE_CURRENT_INSTALLER_PAYLOAD'
Assert-Contract ($installerSource.Contains('-AllowPostgresOnlyRecovery')) 'HOST_PREINSTALL_MUST_ALLOW_ONLY_REVIEWED_POSTGRES_ONLY_RECOVERY'
Assert-Contract ($installerSource -match '(?s)procedure DeinitializeSetup.*?-ResumePostgresOnly') 'HOST_INSTALL_FAILURE_MUST_RESTART_THE_VERIFIED_POSTGRES_SERVICE'
Assert-Contract ($installerSource -notmatch 'provision-host-installation\.ps1|initialize-host-database\.ps1|recover-host-database-credentials\.ps1') 'INSTALLER_MUST_NOT_PROVISION_OR_RECOVER_HOST_DATABASE'
Assert-Contract ($installerSource -match '(?s)procedure CurStepChanged.*?enable-host-lan-listener\.ps1.*?-RestartServices') 'EXISTING_HOST_UPDATE_MUST_CONFIGURE_THE_LAN_LISTENER'
Assert-Contract ($installerSource -notmatch '(?s)procedure CurStepChanged.*?provision-host-installation\.ps1|initialize-host-database\.ps1|recover-host-database-credentials\.ps1') 'INSTALLER_NETWORK_UPDATE_MUST_NOT_PROVISION_OR_RECOVER_DATABASE'
Assert-Contract ($hostLanListener.Contains('-RemoteAddress LocalSubnet') -and $hostLanListener.Contains('-Profile Private')) 'HOST_LAN_FIREWALL_MUST_BE_LIMITED_TO_PRIVATE_LOCAL_SUBNET'
Assert-Contract ($hostLanListener.Contains('HOST_LAN_HOST_SERVICE_MUST_BE_STOPPED') -and $hostLanListener.Contains('service-config.dpapi.pre-lan.bak')) 'HOST_LAN_UPDATE_MUST_REQUIRE_STOPPED_SERVICE_AND_PRESERVE_ORIGINAL_PROTECTED_CONFIG'
Assert-Contract ($hostLanListener -notmatch 'SkipCertificateCheck|TrustAllCerts') 'HOST_LAN_SETUP_MUST_NOT_DISABLE_CERTIFICATE_VALIDATION'
Assert-Contract ($hostLanListener.Contains('Read-HostLanCertificate') -and $hostLanListener.Contains('[Convert]::FromBase64String') -and $hostLanListener -notmatch 'X509Certificate2\]::CreateFromPemFile') 'HOST_LAN_TLS_SELF_TEST_MUST_SUPPORT_WINDOWS_POWERSHELL_5'
Assert-Contract ($hostLanListener.Contains("Stop-ValidatedService 'VentioHost'") -and $hostLanListener.Contains('HOST_LAN_ROLLBACK_LISTENER_STILL_BOUND')) 'HOST_LAN_ROLLBACK_MUST_RESTART_HOST_AFTER_RESTORING_LOCAL_CONFIG'
Assert-Contract ($installerSource -match '(?s)function InitializeUninstall.*?remove-host-installation\.ps1.*?-RemoveData') 'HOST_UNINSTALL_MUST_OFFER_EXPLICIT_DATA_REMOVAL'
Assert-Contract ($installerSource -match "(?s)function InitializeUninstall.*?if not FileExists\(ScriptPath\).*?RegKeyExists\(HKLM, 'SYSTEM\\CurrentControlSet\\Services\\VentioHost'\).*?Result := False") 'HOST_UNINSTALL_MUST_STOP_IF_SERVICE_REMOVAL_HELPER_IS_MISSING'
Assert-Contract ($postgresProvisioner.Contains("Join-Path `$env:ProgramFiles 'Ventio'")) 'POSTGRES_PROVISIONER_PROGRAM_FILES_BOUNDARY_MISSING'
Assert-Contract ($postgresProvisioner.Contains('$pgRoot.StartsWith((Join-Path $env:ProgramFiles ''Ventio\''), [StringComparison]::OrdinalIgnoreCase)')) 'POSTGRES_APPLY_MUST_ENFORCE_PRODUCT_PAYLOAD_BOUNDARY'
Assert-Contract ($hostRegistration.Contains("Join-Path `$payload 'ventio_host.exe'")) 'HOST_SERVICE_MUST_USE_SELECTED_VERIFIED_PAYLOAD'
Assert-Contract ($hostRegistration.Contains("Join-Path `$env:ProgramFiles 'Ventio\host-payload'")) 'HOST_SERVICE_PAYLOAD_MUST_STAY_IN_THE_MACHINE_WIDE_PRODUCT_DIRECTORY'
Assert-Contract ($hostRegistration.Contains("Join-Path `$payload 'ventio_identity_bootstrap.exe'")) 'HOST_SERVICE_MUST_REQUIRE_THE_FIXED_FIRST_ADMIN_BOOTSTRAP_PAYLOAD'
Assert-Contract ($hostRegistration.Contains("`$manifest.identityBootstrapExecutable -ne 'ventio_identity_bootstrap.exe'")) 'HOST_SERVICE_MUST_VALIDATE_THE_FIRST_ADMIN_BOOTSTRAP_MANIFEST_ENTRY'
Assert-Contract ($hostProvisioning.Contains("Join-Path `$setupDirectory 'recover-host-database-credentials.ps1'")) 'HOST_PARTIAL_INSTALL_MUST_USE_THE_BOUNDED_DATABASE_CREDENTIAL_RECOVERY_HELPER'
Assert-Contract ($hostProvisioning.Contains('[switch] $NewHostOnly')) 'HOST_NEW_SETUP_MUST_HAVE_A_SEPARATE_NEW_ONLY_MODE'
Assert-Contract ($hostProvisioning.Contains('HOST_EXISTING_SERVICES_REQUIRE_RECOVERY')) 'HOST_NEW_SETUP_MUST_REFUSE_EXISTING_SERVICES'
Assert-Contract ($hostProvisioning.Contains('HOST_SETUP_PHASE:$phase')) 'HOST_PROVISIONING_MUST_REPORT_ALLOWLISTED_PHASE_MARKERS'
Assert-Contract ($setupBroker.Contains('"--setup-new-host"')) 'SETUP_BROKER_MUST_EXPOSE_ONLY_THE_NEW_HOST_OPERATION'
Assert-Contract ($setupBroker.Contains('"-NewHostOnly"')) 'SETUP_BROKER_MUST_NEVER_INVOKE_HOST_RECOVERY'
Assert-Contract ($setupBroker.Contains('UseShellExecute = false')) 'SETUP_BROKER_MUST_NOT_USE_SHELL_COMMAND_INTERPRETATION'
Assert-Contract ($setupBroker.Contains('Global\Ventio.HostSetup.v1')) 'SETUP_BROKER_MUST_SERIALIZE_HOST_PROVISIONING'
Assert-Contract ($setupBroker.Contains('SetupStatus')) 'SETUP_BROKER_MUST_WRITE_A_SANITIZED_PROGRESS_RECORD'
Assert-Contract ($setupBroker.Contains('SerializeSetupStatus') -and $setupBroker.Contains('PipeJsonOptions')) 'SETUP_STATUS_JSON_MUST_MATCH_THE_FLUTTER_CAMEL_CASE_CONTRACT'
Assert-Contract ($setupBroker.IndexOf('WriteStatus(request, "running", null, "PAYLOAD_VALIDATION")', [StringComparison]::Ordinal) -lt $setupBroker.IndexOf('var paths = GetValidatedPaths();', [StringComparison]::Ordinal)) 'SETUP_BROKER_MUST_PUBLISH_PROGRESS_BEFORE_PAYLOAD_VALIDATION'
Assert-Contract ($setupBroker.Contains('Environment.SpecialFolder.ProgramFiles') -and $setupBroker.Contains('Path.Combine(productDirectory, "SetupStatus")')) 'SETUP_STATUS_MUST_USE_THE_MACHINE_PROTECTED_INSTALL_ROOT'
Assert-Contract ($nativeHostSetup.Contains("Platform.environment['ProgramFiles']") -and $nativeHostSetup.Contains('Ventio\\SetupStatus')) 'FLUTTER_SETUP_STATUS_PATH_MUST_MATCH_THE_PRIVILEGED_BROKER'
Assert-Contract ($setupBroker.Contains('identity.User.Value')) 'SETUP_STATUS_ACL_MUST_REJECT_DIRECT_REQUESTER_WRITE_ACCESS'
Assert-Contract ($payloadBuilder.Contains('VentioSetupBroker.exe')) 'HOST_PAYLOAD_MUST_BUNDLE_THE_SETUP_BROKER'
Assert-Contract ($installerSource -match '(?s)Source: "\{#HostPayload\}\\\*"; DestDir: "\{app\}\\host-payload"; Flags:') 'HOST_PAYLOAD_MUST_BE_INSTALLED_WITHOUT_PROVISIONING_SERVICES'
Assert-Contract ($hostProvisioning.Contains('HOST_INSTALL_RECOVERY_PLAN_VALID')) 'HOST_PARTIAL_INSTALL_MUST_HAVE_A_READ_ONLY_RECOVERY_PLAN'
Assert-Contract ($hostRegistration.Contains('Get-FileHash -LiteralPath $file -Algorithm SHA256')) 'HOST_SERVICE_MUST_VERIFY_CRITICAL_EXECUTABLE_HASHES'
Assert-Contract ($hostRegistration.Contains("@('failureflag', `$serviceName, '1')")) 'HOST_SERVICE_FAILURE_FLAG_MUST_USE_THE_DEDICATED_SC_COMMAND'
Assert-Contract ($hostRegistration -notmatch "(?m)^\s*&\s*\$sc\s+config\s+\$serviceName\s+'failureflag='") 'HOST_SERVICE_FAILURE_FLAG_MUST_NOT_BE_PASSED_TO_SC_CONFIG'
Assert-Contract ($hostRegistration -match "(?s)catch\s*\{.*?throw 'HOST_SERVICE_REGISTRATION_FAILED'") 'HOST_SERVICE_REGISTRATION_FAILURE_MUST_REACH_THE_PROVISIONER'
Assert-Contract ($hostConfigWriter -match '(?s)catch\s*\{.*?throw \$failureCode') 'HOST_CONFIG_FAILURE_MUST_REACH_THE_PROVISIONER'
Assert-Contract ($hostRegistration.Contains("AddSeconds(120)")) 'HOST_SERVICE_START_MUST_WAIT_FOR_READINESS'
Assert-Contract ($hostRegistration.Contains("ToString() -eq 'Running'")) 'HOST_SERVICE_START_MUST_CONFIRM_RUNNING_STATE'
Assert-Contract ($hostProvisioning.Contains("'NT SERVICE\VentioPostgres'")) 'HOST_PROVISIONER_MUST_VALIDATE_THE_POSTGRES_SERVICE_IDENTITY'
Assert-Contract ($hostProvisioning.Contains("'NT SERVICE\VentioHost'")) 'HOST_PROVISIONER_MUST_VALIDATE_THE_HOST_SERVICE_IDENTITY'
Assert-Contract ($hostProvisioning.Contains('HOST_INSTALL_SERVICES_READY_FOR_FIRST_ADMIN')) 'HOST_PROVISIONER_MUST_REPORT_FIRST_ADMIN_HANDOFF'
Assert-Contract ($hostServiceStop.Contains("Stop-ValidatedService 'VentioHost'")) 'HOST_UPGRADE_MUST_STOP_VENTIOHOST_FIRST'
Assert-Contract ($hostServiceStop.Contains("Stop-ValidatedService 'VentioPostgres'")) 'HOST_UPGRADE_MUST_STOP_POSTGRES_SECOND'
Assert-Contract ($hostServiceStop.Contains('Assert-IncompleteHostRecoveryState')) 'HOST_POSTGRES_ONLY_STOP_MUST_VALIDATE_RECOVERABLE_INSTALL_STATE'
Assert-Contract ($hostServiceStop.Contains('Read-HostMigrationCredential')) 'HOST_POSTGRES_ONLY_STOP_MUST_VALIDATE_PROTECTED_MIGRATION_CREDENTIAL'
Assert-Contract ($hostServiceStop.Contains('HOST_POSTGRES_STOPPED_FOR_INCOMPLETE_INSTALL_RECOVERY')) 'HOST_POSTGRES_ONLY_RECOVERY_STOP_MUST_BE_AUDITABLE'
Assert-Contract ($hostRemoval.Contains('HOST_SERVICES_REMOVED_DATA_RETAINED')) 'HOST_UNINSTALL_MUST_SUPPORT_DATA_RETENTION'
Assert-Contract ($hostRemoval.Contains('HOST_SERVICES_REMOVED_AND_DATA_DELETED')) 'HOST_UNINSTALL_MUST_SUPPORT_EXPLICIT_DATA_DELETION'
Assert-Contract ($hostRemoval.Contains('$fullPath.Equals($privateRoot, [StringComparison]::OrdinalIgnoreCase)') -and
  $hostRemoval.Contains('-not $fullPath.StartsWith($privateRootPrefix, [StringComparison]::OrdinalIgnoreCase)')) 'HOST_UNINSTALL_INSPECTION_MUST_STAY_WITHIN_THE_PRODUCT_DATA_ROOT'
Assert-Contract ($hostRemoval.Contains('[IO.Directory]::EnumerateFileSystemEntries($current)')) 'HOST_UNINSTALL_MUST_CHECK_CHILD_REPARSE_POINTS_WITHOUT_FOLLOWING_THEM'
Assert-Contract ($hostRemoval.Contains('Assert-PostgresOnlyFailedInstallation')) 'HOST_UNINSTALL_MUST_VALIDATE_POSTGRES_ONLY_PARTIAL_STATE'
Assert-Contract ($hostRemoval.Contains('HOST_DATABASE_RECOVERY_ROLE_ROTATION_FAILED')) 'HOST_UNINSTALL_MUST_RECOGNIZE_ONLY_THE_CONFIRMED_PARTIAL_FAILURE'
Assert-Contract ($hostRemoval.Contains('HOST_RECOVERY_DIAGNOSTICS_ARCHIVE_VERIFICATION_FAILED')) 'HOST_UNINSTALL_MUST_VERIFY_PROTECTED_DIAGNOSTIC_ARCHIVE'
Assert-Contract ($hostRemoval.Contains('HOST_RECOVERY_EVIDENCE_MANIFEST_ACL_INVALID')) 'HOST_UNINSTALL_MUST_PROTECT_DIAGNOSTIC_ARCHIVE_MANIFEST'
Assert-Contract ($hostRemoval -match '(?s)if \(\$RemoveData\) \{\s*\[void\]\(Assert-PrivateProductRoot \$programDataVentio\).*?Repair-PrivateProductDirectoryForRemoval \$programDataVentio.*?Assert-PrivateProductDirectory \$programDataVentio.*?if \(Assert-PrivateProductRoot \$programDataVentio\) \{\s*Remove-Item -LiteralPath \$programDataVentio -Recurse -Force') 'HOST_UNINSTALL_MUST_VALIDATE_AND_DELETE_THE_COMPLETE_PRODUCT_DATA_ROOT'
Assert-Contract ($hostRemoval -match '(?m)^\s*if \(\$null -eq \$postgres -and \$null -ne \$hostService\)') 'HOST_UNINSTALL_MUST_STILL_REJECT_HOST_ONLY_PARTIAL_SERVICE_STATE'
Assert-Contract ($databaseUpgrade.Contains('Get-HostDataInventory')) 'HOST_UPGRADE_MUST_CREATE_A_VERIFIED_POSTGRES_BACKUP'
Assert-Contract ($databaseUpgrade.Contains('$migrationRole')) 'HOST_UPGRADE_MUST_USE_A_DEDICATED_MIGRATOR_LOGIN'

$programFiles = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio'))
$hostPayload = [IO.Path]::GetFullPath((Join-Path $programFiles 'host-payload'))
$postgresRoot = [IO.Path]::GetFullPath((Join-Path $hostPayload 'postgresql'))
if (-not $postgresRoot.StartsWith($programFiles.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'HOST_POSTGRES_PAYLOAD_OUTSIDE_ALLOWED_PROGRAM_FILES_ROOT'
}
Write-Output 'UNIFIED_INSTALLER_HOST_PROGRAM_FILES_PATH_CONTRACT_PASS'
Write-Output 'UNIFIED_INSTALLER_SHARED_FLUTTER_FIRST_RUN_HOST_CLIENT_CHOICES_PASS'
Write-Output 'UNIFIED_INSTALLER_HOST_PROVISIONING_DEFERRED_TO_FLUTTER_PASS'
