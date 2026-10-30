param(
  [string] $PostgresRoot = (Join-Path $PSScriptRoot '..\..\packages\ventio_host_api\build\windows\host-payload\postgresql')
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PostgresRoot)
$bin = Join-Path $root 'bin'
foreach ($name in @('initdb.exe', 'pg_ctl.exe', 'pg_isready.exe', 'psql.exe')) {
  if (-not (Test-Path -LiteralPath (Join-Path $bin $name) -PathType Leaf)) {
    throw "Packaged PostgreSQL executable is missing: $name"
  }
}

$version = (& (Join-Path $bin 'postgres.exe') --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $version -ne 'postgres (PostgreSQL) 16.15') {
  throw 'Packaged PostgreSQL version did not match the pinned release.'
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('ventio-pg-smoke-' + [guid]::NewGuid().ToString('N'))
$data = Join-Path $temp 'data'
$passwordFile = Join-Path $temp 'initdb-password.txt'
$log = Join-Path $temp 'postgres.log'
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()
$password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36))
$started = $false

try {
  New-Item -ItemType Directory -Path $temp | Out-Null
  [IO.File]::WriteAllText($passwordFile, $password, [Text.Encoding]::ASCII)
  & (Join-Path $bin 'initdb.exe') -D $data -U ventio_test "--pwfile=$passwordFile" `
    --auth-local=scram-sha-256 --auth-host=scram-sha-256 --encoding=UTF8 --no-locale
  if ($LASTEXITCODE -ne 0) { throw 'Temporary PostgreSQL cluster initialization failed.' }

  & (Join-Path $bin 'pg_ctl.exe') -D $data -l $log `
    -o "-h 127.0.0.1 -p $port -c listen_addresses=127.0.0.1" -w start
  if ($LASTEXITCODE -ne 0) { throw 'Temporary PostgreSQL server did not start.' }
  $started = $true

  & (Join-Path $bin 'pg_isready.exe') -h 127.0.0.1 -p $port -t 10
  if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL readiness check failed.' }

  $env:PGPASSWORD = $password
  $result = & (Join-Path $bin 'psql.exe') -h 127.0.0.1 -p $port -U ventio_test -d postgres `
    -v ON_ERROR_STOP=1 -Atc "select current_user || ':' || current_setting('server_version')"
  if ($LASTEXITCODE -ne 0 -or $result -ne 'ventio_test:16.15') {
    throw 'Authenticated PostgreSQL query failed or returned an unexpected server version.'
  }

  Write-Output 'POSTGRES_PAYLOAD_INTEGRATION_PASS'
  Write-Output 'Ephemeral cluster initialized with SCRAM authentication, started on loopback, accepted an authenticated SQL query, and passed readiness.'
}
finally {
  Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
  if ($started -and (Test-Path -LiteralPath $data)) {
    & (Join-Path $bin 'pg_ctl.exe') -D $data -m fast -w stop *> $null
  }
  if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
