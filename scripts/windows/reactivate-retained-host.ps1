[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidatePattern('^[A-Fa-f0-9]{64}$')] [string] $ExpectedManifestSha256,
  [Parameter(Mandatory)] [ValidatePattern('^[0-9]{1,20}$')] [string] $ExpectedClusterId,
  [switch] $Apply
)

$ErrorActionPreference = 'Stop'
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$payload = Join-Path $programFiles 'Ventio\host-payload'
$root = Join-Path $programData 'Ventio'
$data = Join-Path $root 'PostgreSQL\data'
$hostDirectory = Join-Path $root 'Host'
$sc = Join-Path ([Environment]::SystemDirectory) 'sc.exe'

function Assert-RegularPath([string] $Path) {
  for ($cursor = $Path; $cursor; $cursor = Split-Path -Parent $cursor) {
    $item = Get-Item -LiteralPath $cursor -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'HOST_RETAINED_REPARSE_POINT' }
  }
}

$registered = [Collections.Generic.List[string]]::new()
$lock = $null
$locked = $false
try {
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'HOST_RETAINED_ELEVATION_REQUIRED'
  }
  $lock = [Threading.Mutex]::new($false, 'Global\VentioRetainedHostReactivation')
  try { $locked = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
  if (-not $locked) { throw 'HOST_RETAINED_REACTIVATION_IN_PROGRESS' }
  if (Get-Service -Name VentioHost,VentioPostgres -ErrorAction SilentlyContinue) {
    throw 'HOST_RETAINED_SERVICES_ALREADY_PRESENT'
  }

  $manifestPath = Join-Path $payload 'payload-manifest.json'
  Assert-RegularPath $manifestPath
  if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $ExpectedManifestSha256) {
    throw 'HOST_RETAINED_PAYLOAD_MISMATCH'
  }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if ($manifest.formatVersion -ne 1 -or $manifest.postgresVersion -cne '16.15' -or
      $manifest.credentialsIncluded -ne $false -or $manifest.databaseIncluded -ne $false) {
    throw 'HOST_RETAINED_PAYLOAD_INVALID'
  }
  foreach ($entry in $manifest.verifiedFiles) {
    $file = [IO.Path]::GetFullPath((Join-Path $payload $entry.path))
    if (-not $file.StartsWith($payload + '\', [StringComparison]::OrdinalIgnoreCase)) {
      throw 'HOST_RETAINED_PAYLOAD_INVALID'
    }
    Assert-RegularPath $file
    if ((Get-Item -LiteralPath $file).Length -ne [long]$entry.length -or
        (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.sha256) {
      throw 'HOST_RETAINED_PAYLOAD_MISMATCH'
    }
  }

  foreach ($path in @($data, (Join-Path $data 'PG_VERSION'), (Join-Path $data 'global\pg_control'),
      (Join-Path $hostDirectory 'service-config.dpapi'))) {
    Assert-RegularPath $path
  }
  $rootAcl = Get-Acl -LiteralPath $root
  if (-not $rootAcl.AreAccessRulesProtected -or
      $rootAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-32-544' -or
      @($rootAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
        $_.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544') -and
        ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write)
      }).Count -gt 0) {
    throw 'HOST_RETAINED_DATA_ROOT_UNPROTECTED'
  }
  if ((Get-Content -LiteralPath (Join-Path $data 'PG_VERSION') -Raw).Trim() -cne '16' -or
      (Test-Path -LiteralPath (Join-Path $data 'postmaster.pid'))) {
    throw 'HOST_RETAINED_CLUSTER_INVALID'
  }
  $control = & (Join-Path $payload 'postgresql\bin\pg_controldata.exe') $data | Out-String
  if ($LASTEXITCODE -ne 0 -or $control -notmatch '(?m)^Database cluster state:\s+shut down\s*$' -or
      $control -notmatch "(?m)^Database system identifier:\s+$ExpectedClusterId\s*$") {
    throw 'HOST_RETAINED_CLUSTER_MISMATCH'
  }
  if (-not $Apply) {
    Write-Output 'HOST_RETAINED_REACTIVATION_PLAN_VALID'
    return
  }

  $setup = Join-Path $payload 'setup'
  & (Join-Path $setup 'provision-postgres-service.ps1') -PostgresRoot (Join-Path $payload 'postgresql') -Apply -RegisterRetained
  $registered.Add('VentioPostgres')
  & (Join-Path $setup 'register-host-service.ps1') -PayloadDirectory $payload -ManualStart
  $registered.Insert(0, 'VentioHost')
  Import-Module (Join-Path $setup 'HostProductDataRoot.psm1') -Force
  Protect-HostProductDataRoot
  $listenerResult = @(& (Join-Path $setup 'enable-host-lan-listener.ps1') -PayloadDirectory $payload -RestoreRetainedListener)
  if ('HOST_LAN_RETAINED_CONFIGURATION_READY' -cnotin $listenerResult) {
    throw 'HOST_RETAINED_LISTENER_RESTORE_FAILED'
  }
  Write-Output 'HOST_RETAINED_REACTIVATION_COMPLETE'
} catch {
  foreach ($name in $registered) {
    try {
      $service = Get-Service -Name $name
      Set-Service -Name $name -StartupType Manual
      if ($service.Status -ne 'Stopped') { Stop-Service -Name $name }
      $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
      & $sc delete $name | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'HOST_RETAINED_SERVICE_DELETE_FAILED' }
    } catch {
      [Console]::Error.WriteLine('HOST_RETAINED_SERVICE_ROLLBACK_FAILED')
      break
    }
  }
  $code = $_.Exception.Message
  if ($code -notmatch '^(HOST|POSTGRES)_[A-Z0-9_]{1,96}$') { $code = 'HOST_RETAINED_REACTIVATION_FAILED' }
  throw $code
} finally {
  if ($locked) { $lock.ReleaseMutex() }
  if ($lock) { $lock.Dispose() }
}
