$ErrorActionPreference = 'Stop'

$sourcePath = Join-Path $PSScriptRoot 'provision-host-installation.ps1'
$tokens = $null
$parseErrors = $null
$sourceAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'HOST_NEW_INSTALL_STATE_SCRIPT_PARSE_FAILED' }

foreach ($functionName in @('Test-HostDataPathHasNoReparsePoints', 'Assert-HostNewInstallationState')) {
  $functionAst = $sourceAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq $functionName
  }, $true)
  if ($null -eq $functionAst) { throw 'HOST_NEW_INSTALL_STATE_FUNCTION_MISSING' }
  . ([scriptblock]::Create($functionAst.Extent.Text))
}

function Assert-Rejected([scriptblock] $Action, [string] $ExpectedCode) {
  try {
    & $Action
    throw 'HOST_NEW_INSTALL_STATE_EXPECTED_REJECTION_MISSING'
  } catch {
    if ($_.Exception.Message -notlike "*$ExpectedCode*") { throw }
  }
}

$tempRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ventio-host-new-install-state-' + [guid]::NewGuid().ToString('N'))))
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ventio-host-new-install-state-'
$dataRoot = Join-Path $tempRoot 'ProgramData'
$productDataRoot = Join-Path $dataRoot 'Ventio'
$installRoot = Join-Path (Join-Path $tempRoot 'ProgramFiles') 'Ventio'
$setupStatusDirectory = Join-Path $installRoot 'SetupStatus'
$legacySetupStatusDirectory = Join-Path $productDataRoot 'SetupStatus'
$postgresData = Join-Path $productDataRoot 'PostgreSQL\data'
$hostData = Join-Path $productDataRoot 'Host'
$backups = Join-Path $productDataRoot 'Backups'
$installerState = Join-Path $productDataRoot 'Installer'

try {
  [void][IO.Directory]::CreateDirectory($dataRoot)
  [void][IO.Directory]::CreateDirectory($setupStatusDirectory)
  [void][IO.Directory]::CreateDirectory($legacySetupStatusDirectory)
  [IO.File]::WriteAllText((Join-Path $setupStatusDirectory 'operation-status.json'), '{"state":"running"}')
  [IO.File]::WriteAllText((Join-Path $legacySetupStatusDirectory 'legacy-operation-status.json'), '{"state":"failed"}')
  Assert-HostNewInstallationState -PostgresService $null -HostService $null `
    -DataRoot $dataRoot -ProductDataRoot $productDataRoot `
    -ExistingDataDirectories @($postgresData, $hostData, $backups) `
    -InstallerStateDirectory $installerState
  Write-Output 'Current and legacy Host setup status metadata do not make an otherwise fresh installation look like an existing Host.'

  Assert-Rejected {
    Assert-HostNewInstallationState -PostgresService ([pscustomobject]@{ Name = 'VentioPostgres' }) `
      -HostService $null -DataRoot $dataRoot -ProductDataRoot $productDataRoot `
      -ExistingDataDirectories @($postgresData, $hostData, $backups) `
      -InstallerStateDirectory $installerState
  } 'HOST_EXISTING_SERVICES_REQUIRE_RECOVERY'

  [void][IO.Directory]::CreateDirectory($postgresData)
  Assert-Rejected {
    Assert-HostNewInstallationState -PostgresService $null -HostService $null `
      -DataRoot $dataRoot -ProductDataRoot $productDataRoot `
      -ExistingDataDirectories @($postgresData, $hostData, $backups) `
      -InstallerStateDirectory $installerState
  } 'HOST_EXISTING_DATA_REQUIRES_REPAIR'

  [IO.File]::WriteAllText((Join-Path $postgresData 'PG_VERSION'), '16')
  Assert-Rejected {
    Assert-HostNewInstallationState -PostgresService $null -HostService $null `
      -DataRoot $dataRoot -ProductDataRoot $productDataRoot `
      -ExistingDataDirectories @($postgresData, $hostData, $backups) `
      -InstallerStateDirectory $installerState
  } 'HOST_EXISTING_DATA_REQUIRES_REPAIR'

  [IO.Directory]::Delete($postgresData, $true)
  [void][IO.Directory]::CreateDirectory($backups)
  [IO.File]::WriteAllText((Join-Path $backups 'prior-backup.marker'), 'preserve')
  Assert-Rejected {
    Assert-HostNewInstallationState -PostgresService $null -HostService $null `
      -DataRoot $dataRoot -ProductDataRoot $productDataRoot `
      -ExistingDataDirectories @($postgresData, $hostData, $backups) `
      -InstallerStateDirectory $installerState
  } 'HOST_EXISTING_DATA_REQUIRES_REPAIR'

  Assert-Rejected {
    Assert-HostNewInstallationState -PostgresService $null -HostService $null `
      -DataRoot $dataRoot -ProductDataRoot $productDataRoot `
      -ExistingDataDirectories @((Join-Path $tempRoot 'outside')) `
      -InstallerStateDirectory $installerState
  } 'HOST_EXISTING_DATA_REQUIRES_REPAIR'

  Write-Output 'Host new-install state tests passed: fresh state accepted, existing services/data/backups and out-of-bound paths rejected.'
}
finally {
  if ($tempRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $tempRoot) -match '^ventio-host-new-install-state-[0-9a-f]{32}$' -and
      (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
