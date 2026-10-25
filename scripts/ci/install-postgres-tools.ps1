$ErrorActionPreference = 'Stop'

$version = '16.15-5'
$expectedSha256 = '43bb45f173a6f08cf1d29a97a6d8deb119e8e8093a24c00d2d1001a0ccaa8281'
$expectedLength = 373254386
$archiveName = "postgresql-$version-windows-x64-binaries.zip"
$archiveUrl = "https://get.enterprisedb.com/postgresql/$archiveName"
$checksumUrl = "$archiveUrl.sha256"

foreach ($name in @('GITHUB_ENV', 'GITHUB_PATH', 'RUNNER_TEMP', 'RUNNER_TOOL_CACHE')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) {
        throw "GitHub Actions did not provide $name."
    }
}

$toolCache = [IO.Path]::GetFullPath($env:RUNNER_TOOL_CACHE)
$toolRoot = Join-Path $toolCache "ventio-postgresql-$version-x64"
$binDirectory = Join-Path $toolRoot 'pgsql\bin'
$postgresExe = Join-Path $binDirectory 'postgres.exe'
$requiredTools = @('postgres.exe', 'initdb.exe', 'pg_ctl.exe', 'psql.exe', 'pg_dump.exe', 'pg_dumpall.exe', 'pg_restore.exe', 'createdb.exe', 'pg_isready.exe')

function Test-PostgresToolDirectory {
    if (-not (Test-Path -LiteralPath $postgresExe -PathType Leaf)) { return $false }
    foreach ($tool in $requiredTools) {
        if (-not (Test-Path -LiteralPath (Join-Path $binDirectory $tool) -PathType Leaf)) { return $false }
    }
    $versionText = (& $postgresExe --version 2>&1 | Out-String).Trim()
    return ($LASTEXITCODE -eq 0 -and $versionText -eq "postgres (PostgreSQL) $($version.Split('-')[0])")
}

if (-not (Test-PostgresToolDirectory)) {
    New-Item -ItemType Directory -Path $toolCache -Force | Out-Null
    if (Test-Path -LiteralPath $toolRoot) {
        $resolvedToolRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $toolRoot).Path)
        if (-not $resolvedToolRoot.StartsWith($toolCache.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to replace a PostgreSQL cache path outside RUNNER_TOOL_CACHE.'
        }
        Remove-Item -LiteralPath $resolvedToolRoot -Recurse -Force
    }

    $tempRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
    $workRoot = Join-Path $tempRoot "ventio-postgres-install-$PID"
    $resolvedWorkRoot = [IO.Path]::GetFullPath($workRoot)
    if (-not $resolvedWorkRoot.StartsWith($tempRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to create PostgreSQL installation files outside RUNNER_TEMP.'
    }
    $archivePath = Join-Path $workRoot $archiveName
    $extractRoot = Join-Path $workRoot 'expanded'
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

    try {
        $checksum = (Invoke-WebRequest -Uri $checksumUrl -UseBasicParsing -TimeoutSec 60).Content.Trim()
        if ($checksum -notmatch '^([0-9a-fA-F]{64})\s+\S+$' -or $Matches[1].ToLowerInvariant() -ne $expectedSha256) {
            throw 'The PostgreSQL binary archive checksum metadata did not match the pinned EDB release.'
        }

        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        $chunkCount = 8
        $chunkSize = [Math]::Ceiling($expectedLength / $chunkCount)
        $downloads = @()
        for ($index = 0; $index -lt $chunkCount; $index++) {
            $start = [long]$index * $chunkSize
            $end = [Math]::Min($expectedLength - 1, $start + $chunkSize - 1)
            $chunkPath = Join-Path $workRoot "archive-$index.part"
            $arguments = '--fail --location --silent --show-error --range {0}-{1} --output "{2}" "{3}"' -f $start, $end, $chunkPath, $archiveUrl
            $downloads += [pscustomobject]@{
                Index = $index
                Start = $start
                End = $end
                Path = $chunkPath
                Process = Start-Process -FilePath $curl -ArgumentList $arguments -PassThru -WindowStyle Hidden
            }
        }
        foreach ($download in $downloads) { $download.Process.WaitForExit() }
        foreach ($download in $downloads) {
            if ($download.Process.ExitCode -ne 0 -or
                -not (Test-Path -LiteralPath $download.Path) -or
                (Get-Item -LiteralPath $download.Path).Length -ne ($download.End - $download.Start + 1)) {
                throw 'A PostgreSQL archive range failed to download completely from EDB.'
            }
        }
        $archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            foreach ($download in ($downloads | Sort-Object Index)) {
                $chunkStream = [IO.File]::OpenRead($download.Path)
                try { $chunkStream.CopyTo($archiveStream) } finally { $chunkStream.Dispose() }
            }
        }
        finally { $archiveStream.Dispose() }
        if ((Get-Item -LiteralPath $archivePath).Length -ne $expectedLength) {
            throw 'The downloaded PostgreSQL archive length did not match the pinned EDB artifact.'
        }
        $actualSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha256 -ne $expectedSha256) { throw 'The downloaded PostgreSQL binary archive failed SHA-256 verification.' }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
        $extractedPostgres = Join-Path $extractRoot 'pgsql\bin\postgres.exe'
        if (-not (Test-Path -LiteralPath $extractedPostgres -PathType Leaf)) {
            throw 'The verified PostgreSQL archive did not contain the expected pgsql/bin layout.'
        }
        New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
        Move-Item -LiteralPath (Join-Path $extractRoot 'pgsql') -Destination (Join-Path $toolRoot 'pgsql')
        if (-not (Test-PostgresToolDirectory)) { throw 'The installed PostgreSQL tool set did not pass version checks.' }
    }
    finally {
        if (Test-Path -LiteralPath $workRoot) {
            $resolved = [IO.Path]::GetFullPath($workRoot)
            if ($resolved.StartsWith($tempRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[IO.File]::AppendAllText($env:GITHUB_ENV, "VENTIO_TEST_POSTGRES_BIN_DIR=$binDirectory`n", $utf8NoBom)
[IO.File]::AppendAllText($env:GITHUB_PATH, "$binDirectory`n", $utf8NoBom)
Write-Output "Using EDB PostgreSQL $version binaries from the verified runner tool cache."
