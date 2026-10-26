# Run the PostgreSQL-backed identity, RLS and extension package integrations on
# Windows using a uniquely named disposable container and public test-only
# credentials. No existing database or persistent Docker volume is used.
param(
  [switch] $IdentityOnly,
  [switch] $AndroidDeviceIntegration,
  [switch] $HostProcessOnly
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$containerName = 'ventio-extension-test-' + [Guid]::NewGuid().ToString('N')
$containerCreated = $false
$environmentNames = @(
  'VENTIO_DATABASE_URL',
  'VENTIO_MIGRATIONS_DIR',
  'VENTIO_TEST_DATABASE_URL',
  'VENTIO_TEST_RUNTIME_DATABASE_URL',
  'VENTIO_TEST_ADMIN_DATABASE_URL',
  'VENTIO_TEST_MIGRATION_DATABASE_URL',
  'VENTIO_ALLOW_DATABASE_TESTS',
  'VENTIO_RUN_ANDROID_HOST_INTEGRATION',
  'PGPASSWORD'
)
$previousEnvironment = @{}
foreach ($name in $environmentNames) {
  $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable(
    $name,
    'Process'
  )
}

try {
  if ($IdentityOnly -and $HostProcessOnly) {
    throw 'IdentityOnly and HostProcessOnly cannot be used together.'
  }

  if ($AndroidDeviceIntegration) {
    [Environment]::SetEnvironmentVariable(
      'VENTIO_RUN_ANDROID_HOST_INTEGRATION',
      'yes',
      'Process'
    )
  }

  docker info | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop must be running before the disposable test starts.'
  }

  docker run --rm -d --name $containerName -p 127.0.0.1::5432 `
    -e POSTGRES_USER=ventio `
    -e POSTGRES_PASSWORD=ventio_test_only `
    -e POSTGRES_DB=ventio_host_test postgres:16 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Could not start disposable PostgreSQL 16.'
  }
  $containerCreated = $true

  $ready = $false
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    docker exec $containerName pg_isready -U ventio -d ventio_host_test | Out-Null
    if ($LASTEXITCODE -eq 0) {
      $ready = $true
      break
    }
    Start-Sleep -Seconds 1
  }
  if (-not $ready) {
    throw 'Disposable PostgreSQL did not become ready.'
  }

  docker exec $containerName mkdir -p /tmp/ventio-security
  if ($LASTEXITCODE -ne 0) {
    throw 'Could not prepare the test-only security scripts.'
  }
  docker cp (Join-Path $repoRoot 'security/postgres/.') `
    "$($containerName):/tmp/ventio-security" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Could not copy reviewed security scripts into the disposable container.'
  }

  $portMapping = docker port $containerName '5432/tcp'
  if ($LASTEXITCODE -ne 0 -or $portMapping -notmatch ':(\d+)$') {
    throw 'Could not resolve the disposable database port.'
  }
  $port = $Matches[1]
  $databaseUrl = "postgresql://ventio:ventio_test_only@127.0.0.1:$port/ventio_host_test?sslmode=disable"
  [Environment]::SetEnvironmentVariable('VENTIO_DATABASE_URL', $databaseUrl, 'Process')
  [Environment]::SetEnvironmentVariable('VENTIO_MIGRATIONS_DIR', '../../migrations/postgres', 'Process')
  [Environment]::SetEnvironmentVariable('PGPASSWORD', 'ventio_test_only', 'Process')

  Push-Location (Join-Path $repoRoot 'packages/ventio_host_api')
  try {
    dart run ../ventio_postgres/bin/migrate.dart
    if ($LASTEXITCODE -ne 0) {
      throw 'PostgreSQL migrations failed.'
    }

    docker exec --env PGPASSWORD=ventio_test_only $containerName psql `
      -v ON_ERROR_STOP=1 -h localhost -U ventio -d ventio_host_test `
      -v expected_database=ventio_host_test -f /tmp/ventio-security/bootstrap.sql
    if ($LASTEXITCODE -ne 0) {
      throw 'PostgreSQL security bootstrap failed.'
    }
    # Simulate the previous private extension schema, then exercise both the
    # controlled pgcrypto move and repeatable installation on the same schema.
    docker exec --env PGPASSWORD=ventio_test_only $containerName psql `
      -v ON_ERROR_STOP=1 -h localhost -U ventio -d ventio_host_test `
      -c 'ALTER EXTENSION pgcrypto SET SCHEMA ventio_security;'
    if ($LASTEXITCODE -ne 0) {
      throw 'Could not prepare the previous private pgcrypto schema profile.'
    }
    docker exec --env PGPASSWORD=ventio_test_only $containerName psql `
      -v ON_ERROR_STOP=1 -h localhost -U ventio -d ventio_host_test `
      -v expected_database=ventio_host_test -f /tmp/ventio-security/bootstrap.sql
    if ($LASTEXITCODE -ne 0) {
      throw 'Repeat PostgreSQL security bootstrap failed.'
    }
    docker exec --env PGPASSWORD=ventio_test_only $containerName psql `
      -v ON_ERROR_STOP=1 -h localhost -U ventio -d ventio_host_test `
      -f /tmp/ventio-security/test_logins.sql
    if ($LASTEXITCODE -ne 0) {
      throw 'Disposable PostgreSQL test-login setup failed.'
    }

    $baseUrl = "postgresql://ventio:ventio_test_only@127.0.0.1:$port/ventio_host_test?sslmode=disable&connect_timeout=5&query_timeout=20"
    [Environment]::SetEnvironmentVariable('VENTIO_TEST_DATABASE_URL', $baseUrl, 'Process')
    [Environment]::SetEnvironmentVariable(
      'VENTIO_TEST_RUNTIME_DATABASE_URL',
      "postgresql://ventio_runtime_test:runtime_test_only@127.0.0.1:$port/ventio_host_test?sslmode=disable&connect_timeout=5&query_timeout=20",
      'Process'
    )
    [Environment]::SetEnvironmentVariable(
      'VENTIO_TEST_ADMIN_DATABASE_URL',
      "postgresql://ventio_admin_test:admin_test_only@127.0.0.1:$port/ventio_host_test?sslmode=disable&connect_timeout=5&query_timeout=20",
      'Process'
    )
    [Environment]::SetEnvironmentVariable(
      'VENTIO_TEST_MIGRATION_DATABASE_URL',
      "postgresql://ventio_migration_test:migration_test_only@127.0.0.1:$port/ventio_host_test?sslmode=disable&connect_timeout=5&query_timeout=20",
      'Process'
    )
    [Environment]::SetEnvironmentVariable('VENTIO_ALLOW_DATABASE_TESTS', 'yes', 'Process')

    if ($HostProcessOnly) {
      dart run test/local_host_role_process_integration.dart
      if ($LASTEXITCODE -ne 0) {
        throw 'Windows persistent Host process integration failed.'
      }
    }
    else {
      dart run test/identity_integration.dart
      if ($LASTEXITCODE -ne 0) {
        throw 'Persistent identity PostgreSQL integration failed.'
      }
    }

    if (-not $IdentityOnly -and -not $HostProcessOnly) {
      dart run test/database_security_integration.dart
      if ($LASTEXITCODE -ne 0) {
        throw 'PostgreSQL least-privilege and RLS integration failed.'
      }

      dart run test/role_administration_integration.dart
      if ($LASTEXITCODE -ne 0) {
        throw 'Scoped role administration integration failed.'
      }

      dart run test/extension_package_integration.dart
      if ($LASTEXITCODE -ne 0) {
        throw 'Extension package PostgreSQL integration failed.'
      }

      dart run test/local_host_role_process_integration.dart
      if ($LASTEXITCODE -ne 0) {
        throw 'Windows persistent Host process role-administration integration failed.'
      }
    }
  }
  finally {
    Pop-Location
  }
}
finally {
  foreach ($name in $environmentNames) {
    [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
  }
  if ($containerCreated) {
    $runningContainer = docker ps -q --filter "name=^$containerName$"
    if ($runningContainer) {
      docker stop $containerName | Out-Null
    }
  }
}
