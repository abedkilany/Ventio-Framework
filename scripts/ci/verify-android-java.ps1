$ErrorActionPreference = 'Stop'

$expectedJavaHome = 'C:\Program Files\Android\Android Studio\jbr'
if ($env:JAVA_HOME -ne $expectedJavaHome) {
    throw "Expected JAVA_HOME=$expectedJavaHome; received '$env:JAVA_HOME'."
}

$java = Join-Path $expectedJavaHome 'bin\java.exe'
if (-not (Test-Path -LiteralPath $java -PathType Leaf)) {
    throw "Android Studio Java runtime not found: $java"
}

$versionOutput = (& $java -version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch 'openjdk version "21\.') {
    throw "Expected Android Studio JDK 21. Received: $versionOutput"
}

if (-not $env:GITHUB_PATH) { throw 'GitHub Actions did not provide GITHUB_PATH.' }
[IO.File]::AppendAllText($env:GITHUB_PATH, "$expectedJavaHome\bin`n", [Text.UTF8Encoding]::new($false))
Write-Output $versionOutput.Trim()
