# Windows Ventio Installer

## Reproducible build

Prerequisites for maintainers are Flutter's Windows desktop toolchain, the .NET 8 SDK, Inno Setup 6.7.3, Windows PowerShell 5.1 or later, and the pinned PostgreSQL tools described below. The verified local toolchain for the 2026-11-02 development build was Flutter 3.44.1 (Dart 3.12.1), .NET SDK 8.0.421, and Inno Setup 6.7.3.

The Host payload build requires the EDB PostgreSQL 16.15-5 Windows x64 binaries archive. It is a build-time dependency; it is not stored in Git and is not downloaded by the end-user installer. The official archive is [postgresql-16.15-5-windows-x64-binaries.zip](https://get.enterprisedb.com/postgresql/postgresql-16.15-5-windows-x64-binaries.zip), 373,254,386 bytes, pinned to SHA-256 `43bb45f173a6f08cf1d29a97a6d8deb119e8e8093a24c00d2d1001a0ccaa8281`. The default expected directory is `%LOCALAPPDATA%\VentioFramework\postgresql-16.15-tools\pgsql\bin`; the directory must contain the PostgreSQL 16.15 executables. When using another verified extraction path, pass it with `-PostgresBinDirectory`.

If the verified tool archive is not already cached, retrieve and verify it before extraction:

```powershell
$archiveUrl = 'https://get.enterprisedb.com/postgresql/postgresql-16.15-5-windows-x64-binaries.zip'
$archivePath = Join-Path $env:TEMP ('postgresql-16.15-5-windows-x64-binaries-' + [guid]::NewGuid().ToString('N') + '.zip')
$expectedArchiveSha256 = '43bb45f173a6f08cf1d29a97a6d8deb119e8e8093a24c00d2d1001a0ccaa8281'
Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath
if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedArchiveSha256) {
  throw 'PostgreSQL build archive SHA-256 mismatch.'
}
$toolsRoot = Join-Path $env:LOCALAPPDATA 'VentioFramework\postgresql-16.15-tools'
if (Test-Path -LiteralPath $toolsRoot) {
  throw 'The expected PostgreSQL tools directory already exists; preserve it and choose an unused extraction directory with -PostgresBinDirectory.'
}
Expand-Archive -LiteralPath $archivePath -DestinationPath $toolsRoot
if (-not (Test-Path -LiteralPath (Join-Path $toolsRoot 'pgsql\bin\postgres.exe') -PathType Leaf)) {
  throw 'PostgreSQL tools archive did not produce the expected pgsql\bin layout.'
}
```

Build from the repository root. These commands choose fresh output directories so they preserve any previous payload or installer:

```powershell
$buildId = Get-Date -Format 'yyyyMMdd-HHmmss'
$repo = (Get-Location).Path
$postgresBin = Join-Path $env:LOCALAPPDATA 'VentioFramework\postgresql-16.15-tools\pgsql\bin'
$payload = Join-Path $repo "packages\ventio_host_api\build\windows\host-payload-$buildId"
$installerOutput = Join-Path $repo "dist\windows\wave1-$buildId"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/build-host-payload.ps1 -PostgresBinDirectory $postgresBin -OutputDirectory $payload
if ($LASTEXITCODE -ne 0) { throw 'Host payload build failed.' }
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/build-windows-installer.ps1 -HostPayloadDirectory $payload -InstallerOutputDirectory $installerOutput
if ($LASTEXITCODE -ne 0) { throw 'Unified installer build failed.' }
Get-FileHash (Join-Path $installerOutput 'Ventio-Setup-0.1.0.exe') -Algorithm SHA256
Get-AuthenticodeSignature (Join-Path $installerOutput 'Ventio-Setup-0.1.0.exe') | Select-Object Status
```

The installer build validates the Host payload manifest, payload file count and byte count, rejects the StackBuilder executable and directory, and verifies each critical SHA-256 before invoking Inno Setup. The Host payload includes PostgreSQL 16.15 runtime `bin`, `lib`, `share` files and license texts. It intentionally excludes PostgreSQL documentation, development headers, pgAdmin 4 and StackBuilder; `postgresql\bin\stackbuilder.exe` is explicitly removed from the isolated payload staging tree and rechecked by the installer builder and lifecycle validator. Database state and credentials are never in the payload.

The latest verified development artifact was built from source commit `8f50e8cf618d18e5dff99b0f9a63d9db485d73c7`: `dist/windows/wave1-gitpush-20261102-stackbuilder-fix/Ventio-Setup-0.1.0.exe`, **84,878,879 bytes**, SHA-256 `1fe6c68d85c806d06b3fcfbf03f794760858a50c781ecdd0f358cc5772f6ffc6`, Authenticode `NotSigned`. Its Host payload contains 1,694 files / 287,245,613 bytes; all 61 critical manifest file hashes match and no StackBuilder executable is present. The adjacent `Ventio-Setup-SHA256SUMS.txt` records the installer hash. The verified build used Flutter 3.44.1 / Dart 3.12.1, .NET SDK 8.0.421, PostgreSQL 16.15-5 tools and Inno Setup 6.7.3. The Inno compiler printed “Non-commercial use only”; commercial toolchain licensing has not been verified.

The Inno installer installs the shared Flutter application plus the verified Host runtime payload under the machine-wide `%ProgramFiles%\Ventio` root. It does not have an install-time Client/Host type page. After launch, Flutter first-run offers Host setup or connection to an existing Host as a Client. The implementation plan specifies using the same Flutter application in either mode. Flutter runs unelevated; the fixed Setup Broker owns the narrow elevated setup operations.

## Current verification

`scripts/windows/test-unified-installer-path-contract.ps1` checks the protected Program Files root, shared Flutter Host/Client first-run choices, unelevated application boundary and deferred Host provisioning. `scripts/windows/test-unified-installer-host-privilege-guard.ps1` checks that invalid Host-per-user launch is rejected. Both current static checks pass. The unified install/uninstall validator targets `%ProgramFiles%\Ventio`, refuses to run unless the current shell is already elevated and the installation/data/services are absent, then checks the shared application, Host payload and external data retention. It has not been run against the current unified artifact because no clean elevated Windows environment is available.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/validate-unified-installer.ps1 -InstallerPath dist/windows/wave1-gitpush-20261102-stackbuilder-fix/Ventio-Setup-0.1.0.exe
```

This destructive lifecycle validator was not run here: it requires an already elevated shell and a clean isolated Windows host, while this development workstation has registered Ventio services and product paths. The builder's static path/privilege checks and the installer compilation passed; the full installer lifecycle remains open for acceptance.

The former `-SetupType client|host` argument only changed test labels and has been removed. A separate per-user Client package passed install/repeat/upgrade/uninstall checks, but that artifact is not the unified installer. The reduced PostgreSQL payload passed isolated SCRAM initialization/readiness/authentication, migrations 001–030, security bootstrap, runtime and Identity API login checks, protected DPAPI configuration validation, and the no-mutation service plan check. `test-postgres-single-user-recovery.ps1` also passed disposable backup-collision, failure-classification, credential-rotation, role-login and migration-ledger checks. It does not reproduce the historical partial-install failure.

## Not yet provided by this artifact

The installer package itself stages the shared Flutter application and verified Host files; it does not provision services during silent installation. Interactive Flutter first-run is wired to the Host wizard or Client pairing flow. Local setup and live pairing tests pass, but these flows have not been exercised from the installed unified package on a clean elevated Windows system. PostgreSQL/Host service installation, first-admin bootstrap, reboot recovery, installed upgrade and service-aware uninstall remain mandatory and open. Do not use this unsigned development artifact as a production installer.

Historical package size (2026-10-30): the reduced PostgreSQL payload contained 1,680 files totaling 212,081,806 bytes, and that earlier unified installer was 63,333,918 bytes. Those counts do not describe the latest artifact identified above. The 373,254,386-byte PostgreSQL tools archive is a separate build/test source and is not downloaded during end-user installation. The current package has not been installed as a persistent Windows service.

The current unified installer lifecycle, including installed-service removal and explicit data-retention choices, has not been run on a clean elevated Windows host. The Stage 10 acceptance record tracks those checks as open.
