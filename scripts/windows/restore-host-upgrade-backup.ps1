[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $BackupDirectory,
  [switch] $ConfirmRestore,
  [switch] $AllowLegacyInventoryOnly,
  [string] $PostgresRoot = (Join-Path $env:ProgramFiles 'Ventio\host-payload\postgresql')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HostBackupIntegrity.psm1') -Force -ErrorAction Stop
if (-not $ConfirmRestore) { throw 'HOST_UPGRADE_RESTORE_CONFIRMATION_REQUIRED' }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'HOST_UPGRADE_RESTORE_ADMIN_ELEVATION_REQUIRED'
}

$programData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
$backupRoot = [IO.Path]::GetFullPath($BackupDirectory)
$expectedBackupRoot = [IO.Path]::GetFullPath((Join-Path $programData 'Ventio\Backups')).TrimEnd('\') + '\'
if (-not $backupRoot.StartsWith($expectedBackupRoot, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $backupRoot) -notmatch '^ventio-postgresql-before-upgrade-\d{8}T\d{9}Z-[0-9a-f]{32}$') {
  throw 'HOST_UPGRADE_RESTORE_BACKUP_PATH_INVALID'
}
$dataDirectory = [IO.Path]::GetFullPath((Join-Path $programData 'Ventio\PostgreSQL\data'))
$postgresRoot = [IO.Path]::GetFullPath($PostgresRoot)
$postgresBin = Join-Path $postgresRoot 'bin'
$pgCtl = Join-Path $postgresBin 'pg_ctl.exe'
$robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
$serviceName = 'VentioPostgres'
$hostServiceName = 'VentioHost'
foreach ($path in @($pgCtl, $robocopy, (Join-Path $backupRoot 'data\PG_VERSION'), (Join-Path $backupRoot 'backup-manifest.json'))) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'HOST_UPGRADE_RESTORE_BACKUP_INCOMPLETE' }
}
$databaseService = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction Stop
$hostService = Get-CimInstance Win32_Service -Filter "Name='$hostServiceName'" -ErrorAction Stop
if ($databaseService.StartName -cne 'NT SERVICE\VentioPostgres' -or
    $databaseService.PathName -notmatch [regex]::Escape($pgCtl) -or
    $databaseService.PathName -notmatch [regex]::Escape($dataDirectory) -or
    $hostService.StartName -cne 'NT SERVICE\VentioHost' -or
    $hostService.State -ne 'Stopped') {
  throw 'HOST_UPGRADE_RESTORE_SERVICE_PROFILE_INVALID'
}
if (-not (Test-Path -LiteralPath $dataDirectory -PathType Container) -or
    (Get-Item -LiteralPath $dataDirectory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
  throw 'HOST_UPGRADE_RESTORE_DATA_PATH_INVALID'
}

function Get-DataInventory([string] $Path) {
  $stack = [Collections.Generic.Stack[string]]::new()
  $stack.Push([IO.Path]::GetFullPath($Path))
  $files = 0
  [long]$bytes = 0
  while ($stack.Count -gt 0) {
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($stack.Pop())) {
      $item = Get-Item -LiteralPath $entry -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'HOST_UPGRADE_RESTORE_REPARSE_POINT'
      }
      if ($item.PSIsContainer) { $stack.Push($item.FullName) }
      else { $files++; $bytes += [long]$item.Length }
    }
  }
  return [pscustomobject]@{ fileCount = $files; bytes = $bytes }
}

function Set-PostgresDataAcl([string] $Path, [string[]] $ServiceSids) {
  $security = [Security.AccessControl.DirectorySecurity]::new()
  $security.SetAccessRuleProtection($true, $false)
  $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
  foreach ($sid in @('S-1-5-32-544', 'S-1-5-18') + $ServiceSids) {
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      [Security.Principal.SecurityIdentifier]::new($sid),
      [Security.AccessControl.FileSystemRights]::FullControl,
      [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit,
      [Security.AccessControl.PropagationFlags]::None,
      [Security.AccessControl.AccessControlType]::Allow))
  }
  Set-Acl -LiteralPath $Path -AclObject $security
}

