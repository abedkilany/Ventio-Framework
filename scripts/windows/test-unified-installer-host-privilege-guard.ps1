param(
  [Parameter(Mandatory = $true)] [string] $InstallerPath
)
$ErrorActionPreference = 'Stop'

$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$rootName = 'VentioHostPerUserGuard-' + [guid]::NewGuid().ToString('N')
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) $rootName))
$installDir = Join-Path $root 'app'
$log = Join-Path $root 'setup.log'
if (-not $root.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $root) -ne $rootName) {
  throw 'Installer privilege guard fixture escaped the temporary directory.'
}

$beforeServices = @(Get-CimInstance -ClassName Win32_Service |
  Where-Object { $_.Name -in @('VentioHost', 'VentioPostgres') } |
  Select-Object Name, State, StartMode, PathName | Sort-Object Name | ConvertTo-Json -Compress)
[void][IO.Directory]::CreateDirectory($root)
$process = [Diagnostics.Process]::new()
$process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
$process.StartInfo.FileName = $installer
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = $true
$process.StartInfo.Arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /TYPE=host /CURRENTUSER ' +
  ('/DIR="' + $installDir + '" ') + ('/LOG="' + $log + '"')
try {
  if (-not $process.Start()) { throw 'HOST_PER_USER_GUARD_PROCESS_START_FAILED' }
  if (-not $process.WaitForExit(30000)) {
    $process.Kill()
    $process.WaitForExit()
    throw 'HOST_PER_USER_GUARD_TIMEOUT'
  }
  if ($process.ExitCode -eq 0) { throw 'HOST_PER_USER_INSTALL_UNEXPECTEDLY_SUCCEEDED' }
  if (Test-Path -LiteralPath $installDir) { throw 'HOST_PER_USER_GUARD_CREATED_INSTALL_DIRECTORY' }
  if (-not (Test-Path -LiteralPath $log -PathType Leaf) -or
      -not (Select-String -LiteralPath $log -SimpleMatch 'HOST_INSTALL_REQUIRES_ADMIN_MODE' -Quiet)) {
    throw 'HOST_PER_USER_GUARD_LOG_MARKER_MISSING'
  }
  $afterServices = @(Get-CimInstance -ClassName Win32_Service |
    Where-Object { $_.Name -in @('VentioHost', 'VentioPostgres') } |
    Select-Object Name, State, StartMode, PathName | Sort-Object Name | ConvertTo-Json -Compress)
  if (($beforeServices -join '') -ne ($afterServices -join '')) {
    throw 'HOST_PER_USER_GUARD_CHANGED_SERVICE_STATE'
  }
  Write-Output 'UNIFIED_INSTALLER_HOST_PER_USER_REJECTED_PASS'
}
finally {
  if ($process -and -not $process.HasExited) {
    $process.Kill()
    $process.WaitForExit()
  }
  $process.Dispose()
  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
  $resolvedRoot = [IO.Path]::GetFullPath($root)
  if ($resolvedRoot.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $resolvedRoot) -eq $rootName -and
      (Test-Path -LiteralPath $resolvedRoot)) {
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
  }
}
