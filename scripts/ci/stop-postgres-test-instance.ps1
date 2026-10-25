$ErrorActionPreference = 'Stop'

if (-not $env:VENTIO_CI_RUN_LABEL -or $env:VENTIO_CI_RUN_LABEL -notmatch '^\d+-\d+$') {
    Write-Output 'No scoped PostgreSQL fixture was created for this run.'
    exit 0
}

if (-not $env:RUNNER_TEMP -or -not $env:VENTIO_TEST_POSTGRES_DATA_DIRECTORY -or -not $env:VENTIO_TEST_POSTGRES_BIN_DIR) {
    throw 'The PostgreSQL fixture cleanup metadata is incomplete.'
}

$tempRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot "ventio-pg-$($env:VENTIO_CI_RUN_LABEL)"))
$dataDirectory = [IO.Path]::GetFullPath($env:VENTIO_TEST_POSTGRES_DATA_DIRECTORY)
$expectedDataDirectory = [IO.Path]::GetFullPath((Join-Path $fixtureRoot 'data'))
$pgCtl = Join-Path ([IO.Path]::GetFullPath($env:VENTIO_TEST_POSTGRES_BIN_DIR)) 'pg_ctl.exe'
if (-not $fixtureRoot.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $fixtureRoot) -ne "ventio-pg-$($env:VENTIO_CI_RUN_LABEL)" -or
    $dataDirectory -ne $expectedDataDirectory -or
    -not (Test-Path -LiteralPath $pgCtl -PathType Leaf)) {
    throw 'Refusing to clean up a PostgreSQL path outside this workflow run.'
}

function Stop-PostgresDataDirectory([string] $path) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return }
    & $pgCtl -D $path status *> $null
    if ($LASTEXITCODE -eq 0) {
        & $pgCtl -D $path -m immediate -w -t 30 stop 2>&1 | Out-Null
        & $pgCtl -D $path status *> $null
        if ($LASTEXITCODE -eq 0) { throw 'A disposable PostgreSQL process is still running.' }
    }
}

foreach ($recoveryRoot in Get-ChildItem -LiteralPath $fixtureRoot -Directory -Filter 'recovery-*' -ErrorAction SilentlyContinue) {
    $recoveryPath = [IO.Path]::GetFullPath($recoveryRoot.FullName)
    if (-not $recoveryPath.StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to inspect a recovery fixture outside this workflow run.'
    }
    Stop-PostgresDataDirectory (Join-Path $recoveryPath 'restored-data')
}
Stop-PostgresDataDirectory $dataDirectory

if (Test-Path -LiteralPath $fixtureRoot) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    Write-Output "Removed disposable PostgreSQL fixture for Actions run $($env:VENTIO_CI_RUN_LABEL)."
}
