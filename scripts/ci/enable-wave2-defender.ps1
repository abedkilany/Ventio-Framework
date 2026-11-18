$ErrorActionPreference = 'Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:COMPUTERNAME -in 'BAHAA','TEST-01','TEST-02'){throw 'Disposable GitHub-hosted Windows only'}
$evidence=[ordered]@{protectionDisabledByThisScript=$false;exclusionsAdded=@();removedHostedImageExclusions=@();utc=[datetime]::UtcNow.ToString('o')}
try {
  $evidence.before=Get-MpComputerStatus | Select-Object AMRunningMode,AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,BehaviorMonitorEnabled,IoavProtectionEnabled,IsTamperProtected,AntivirusSignatureVersion
  $prefs=Get-MpPreference
  $evidence.exclusionsBefore=$prefs | Select-Object ExclusionPath,ExclusionExtension,ExclusionProcess,DisableArchiveScanning
  Set-MpPreference -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false -DisableIOAVProtection $false -DisableArchiveScanning $false -ErrorAction Stop
  foreach($path in @($prefs.ExclusionPath)) {
    if($path -notin @('C:\','D:\')){throw 'Unexpected exclusion on hosted image requires independent review'}
    # Remove only these documented image-wide exclusions. Never add/re-add any.
    Remove-MpPreference -ExclusionPath $path -ErrorAction Stop
    $evidence.removedHostedImageExclusions += $path
  }
  Update-MpSignature -ErrorAction Stop
  for($attempt=0;$attempt -lt 30;$attempt++) {
    $status=Get-MpComputerStatus
    if($status.RealTimeProtectionEnabled -and $status.BehaviorMonitorEnabled -and $status.IoavProtectionEnabled){break}
    Start-Sleep -Seconds 1
  }
  $prefs=Get-MpPreference
  $evidence.after=$status | Select-Object AMRunningMode,AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,BehaviorMonitorEnabled,IoavProtectionEnabled,IsTamperProtected,AntivirusSignatureVersion,DefenderSignaturesOutOfDate
  $evidence.exclusionsAfter=$prefs | Select-Object ExclusionPath,ExclusionExtension,ExclusionProcess,DisableArchiveScanning
  if(-not($status.RealTimeProtectionEnabled -and $status.BehaviorMonitorEnabled -and $status.IoavProtectionEnabled -and $status.AntivirusEnabled -and $status.AMServiceEnabled) -or $status.AMRunningMode -ne 'Normal' -or $status.DefenderSignaturesOutOfDate -or $prefs.DisableArchiveScanning -or $prefs.ExclusionPath -or $prefs.ExclusionExtension -or $prefs.ExclusionProcess){throw 'Effective enabled protection without exclusions could not be established'}
  $evidence.status='ENABLED_WITHOUT_EXCLUSIONS'
} catch { $evidence.status='BLOCKED';$evidence.reason=$_.Exception.Message }
$evidence | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $env:RUNNER_TEMP 'wave2-defender-enablement.json')
$evidence | ConvertTo-Json -Depth 7
if($evidence.status -ne 'ENABLED_WITHOUT_EXCLUSIONS'){throw 'Normal Defender policy APIs did not establish the required protections; no bypass attempted'}
