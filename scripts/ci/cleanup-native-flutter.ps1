$ErrorActionPreference = 'Stop'

$runnerTemp = [System.IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$runId = [string]$env:GITHUB_RUN_ID
$runAttempt = [string]$env:GITHUB_RUN_ATTEMPT
if ($runId -notmatch '^\d+$' -or $runAttempt -notmatch '^\d+$') {
    throw 'GitHub Actions run identity is required to clean Flutter paths.'
}

$expectedAppData = [System.IO.Path]::GetFullPath(
    (Join-Path $runnerTemp "ventio-flutter-appdata-$runId-$runAttempt")
)
$appData = [System.IO.Path]::GetFullPath($env:VENTIO_FLUTTER_APPDATA)
if (-not [string]::Equals($appData, $expectedAppData, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove Flutter APPDATA outside this run's directory: $expectedAppData"
}

$expectedBuildPath = [System.IO.Path]::GetFullPath(
    (Join-Path $runnerTemp "ventio-native-build-$runId-$runAttempt")
)
$buildPath = [System.IO.Path]::GetFullPath($env:VENTIO_FLUTTER_BUILD_PATH)
if (-not [string]::Equals($buildPath, $expectedBuildPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove Flutter output outside this run's directory: $expectedBuildPath"
}

foreach ($path in @($buildPath, $appData)) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to remove a reparse-point Flutter directory: $path"
    }
    Remove-Item -LiteralPath $path -Recurse -Force
}

Write-Output 'Removed the run-scoped Flutter build and settings directories.'
