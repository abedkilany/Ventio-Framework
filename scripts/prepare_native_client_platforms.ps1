$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$clientDirectory = Join-Path $repositoryRoot 'packages/ventio_native_client'
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
}
finally {
    Pop-Location
}