function Copy-Data([string] $Source, [string] $Destination) {
  $process = [Diagnostics.Process]::new()
  try {
    $info = [Diagnostics.ProcessStartInfo]::new($robocopy)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $arguments = @($Source, $Destination, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:2', '/XJ', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    $quoted = foreach ($argument in $arguments) {
      $escaped = [regex]::Replace([string]$argument, '(\\*)"', '$1$1\"')
      $trailingSlashes = [regex]::Match($escaped, '\\+$').Length
      if ($trailingSlashes -gt 0) {
        $escaped = $escaped.Substring(0, $escaped.Length - $trailingSlashes) + ('\' * ($trailingSlashes * 2))
      }
      '"' + $escaped + '"'
    }
    $info.Arguments = [string]::Join(' ', [string[]]$quoted)
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'HOST_UPGRADE_RESTORE_COPY_FAILED' }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(1800000)) {
      try { $process.Kill() } catch { }
      throw 'HOST_UPGRADE_RESTORE_COPY_TIMEOUT'
    }
    $null = $stdout.GetAwaiter().GetResult()
    $null = $stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ge 8) { throw 'HOST_UPGRADE_RESTORE_COPY_FAILED' }
  } finally { $process.Dispose() }
}

if (((Get-Item -LiteralPath (Join-Path $backupRoot 'backup-manifest.json') -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'HOST_UPGRADE_RESTORE_REPARSE_POINT' }
$manifest = Get-Content -LiteralPath (Join-Path $backupRoot 'backup-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.formatVersion -notin @(1, 2) -or $manifest.postgresVersion -ne '16.15' -or
    $manifest.dataDirectory -cne 'data' -or
    (Get-Content -LiteralPath (Join-Path $backupRoot 'data\PG_VERSION') -Raw).Trim() -cne '16') {
  throw 'HOST_UPGRADE_RESTORE_BACKUP_MANIFEST_INVALID'
}
$backupInventory = Get-DataInventory (Join-Path $backupRoot 'data')
if ($backupInventory.fileCount -ne [long]$manifest.fileCount -or
    $backupInventory.bytes -ne [long]$manifest.bytes) {
  throw 'HOST_UPGRADE_RESTORE_BACKUP_VERIFICATION_FAILED'
}

if ($manifest.formatVersion -eq 1 -and -not $AllowLegacyInventoryOnly) {
  throw 'HOST_UPGRADE_RESTORE_LEGACY_INTEGRITY_OPT_IN_REQUIRED'
}
if ($manifest.formatVersion -eq 2) {
  if ($manifest.integrityAlgorithm -cne 'SHA-256' -or $manifest.recoveryAuthorityIncluded -ne $false) {
    throw 'HOST_UPGRADE_RESTORE_INTEGRITY_PROFILE_INVALID'
  }
  # Hashes detect content damage; private manifest ownership provides trust.
  # Never treat an uploaded or broadly writable manifest as restore authority.
  $manifestAcl = Get-Acl -LiteralPath (Join-Path $backupRoot 'backup-manifest.json')
  $allowedSids = @('S-1-5-32-544', 'S-1-5-18')
  if (-not $manifestAcl.AreAccessRulesProtected -or
      $manifestAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-32-544') {
    throw 'HOST_UPGRADE_RESTORE_MANIFEST_TRUST_INVALID'
  }
  foreach ($rule in $manifestAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
    if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
        $allowedSids -notcontains $rule.IdentityReference.Value) { throw 'HOST_UPGRADE_RESTORE_MANIFEST_TRUST_INVALID' }
  }
  Assert-HostBackupIntegrity (Join-Path $backupRoot 'data') @($manifest.files)
}

$serviceSid = ([Security.Principal.NTAccount]::new('NT SERVICE', $serviceName)).Translate(
  [Security.Principal.SecurityIdentifier]).Value
if ($databaseService.State -eq 'Running') {
  Stop-Service -Name $serviceName -Force -ErrorAction Stop
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  while ((Get-Service -Name $serviceName).Status -ne 'Stopped') {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_UPGRADE_RESTORE_POSTGRES_STOP_TIMEOUT' }
    Start-Sleep -Milliseconds 500
  }
}

$backupDirectory = Join-Path $programData 'Ventio\Backups'
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture)
$preservedCurrent = Join-Path $backupDirectory "ventio-postgresql-before-recovery-$stamp-$([guid]::NewGuid().ToString('N'))"
$restoreTemp = Join-Path (Split-Path -Parent $dataDirectory) ('.data-restore-' + [guid]::NewGuid().ToString('N'))
$quarantine = Join-Path (Split-Path -Parent $dataDirectory) ('data.failed-upgrade-' + [guid]::NewGuid().ToString('N'))
$restored = $false
try {
  [void][IO.Directory]::CreateDirectory($preservedCurrent)
  Set-PostgresDataAcl $preservedCurrent @()
  Copy-Data $dataDirectory (Join-Path $preservedCurrent 'data')
  $currentInventory = Get-DataInventory (Join-Path $preservedCurrent 'data')
  $sourceInventory = Get-DataInventory $dataDirectory
  if ($currentInventory.fileCount -ne $sourceInventory.fileCount -or
      $currentInventory.bytes -ne $sourceInventory.bytes) { throw 'HOST_UPGRADE_RESTORE_CURRENT_BACKUP_FAILED' }
  $preservedManifest = [ordered]@{
    formatVersion = 1
    createdAtUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    postgresVersion = '16.15'
    dataDirectory = 'data'
    fileCount = $currentInventory.fileCount
    bytes = $currentInventory.bytes
  }
  $manifestPath = Join-Path $preservedCurrent 'backup-manifest.json'
  [IO.File]::WriteAllText($manifestPath, ($preservedManifest | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))

  [void][IO.Directory]::CreateDirectory($restoreTemp)
  Set-PostgresDataAcl $restoreTemp @($serviceSid)
  Copy-Data (Join-Path $backupRoot 'data') $restoreTemp
  $restoredInventory = Get-DataInventory $restoreTemp
  if ($restoredInventory.fileCount -ne $backupInventory.fileCount -or
      $restoredInventory.bytes -ne $backupInventory.bytes) { throw 'HOST_UPGRADE_RESTORE_COPY_VERIFICATION_FAILED' }
  if ($manifest.formatVersion -eq 2) { Assert-HostBackupIntegrity $restoreTemp @($manifest.files) }
  Set-PostgresDataAcl $restoreTemp @($serviceSid)

  [IO.Directory]::Move($dataDirectory, $quarantine)
  try {
    [IO.Directory]::Move($restoreTemp, $dataDirectory)
    $restored = $true
  } catch {
    [IO.Directory]::Move($quarantine, $dataDirectory)
    throw
  }
  Start-Service -Name $serviceName -ErrorAction Stop
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  while ((Get-Service -Name $serviceName).Status -ne 'Running') {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'HOST_UPGRADE_RESTORE_POSTGRES_START_TIMEOUT' }
    Start-Sleep -Milliseconds 500
  }
  Write-Output 'HOST_UPGRADE_VERIFIED_PREVIOUS_CLUSTER_RESTORED'
  Write-Output ('Preserved failed-upgrade cluster backup: ' + $preservedCurrent)
  Write-Output ('Preserved original data directory: ' + $quarantine)
  Write-Output 'VentioHost remains stopped. Retry the versioned Ventio Setup installer to perform the Recovery Authority-coordinated upgrade.'
} catch {
  if (-not $restored -and (Test-Path -LiteralPath $restoreTemp)) {
    Remove-Item -LiteralPath $restoreTemp -Recurse -Force -ErrorAction SilentlyContinue
  }
  throw
}
