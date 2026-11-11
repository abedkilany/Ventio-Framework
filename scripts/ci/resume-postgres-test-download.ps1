param(
  [Parameter(Mandatory = $true)]
  [string] $WorkRoot
)

$ErrorActionPreference = 'Stop'
$workRoot = [IO.Path]::GetFullPath($WorkRoot)
$archiveUrl = 'https://get.enterprisedb.com/postgresql/postgresql-16.15-5-windows-x64-binaries.zip'
$expectedLength = 373254386L
$chunkSize = [long][Math]::Ceiling($expectedLength / 8)
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path -LiteralPath $workRoot -PathType Container)) { throw 'Resumable PostgreSQL download directory is missing.' }
$jobs = @()
for ($i = 0; $i -lt 8; $i++) {
  $start = [long]$i * $chunkSize
  $end = [Math]::Min($expectedLength - 1, $start + $chunkSize - 1)
  $part = Join-Path $workRoot "archive-$i.part"
  $suffix = Join-Path $workRoot "archive-$i.resume"
  if (Test-Path -LiteralPath $suffix) {
    $currentLength = if (Test-Path -LiteralPath $part) { (Get-Item -LiteralPath $part).Length } else { 0 }
    $suffixLength = (Get-Item -LiteralPath $suffix).Length
    if ($currentLength + $suffixLength -gt ($end - $start + 1)) { throw "Saved chunk $i exceeds its range." }
    if (-not (Test-Path -LiteralPath $part)) { New-Item -ItemType File -Path $part | Out-Null }
    $output = [IO.File]::Open($part, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $input = [IO.File]::OpenRead($suffix); try { $input.CopyTo($output) } finally { $input.Dispose() } } finally { $output.Dispose() }
    Remove-Item -LiteralPath $suffix -Force
  }
  $length = if (Test-Path -LiteralPath $part) { (Get-Item -LiteralPath $part).Length } else { 0 }
  if ($length -gt ($end - $start + 1)) { throw "Chunk $i exceeds its range." }
  if ($length -lt ($end - $start + 1)) {
    $resumeStart = $start + $length
    $suffix = Join-Path $workRoot "archive-$i.resume"
    $args = '--fail --location --silent --show-error --connect-timeout 30 --max-time 1800 --range {0}-{1} --output "{2}" "{3}"' -f $resumeStart, $end, $suffix, $archiveUrl
    $jobs += Start-Process -FilePath $curl -ArgumentList $args -PassThru -WindowStyle Hidden
  }
}
foreach ($job in $jobs) { $job.WaitForExit() }
for ($i = 0; $i -lt 8; $i++) {
  $start = [long]$i * $chunkSize
  $end = [Math]::Min($expectedLength - 1, $start + $chunkSize - 1)
  $part = Join-Path $workRoot "archive-$i.part"
  $suffix = Join-Path $workRoot "archive-$i.resume"
  if (Test-Path -LiteralPath $suffix) {
    $actual = (Get-Item -LiteralPath $suffix).Length
    $needed = $end - $start + 1 - (Get-Item -LiteralPath $part).Length
    if ($actual -gt $needed) { throw "Chunk $i resumed beyond its expected range." }
    $output = [IO.File]::Open($part, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
      $input = [IO.File]::OpenRead($suffix)
      try { $input.CopyTo($output) } finally { $input.Dispose() }
    } finally { $output.Dispose() }
    Remove-Item -LiteralPath $suffix -Force
  }
  $final = (Get-Item -LiteralPath $part).Length
  if ($final -lt ($end - $start + 1)) { Write-Warning "Chunk $i remains incomplete at $final bytes; rerun this script to resume." }
}
Get-ChildItem -LiteralPath $workRoot -Filter 'archive-*.part' | Select-Object Name, Length
