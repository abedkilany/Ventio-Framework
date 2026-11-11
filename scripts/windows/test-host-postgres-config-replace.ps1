param()

$ErrorActionPreference = 'Stop'
$contracts = @(
  @{ Path = 'upgrade-host-database.ps1'; Pattern = '\[IO\.File\]::Replace\(\$temporaryConfig,\s*\$postgresConfig,\s*\$replacementBackup,\s*\$true\)' },
  @{ Path = 'upgrade-host-database.ps1'; Pattern = '\[IO\.File\]::Replace\(\$tempPath,\s*\$requestPath,\s*\$replacementBackup,\s*\$true\)' },
  @{ Path = 'HostMigrationCredential.psm1'; Pattern = '\[IO\.File\]::Replace\(\$tempPath,\s*\$path,\s*\$replacementBackup,\s*\$true\)' },
  @{ Path = 'write-host-service-config.ps1'; Pattern = '\[IO\.File\]::Replace\(\$tempPath,\s*\$targetPath,\s*\$replacementBackup,\s*\$true\)' }
)
foreach ($contract in $contracts) {
  $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot $contract.Path) -Raw
  if ($source -notmatch $contract.Pattern) {
    throw ('HOST_POSTGRES_CONFIG_REPLACE_BACKUP_CONTRACT_MISSING_' + $contract.Path)
  }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ventio-postgres-config-replace-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
  $destination = Join-Path $scratch 'postgresql.conf'
  $temporary = Join-Path $scratch 'postgresql.conf.tmp'
  $backup = Join-Path $scratch 'postgresql.conf.replace-backup'
  $secondTemporary = Join-Path $scratch 'postgresql.conf.second.tmp'
  $secondBackup = Join-Path $scratch 'postgresql.conf.second-replace-backup'
  [IO.File]::WriteAllText($destination, 'original-config')
  [IO.File]::WriteAllText($temporary, 'replacement-config')
  $destinationAcl = Get-Acl -LiteralPath $destination
  Set-Acl -LiteralPath $temporary -AclObject $destinationAcl

  [IO.File]::Replace($temporary, $destination, $backup, $true)
  if ([IO.File]::ReadAllText($destination) -cne 'replacement-config') {
    throw 'HOST_POSTGRES_CONFIG_REPLACE_DESTINATION_INVALID'
  }
  if ([IO.File]::ReadAllText($backup) -cne 'original-config') {
    throw 'HOST_POSTGRES_CONFIG_REPLACE_BACKUP_INVALID'
  }
  if (Test-Path -LiteralPath $temporary) {
    throw 'HOST_POSTGRES_CONFIG_REPLACE_TEMPORARY_NOT_CONSUMED'
  }

  [IO.File]::WriteAllText($secondTemporary, 'second-replacement-config')
  Set-Acl -LiteralPath $secondTemporary -AclObject (Get-Acl -LiteralPath $destination)
  [IO.File]::Replace($secondTemporary, $destination, $secondBackup, $true)
  if ([IO.File]::ReadAllText($destination) -cne 'second-replacement-config' -or
      [IO.File]::ReadAllText($secondBackup) -cne 'replacement-config') {
    throw 'HOST_POSTGRES_CONFIG_REPLACE_EXISTING_DESTINATION_INVALID'
  }

  Remove-Item -LiteralPath $backup -Force
  Remove-Item -LiteralPath $secondBackup -Force
  Write-Output 'HOST_POSTGRES_CONFIG_REPLACE_PASS'
} finally {
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
