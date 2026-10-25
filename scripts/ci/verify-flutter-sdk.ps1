$ErrorActionPreference = 'Stop'

$flutter = 'C:\flutter\bin\flutter.bat'
$dart = 'C:\flutter\bin\dart.bat'
$runnerTemp = [System.IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$workspace = [System.IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\')
$runId = [string]$env:GITHUB_RUN_ID
$runAttempt = [string]$env:GITHUB_RUN_ATTEMPT
if ($runId -notmatch '^\d+$' -or $runAttempt -notmatch '^\d+$') {
    throw 'GitHub Actions run identity is required for isolated Flutter paths.'
}

$expectedAppData = [System.IO.Path]::GetFullPath(
    (Join-Path $runnerTemp "ventio-flutter-appdata-$runId-$runAttempt")
)
$appData = [System.IO.Path]::GetFullPath($env:VENTIO_FLUTTER_APPDATA)
if (-not [string]::Equals($appData, $expectedAppData, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Flutter APPDATA must be isolated under RUNNER_TEMP: $expectedAppData"
}

$expectedBuildPath = [System.IO.Path]::GetFullPath(
    (Join-Path $runnerTemp "ventio-native-build-$runId-$runAttempt")
)
$buildPath = [System.IO.Path]::GetFullPath($env:VENTIO_FLUTTER_BUILD_PATH)
if (-not [string]::Equals($buildPath, $expectedBuildPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Flutter build output must be isolated under RUNNER_TEMP: $expectedBuildPath"
}

New-Item -ItemType Directory -Path $appData -Force | Out-Null
$env:APPDATA = $appData

foreach ($executable in @($flutter, $dart)) {
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Required Flutter SDK executable not found: $executable"
    }
}

$flutterVersion = (& $flutter --version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $flutterVersion -notmatch '(?m)^Flutter 3\.44\.1\b') {
    throw "Expected Flutter 3.44.1 from $flutter. Received: $flutterVersion"
}

$dartVersion = (& $dart --version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $dartVersion -notmatch 'Dart SDK version: 3\.12\.1\b') {
    throw "Expected Dart 3.12.1 from $dart. Received: $dartVersion"
}

$clientDirectory = Join-Path $workspace 'packages/ventio_native_client'
$clientUri = [Uri]::new(($clientDirectory.TrimEnd('\') + '\'), [UriKind]::Absolute)
$buildUri = [Uri]::new(($buildPath.TrimEnd('\') + '\'), [UriKind]::Absolute)
$relativeBuildPath = [Uri]::UnescapeDataString(
    $clientUri.MakeRelativeUri($buildUri).ToString()
).Replace('/', '\').TrimEnd('\')
if ([System.IO.Path]::IsPathRooted($relativeBuildPath)) {
    throw 'Flutter build directory must be relative to the native client project.'
}

Push-Location $clientDirectory
try {
    & $flutter config --build-dir $relativeBuildPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not configure the run-scoped short Flutter build directory.'
    }
}
finally {
    Pop-Location
}

if (-not $env:GITHUB_PATH) { throw 'GitHub Actions did not provide GITHUB_PATH.' }
[IO.File]::AppendAllText($env:GITHUB_PATH, "C:\flutter\bin`n", [Text.UTF8Encoding]::new($false))
if (-not $env:GITHUB_ENV) { throw 'GitHub Actions did not provide GITHUB_ENV.' }
[IO.File]::AppendAllText($env:GITHUB_ENV, "APPDATA=$appData`n", [Text.UTF8Encoding]::new($false))
Write-Output $flutterVersion.Trim()
Write-Output $dartVersion.Trim()
Write-Output "Flutter build output uses the run-scoped short path: $buildPath"
