$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$installerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'installer\windows\ventio.iss') -Raw
$postgresProvisioner = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'provision-postgres-service.ps1') -Raw
$hostRegistration = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'register-host-service.ps1') -Raw

function Assert-Contract([bool] $Condition, [string] $Code) {
  if (-not $Condition) { throw $Code }
}

Assert-Contract ($installerSource -match '(?m)^DefaultDirName=\{autopf\}\\Ventio\s*$') 'INSTALLER_DEFAULT_MUST_FOLLOW_INSTALL_MODE'
Assert-Contract ($installerSource -match '(?m)^PrivilegesRequired=admin\s*$') 'INSTALLER_HOST_MUST_SUPPORT_ELEVATION'
Assert-Contract ($installerSource -match '(?m)^PrivilegesRequiredOverridesAllowed=dialog\s*$') 'INSTALLER_CLIENT_MUST_ALLOW_PER_USER_MODE'
Assert-Contract ($installerSource -match '(?m)^Source: "\{#HostPayload\}\\\*"; DestDir: "\{app\}\\host-payload"; Components: host;') 'HOST_PAYLOAD_DESTINATION_MUST_STAY_PRODUCT_OWNED'
Assert-Contract ($installerSource -match "(?s)function NextButtonClick.*?WizardSetupType\(False\) = 'host'.*?not IsAdminInstallMode") 'HOST_PER_USER_INSTALL_MUST_BE_REJECTED'
Assert-Contract ($installerSource -match "(?s)function NextButtonClick.*?ExpectedHostDir := ExpandConstant\('\{autopf\}\\Ventio'\).*?CompareText\(SelectedDir, ExpectedHostDir\)") 'HOST_INSTALL_DIRECTORY_MUST_MATCH_PROVISIONER_ROOT'
Assert-Contract ($installerSource -match "(?s)function InitializeSetup.*?WizardSilent then\s+Log\('HOST_INSTALL_REQUIRES_ADMIN_MODE'\)") 'SILENT_HOST_REJECTION_MUST_BE_NONINTERACTIVE'
Assert-Contract ($installerSource -match 'runasoriginaluser') 'FLUTTER_APP_MUST_NOT_LAUNCH_ELEVATED'
Assert-Contract ($postgresProvisioner.Contains("Join-Path `$env:ProgramFiles 'Ventio'")) 'POSTGRES_PROVISIONER_PROGRAM_FILES_BOUNDARY_MISSING'
Assert-Contract ($postgresProvisioner.Contains('$pgRoot.StartsWith((Join-Path $env:ProgramFiles ''Ventio\''), [StringComparison]::OrdinalIgnoreCase)')) 'POSTGRES_APPLY_MUST_ENFORCE_PRODUCT_PAYLOAD_BOUNDARY'
Assert-Contract ($hostRegistration.Contains("Join-Path `$payload 'ventio_host.exe'")) 'HOST_SERVICE_MUST_USE_SELECTED_VERIFIED_PAYLOAD'
Assert-Contract ($hostRegistration.Contains("Join-Path `$env:ProgramFiles 'Ventio\host-payload'")) 'HOST_SERVICE_PAYLOAD_MUST_STAY_IN_THE_MACHINE_WIDE_PRODUCT_DIRECTORY'
Assert-Contract ($hostRegistration.Contains("Join-Path `$payload 'ventio_identity_bootstrap.exe'")) 'HOST_SERVICE_MUST_REQUIRE_THE_FIXED_FIRST_ADMIN_BOOTSTRAP_PAYLOAD'
Assert-Contract ($hostRegistration.Contains("`$manifest.identityBootstrapExecutable -ne 'ventio_identity_bootstrap.exe'")) 'HOST_SERVICE_MUST_VALIDATE_THE_FIRST_ADMIN_BOOTSTRAP_MANIFEST_ENTRY'
Assert-Contract ($hostRegistration.Contains('Get-FileHash -LiteralPath $file -Algorithm SHA256')) 'HOST_SERVICE_MUST_VERIFY_CRITICAL_EXECUTABLE_HASHES'
Assert-Contract ($hostRegistration.Contains("AddSeconds(120)")) 'HOST_SERVICE_START_MUST_WAIT_FOR_READINESS'
Assert-Contract ($hostRegistration.Contains("ToString() -eq 'Running'")) 'HOST_SERVICE_START_MUST_CONFIRM_RUNNING_STATE'

$programFiles = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Ventio'))
$hostPayload = [IO.Path]::GetFullPath((Join-Path $programFiles 'host-payload'))
$postgresRoot = [IO.Path]::GetFullPath((Join-Path $hostPayload 'postgresql'))
if (-not $postgresRoot.StartsWith($programFiles.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'HOST_POSTGRES_PAYLOAD_OUTSIDE_ALLOWED_PROGRAM_FILES_ROOT'
}
$userPrograms = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs\Ventio'))
if ($userPrograms.StartsWith($programFiles.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'PER_USER_CLIENT_PATH_UNEXPECTEDLY_RESOLVES_TO_PROGRAM_FILES'
}

Write-Output 'UNIFIED_INSTALLER_HOST_PROGRAM_FILES_PATH_CONTRACT_PASS'
Write-Output 'UNIFIED_INSTALLER_CLIENT_PER_USER_PATH_CONTRACT_PASS'
