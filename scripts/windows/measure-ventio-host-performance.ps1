[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $OutputPath,

  [ValidateRange(30, 3600)]
  [int] $DurationSeconds = 300,

  [ValidateRange(250, 5000)]
  [int] $SampleIntervalMilliseconds = 1000
)

$ErrorActionPreference = 'Stop'
$output = [IO.Path]::GetFullPath($OutputPath)
if (-not [IO.Path]::IsPathFullyQualified($output)) { throw 'OutputPath must be absolute.' }
if (Test-Path -LiteralPath $output) { throw 'OutputPath must be a new evidence file.' }
$parent = Split-Path -Parent $output
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'OutputPath parent must exist.' }

$cpuCounter = $null
$diskCounter = $null
$memoryCounter = $null
try {
  $cpuCounter = [Diagnostics.PerformanceCounter]::new('Processor', '% Processor Time', '_Total')
  [void]$cpuCounter.NextValue()
  $diskCounter = [Diagnostics.PerformanceCounter]::new('PhysicalDisk', '% Disk Time', '_Total')
  [void]$diskCounter.NextValue()
  $memoryCounter = [Diagnostics.PerformanceCounter]::new('Memory', 'Available MBytes')
  [void]$memoryCounter.NextValue()
} catch {
  foreach ($counter in @($cpuCounter, $diskCounter, $memoryCounter)) { if ($counter) { $counter.Dispose() } }
  $cpuCounter = $null
  $diskCounter = $null
  $memoryCounter = $null
}

$logicalCpuCount = [Math]::Max(1, [Environment]::ProcessorCount)
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$previousSample = [Diagnostics.Stopwatch]::StartNew()
$previousCpuMs = @{ VentioHostService = 0.0; postgres = 0.0 }
$lines = [IO.StreamWriter]::new($output, $false, [Text.UTF8Encoding]::new($false))
try {
  while ($stopwatch.Elapsed.TotalSeconds -lt $DurationSeconds) {
    Start-Sleep -Milliseconds $SampleIntervalMilliseconds
    $elapsedMs = [Math]::Max(1.0, $previousSample.Elapsed.TotalMilliseconds)
    $sample = [ordered]@{
      atUtc = [DateTime]::UtcNow.ToString('o')
      elapsedMs = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 1)
      processes = @{}
      systemCpuPercent = $null
      systemDiskBusyPercent = $null
      systemAvailableMemoryMiB = $null
    }
    $ioProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('VentioHostService.exe', 'postgres.exe') })
    foreach ($name in @('VentioHostService', 'postgres')) {
      $items = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
      $cpuMs = 0.0
      $privateBytes = [long]0
      $workingSetBytes = [long]0
      $readBytes = [long]0
      $writeBytes = [long]0
      foreach ($item in $items) {
        $cpuMs += $item.TotalProcessorTime.TotalMilliseconds
        $privateBytes += $item.PrivateMemorySize64
        $workingSetBytes += $item.WorkingSet64
        $ioProcess = $ioProcesses | Where-Object { $_.ProcessId -eq $item.Id } | Select-Object -First 1
        if ($ioProcess) {
          $readBytes += [long]$ioProcess.ReadTransferCount
          $writeBytes += [long]$ioProcess.WriteTransferCount
        }
      }
      $sample.processes[$name] = [ordered]@{
        count = $items.Count
        cpuPercent = if ($items.Count) { [Math]::Round((($cpuMs - $previousCpuMs[$name]) / $elapsedMs / $logicalCpuCount) * 100, 2) } else { $null }
        cpuMs = if ($items.Count) { [Math]::Round($cpuMs, 1) } else { $null }
        privateBytes = if ($items.Count) { $privateBytes } else { $null }
        workingSetBytes = if ($items.Count) { $workingSetBytes } else { $null }
        readBytes = if ($items.Count) { $readBytes } else { $null }
        writeBytes = if ($items.Count) { $writeBytes } else { $null }
      }
      if ($items.Count) { $previousCpuMs[$name] = $cpuMs }
    }
    if ($cpuCounter) { try { $sample.systemCpuPercent = [Math]::Round($cpuCounter.NextValue(), 2) } catch {} }
    if ($diskCounter) { try { $sample.systemDiskBusyPercent = [Math]::Round($diskCounter.NextValue(), 2) } catch {} }
    if ($memoryCounter) { try { $sample.systemAvailableMemoryMiB = [Math]::Round($memoryCounter.NextValue(), 1) } catch {} }
    $lines.WriteLine(($sample | ConvertTo-Json -Depth 5 -Compress))
    $lines.Flush()
  }
} finally {
  $lines.Dispose()
  foreach ($counter in @($cpuCounter, $diskCounter, $memoryCounter)) { if ($counter) { $counter.Dispose() } }
  $stopwatch.Stop()
}
Write-Output "Ventio Host resource trace: $output"
