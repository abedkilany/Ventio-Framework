param(
  [Parameter(Mandatory = $true)] [string] $InstallerPath
)

$ErrorActionPreference = 'Stop'
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$sourcePath = Join-Path $repoRoot 'installer\windows\ventio.iss'
$source = Get-Content -LiteralPath $sourcePath -Raw

if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
  throw 'UNIFIED_INSTALLER_ARTIFACT_MISSING'
}
if ($source -notmatch '(?m)^PrivilegesRequired=admin\s*$' -or
    $source -notmatch '(?m)^DefaultDirName=\{autopf\}\\Ventio\s*$' -or
    $source -notmatch '(?m)^DisableDirPage=yes\s*$' -or
    $source -match '(?m)^PrivilegesRequiredOverridesAllowed=' -or
    $source -match '(?m)^\[(Types|Components)\]\s*$') {
  throw 'UNIFIED_INSTALLER_PRIVILEGE_BOUNDARY_INVALID'
}

$runSection = [regex]::Match($source, '(?ms)^\[Run\]\s*(.*?)(?=^\[|\z)').Groups[1].Value
if (-not $runSection -or $runSection -notmatch '\{#AppExeName\}' -or
    $runSection -match '(?i)provision-host-installation|initialize-host-database|recover-host-database-credentials|--host-setup') {
  throw 'UNIFIED_INSTALLER_MUST_LAUNCH_ONLY_THE_NORMAL_APPLICATION'
}
if ($source -notmatch '(?m)^Source: "\{#HostPayload\}\\\*"; DestDir: "\{app\}\\host-payload"; Flags: ignoreversion recursesubdirs createallsubdirs\s*$') {
  throw 'UNIFIED_INSTALLER_PROTECTED_HOST_PAYLOAD_MISSING'
}

Write-Output 'UNIFIED_INSTALLER_MACHINE_WIDE_HOST_SETUP_BOUNDARY_PASS'
Write-Output 'UNIFIED_INSTALLER_STAGE_A_NO_DATABASE_OR_SERVICE_PROVISIONING_PASS'
