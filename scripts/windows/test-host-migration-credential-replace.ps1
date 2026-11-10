param()

$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot 'HostMigrationCredential.psm1'
Import-Module $module -Force
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testRoot = Join-Path $tempRoot ('ventio-pg-initdb-test-' + [guid]::NewGuid().ToString('N'))
$directory = Join-Path $testRoot 'protected-migration-credential'
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$resolvedDirectory = [IO.Path]::GetFullPath($directory)
if (-not $resolvedTestRoot.StartsWith($tempRoot + 'ventio-pg-initdb-test-', [StringComparison]::OrdinalIgnoreCase) -or
    -not $resolvedDirectory.StartsWith($resolvedTestRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'HOST_MIGRATION_CREDENTIAL_TEST_PATH_INVALID'
}

$password = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg'
$credential = [PSCredential]::new('ventio_migrator_app', (ConvertTo-SecureString $password -AsPlainText -Force))
try {
  Write-HostMigrationCredential -Credential $credential -OutputDirectory $resolvedDirectory -TestMode
  Write-HostMigrationCredential -Credential $credential -OutputDirectory $resolvedDirectory -TestMode
  $restored = Read-HostMigrationCredential -OutputDirectory $resolvedDirectory -TestMode
  if ($restored.UserName -cne $credential.UserName -or
      $restored.GetNetworkCredential().Password -cne $password) {
    throw 'HOST_MIGRATION_CREDENTIAL_REPLACE_ROUNDTRIP_FAILED'
  }
  $leftovers = @(Get-ChildItem -LiteralPath $resolvedDirectory -File -Force |
    Where-Object { $_.Name -like '*.replace-backup' -or $_.Name -like '*.tmp' })
  if ($leftovers.Count -gt 0) { throw 'HOST_MIGRATION_CREDENTIAL_REPLACE_TEMPORARY_LEFTOVER' }
  Write-Output 'HOST_MIGRATION_CREDENTIAL_REPLACE_PASS'
}
finally {
  $credential = $null
  $restored = $null
  if (Test-Path -LiteralPath $resolvedTestRoot) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}
