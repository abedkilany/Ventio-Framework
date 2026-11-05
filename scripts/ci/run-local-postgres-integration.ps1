[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PostgresBinDirectory,
    [switch] $HostSecuritySuites,
    [switch] $ClientOfflineIntegration,
    [switch] $HostProcessIntegration,
    [switch] $HostDiagnosticsProcessIntegration,
    [ValidateSet('api_integration.dart', 'first_admin_bootstrap_integration.dart', 'database_security_integration.dart', 'identity_integration.dart', 'management_users_integration.dart', 'role_administration_integration.dart', 'pairing_integration.dart', 'recovery_integration.dart')]
    [string] $OnlyHostSuite
)

$ErrorActionPreference = 'Stop'
if (@($HostSecuritySuites, $ClientOfflineIntegration, $HostProcessIntegration, $HostDiagnosticsProcessIntegration).Where({ $_ }).Count -gt 1) {
    throw 'Select exactly one local PostgreSQL integration mode.'
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This disposable PostgreSQL runner is for Windows.'
}

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$binDirectory = [IO.Path]::GetFullPath($PostgresBinDirectory)
$postgres = Join-Path $binDirectory 'postgres.exe'
if (-not (Test-Path -LiteralPath $postgres -PathType Leaf)) {
    throw 'The supplied PostgreSQL binary directory is incomplete.'
}
$version = (& $postgres --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $version -ne 'postgres (PostgreSQL) 16.15') {
    throw 'The disposable test runner requires verified PostgreSQL 16.15 binaries.'
}

$runId = ([DateTime]::UtcNow.ToString('yyyyMMddHHmmss') +
    (Get-Random -Minimum 100 -Maximum 999))
$attempt = '1'
$runLabel = "$runId-$attempt"
$runnerTemp = Join-Path $env:LOCALAPPDATA "VentioFramework\postgres-test-runs\$runLabel"
if (Test-Path -LiteralPath $runnerTemp) {
    throw 'The unique disposable test directory already exists.'
}
New-Item -ItemType Directory -Path $runnerTemp -Force | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$sid = $identity.User.Value
$userRule = '*{0}:(OI)(CI)F' -f $sid
& icacls.exe $runnerTemp /inheritance:r /grant:r $userRule '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not protect the disposable PostgreSQL test environment.'
}

$envFile = Join-Path $runnerTemp 'github-env.txt'
New-Item -ItemType File -Path $envFile | Out-Null
$fileUserRule = '*{0}:F' -f $sid
& icacls.exe $envFile /inheritance:r /grant:r $fileUserRule '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not protect the disposable PostgreSQL test environment file.'
}

