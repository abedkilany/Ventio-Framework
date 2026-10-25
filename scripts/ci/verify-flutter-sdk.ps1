$ErrorActionPreference = 'Stop'

$flutter = 'C:\flutter\bin\flutter.bat'
$dart = 'C:\flutter\bin\dart.bat'
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

if (-not $env:GITHUB_PATH) { throw 'GitHub Actions did not provide GITHUB_PATH.' }
[IO.File]::AppendAllText($env:GITHUB_PATH, "C:\flutter\bin`n", [Text.UTF8Encoding]::new($false))
Write-Output $flutterVersion.Trim()
Write-Output $dartVersion.Trim()
