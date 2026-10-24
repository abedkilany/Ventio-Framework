$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$clientDirectory = Join-Path $repositoryRoot 'packages/ventio_native_client'
$existingPlatforms = @('android', 'windows') | Where-Object {
    Test-Path -LiteralPath (Join-Path $clientDirectory $_)
}
if ($existingPlatforms.Count -gt 0) {
    throw "Refusing to regenerate existing platform folders ($($existingPlatforms -join ', ')). Preserve or back them up before generating fresh runners."
}

Push-Location $clientDirectory
try {
    flutter config --enable-windows-desktop
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not enable Windows desktop support.'
    }

    flutter create `
        --empty `
        --no-pub `
        --platforms=android,windows `
        --project-name=ventio_native_client `
        --org=com.ventio `
        .
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not generate Android and Windows runner scaffolding.'
    }

    $manifestPath = Join-Path $clientDirectory 'android/app/src/main/AndroidManifest.xml'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw
    $permission = '    <uses-permission android:name="android.permission.INTERNET" />'
    if (-not $manifest.Contains($permission)) {
        $manifest = [regex]::Replace(
            $manifest,
            '(<manifest\b[^>]*>)',
            ('$1' + [Environment]::NewLine + $permission),
            1
        )
        [System.IO.File]::WriteAllText(
            $manifestPath,
            $manifest,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
}
finally {
    Pop-Location
}
