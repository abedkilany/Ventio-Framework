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
$appData = $expectedAppData

$expectedBuildPath = [System.IO.Path]::GetFullPath(
    (Join-Path $runnerTemp "ventio-native-build-$runId-$runAttempt")
)
$buildPath = $expectedBuildPath

foreach ($path in @($buildPath, $appData)) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to remove a reparse-point Flutter directory: $path"
    }
    Remove-Item -LiteralPath $path -Recurse -Force
}

Write-Output 'Removed the run-scoped Flutter build and settings directories.'
