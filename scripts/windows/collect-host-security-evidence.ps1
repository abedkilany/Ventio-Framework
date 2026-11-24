param([Parameter(Mandatory=$true)][ValidateSet('VENTIO-TEST-01','VENTIO-TEST-02')][string]$ExpectedComputer)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:COMPUTERNAME -ne $ExpectedComputer) { throw 'Unexpected test computer.' }
$status = Get-MpComputerStatus
$preference = Get-MpPreference
$events = @(Get-WinEvent -FilterHashtable @{
  LogName = 'Microsoft-Windows-Windows Defender/Operational'
  Id = @(1116,1117,1118,1119)
  StartTime = [datetime]'2026-11-14T00:00:00Z'
} -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'ventio_host\.exe' } | ForEach-Object {
  $xml = [xml]$_.ToXml()
  $fields = [ordered]@{}
  foreach ($d in $xml.Event.EventData.Data) { $fields[[string]$d.Name] = [string]$d.'#text' }
  [ordered]@{ id=$_.Id; recordId=$_.RecordId; utc=$_.TimeCreated.ToUniversalTime().ToString('o'); fields=$fields }
})
$detections = @(Get-MpThreatDetection | Where-Object { ($_.Resources -join ';') -match 'ventio_host\.exe' } | Select-Object DetectionID,ThreatID,ActionSuccess,CleaningActionID,ThreatStatusID,ThreatStatusErrorCode,InitialDetectionTime,LastThreatStatusChangeTime,RemediationTime,DetectionSourceTypeID,CurrentThreatExecutionStatusID,ProcessName,Resources)
$manifest = Get-Content -LiteralPath 'C:\Program Files\Ventio\host-payload\payload-manifest.json' -Raw | ConvertFrom-Json
$root = 'C:\Program Files\Ventio\host-payload'
$files = @($manifest.verifiedFiles | ForEach-Object {
  $p = Join-Path $root $_.path
  $present = Test-Path -LiteralPath $p -PathType Leaf
  [ordered]@{ path=$_.path; expectedSha256=$_.sha256; expectedLength=$_.length; present=$present }
})
$mp = Get-ChildItem -LiteralPath 'C:\ProgramData\Microsoft\Windows Defender\Platform' -Directory | Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'MpCmdRun.exe' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$quarantineRaw = (& $mp -Restore -ListAll 2>&1 | Out-String)
$listExit = $LASTEXITCODE
$quarantine = @($quarantineRaw -split '(?m)(?=^ThreatName = )' | Where-Object { $_ -match 'ventio_host\.exe' })
[ordered]@{
  collectedAtUtc=[datetime]::UtcNow.ToString('o'); computer=$env:COMPUTERNAME
  os=(Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber)
  defender=($status | Select-Object AMProductVersion,AMEngineVersion,AntivirusSignatureVersion,AntivirusSignatureLastUpdated,AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,BehaviorMonitorEnabled,IoavProtectionEnabled,NISEnabled,IsTamperProtected)
  submissionPolicy=($preference | Select-Object MAPSReporting,SubmitSamplesConsent,DisableBlockAtFirstSeen)
  detections=$detections; events=$events; manifestFiles=$files
  quarantineListExitCode=$listExit; quarantineList=$quarantine
  services=@(Get-CimInstance Win32_Service -Filter "Name='VentioHost' OR Name='VentioPostgres'" | Select-Object Name,State,ExitCode,StartName,PathName)
} | ConvertTo-Json -Depth 10
