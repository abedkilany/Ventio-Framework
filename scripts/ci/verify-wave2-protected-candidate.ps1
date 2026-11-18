$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:COMPUTERNAME -in 'BAHAA','TEST-01','TEST-02') { throw 'Disposable hosted verification required' }
$context = Get-Content -LiteralPath $env:VENTIO_VERIFY_CONTEXT -Raw | ConvertFrom-Json
$out = Split-Path -Parent $env:VENTIO_VERIFY_CONTEXT
$report = [ordered]@{identity=$context.identity;candidateCommit=$context.candidateCommit;verificationCommit=$env:GITHUB_SHA;securityStatus='BLOCKED';installerSmoke='UNEXECUTED';noExclusionsAdded=$true;protectionNeverDisabled=$true;physicalMachinesTouched=$false}
try {
  $report.protectionBefore = Get-MpComputerStatus | Select-Object AMRunningMode,AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,BehaviorMonitorEnabled,IoavProtectionEnabled,IsTamperProtected,AntivirusSignatureVersion,DefenderSignaturesOutOfDate
  # Strengthen only this disposable runner through normal Defender APIs. Never
  # override a denying policy, alter exclusions, disable or restore anything.
  ./scripts/ci/enable-wave2-defender.ps1
  Copy-Item -LiteralPath (Join-Path $env:RUNNER_TEMP 'wave2-defender-enablement.json') -Destination $out
  for($attempt=0;$attempt -lt 30;$attempt++) {
    $protected = Get-MpComputerStatus
    if($protected.RealTimeProtectionEnabled -and $protected.BehaviorMonitorEnabled -and $protected.IoavProtectionEnabled){break}
    Start-Sleep -Seconds 1
  }
  $report.protectionForScan = $protected | Select-Object AMRunningMode,AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,BehaviorMonitorEnabled,IoavProtectionEnabled,IsTamperProtected,AntivirusSignatureVersion,DefenderSignaturesOutOfDate
  if (-not ($protected.RealTimeProtectionEnabled -and $protected.BehaviorMonitorEnabled -and $protected.IoavProtectionEnabled -and $protected.AntivirusEnabled -and $protected.AMServiceEnabled) -or $protected.AMRunningMode -ne 'Normal' -or $protected.DefenderSignaturesOutOfDate) { throw 'Effective protection cannot be established through normal APIs' }
  $prefs = Get-MpPreference
  $report.exclusions = $prefs | Select-Object ExclusionPath,ExclusionExtension,ExclusionProcess,DisableArchiveScanning
  if ($prefs.DisableArchiveScanning) { throw 'Archive scanning is disabled by the image; policy is left unchanged' }
  $mp = Join-Path $env:ProgramData 'Microsoft/Windows Defender/Platform/CurrentVersion/MpCmdRun.exe'
  $sig = Get-AuthenticodeSignature $mp
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike '*Microsoft*') { throw 'Defender CLI signature not verified' }
  $report.exclusionChecks = @()
  foreach($path in @($context.zip,$context.payload)) {
    $text = & $mp -CheckExclusion -Path $path 2>&1 | Out-String
    $code = $LASTEXITCODE
    $report.exclusionChecks += [pscustomobject]@{path=$path;exitCode=$code;output=$text.Trim()}
    if ($code -ne 1) { throw 'A scan target is excluded or exclusion visibility is unavailable' }
  }
  $files = @(Get-ChildItem -LiteralPath $context.payload -Recurse -File)
  foreach($file in $files) {
    foreach($pattern in @($prefs.ExclusionPath)) {
      if ($pattern -and $file.FullName -like [Environment]::ExpandEnvironmentVariables($pattern)) { throw 'A package member matches an existing exclusion' }
    }
    foreach($extension in @($prefs.ExclusionExtension)) {
      if ($extension -and ($file.Extension.TrimStart('.') -like ([string]$extension).TrimStart('.'))) { throw 'A package member extension is excluded' }
    }
  }
  $before = (Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -MaxEvents 1).RecordId
  foreach($path in @($context.zip,$context.payload)) { Start-MpScan -ScanType CustomScan -ScanPath $path -ErrorAction Stop }
  $finished = $false
  for($attempt=0;$attempt -lt 30;$attempt++) {
    $events = @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Defender/Operational';Id=1000,1001,1002,1116,1117,1118,1119} | Where-Object {$_.RecordId -gt $before})
    $pairs = @(foreach($event in $events) {
      $xml=[xml]$event.ToXml();$fields=@{}
      foreach($data in $xml.Event.EventData.Data){$fields[$data.Name]=$data.'#text'}
      [pscustomobject]@{id=$event.Id;recordId=$event.RecordId;scanId=$fields['Scan ID'];resource=$fields['Scan Resources'];message=$event.Message;utc=$event.TimeCreated.ToUniversalTime().ToString('o')}
    })
    $starts = @($pairs | Where-Object {$_.id -eq 1000 -and ($_.resource -like "*$($context.zip)*" -or $_.resource -like "*$($context.payload)*")})
    if ($starts.Count -eq 2 -and @($starts | Where-Object {$sid=$_.scanId;@($pairs | Where-Object {$_.id -eq 1001 -and $_.scanId -eq $sid}).Count -eq 1}).Count -eq 2) {$finished=$true;break}
    Start-Sleep -Seconds 1
  }
  $report.scanEvents = $pairs
  $report.threats = @(Get-MpThreat | Select-Object ThreatID,ThreatName,IsActive,DidThreatExecute)
  $report.detections = @(Get-MpThreatDetection | Select-Object ThreatID,InitialDetectionTime,ActionSuccess,Resources)
  if (-not $finished -or @($pairs | Where-Object {$_.id -in 1116,1117,1118,1119}).Count -or @($report.threats | Where-Object IsActive).Count) { throw 'Scan completion or threat evidence blocks execution' }
  $expected = (Get-Content -LiteralPath ($context.zip+'.sha256') -Raw).Split(' ')[0]
  if ((Get-FileHash -LiteralPath $context.zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected) { throw 'ZIP changed after scanning' }
  foreach($line in Get-Content -LiteralPath (Join-Path $context.payload 'SHA256SUMS.txt')) {
    $parts=$line -split '  ',2
    if ((Get-FileHash -LiteralPath (Join-Path $context.payload $parts[1]) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $parts[0]) { throw 'Payload changed or was quarantined after scanning' }
  }
  $report.securityStatus='COMPLETED_NO_NEW_DETECTIONS_REPORTED'
  $report.protectionAfter = Get-MpComputerStatus | Select-Object AMRunningMode,RealTimeProtectionEnabled,BehaviorMonitorEnabled,IoavProtectionEnabled,AntivirusEnabled,AntivirusSignatureVersion,IsTamperProtected
  if (-not ($report.protectionAfter.RealTimeProtectionEnabled -and $report.protectionAfter.AntivirusEnabled)) { throw 'Protection changed during verification' }
  $installRoot = Join-Path $env:ProgramFiles 'Ventio'
  $dataRoot = Join-Path $env:ProgramData 'Ventio'
  if ((Test-Path $installRoot) -or (Test-Path $dataRoot) -or (Get-Service -Name VentioHost,VentioPostgres -ErrorAction SilentlyContinue)) { throw 'Fresh installer smoke requires no existing Ventio state' }
  if (-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Normal elevated hosted token required; no elevation bypass is used' }
  $report.executionPoliciesBefore = @(Get-ExecutionPolicy -List | Select-Object Scope,ExecutionPolicy)
  $installer = Get-ChildItem -LiteralPath $context.payload -Filter 'Ventio-Setup-*.exe' -File
  if (@($installer).Count -ne 1) { throw 'One verified installer required' }
  $process = Start-Process -FilePath $installer.FullName -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' -Wait -PassThru -WindowStyle Hidden
  $report.installerExitCode = $process.ExitCode
  if ($process.ExitCode -ne 0) { throw 'Fresh installer did not complete; no restart or bypass attempted' }
  if ((Test-Path $dataRoot) -or (Get-Service -Name VentioHost,VentioPostgres -ErrorAction SilentlyContinue) -or (Get-Process -Name ventio_native_client -ErrorAction SilentlyContinue)) { throw 'Installer unexpectedly provisioned or launched Ventio' }
  $compared=0
  foreach($component in @('Client','HostPayload')) {
    $source = Join-Path $context.payload $component
    $target = if($component -eq 'Client'){$installRoot}else{Join-Path $installRoot 'host-payload'}
    foreach($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
      $relative = [IO.Path]::GetRelativePath($source,$file.FullName)
      if ((Get-FileHash -LiteralPath (Join-Path $target $relative) -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) { throw 'Installed payload differs from the verified candidate' }
      $compared++
    }
  }
  $report.installedPayloadFilesMatched=$compared
  $uninstaller=Join-Path $installRoot 'unins000.exe'
  $process=Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait -PassThru -WindowStyle Hidden
  $report.uninstallerExitCode=$process.ExitCode
  for($attempt=0;$attempt -lt 30 -and (Test-Path $installRoot);$attempt++){Start-Sleep -Seconds 1}
  if($process.ExitCode -ne 0 -or (Test-Path $installRoot) -or (Test-Path $dataRoot) -or (Get-Service -Name VentioHost,VentioPostgres -ErrorAction SilentlyContinue)){throw 'Client-only rollback smoke did not cleanly complete'}
  $report.executionPoliciesAfter = @(Get-ExecutionPolicy -List | Select-Object Scope,ExecutionPolicy)
  if(($report.executionPoliciesBefore|ConvertTo-Json -Compress) -cne ($report.executionPoliciesAfter|ConvertTo-Json -Compress)){throw 'Installer changed an execution policy'}
  $report.installerSmoke='PASSED_FRESH_CLIENT_INSTALL_AND_UNINSTALL_NO_LAUNCH_OR_HOST_PROVISIONING'
} catch { $report.reason=$_.Exception.Message }
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $out 'protected-verification.json')
$report | ConvertTo-Json -Depth 12
if($report.securityStatus -ne 'COMPLETED_NO_NEW_DETECTIONS_REPORTED' -or $report.installerSmoke -notlike 'PASSED*'){exit 1}
exit 0
