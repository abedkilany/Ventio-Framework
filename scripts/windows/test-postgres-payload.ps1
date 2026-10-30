param(
  [string] $PostgresRoot = (Join-Path $PSScriptRoot '..\..\packages\ventio_host_api\build\windows\host-payload\postgresql')
)

$ErrorActionPreference = 'Stop'
$provisioner = Join-Path $PSScriptRoot 'provision-postgres-service.ps1'
if (-not (Test-Path -LiteralPath $provisioner -PathType Leaf)) {
  throw 'POSTGRES_PAYLOAD_TEST_PROVISIONER_MISSING'
}

# Reuse the provisioner's disposable test path so the SCRAM bootstrap secret
# travels through a current-user-only named pipe instead of a plaintext file.
& $provisioner -PostgresRoot $PostgresRoot -TestInitDbOnly
if (-not $?) { throw 'POSTGRES_PAYLOAD_INTEGRATION_FAILED' }

Write-Output 'POSTGRES_PAYLOAD_INTEGRATION_PASS'
Write-Output 'Packaged PostgreSQL passed disposable SCRAM initialization, loopback readiness, authenticated SQL, and teardown.'
