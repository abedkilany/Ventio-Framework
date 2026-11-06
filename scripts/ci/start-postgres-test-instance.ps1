$ErrorActionPreference = 'Stop'

foreach ($name in @('GITHUB_ENV', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'RUNNER_TEMP', 'VENTIO_TEST_POSTGRES_BIN_DIR')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "GitHub Actions did not provide $name." }
}

$runLabel = "$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)"
if ($runLabel -notmatch '^\d+-\d+$') { throw 'GitHub returned an invalid run identifier.' }

$tempRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot "ventio-pg-$runLabel"))
if (-not $fixtureRoot.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $fixtureRoot) -ne "ventio-pg-$runLabel") {
    throw 'The PostgreSQL fixture path is outside the current Actions temporary directory.'
}
if (Test-Path -LiteralPath $fixtureRoot) { throw 'A PostgreSQL fixture already exists for this workflow run.' }

$binDirectory = [IO.Path]::GetFullPath($env:VENTIO_TEST_POSTGRES_BIN_DIR)
$pgCtl = Join-Path $binDirectory 'pg_ctl.exe'
$initdb = Join-Path $binDirectory 'initdb.exe'
$createdb = Join-Path $binDirectory 'createdb.exe'
$pgIsReady = Join-Path $binDirectory 'pg_isready.exe'
foreach ($tool in @($pgCtl, $initdb, $createdb, $pgIsReady)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Required PostgreSQL tool is missing: $(Split-Path -Leaf $tool)" }
}

Write-Output '::add-mask::ventio_test_only'
Write-Output '::add-mask::runtime_test_only'
Write-Output '::add-mask::admin_test_only'
Write-Output '::add-mask::user_api_test_only'
Write-Output '::add-mask::migration_test_only'
Write-Output '::add-mask::restore_fixture_only'

$dataDirectory = Join-Path $fixtureRoot 'data'
$logFile = Join-Path $fixtureRoot 'postgres.log'
$passwordFile = Join-Path $fixtureRoot 'bootstrap-password.txt'
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()

$postgresPassword = 'ventio_test_only'
$targetRoot = $null
try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSid = $identity.User.Value
    if ($currentSid -notmatch '^S-1-\d+(?:-\d+)+$') { throw 'Cannot resolve the runner service SID.' }
    & icacls.exe $fixtureRoot /inheritance:r /grant:r "*$currentSid`:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not protect PostgreSQL fixture files with a private Windows ACL.' }

    [IO.File]::WriteAllText($passwordFile, $postgresPassword, [System.Text.UTF8Encoding]::new($false))
    & $initdb -D $dataDirectory -U ventio --auth-local=scram-sha-256 --auth-host=scram-sha-256 "--pwfile=$passwordFile" --encoding=UTF8 --no-sync
    if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL initdb failed.' }
    Remove-Item -LiteralPath $passwordFile -Force

    $pgOptions = "-h 127.0.0.1 -p $port -c listen_addresses=127.0.0.1 -c logging_collector=off -c max_prepared_transactions=1"
    & $pgCtl -D $dataDirectory -l $logFile -o $pgOptions -w -t 60 start
    if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL did not start within one minute.' }

    $env:PGPASSWORD = $postgresPassword
    $ready = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        & $pgIsReady -h 127.0.0.1 -p $port -U ventio -d postgres | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw 'PostgreSQL did not accept loopback connections.' }
    & $createdb -h 127.0.0.1 -p $port -U ventio ventio_host_test
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the disposable Ventio test database.' }

    $values = [ordered]@{
        VENTIO_TEST_POSTGRES_MODE = 'process'
        VENTIO_CI_RUN_LABEL = $runLabel
        VENTIO_TEST_POSTGRES_DATA_DIRECTORY = $dataDirectory
        VENTIO_TEST_POSTGRES_LOG_FILE = $logFile
        VENTIO_TEST_POSTGRES_PORT = [string]$port
        VENTIO_TEST_POSTGRES_BIN_DIR = $binDirectory
        VENTIO_TEST_DATABASE_URL = "postgresql://ventio:ventio_test_only@127.0.0.1:$port/ventio_host_test?sslmode=disable"
        VENTIO_DATABASE_URL = "postgresql://ventio:ventio_test_only@127.0.0.1:$port/ventio_host_test?sslmode=disable"
        VENTIO_TEST_RUNTIME_DATABASE_URL = "postgresql://ventio_runtime_test:runtime_test_only@127.0.0.1:$port/ventio_host_test?sslmode=disable"
        VENTIO_TEST_ADMIN_DATABASE_URL = "postgresql://ventio_admin_test:admin_test_only@127.0.0.1:$port/ventio_host_test?sslmode=disable"
        VENTIO_TEST_API_ADMIN_DATABASE_URL = "postgresql://ventio_user_api_test:user_api_test_only@127.0.0.1:$port/ventio_host_test?sslmode=disable"
        VENTIO_TEST_MIGRATION_DATABASE_URL = "postgresql://ventio_migration_test:migration_test_only@127.0.0.1:$port/ventio_host_test?sslmode=disable"
        VENTIO_ALLOW_DATABASE_TESTS = 'yes'
        VENTIO_ALLOW_POSTGRES_CRASH_TEST = 'yes'
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    foreach ($entry in $values.GetEnumerator()) {
        if ($entry.Value -match '[\r\n]') { throw "Invalid environment value for $($entry.Key)." }
        [IO.File]::AppendAllText($env:GITHUB_ENV, "$($entry.Key)=$($entry.Value)`n", $utf8NoBom)
    }

    Write-Output "Started isolated PostgreSQL $(((& (Join-Path $binDirectory 'postgres.exe') --version) -join '').Trim()) on 127.0.0.1:$port."
}
catch {
    $targetRoot = [IO.Path]::GetFullPath($fixtureRoot)
    if ($targetRoot.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $dataDirectory)) {
        & $pgCtl -D $dataDirectory -m immediate -w -t 20 stop *> $null
    }
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
    throw
}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
