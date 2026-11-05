Set-StrictMode -Version Latest

function ConvertTo-VentioVcRuntimeVersion {
  [CmdletBinding()]
  param([AllowNull()][object] $Value)

  if ($null -eq $Value) { return $null }
  $text = ([string]$Value).Trim()
  if ($text.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
    $text = $text.Substring(1)
  }

  $parsed = $null
  if ([version]::TryParse($text, [ref]$parsed)) {
    if ($parsed.Build -lt 0) { return [version]::new($parsed.Major, $parsed.Minor, 0, 0) }
    if ($parsed.Revision -lt 0) { return [version]::new($parsed.Major, $parsed.Minor, $parsed.Build, 0) }
    return $parsed
  }
  return $null
}

function Get-VentioInstalledVcRuntimeVersion {
  [CmdletBinding()]
  param()

  $subKeyPath = 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
  $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::LocalMachine,
    [Microsoft.Win32.RegistryView]::Registry64)
  try {
    $runtimeKey = $baseKey.OpenSubKey($subKeyPath, $false)
    if ($null -eq $runtimeKey) { return $null }
    try {
      if ([int]$runtimeKey.GetValue('Installed', 0) -ne 1) { return $null }

      $version = ConvertTo-VentioVcRuntimeVersion $runtimeKey.GetValue('Version', $null)
      if ($null -ne $version) { return $version }

      $major = $runtimeKey.GetValue('Major', $null)
      $minor = $runtimeKey.GetValue('Minor', $null)
      $build = $runtimeKey.GetValue('Bld', $null)
      $revision = $runtimeKey.GetValue('Rbld', $null)
      if ($null -eq $major -or $null -eq $minor -or $null -eq $build -or $null -eq $revision) {
        return $null
      }
      return [version]::new([int]$major, [int]$minor, [int]$build, [int]$revision)
    }
    finally {
      $runtimeKey.Dispose()
    }
  }
  finally {
    $baseKey.Dispose()
  }
}

function Test-VentioVcRuntimeSufficient {
  [CmdletBinding()]
  param(
    [AllowNull()][object] $InstalledVersion,
    [Parameter(Mandatory)][string] $MinimumVersion
  )

  $minimum = ConvertTo-VentioVcRuntimeVersion $MinimumVersion
  $installed = ConvertTo-VentioVcRuntimeVersion $InstalledVersion
  return ($null -ne $minimum -and $null -ne $installed -and $installed -ge $minimum)
}

function Invoke-VentioVcRuntimePrerequisite {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $RuntimeInstallerPath,
    [Parameter(Mandatory)][string] $MinimumVersion,
    [scriptblock] $GetInstalledVersion = { Get-VentioInstalledVcRuntimeVersion },
    [scriptblock] $InstallPackage = {
      param([string] $Path, [string] $Arguments)
      $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
      return [int]$process.ExitCode
    }
  )

  $minimum = ConvertTo-VentioVcRuntimeVersion $MinimumVersion
  if ($null -eq $minimum) {
    return [pscustomobject]@{ Status = 'InvalidMinimumVersion'; ExitCode = 1; InstalledVersion = $null }
  }

  try {
    $current = & $GetInstalledVersion
  }
  catch {
    return [pscustomobject]@{ Status = 'RuntimeDetectionFailed'; ExitCode = 1; InstalledVersion = $null }
  }
  if (Test-VentioVcRuntimeSufficient -InstalledVersion $current -MinimumVersion $minimum.ToString()) {
    return [pscustomobject]@{ Status = 'AlreadySatisfied'; ExitCode = 0; InstalledVersion = $current }
  }
  if (-not (Test-Path -LiteralPath $RuntimeInstallerPath -PathType Leaf)) {
    return [pscustomobject]@{ Status = 'RuntimePackageMissing'; ExitCode = 1; InstalledVersion = $current }
  }

  try {
    $installerExitCode = [int](& $InstallPackage $RuntimeInstallerPath '/install /quiet /norestart')
    $installedAfter = & $GetInstalledVersion
  }
  catch {
    return [pscustomobject]@{ Status = 'RuntimeInstallFailed'; ExitCode = 1; InstalledVersion = $current }
  }

  if ($installerExitCode -in 3010, 1641) {
    return [pscustomobject]@{ Status = 'RestartRequired'; ExitCode = 3010; InstalledVersion = $installedAfter }
  }
  if ($installerExitCode -in 0, 1638 -and
      (Test-VentioVcRuntimeSufficient -InstalledVersion $installedAfter -MinimumVersion $minimum.ToString())) {
    $status = if ($installerExitCode -eq 1638) { 'NewerRuntimeAlreadyPresent' } else { 'Installed' }
    return [pscustomobject]@{ Status = $status; ExitCode = 0; InstalledVersion = $installedAfter }
  }

  return [pscustomobject]@{ Status = 'RuntimeInstallFailed'; ExitCode = 1; InstalledVersion = $installedAfter }
}

Export-ModuleMember -Function @(
  'ConvertTo-VentioVcRuntimeVersion',
  'Get-VentioInstalledVcRuntimeVersion',
  'Test-VentioVcRuntimeSufficient',
  'Invoke-VentioVcRuntimePrerequisite'
)
