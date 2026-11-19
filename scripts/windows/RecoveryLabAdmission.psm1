Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Assert-RecoveryLabIdentity {
  [CmdletBinding()]param([Parameter(Mandatory)]$Record,[Parameter(Mandatory)]$Observation)
  # Pure validation also used by hosted tests. It never creates an admission marker.
  if($Record.schemaVersion -ne 1 -or $Record.fixtureOnly -ne $true -or $Record.ownerApproved -ne $true){throw 'RECOVERY_ADMISSION_NOT_APPROVED'}
  if($Record.guest.machineGuid -cne '5cb98737-7141-4486-9a87-08484566e292' -or $Record.guest.smbiosUuid -ine 'BBFBFFD7-D087-4E7C-9D65-D7884CAE0420' -or $Record.guest.adapterMac -cne '00155D016805'){throw 'RECOVERY_APPROVED_GUEST_CHANGED'}
  $denied=@('BAHAA','TEST-01','TEST-02','VENTIO-TEST-01','VENTIO-TEST-02')
  if($Observation.machineName -in $denied -or $Observation.machineGuid -eq '206b0dfe-e035-49c5-8b38-3d1d19ceadf7'){throw 'RECOVERY_PRESERVED_MACHINE'}
  if($Record.guest.machineName -cnotmatch '^VENTIO-W2-VM[0-9]{2}$' -or $Observation.machineName -cne $Record.guest.machineName){throw 'RECOVERY_GUEST_NAME_MISMATCH'}
  foreach($field in @('machineGuid','smbiosUuid')){
    $expected=[guid]::Empty;$actual=[guid]::Empty
    if(-not [guid]::TryParse([string]$Record.guest.$field,[ref]$expected) -or $expected -eq [guid]::Empty -or
       -not [guid]::TryParse([string]$Observation.$field,[ref]$actual) -or $actual -ne $expected){throw 'RECOVERY_GUEST_IDENTITY_MISMATCH'}
  }
  if($Observation.manufacturer -cne 'Microsoft Corporation' -or $Observation.model -cne 'Virtual Machine'){throw 'RECOVERY_VIRTUAL_HARDWARE_REQUIRED'}
  $mac=([string]$Record.guest.adapterMac).Replace('-','').Replace(':','').ToUpperInvariant()
  if($mac -cnotmatch '^[0-9A-F]{12}$' -or @($Observation.adapterMacs | Where-Object {$_ -ceq $mac}).Count -ne 1 -or @($Observation.adapterMacs).Count -ne 1){throw 'RECOVERY_ADAPTER_MISMATCH'}
  if($Record.management.machineName -cne 'BAHAA' -or $Record.management.disposable -ne $false -or
     $Record.management.machineGuid -cne '206b0dfe-e035-49c5-8b38-3d1d19ceadf7' -or
     $Record.management.vmId -cne '99aba626-2cc9-486e-86ab-af7966848126' -or
     $Record.ssh.ed25519Fingerprint -cne 'SHA256:2apYDxmYxd9YL51EUuqWJRKYAF6grFa/pE1wbds7b0I'){throw 'RECOVERY_MANAGEMENT_BINDING_MISMATCH'}
  # These are pinned independent approval inputs, not guest assertions of effective isolation.
  foreach($field in @('networkPlanSha256','networkEvidenceSha256','signingEvidenceSha256')){
    if([string]$Record.$field -cnotmatch '^[0-9a-f]{64}$' -or [string]$Record.$field -eq ('0'*64)){throw 'RECOVERY_APPROVAL_EVIDENCE_MISSING'}
  }
  if([string]$Record.publisherThumbprint -cnotmatch '^[0-9A-F]{40}$'){throw 'RECOVERY_PUBLISHER_PIN_MISSING'}
}
function Read-RecoveryLabAdmission {
  [CmdletBinding()]param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedSha256)
  $item=Get-Item -LiteralPath $Path -ErrorAction Stop
  if($item.Length -gt 65536 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'RECOVERY_ADMISSION_FILE_INVALID'}
  if((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedSha256){throw 'RECOVERY_ADMISSION_DIGEST_MISMATCH'}
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Assert-CurrentRecoveryLabAdmission {
  [CmdletBinding()]param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedSha256)
  $record=Read-RecoveryLabAdmission -Path $Path -ExpectedSha256 $ExpectedSha256
  $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'RECOVERY_NORMAL_ELEVATION_REQUIRED'}
  $computer=Get-CimInstance Win32_ComputerSystem
  $observation=@{machineName=$env:COMPUTERNAME;machineGuid=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid;smbiosUuid=(Get-CimInstance Win32_ComputerSystemProduct).UUID;manufacturer=$computer.Manufacturer;model=$computer.Model;adapterMacs=@(Get-NetAdapter -Physical | ForEach-Object {$_.MacAddress.Replace('-','').ToUpperInvariant()})}
  Assert-RecoveryLabIdentity -Record $record -Observation $observation
  if((Get-ExecutionPolicy) -ne 'AllSigned'){throw 'RECOVERY_ALLSIGNED_REQUIRED'}
  return $record
}
Export-ModuleMember -Function Assert-RecoveryLabIdentity,Read-RecoveryLabAdmission,Assert-CurrentRecoveryLabAdmission
