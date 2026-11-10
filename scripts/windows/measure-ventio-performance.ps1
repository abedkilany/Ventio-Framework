[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $ExecutablePath,

  [Parameter(Mandatory = $true)]
  [string] $OutputDirectory,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')]
  [string] $RunLabel,

  [string] $AppSupportDirectory,

  [switch] $ReuseIsolatedProfile,

  [switch] $CloseAfterFirstScreen,

  [ValidateRange(100, 5000)]
  [int] $SampleIntervalMilliseconds = 500
)

$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $output -PathType Container)) {
  throw 'OutputDirectory must be an existing acceptance evidence directory.'
}
if ($AppSupportDirectory) {
  if (-not [IO.Path]::IsPathFullyQualified($AppSupportDirectory)) {
    throw 'AppSupportDirectory must be absolute.'
  }
  $support = [IO.Path]::GetFullPath($AppSupportDirectory)
  $defaultSupport = Join-Path $env:APPDATA 'VentioFramework'
  if ($support.Equals([IO.Path]::GetFullPath($defaultSupport), [StringComparison]::OrdinalIgnoreCase) -or
      $support.StartsWith([IO.Path]::GetFullPath($defaultSupport).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'An isolated profile path must not overlap the installed Ventio user-data directory.'
  }
  $profileMarker = Join-Path $support '.ventio-performance-profile.json'
  if (Test-Path -LiteralPath $support) {
    if (-not $ReuseIsolatedProfile -or -not (Test-Path -LiteralPath $profileMarker -PathType Leaf)) {
      throw "An existing profile is reused only when it has this tool's marker and -ReuseIsolatedProfile is supplied."
    }
    $marker = Get-Content -LiteralPath $profileMarker -Raw | ConvertFrom-Json
    if ($marker.formatVersion -ne 1 -or
        [IO.Path]::GetFullPath([string]$marker.profilePath) -ne $support) {
      throw 'The isolated profile marker does not match this exact directory.'
    }
  } else {
    if ($ReuseIsolatedProfile) {
      throw 'The requested isolated profile does not exist for a warm run.'
    }
    [void](New-Item -ItemType Directory -Path $support -Force)
    $markerJson = [ordered]@{
      formatVersion = 1
      profilePath = $support
      createdAtUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText($profileMarker, $markerJson, [Text.UTF8Encoding]::new($false))
  }
}
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$tracePath = Join-Path $output "performance-$RunLabel-$stamp.jsonl"
$summaryPath = Join-Path $output "performance-$RunLabel-$stamp-summary.json"
if ((Test-Path -LiteralPath $tracePath) -or (Test-Path -LiteralPath $summaryPath)) {
  throw 'The performance output already exists.'
}

$previousTrace = $env:VENTIO_PERF_TRACE_PATH
$previousSupport = $env:VENTIO_APP_SUPPORT_DIRECTORY
$env:VENTIO_PERF_TRACE_PATH = $tracePath
if ($AppSupportDirectory) { $env:VENTIO_APP_SUPPORT_DIRECTORY = $support }
else { Remove-Item Env:VENTIO_APP_SUPPORT_DIRECTORY -ErrorAction SilentlyContinue }

$samples = [System.Collections.Generic.List[object]]::new()
$watch = [Diagnostics.Stopwatch]::StartNew()
$startedAtUtc = [DateTime]::UtcNow
$process = $null
try {
  $process = Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -PassThru
  $pidValue = $process.Id
  Write-Output "Ventio started (PID $pidValue). Perform the labeled workflow(s), then close Ventio to finish collection."
  $logicalCpuCount = [Math]::Max(1, [Environment]::ProcessorCount)
  $systemCpuCounter = $null
  $systemDiskCounter = $null
  $systemMemoryCounter = $null
  try {
    $systemCpuCounter = [Diagnostics.PerformanceCounter]::new('Processor', '% Processor Time', '_Total')
    [void]$systemCpuCounter.NextValue()
    $systemDiskCounter = [Diagnostics.PerformanceCounter]::new('PhysicalDisk', '% Disk Time', '_Total')
    [void]$systemDiskCounter.NextValue()
    $systemMemoryCounter = [Diagnostics.PerformanceCounter]::new('Memory', 'Available MBytes')
    [void]$systemMemoryCounter.NextValue()
  } catch {
    if ($systemCpuCounter) { $systemCpuCounter.Dispose(); $systemCpuCounter = $null }
    if ($systemDiskCounter) { $systemDiskCounter.Dispose(); $systemDiskCounter = $null }
    if ($systemMemoryCounter) { $systemMemoryCounter.Dispose(); $systemMemoryCounter = $null }
  }
  $lastSampleAt = [Diagnostics.Stopwatch]::StartNew()
  $lastCpu = [TimeSpan]::Zero
  $lastIoRead = [long]0
  $lastIoWrite = [long]0
  $systemCpu = $null
  $firstScreenSeen = $false
  while (-not $process.HasExited) {
    Start-Sleep -Milliseconds $SampleIntervalMilliseconds
    try { $process.Refresh() } catch { break }
    if ($process.HasExited) { break }
    $elapsedMs = $lastSampleAt.Elapsed.TotalMilliseconds
    if ($elapsedMs -le 0) { $elapsedMs = $SampleIntervalMilliseconds }
    $cpu = $process.TotalProcessorTime
    $ioProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $pidValue" -ErrorAction SilentlyContinue
    $readBytes = if ($ioProcess) { [long]$ioProcess.ReadTransferCount } else { $lastIoRead }
    $writeBytes = if ($ioProcess) { [long]$ioProcess.WriteTransferCount } else { $lastIoWrite }
    $cpuSystemValue = $null
    $diskSystemValue = $null
    $memorySystemValue = $null
    if ($systemCpuCounter) { try { $cpuSystemValue = [Math]::Round($systemCpuCounter.NextValue(), 2) } catch {} }
    if ($systemDiskCounter) { try { $diskSystemValue = [Math]::Round($systemDiskCounter.NextValue(), 2) } catch {} }
    if ($systemMemoryCounter) { try { $memorySystemValue = [Math]::Round($systemMemoryCounter.NextValue(), 1) } catch {} }
    $samples.Add([pscustomobject]@{
      atUtc = [DateTime]::UtcNow.ToString('o')
      elapsedMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
      processCpuPercent = [Math]::Round((($cpu - $lastCpu).TotalMilliseconds / $elapsedMs / $logicalCpuCount) * 100, 2)
      systemCpuPercent = $cpuSystemValue
      systemDiskBusyPercent = $diskSystemValue
      systemAvailableMemoryMiB = $memorySystemValue
      privateBytes = [long]$process.PrivateMemorySize64
      workingSetBytes = [long]$process.WorkingSet64
      readBytes = [long]$readBytes
      writeBytes = [long]$writeBytes
      readBytesPerSecond = [Math]::Round(($readBytes - $lastIoRead) / ($elapsedMs / 1000), 1)
      writeBytesPerSecond = [Math]::Round(($writeBytes - $lastIoWrite) / ($elapsedMs / 1000), 1)
    })
    $lastCpu = $cpu
    $lastIoRead = $readBytes
    $lastIoWrite = $writeBytes
    $lastSampleAt.Restart()
    if ($CloseAfterFirstScreen -and -not $firstScreenSeen -and
        (Test-Path -LiteralPath $tracePath -PathType Leaf) -and
        (Select-String -LiteralPath $tracePath -SimpleMatch '"workflow":"startup.first_screen.ready"' -Quiet)) {
      $firstScreenSeen = $true
      [void]$process.CloseMainWindow()
    }
  }
  if ($systemCpuCounter) { $systemCpuCounter.Dispose() }
  if ($systemDiskCounter) { $systemDiskCounter.Dispose() }
  if ($systemMemoryCounter) { $systemMemoryCounter.Dispose() }
  if (-not $process.HasExited) { $process.WaitForExit() }
  $watch.Stop()
  $events = @()
  if (Test-Path -LiteralPath $tracePath -PathType Leaf) {
    $events = @(Get-Content -LiteralPath $tracePath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
  }
  $firstScreen = $events | Where-Object { $_.workflow -eq 'startup.first_screen.ready' } | Select-Object -First 1
  $firstScreenElapsedMs = $null
  if ($firstScreen) {
    $markerTime = $firstScreen.atUtc
    $firstScreenUtc = if ($markerTime -is [DateTime]) {
      if ($markerTime.Kind -eq [DateTimeKind]::Utc) { $markerTime }
      else { $markerTime.ToUniversalTime() }
    } else {
      [DateTimeOffset]::Parse(
        [string]$markerTime,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
      ).UtcDateTime
    }
    $firstScreenElapsedMs = [Math]::Round(($firstScreenUtc - $startedAtUtc).TotalMilliseconds, 1)
  }
  $peakPrivate = if ($samples.Count) { ($samples | Measure-Object -Property privateBytes -Maximum).Maximum } else { $null }
  $peakWorkingSet = if ($samples.Count) { ($samples | Measure-Object -Property workingSetBytes -Maximum).Maximum } else { $null }
  $summary = [ordered]@{
    runLabel = $RunLabel
    executable = $exe
    startedAtUtc = $startedAtUtc.ToString('o')
    processId = $pidValue
    processExitCode = $process.ExitCode
    processLifetimeMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
    firstScreenFromProcessLaunchMs = $firstScreenElapsedMs
    traceFile = [IO.Path]::GetFileName($tracePath)
    appEventCount = $events.Count
    sampledProcessPeakPrivateBytes = $peakPrivate
    sampledProcessPeakWorkingSetBytes = $peakWorkingSet
    finalProcessCpuMs = [Math]::Round($process.TotalProcessorTime.TotalMilliseconds, 1)
    sampleIntervalMilliseconds = $SampleIntervalMilliseconds
    sampleCount = $samples.Count
    samples = @($samples)
  }
  [IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
  Write-Output "Performance trace: $tracePath"
  Write-Output "Performance summary: $summaryPath"
  if ($null -ne $firstScreenElapsedMs) { Write-Output "Process launch to first-screen event: $firstScreenElapsedMs ms" }
  else { Write-Warning 'No first-screen marker was captured; use the event trace and mark launch-to-screen measurement incomplete.' }
}
finally {
  if ($null -eq $previousTrace) { Remove-Item Env:VENTIO_PERF_TRACE_PATH -ErrorAction SilentlyContinue }
  else { $env:VENTIO_PERF_TRACE_PATH = $previousTrace }
  if ($null -eq $previousSupport) { Remove-Item Env:VENTIO_APP_SUPPORT_DIRECTORY -ErrorAction SilentlyContinue }
  else { $env:VENTIO_APP_SUPPORT_DIRECTORY = $previousSupport }
}
