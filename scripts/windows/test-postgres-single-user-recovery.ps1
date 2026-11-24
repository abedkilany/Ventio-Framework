[CmdletBinding()]
param(
  [string] $PostgresRoot,
  [int] $ValidateMigrationPort = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted') {
  throw 'POSTGRES_RECOVERY_DISPOSABLE_HOSTED_RUNNER_REQUIRED'
}
if ([string]::IsNullOrWhiteSpace($PostgresRoot)) {
  $PostgresRoot = Join-Path $PSScriptRoot '..\..\packages\ventio_host_api\build\windows\host-payload\postgresql'
}
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$recoveryScript = Join-Path $PSScriptRoot 'recover-host-database-credentials.ps1'

if ($ValidateMigrationPort -gt 0) {
  # Run the actual product ledger/profile validator against the running fixture.
  $tokens = $null
  $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($recoveryScript, [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors.Count) { throw 'POSTGRES_RECOVERY_SCRIPT_PARSE_FAILED' }
  foreach ($name in @('ConvertTo-HostRecoveryArgument', 'Invoke-HostRecoveryProcess', 'Invoke-HostRecoveryMigrationValidation')) {
    $definition = $ast.Find({ param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true)
    if (-not $definition) { throw 'POSTGRES_RECOVERY_VALIDATOR_MISSING' }
    . ([scriptblock]::Create($definition.Extent.Text))
  }
  $psql = Join-Path $PostgresRoot 'bin\psql.exe'
  $password = $env:VENTIO_TEST_MIGRATOR_PASSWORD
  Remove-Item Env:VENTIO_TEST_MIGRATOR_PASSWORD
  $credential = [PSCredential]::new('ventio_migrator_app', (ConvertTo-SecureString $password -AsPlainText -Force))
  try {
    $password = $null
    Invoke-HostRecoveryMigrationValidation $ValidateMigrationPort $credential (Join-Path $repoRoot 'migrations\postgres')
    Write-Output 'HOST_DATABASE_RECOVERY_MIGRATION_LEDGER_TEST_PASS'
  } finally { $credential.Password.Dispose() }
  return
}

# A unique virtual-account Windows service and a fresh private cluster exercise
# the same token/worker implementation as the shipped fixed-path command.
& dotnet run --project (Join-Path $repoRoot 'installer\windows\host-service.tests\HostService.Tests.csproj') -c Release -- --postgres-recovery-fixture ([IO.Path]::GetFullPath($PostgresRoot))
if ($LASTEXITCODE -ne 0) { throw 'POSTGRES_SERVICE_IDENTITY_RECOVERY_FIXTURE_FAILED' }
