$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
Import-Module (Join-Path $PSScriptRoot 'vc-runtime-prerequisite.psm1') -Force

function Assert-True([bool]$Condition, [string]$Code) {
  if (-not $Condition) { throw $Code }
}

$minimum = '14.50.35719.0'
Assert-True (Test-VentioVcRuntimeSufficient 'v14.50.35719.0' $minimum) 'VC_RUNTIME_EQUAL_VERSION_NOT_ACCEPTED'
Assert-True (Test-VentioVcRuntimeSufficient '14.51.36247.0' $minimum) 'VC_RUNTIME_NEWER_VERSION_NOT_ACCEPTED'
Assert-True (-not (Test-VentioVcRuntimeSufficient '14.50.35718.0' $minimum)) 'VC_RUNTIME_OLDER_VERSION_ACCEPTED'
Assert-True (-not (Test-VentioVcRuntimeSufficient $null $minimum)) 'VC_RUNTIME_MISSING_VERSION_ACCEPTED'
Assert-True ($null -eq (ConvertTo-VentioVcRuntimeVersion 'invalid')) 'VC_RUNTIME_MALFORMED_VERSION_ACCEPTED'

$fixture = New-TemporaryFile
try {
  $state = [pscustomobject]@{ Version = '14.50.35719.0'; InstallerCalled = $false; Arguments = ''; RegistryReads = 0 }
  $getVersion = { return $state.Version }.GetNewClosure()
  $runInstaller = { param($Path, $Arguments) $state.InstallerCalled = $true; $state.Arguments = $Arguments; return 0 }.GetNewClosure()
  $result = Invoke-VentioVcRuntimePrerequisite -RuntimeInstallerPath $fixture.FullName -MinimumVersion $minimum -GetInstalledVersion $getVersion -InstallPackage $runInstaller
  Assert-True ($result.Status -eq 'AlreadySatisfied' -and -not $state.InstallerCalled) 'VC_RUNTIME_PRESENT_MUST_SKIP_INSTALL'

  $state.Version = $null
  $runInstaller = {
    param($Path, $Arguments)
    $state.InstallerCalled = $true
    $state.Arguments = $Arguments
    $state.Version = '14.50.35719.0'
    return 0
  }.GetNewClosure()
  $result = Invoke-VentioVcRuntimePrerequisite -RuntimeInstallerPath $fixture.FullName -MinimumVersion $minimum -GetInstalledVersion $getVersion -InstallPackage $runInstaller
  Assert-True ($result.Status -eq 'Installed' -and $result.ExitCode -eq 0) 'VC_RUNTIME_MISSING_MUST_INSTALL'
  Assert-True ($state.Arguments -match '/install' -and $state.Arguments -match '/quiet' -and $state.Arguments -match '/norestart') 'VC_RUNTIME_INSTALL_ARGUMENTS_UNSAFE'

  $state.Version = '14.51.36247.0'
  $state.InstallerCalled = $false
  $result = Invoke-VentioVcRuntimePrerequisite -RuntimeInstallerPath $fixture.FullName -MinimumVersion $minimum -GetInstalledVersion $getVersion -InstallPackage $runInstaller
  Assert-True ($result.Status -eq 'AlreadySatisfied' -and -not $state.InstallerCalled) 'VC_RUNTIME_NEWER_VERSION_MUST_NOT_BE_DOWNGRADED'

  $state.Version = $null
  $state.RegistryReads = 0
  $runInstaller = { param($Path, $Arguments) return 1638 }.GetNewClosure()
  $getNewerVersion = {
    $state.RegistryReads++
    if ($state.RegistryReads -eq 1) { return $null }
    return '14.51.36247.0'
  }.GetNewClosure()
  $result = Invoke-VentioVcRuntimePrerequisite -RuntimeInstallerPath $fixture.FullName -MinimumVersion $minimum -GetInstalledVersion $getNewerVersion -InstallPackage $runInstaller
  Assert-True ($result.Status -eq 'NewerRuntimeAlreadyPresent' -and $result.ExitCode -eq 0) 'VC_RUNTIME_NEWER_PACKAGE_RESULT_NOT_ACCEPTED'

  foreach ($exitCode in @(3010, 1641)) {
    $runRebootInstaller = { param($Path, $Arguments) return $exitCode }.GetNewClosure()
    $result = Invoke-VentioVcRuntimePrerequisite -RuntimeInstallerPath $fixture.FullName -MinimumVersion $minimum -GetInstalledVersion { return $null } -InstallPackage $runRebootInstaller
    Assert-True ($result.Status -eq 'RestartRequired' -and $result.ExitCode -eq 3010) 'VC_RUNTIME_REBOOT_REQUIRED_NOT_PROPAGATED'
  }

  $runFailedInstaller = { param($Path, $Arguments) return 1603 }
  $result = Invoke-VentioVcRuntimePrerequisite -RuntimeInstallerPath $fixture.FullName -MinimumVersion $minimum -GetInstalledVersion { return $null } -InstallPackage $runFailedInstaller
  Assert-True ($result.Status -eq 'RuntimeInstallFailed' -and $result.ExitCode -ne 0) 'VC_RUNTIME_INSTALL_FAILURE_NOT_BLOCKED'

  $missingPath = Join-Path $fixture.DirectoryName 'missing-vc-redist.exe'
  $result = Invoke-VentioVcRuntimePrerequisite -RuntimeInstallerPath $missingPath -MinimumVersion $minimum -GetInstalledVersion { return $null } -InstallPackage $runFailedInstaller
  Assert-True ($result.Status -eq 'RuntimePackageMissing' -and $result.ExitCode -ne 0) 'VC_RUNTIME_MISSING_PACKAGE_NOT_BLOCKED'
}
finally {
  Remove-Item -LiteralPath $fixture.FullName -Force -ErrorAction SilentlyContinue
}

Write-Output 'PASS: Visual C++ runtime version detection, skip/install decision, no-downgrade, install arguments, failure blocking, and reboot-required handling.'
