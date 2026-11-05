[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $RuntimeInstallerPath,
  [Parameter(Mandatory)][string] $MinimumVersion
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'vc-runtime-prerequisite.psm1') -Force

try {
  $result = Invoke-VentioVcRuntimePrerequisite `
    -RuntimeInstallerPath $RuntimeInstallerPath `
    -MinimumVersion $MinimumVersion
  if ($result.ExitCode -eq 3010) {
    [Console]::Error.WriteLine('VENTIO_VC_RUNTIME_REBOOT_REQUIRED')
    exit 3010
  }
  if ($result.ExitCode -ne 0) {
    [Console]::Error.WriteLine('VENTIO_VC_RUNTIME_PREREQUISITE_FAILED')
    exit 1
  }
  exit 0
}
catch {
  [Console]::Error.WriteLine('VENTIO_VC_RUNTIME_PREREQUISITE_FAILED')
  exit 1
}