$env:GITHUB_RUN_ID = $runId
$env:GITHUB_RUN_ATTEMPT = $attempt
$env:GITHUB_ENV = $envFile
$env:RUNNER_TEMP = $runnerTemp
$env:VENTIO_TEST_POSTGRES_BIN_DIR = $binDirectory
$testExitCode = 99
$started = $false
try {
    & (Join-Path $PSScriptRoot 'start-postgres-test-instance.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw 'The isolated PostgreSQL fixture did not start.'
    }
    $started = $true

    foreach ($line in [IO.File]::ReadAllLines($envFile)) {
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) {
            [Environment]::SetEnvironmentVariable(
                $line.Substring(0, $separator),
                $line.Substring($separator + 1),
                [EnvironmentVariableTarget]::Process
            )
        }
    }

    $hostApiDirectory = Join-Path $workspace 'packages\ventio_host_api'
    if ($HostSecuritySuites -or $ClientOfflineIntegration -or $HostProcessIntegration -or $HostDiagnosticsProcessIntegration) {
        $env:VENTIO_MIGRATIONS_DIR = Join-Path $workspace 'migrations\postgres'
        $env:PGPASSWORD = 'ventio_test_only'
        Push-Location $hostApiDirectory
        try {
            & dart run ..\ventio_postgres\bin\migrate.dart
            if ($LASTEXITCODE -ne 0) { throw 'Host database migrations failed.' }
            $psql = Join-Path $binDirectory 'psql.exe'
            & $psql -X -h 127.0.0.1 -p $env:VENTIO_TEST_POSTGRES_PORT -U ventio -d ventio_host_test -v ON_ERROR_STOP=1 -v expected_database=ventio_host_test -f (Join-Path $workspace 'security\postgres\bootstrap.sql')
            if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL least-privilege role bootstrap failed.' }
            & $psql -X -h 127.0.0.1 -p $env:VENTIO_TEST_POSTGRES_PORT -U ventio -d ventio_host_test -f (Join-Path $workspace 'security\postgres\test_logins.sql')
            if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL integration login setup failed.' }
            $env:PGPASSWORD = 'migration_test_only'
            $pairingCreateContract = Join-Path $workspace 'security\postgres\pairing_create.sql'
            & $psql -X -h 127.0.0.1 -p $env:VENTIO_TEST_POSTGRES_PORT -U ventio_migration_test -d ventio_host_test -v ON_ERROR_STOP=1 -c 'SET ROLE ventio_owner' -f $pairingCreateContract
            if ($LASTEXITCODE -ne 0) { throw 'Restricted pairing contract upgrade failed.' }
            $pairingContractReady = & $psql -X -h 127.0.0.1 -p $env:VENTIO_TEST_POSTGRES_PORT -U ventio_migration_test -d ventio_host_test -Atc "SET ROLE ventio_owner; SELECT position('Pairing request was already accepted' IN pg_get_functiondef('ventio_security.scoped_pairing_create(text,text,text,text,text,text)'::regprocedure)) > 0"
            $pairingContractMatch = [regex]::Match([string]::Join(' ', @($pairingContractReady)).Trim(), '(?:^|\s)(t|f)$')
            if ($LASTEXITCODE -ne 0 -or -not $pairingContractMatch.Success -or $pairingContractMatch.Groups[1].Value -cne 't') { throw 'Restricted pairing contract upgrade verification failed.' }
            Write-Output 'PASS: The restricted migrator applies and verifies the pairing request idempotency contract.'
        }
        finally {
            Pop-Location
            Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
        }
    }

    Push-Location $hostApiDirectory
    try {
        $suites = if ($HostSecuritySuites) {
            @('database_security_integration.dart', 'management_users_integration.dart', 'role_administration_integration.dart', 'pairing_integration.dart')
        } else {
            @('..\..\packages\ventio_postgres\test\postgres_integration.dart')
        }
        if ($OnlyHostSuite) { $suites = @($OnlyHostSuite) }
        if ($HostDiagnosticsProcessIntegration -or $HostProcessIntegration) {
            if ($HostDiagnosticsProcessIntegration) {
                $env:VENTIO_HOST_DIAGNOSTICS_PROCESS_TEST = 'yes'
            }
            & dart run 'test\local_host_role_process_integration.dart'
            $testExitCode = $LASTEXITCODE
        } elseif ($ClientOfflineIntegration) {
            Push-Location (Join-Path $workspace 'packages\ventio_native_client')
            try {
                $clientIntegration = 'test\official_inventory_host_sqlite_integration_test.dart'
                & flutter test --reporter expanded $clientIntegration
                $testExitCode = $LASTEXITCODE
            }
            finally {
                Pop-Location
            }
        } else {
            foreach ($suite in $suites) {
                if ($suite.StartsWith('..')) {
                    & dart run $suite
                } else {
                    & dart run "test\$suite"
                }
                $testExitCode = $LASTEXITCODE
                if ($testExitCode -ne 0) { break }
            }
        }
    }
    finally {
        Pop-Location
    }
    if ($testExitCode -ne 0) {
        throw "PostgreSQL persistence integration failed with exit code $testExitCode."
    }
}
finally {
    if ($started) {
        $fixtureRoot = Join-Path $runnerTemp "ventio-pg-$runLabel"
        & (Join-Path $PSScriptRoot 'stop-postgres-test-instance.ps1')
        if (Test-Path -LiteralPath $fixtureRoot) {
            throw 'The disposable PostgreSQL fixture did not clean up safely.'
        }
    }
    Remove-Item -LiteralPath $envFile -Force -ErrorAction SilentlyContinue
    $resolvedRunnerTemp = [IO.Path]::GetFullPath($runnerTemp)
    $expectedRunnerRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'VentioFramework\postgres-test-runs')).TrimEnd('\') + '\'
    if ($resolvedRunnerTemp.StartsWith($expectedRunnerRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedRunnerTemp) -ceq $runLabel -and
        $runLabel -match '^\d{17}-1$' -and
        (Test-Path -LiteralPath $resolvedRunnerTemp -PathType Container)) {
        $runnerAttributes = [IO.File]::GetAttributes($resolvedRunnerTemp)
        $runnerEntries = @(Get-ChildItem -LiteralPath $resolvedRunnerTemp -Force)
        if (($runnerAttributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and $runnerEntries.Count -eq 0) {
            Remove-Item -LiteralPath $resolvedRunnerTemp -Force
        } else {
            Write-Warning 'POSTGRES_TEST_RUN_DIRECTORY_PRESERVED_NONEMPTY_OR_UNSAFE'
        }
    }
}

if ($testExitCode -ne 0) {
    throw "PostgreSQL persistence integration did not pass ($testExitCode)."
}
