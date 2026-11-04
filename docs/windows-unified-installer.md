# Windows Ventio Installer

## Reproducible build

Prerequisites for maintainers are Flutter's Windows desktop toolchain, Visual Studio Build Tools with the Desktop development with C++ workload and Windows SDK, the .NET 8 SDK, Inno Setup 6.7.3, Windows PowerShell 5.1 or later, and the pinned PostgreSQL tools described below. Follow [Flutter's Windows setup guide](https://docs.flutter.dev/platform-integration/windows/setup) and verify the Windows toolchain with `flutter doctor -v` before building. The verified local toolchain for the 2026-11-02 development build was Flutter 3.44.1 (Dart 3.12.1), Visual Studio Build Tools 2026 18.4.0 with Windows SDK 10.0.26100.0, .NET SDK 8.0.421, and Inno Setup 6.7.3.

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

The earlier 0.1.0 development artifact (2026-11-02) was built from source commit `8f50e8cf618d18e5dff99b0f9a63d9db485d73c7`: `dist/windows/wave1-gitpush-20261102-stackbuilder-fix/Ventio-Setup-0.1.0.exe`, **84,878,879 bytes**, SHA-256 `1fe6c68d85c806d06b3fcfbf03f794760858a50c781ecdd0f358cc5772f6ffc6`, Authenticode `NotSigned`. Its Host payload contains 1,694 files / 287,245,613 bytes; all 61 critical manifest file hashes match and no StackBuilder executable is present. The adjacent `Ventio-Setup-SHA256SUMS.txt` records the installer hash. The verified build used Flutter 3.44.1 / Dart 3.12.1, Visual Studio Build Tools 2026 18.4.0 / Windows SDK 10.0.26100.0, .NET SDK 8.0.421, PostgreSQL 16.15-5 tools and Inno Setup 6.7.3. The Inno compiler printed “Non-commercial use only”; commercial toolchain licensing has not been verified. The latest artifact is documented below.

The source build procedure and required tool versions are documented, but bit-for-bit deterministic output has not been established. The SHA-256 above identifies the exact locally built artifact; calculate and record the checksum of each independently rebuilt installer.

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

## Host provisioning defect closure — 2026-11-04

The fixed Windows Release and Host payload were built from source commit `9bb95852c46eb6159bb56419d03cef2ce7d32259`. The unified installer `dist/windows/host-setup-defect-closure-9bb9585/Ventio-Setup-0.1.1.exe` is 84,868,040 bytes with SHA-256 `e5f5b206c50230283baad4cc35a5f4fed82f42bd360cf78dbc38000e52da3f66`; its signature status is `NotSigned`. The 30-migration disposable database regression and installer static/build checks passed, and the owner confirms Host installation now succeeds. This provides bounded Stage 10 evidence only; clean elevated install/uninstall, SCM lifecycle, reboot, recovery and data-retention gates remain open. Full details are in [the defect closure record](wave1/host-setup-provisioning-defect-closure-20261104.md).

## LAN HTTPS network-profile compatibility — 2026-11-04

The Host engine already supports an independent TLS listener for LAN Clients. First-run provisioning and the unified installer upgrade both invoke `enable-host-lan-listener.ps1`. The helper previously accepted only Windows `Private` network profiles. A domain-joined adapter is reported as `DomainAuthenticated`, so the helper rejected an otherwise trusted network before completing the LAN listener configuration. During an in-place upgrade, the installer consequently restored the prior local-only Host configuration. This accounts for a Host that remains operational on loopback while exposing no LAN listener when the active adapter is domain-authenticated. The reported test computer's profile was not inspected from this development environment; the confirmed code-path defect applies when that profile is `DomainAuthenticated`.

The helper now maps `Private` to the Windows Firewall `Private` profile and `DomainAuthenticated` to `Domain`. It can reconcile the Ventio-owned rule between these trusted profiles after verifying its exact scope: inbound TCP 8443, the installed Host engine executable, `LocalSubnet` as the only remote address, and edge traversal blocked. It verifies the resulting rule in the active firewall policy. It still rejects Public-only networks, unsafe firewall defaults, conflicting rules, or a rule that Windows does not make effective. It never adds HTTP on a network interface and never permits the Public profile.

LAN setup continues to provision the Host certificate through the Host service, keep the private key ACL limited to the Host service identity, SYSTEM and Administrators, protect service configuration with machine DPAPI, preserve its existing database and Recovery Authority entries, and verify TLS against the provisioned certificate fingerprint. Local Host administration remains on loopback HTTP. The Host Settings view discovers the public certificate fingerprint, and Client enrollment validates that pinned certificate. The UI now explains the trusted-profile and firewall-policy failures without suggesting a firewall bypass.

### Existing installation upgrade

Use the 0.1.2 development installer over the existing installation; do not uninstall Ventio or remove the Host data directory. The installer stops the existing services through its reviewed upgrade path, replaces application and Host payload files, then runs the LAN configuration helper. The helper adds the LAN listener settings to the existing DPAPI-protected service configuration, creates or validates its certificate material, scopes the firewall rule to the authenticated Domain or Private profile, restarts the existing services, and checks HTTPS with the exact provisioned certificate. It does not reset PostgreSQL, remove the database, regenerate Recovery Authority state, or change the local management endpoint. If the helper cannot establish the safe listener, its rollback restores the prior service configuration and the Host remains local-only; Public-profile exposure is not a fallback.

The verified development artifact built for this change is `dist/windows/lan-https-0.1.2-20261104/Ventio-Setup-0.1.2.exe`, 84,877,540 bytes, SHA-256 `887b53ed4c0fb69ecd7655ea68ee0500f28395f2793b55a06990981c4bd3125e`. It is unsigned (`NotSigned`) and is for isolated development testing only. It was built from the current working tree at `a7f90f7` plus the uncommitted LAN HTTPS changes; that commit alone does not reproduce this artifact. The Host payload uses the locally available PostgreSQL 16.15-5 toolchain, contains 1,694 files / 287,253,050 bytes, and excludes database and credential state. The preserved prior Flutter Release snapshot is at `%LOCALAPPDATA%\VentioFramework\codex-snapshots\pre-lan-https-release-20261104-001`.

The new isolated regressions passed: Domain profile selection, combined Private and Domain profile selection, Public-only rejection, and preservation of existing protected service configuration; the unified installer/listener contract test; the Host service certificate and ACL suite; the Host-backed HTTPS integration using disposable PostgreSQL; Client certificate-pin validation and pairing over HTTPS; and the Host Setup Flutter tests (25/25). The integration confirmed the local HTTP management listener remained on loopback while the separate TLS listener served a non-loopback address. Flutter Windows Release and the unified Inno installer also compiled successfully.

The office installation was not changed from this development workstation. Therefore, actual Service Control Manager identity/configuration, firewall policy effectiveness, in-place upgrade, LAN reachability from another installed Client, and database/Recovery Authority continuity remain to be verified in the prepared Windows VM. Those checks require installing the above artifact over the existing VM installation and verifying the retained data and the two listener bindings. No Wave 1 stage acceptance points are awarded by this build or its isolated tests.

## LAN upgrade failure-code visibility — 2026-11-04

The Windows VM's 0.1.2 upgrade returned the generic LAN setup failure dialog. The installed helper hash matched the tested Domain/Private-aware script, both services ran under their expected service identities, and the Host service configuration hash matched its pre-LAN backup after the failure. Active firewall policy allowed local rules, but no LAN rule or 8443 listener remained. No related System or Application events were recorded. This confirms safe configuration rollback and local-only operation; it does not identify which post-certificate firewall, service-start or TLS-readiness step failed.

The installer previously discarded the helper's classified failure code. The helper now writes only a validated `HOST_LAN_*` code to the installer's temporary directory; the installer validates that code again before adding it to the error dialog, then removes the temporary file. It stores no exception text, credentials, configuration contents, certificate data or other secrets. Fallback phase codes are normalized to stable uppercase identifiers. The failure-code writer regression, LAN configuration tests and unified-installer path contract tests pass.

The 0.1.3 diagnostic development installer is `dist/windows/lan-diagnostic-0.1.3-20261104/Ventio-Setup-0.1.3.exe`, 84,870,208 bytes, SHA-256 `550e0f2a48ede04db2f1df0bfb12ac73b11aae2fa42da1fe824b690b692ddef8`, Authenticode `NotSigned`. It was built from working tree `a7f90f7` plus uncommitted changes, using the local Flutter Release and PostgreSQL 16.15-5 payload toolchain. An in-place upgrade over 0.1.2 preserves the existing database and Recovery Authority; no uninstall or data deletion is needed. If the attempt still fails, its dialog will now provide the safe failure code needed to target the next fix.

## Firewall conflict rollback correction — 2026-11-04

The 0.1.3 installer reported `HOST_LAN_FIREWALL_RULE_CONFLICT`. The test machine's active policy allowed local firewall rules, and the prior network-profile checks showed Private adapters with enabled, inbound-blocking profiles. The code indicates an existing rule named `Ventio Host HTTPS LAN` failed one or more scope checks (or multiple matching rules existed); the conflicting rule's original filters were not captured before the attempt, so the exact mismatch is not yet known.

Review found that the failure rollback could remove a pre-existing matching rule whenever a protected configuration backup existed. The rollback now removes only a firewall rule created during the current attempt; if the helper changed the profile of a validated existing rule, it restores that profile. A pre-existing conflicting rule remains untouched. The focused LAN tests and installer path-contract tests pass with this ownership boundary.

The updated in-place development installer is `dist/windows/lan-firewall-safe-0.1.4-20261104/Ventio-Setup-0.1.4.exe`, 84,876,528 bytes, SHA-256 `33aeb32ef16fdbf400b01e4fc35127addcfef3c3fa6d98dea93d14b1cfc20f21`, Authenticode `NotSigned`. It includes both the safe failure-code display and rollback correction. Before applying it to the VM, inspect the current matching firewall rule in ActiveStore and PersistentStore, because a prior 0.1.3 rollback may have removed a local matching rule. Do not delete or modify a remaining rule automatically; Public-profile access remains prohibited.

The subsequent read-only inspection found no rule with that name in either ActiveStore or PersistentStore. Because the 0.1.3 failure path could remove a pre-existing Ventio rule or remove a newly created rule after its effective-scope validation failed, the original rule filters cannot be recovered from the current stores. The exact conflict source remains unknown. The helper now returns distinct safe codes for duplicate rules, unsupported existing profiles, and filter mismatches by stage (`EXISTING` versus `ACTIVE`) and field (`DIRECTION`, `ACTION`, `ENABLED`, `PROTOCOL`, `LOCAL_PORT`, `REMOTE_ADDRESS`, `PROGRAM`, `EDGE_TRAVERSAL` or `PROFILE`).

The diagnostic and rollback-safe development installer is `dist/windows/lan-filter-diagnostic-0.1.5-20261104/Ventio-Setup-0.1.5.exe`, 84,861,663 bytes, SHA-256 `6b6fdc9ac93565af7bec205033871701be60587fc102459b210fafab1b4c0f1d`, Authenticode `NotSigned`. It builds on 0.1.4's preservation fix and carries the field-specific failure codes. Apply it only as an in-place update over the existing install; if it fails, retain its exact error code for the next diagnosis.

## Local-subnet firewall filter normalization — 2026-11-04

The owner reported that the 0.1.5 in-place update returned `HOST_LAN_FIREWALL_RULE_CONFLICT_ACTIVE_REMOTE_ADDRESS`. A read-only inspection after the failure found both Host services running but no `Ventio Host HTTPS LAN` rule in ActiveStore or PersistentStore and no listener on TCP 8443, consistent with the helper's rollback to local-only operation. The failure code identifies the ActiveStore remote-address check. Source review found that the helper accepted only the exact `LocalSubnet` string, although Windows Firewall supports the equivalent IPv4/IPv6 keyword forms `LocalSubnet4` and `LocalSubnet6` and can return these as separate filter values. This strict comparison is the likely cause; rollback means the failed machine no longer retains the effective rule filter, so the exact returned token set could not be independently confirmed there. Microsoft documents the IPv4/IPv6-specific keyword forms in [`New-NetFirewallRule`](https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallrule?view=windowsserver2025-ps).

The validator now accepts a nonempty set containing only `LocalSubnet`, `LocalSubnet4`, or `LocalSubnet6`, including comma-separated or combined IPv4/IPv6 values. It continues to reject `Any`, arbitrary addresses/ranges, mixed local-subnet and arbitrary scopes, and an empty scope. The regression covers each accepted representation and those rejected cases. It does not relax the trusted Domain/Private profile requirement, TLS, or local-only HTTP management endpoint.

The focused Host LAN configuration test passes, including DPAPI configuration preservation, Domain profile selection, Public-only rejection, remote-scope normalization and upgrade config preservation. The unified installer path-contract test passes. Flutter Host setup tests pass (25/25), and targeted Flutter analysis reports no issues. A fresh Host payload built with PostgreSQL 16.15 contains 1,694 files / 287,254,413 bytes; its manifest excludes credentials and database state, and a filename scan found no private-key/certificate, database, DPAPI, witness or environment files. The payload's LAN helper SHA-256 matches the source helper (`ee0dcb4e1ed073ec03505c8bb3b4f618d530c96aea90d24e19c09005b0eba2f4`).

The 0.1.6 development installer is `dist/windows/lan-subnet-fix-0.1.6-20261104/Ventio-Setup-0.1.6.exe`, 84,863,685 bytes, SHA-256 `01cc2f39f766b88b565f38df8d029e41519f0a70fb8b4fc7eebcaf32bfd1a95e`, Authenticode `NotSigned`. It was built from working-tree HEAD `a7f90f71ca8d84fcba8ec05eba3bbe70ca0229d1` plus the current uncommitted source changes using Flutter's Windows Release toolchain, PostgreSQL 16.15-5 and Inno Setup 6.7.3. It is a development build, not a signed production installer. Use it as an in-place update over the current Ventio installation; do not uninstall or remove data. The installer has not been run by this build process against the installed Host. Therefore the repaired listener, effective firewall rule, and service configuration still require post-update verification on the target machine. No Wave 1 acceptance points are awarded by this fix or its local checks.

## Unified development installer 0.1.7 — 2026-11-04

The latest unified development installer is `dist/windows/wave1-0.1.7-20261104-c1cc23f/Ventio-Setup-0.1.7.exe`, **84,869,354 bytes**, SHA-256 `afc7a467e7355a32f63beda681ae66bbc9ba077daca4da6398a34e64eed3f32f`. Authenticode status is `NotSigned`; this is an unsigned development build, not a production-ready installer. Its exact committed source checkpoint is `c1cc23f3a3d5d16e4abdd928a25d5db28bb81190` on `codex/extension-platform`.

The build used Flutter 3.44.1 / Dart 3.12.1, Visual Studio Build Tools 2026 with Windows SDK 10.0.26100.0, .NET SDK 8.0.421, EDB PostgreSQL 16.15-5 tools, and Inno Setup 6.7.3. The Host payload was built at `packages/ventio_host_api/build/windows/host-payload-wave1-0.1.7-20261104-160842`; it contains 1,694 files / 287,254,413 bytes and verifies 61 critical hashes. Its manifest excludes database state and credentials. The installer builder ran the Host Program Files path and privilege guard checks. The adjacent `Ventio-Setup-SHA256SUMS.txt` records the installer checksum.

To reproduce from a clean clone or worktree, fetch the development branch and check out the exact source revision used here. Keep any existing working tree with local changes intact:

```powershell
git fetch origin codex/extension-platform
git checkout --detach c1cc23f3a3d5d16e4abdd928a25d5db28bb81190
Push-Location packages\ventio_native_client
flutter build windows --release
Pop-Location
$buildId = 'wave1-0.1.7-rebuild-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$payload = "packages\ventio_host_api\build\windows\host-payload-$buildId"
$installerOutput = "dist\windows\$buildId"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/build-host-payload.ps1 -PostgresBinDirectory "$env:LOCALAPPDATA\VentioFramework\postgresql-16.15-tools\pgsql\bin" -OutputDirectory $payload
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/build-windows-installer.ps1 -SkipFlutterBuild -ReleaseDirectory packages/ventio_native_client/build/windows/x64/runner/Release -HostPayloadDirectory $payload -InstallerOutputDirectory $installerOutput
Get-FileHash (Join-Path $installerOutput 'Ventio-Setup-0.1.7.exe') -Algorithm SHA256
Get-AuthenticodeSignature (Join-Path $installerOutput 'Ventio-Setup-0.1.7.exe') | Select-Object Status
```

The in-place upgrade branch replaces application files and configures the scoped LAN HTTPS listener; it does not run database provisioning, migration, credential rotation, or Recovery Authority initialization. Isolated regression tests verified preservation of existing DPAPI database settings, Recovery Authority file/owner/reader settings, diagnostics path, loopback HTTP address/port, and a witness-file fixture. Existing certificate retry tests verified the certificate fingerprint remains stable and the private-key ACL stays restricted. The installer was **not** run against this workstation's existing Host installation or product data. The prepared Windows VM must still verify the installed service configuration, effective firewall rule, LAN reachability, and live database/Recovery Authority continuity after an in-place update. Do not uninstall or delete application data to apply this development update.
