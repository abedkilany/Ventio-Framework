param(
  [string] $PostgresBinDirectory = (Join-Path $env:LOCALAPPDATA 'VentioFramework\postgresql-16.15-tools\pgsql\bin'),
  [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$hostRoot = Join-Path $repoRoot 'packages\ventio_host_api'
$defaultOutput = Join-Path $hostRoot 'build\windows\host-payload'
if (-not $OutputDirectory) { $OutputDirectory = $defaultOutput }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$buildRoot = [IO.Path]::GetFullPath((Join-Path $hostRoot 'build'))
if (-not $OutputDirectory.StartsWith($buildRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Host payload output must stay under packages/ventio_host_api/build.'
}
if (Test-Path -LiteralPath $OutputDirectory) {
  throw 'Host payload output already exists; choose a new isolated output directory to preserve existing artifacts.'
}

$postgresBin = [IO.Path]::GetFullPath($PostgresBinDirectory)
$postgresRoot = Split-Path -Parent $postgresBin
$requiredPostgres = @('postgres.exe', 'initdb.exe', 'pg_ctl.exe', 'psql.exe', 'pg_isready.exe', 'pg_controldata.exe', 'createdb.exe')
foreach ($name in $requiredPostgres) {
  if (-not (Test-Path -LiteralPath (Join-Path $postgresBin $name) -PathType Leaf)) {
    throw "Pinned PostgreSQL tool is missing: $name"
  }
}
$versionOutput = (& (Join-Path $postgresBin 'postgres.exe') --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $versionOutput -ne 'postgres (PostgreSQL) 16.15') {
  throw 'Host payload requires the verified PostgreSQL 16.15 Windows tools.'
}

$migrationDirectory = Join-Path $repoRoot 'migrations\postgres'
$securityDirectory = Join-Path $repoRoot 'security\postgres'
$windowsScriptDirectory = Join-Path $repoRoot 'scripts\windows'
$migrationPackage = Join-Path $repoRoot 'packages\ventio_postgres'
$migrationSource = Join-Path $migrationPackage 'bin\migrate.dart'
$identityBootstrapSource = Join-Path $hostRoot 'bin\bootstrap_first_administrator.dart'
$trustedPairingSource = Join-Path $hostRoot 'bin\trusted_windows_pairing.dart'
$trustedCredentialReissueSource = Join-Path $hostRoot 'bin\trusted_windows_credential_reissue.dart'
$trustedHostUpgradeSource = Join-Path $hostRoot 'bin\trusted_windows_host_upgrade.dart'
$serviceProject = Join-Path $repoRoot 'installer\windows\host-service\VentioHostService.csproj'
$setupBrokerProject = Join-Path $repoRoot 'installer\windows\setup-broker\VentioSetupBroker.csproj'
foreach ($path in @($migrationDirectory, $securityDirectory, (Join-Path $hostRoot 'bin\local_host.dart'), $migrationSource, $identityBootstrapSource, $trustedPairingSource, $trustedCredentialReissueSource, $trustedHostUpgradeSource, $serviceProject, $setupBrokerProject)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Required Host payload input is missing: $path" }
}

$tempDirectory = Join-Path (Split-Path -Parent $OutputDirectory) ('.host-payload-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null
try {
  $hostExe = Join-Path $tempDirectory 'ventio_host.exe'
  Push-Location $hostRoot
  try {
    & dart compile exe bin/local_host.dart -o $hostExe
    if ($LASTEXITCODE -ne 0) { throw "Host Engine compilation failed with exit code $LASTEXITCODE." }
  }
  finally { Pop-Location }

  $trustedPairingExe = Join-Path $tempDirectory 'ventio_trusted_pairing.exe'
  Push-Location $hostRoot
  try {
    & dart compile exe bin/trusted_windows_pairing.dart -o $trustedPairingExe
    if ($LASTEXITCODE -ne 0) { throw "Trusted Windows pairing compilation failed with exit code $LASTEXITCODE." }
  }
  finally { Pop-Location }

  $trustedCredentialReissueExe = Join-Path $tempDirectory 'ventio_trusted_credential_reissue.exe'
  Push-Location $hostRoot
  try {
    & dart compile exe bin/trusted_windows_credential_reissue.dart -o $trustedCredentialReissueExe
    if ($LASTEXITCODE -ne 0) { throw "Trusted same-device credential reissue compilation failed with exit code $LASTEXITCODE." }
  }
  finally { Pop-Location }

  $trustedHostUpgradeExe = Join-Path $tempDirectory 'ventio_trusted_host_upgrade.exe'
  Push-Location $hostRoot
  try {
    & dart compile exe bin/trusted_windows_host_upgrade.dart -o $trustedHostUpgradeExe
    if ($LASTEXITCODE -ne 0) { throw "Recovery-aware Host upgrade helper compilation failed with exit code $LASTEXITCODE." }
  }
  finally { Pop-Location }

  $identityBootstrapExe = Join-Path $tempDirectory 'ventio_identity_bootstrap.exe'
  Push-Location $hostRoot
  try {
    & dart compile exe bin/bootstrap_first_administrator.dart -o $identityBootstrapExe
    if ($LASTEXITCODE -ne 0) { throw "Host first-administrator bootstrap compilation failed with exit code $LASTEXITCODE." }
  }
  finally { Pop-Location }

  $migrationExe = Join-Path $tempDirectory 'ventio_migrate.exe'
  Push-Location $migrationPackage
  try {
    & dart compile exe bin/migrate.dart -o $migrationExe
    if ($LASTEXITCODE -ne 0) { throw "Host migration runner compilation failed with exit code $LASTEXITCODE." }
  }
  finally { Pop-Location }

  $serviceOutput = Join-Path $tempDirectory '.service-publish'
  & dotnet publish $serviceProject -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $serviceOutput
  if ($LASTEXITCODE -ne 0) { throw "Windows Host service compilation failed with exit code $LASTEXITCODE." }
  $serviceExe = Join-Path $serviceOutput 'VentioHostService.exe'
  if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) { throw 'Windows Host service executable was not published.' }
  Copy-Item -LiteralPath $serviceExe -Destination (Join-Path $tempDirectory 'VentioHostService.exe')
  Remove-Item -LiteralPath $serviceOutput -Recurse -Force

  $setupBrokerOutput = Join-Path $tempDirectory '.setup-broker-publish'
  & dotnet publish $setupBrokerProject -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $setupBrokerOutput
  if ($LASTEXITCODE -ne 0) { throw "Windows Host setup broker compilation failed with exit code $LASTEXITCODE." }
  $setupBrokerExe = Join-Path $setupBrokerOutput 'VentioSetupBroker.exe'
  if (-not (Test-Path -LiteralPath $setupBrokerExe -PathType Leaf)) { throw 'Windows Host setup broker executable was not published.' }
  Copy-Item -LiteralPath $setupBrokerExe -Destination (Join-Path $tempDirectory 'VentioSetupBroker.exe')
  Remove-Item -LiteralPath $setupBrokerOutput -Recurse -Force

  $runtimePostgresRoot = Join-Path $tempDirectory 'postgresql'
  [void](New-Item -ItemType Directory -Path $runtimePostgresRoot -Force)
  foreach ($runtimeDirectory in @('bin', 'lib', 'share')) {
    $source = Join-Path $postgresRoot $runtimeDirectory
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
      throw "Required PostgreSQL runtime directory is missing: $runtimeDirectory"
    }
    Copy-Item -LiteralPath $source -Destination $runtimePostgresRoot -Recurse
  }
  Get-ChildItem -LiteralPath $postgresRoot -File -Filter '*.txt' |
    Copy-Item -Destination $runtimePostgresRoot
  $payloadRootPrefix = [IO.Path]::GetFullPath($tempDirectory).TrimEnd('\') + '\'
  $stackBuilderExecutable = [IO.Path]::GetFullPath((Join-Path $runtimePostgresRoot 'bin\stackbuilder.exe'))
  if (-not $stackBuilderExecutable.StartsWith($payloadRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'PostgreSQL component exclusion escaped the isolated Host payload directory.'
  }
  if (Test-Path -LiteralPath $stackBuilderExecutable) {
    Remove-Item -LiteralPath $stackBuilderExecutable -Force
  }
  if (Test-Path -LiteralPath $stackBuilderExecutable) {
    throw 'StackBuilder executable remains in the Host payload.'
  }
  Copy-Item -LiteralPath $migrationDirectory -Destination (Join-Path $tempDirectory 'migrations') -Recurse
  Copy-Item -LiteralPath $securityDirectory -Destination (Join-Path $tempDirectory 'security') -Recurse
  $setupDirectory = Join-Path $tempDirectory 'setup'
  [void](New-Item -ItemType Directory -Path $setupDirectory -Force)
  foreach ($scriptName in @(
    'provision-host-installation.ps1', 'provision-postgres-service.ps1',
    'initialize-host-database.ps1', 'register-host-service.ps1',
    'write-host-service-config.ps1', 'HostMigrationCredential.psm1', 'HostProductDataRoot.psm1', 'HostServiceRecoveryPolicy.psm1', 'HostBackupIntegrity.psm1',
    'enable-host-lan-listener.ps1',
    'recover-host-database-credentials.ps1',
    'upgrade-host-database.ps1', 'stop-host-services.ps1',
    'restore-host-upgrade-backup.ps1',
    'remove-host-installation.ps1', 'reactivate-retained-host.ps1'
  )) {
    $scriptPath = Join-Path $windowsScriptDirectory $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
      throw "Required Host setup script is missing: $scriptName"
    }
    Copy-Item -LiteralPath $scriptPath -Destination $setupDirectory
  }

  $payloadFiles = Get-ChildItem -LiteralPath $tempDirectory -File -Recurse
  $migrationRoot = Join-Path $tempDirectory 'migrations'
  $securityRoot = Join-Path $tempDirectory 'security'
  $verifiedFiles = @(
    Get-Item -LiteralPath $hostExe
    Get-Item -LiteralPath $migrationExe
    Get-Item -LiteralPath $identityBootstrapExe
    Get-Item -LiteralPath $trustedPairingExe
    Get-Item -LiteralPath $trustedCredentialReissueExe
    Get-Item -LiteralPath $trustedHostUpgradeExe
    Get-Item -LiteralPath (Join-Path $tempDirectory 'VentioHostService.exe')
    Get-Item -LiteralPath (Join-Path $tempDirectory 'VentioSetupBroker.exe')
    foreach ($name in $requiredPostgres) { Get-Item -LiteralPath (Join-Path $tempDirectory "postgresql\bin\$name") }
    Get-ChildItem -LiteralPath $setupDirectory -File
    $payloadFiles | Where-Object {
      $_.Extension -eq '.sql' -and
      ($_.FullName.StartsWith($migrationRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
       $_.FullName.StartsWith($securityRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))
    }
  ) | Sort-Object FullName -Unique
  $payloadRootPrefix = [IO.Path]::GetFullPath($tempDirectory).TrimEnd('\') + '\'
  $files = $verifiedFiles | ForEach-Object {
    $fullPath = [IO.Path]::GetFullPath($_.FullName)
    if (-not $fullPath.StartsWith($payloadRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'Verified Host payload file escaped its isolated staging directory.'
    }
    [pscustomobject]@{
      path = $fullPath.Substring($payloadRootPrefix.Length).Replace('\', '/')
      length = $_.Length
      sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
  $manifest = [ordered]@{
    formatVersion = 1
    hostExecutable = 'ventio_host.exe'
    migrationExecutable = 'ventio_migrate.exe'
    identityBootstrapExecutable = 'ventio_identity_bootstrap.exe'
    trustedPairingExecutable = 'ventio_trusted_pairing.exe'
    trustedCredentialReissueExecutable = 'ventio_trusted_credential_reissue.exe'
    trustedHostUpgradeExecutable = 'ventio_trusted_host_upgrade.exe'
    serviceExecutable = 'VentioHostService.exe'
    setupBrokerExecutable = 'VentioSetupBroker.exe'
    postgresVersion = '16.15'
    postgresIncludedComponents = @('bin', 'lib', 'share', '*.txt')
    postgresExcludedComponents = @('doc', 'include', 'pgAdmin 4', 'StackBuilder')
    postgresSourceArchiveSha256 = '43bb45f173a6f08cf1d29a97a6d8deb119e8e8093a24c00d2d1001a0ccaa8281'
    postgresSourceArchiveLength = 373254386
    migrationsDirectory = 'migrations'
    securityDirectory = 'security'
    credentialsIncluded = $false
    databaseIncluded = $false
    payloadFileCount = $payloadFiles.Count
    payloadBytes = ($payloadFiles | Measure-Object Length -Sum).Sum
    verifiedFiles = @($files)
  }
  $json = $manifest | ConvertTo-Json -Depth 5
  [IO.File]::WriteAllText((Join-Path $tempDirectory 'payload-manifest.json'), $json, [Text.UTF8Encoding]::new($false))

  Move-Item -LiteralPath $tempDirectory -Destination $OutputDirectory
  Write-Output "Host payload created at $OutputDirectory"
  Write-Output "PostgreSQL tools: $versionOutput"
  Write-Output 'Payload manifest excludes credentials and database files.'
}
finally {
  if (Test-Path -LiteralPath $tempDirectory) {
    $resolvedTemp = [IO.Path]::GetFullPath($tempDirectory)
    $safeParent = [IO.Path]::GetFullPath((Join-Path $hostRoot 'build\windows')).TrimEnd('\') + '\'
    if ($resolvedTemp.StartsWith($safeParent, [StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
