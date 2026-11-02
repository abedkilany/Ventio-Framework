# Windows Unified Installer Test Report

## Current checkpoint — 2026-11-02

The latest unified development artifact is `dist/windows/wave1-gitpush-20261102-stackbuilder-fix/Ventio-Setup-0.1.0.exe`, built from source commit `8f50e8cf618d18e5dff99b0f9a63d9db485d73c7` (84,878,879 bytes; SHA-256 `1fe6c68d85c806d06b3fcfbf03f794760858a50c781ecdd0f358cc5772f6ffc6`; Authenticode `NotSigned`). Its Host payload contains 1,694 files / 287,245,613 bytes, with 61 critical hashes verified and the StackBuilder executable excluded. The build toolchain was Flutter 3.44.1 / Dart 3.12.1, Visual Studio Build Tools 2026 18.4.0 / Windows SDK 10.0.26100.0, .NET SDK 8.0.421, and Inno Setup 6.7.3. The current Inno source installs the shared Flutter application and Host payload in the protected machine-wide directory. The app's first-run page offers Host setup or Client connection; the installer has no type selector by design. The Inno compiler printed “Non-commercial use only”; commercial licensing remains unverified.

The former `validate-unified-installer.ps1 -SetupType client|host` argument only changed the test label, not installer behavior. That misleading argument has been removed. The unified validator now describes one shared-app/Host-payload install and uninstall. The current unified artifact has not been installed because validation requires a clean elevated Windows host; this workstation has an unelevated token and registered Ventio services/product paths.

Current local evidence: `test-unified-installer-path-contract.ps1` and the artifact-specific `test-unified-installer-host-privilege-guard.ps1` pass; the fresh Flutter Windows Release, Host payload, critical-hash verification and Inno compilation passed. The Host/Client integration run `20261102174911885-1` passed live Flutter Client enrollment UI against Host over pinned HTTPS; independent offline sync run `20261102175443262-1` passed 1/1. The separately built per-user Client package has its own install/repeat/upgrade/uninstall evidence, which is supplementary and does not prove the unified artifact lifecycle.

The latest build excluded `postgresql\bin\stackbuilder.exe` from the payload after an inventory review found it in an earlier build despite the existing exclusion manifest. The payload builder now removes it only inside its generated isolated staging directory; the installer build and lifecycle validator both reject it if present. Rebuilding passed the static contract test, PowerShell parser checks, payload inventory and critical hashes. No install or service lifecycle was attempted because the validator requires an already elevated shell and a clean Windows environment.

The matrix and artifact below are historical evidence from the 2026-10-30 installer source and must not be read as a result for the 2026-11-02 unified artifact.

**Date:** 2026-10-30 (UTC)  

## Historical Host standalone update — 2026-10-31

The latest development installer is `dist/windows/host-standalone-readiness-20261031/Ventio-Setup-0.1.0.exe` (84,906,485 bytes; SHA-256 `4697ae82da0993494b14979a842c9a2083312b9fef5ea5e8f18aaceb6234c6f7`). It compiles with Host provisioning deferred until Host is selected and includes PostgreSQL 16.15 without a database or credentials. It is unsigned and has not been installed on a clean VM. The current Host standalone milestone remains BLOCKED pending clean-VM UAC/setup, reboot and network TLS checks; see `docs/wave1/host-standalone-readiness-20261031.md`. The test matrix below records the earlier 2026-10-30 artifact and remains historical evidence for those checks.

**Artifact:** `dist/windows/Ventio-Setup-0.1.0.exe`  
**SHA-256:** `23483ab386aaaa4910e1a60ecda7f0cb90b06bab87348ecad56cb1370b9a638d`
**Size:** 63,333,918 bytes
**Build:** Inno Setup 6.7.3; reproducible source in `installer/windows/ventio.iss` and `scripts/windows/build-windows-installer.ps1`.

## Evidence

| Check | Result | Evidence |
|---|---|---|
| Host payload inventory and critical hashes | PASS | 1,680 files / 212,081,806 bytes; 16.15 version and all critical hashes validated before compilation. No credentials or database files in payload. |
| PostgreSQL runtime payload | PASS | Temporary SCRAM cluster initialized, started on loopback, passed readiness/authenticated SQL, then stopped and removed. |
| Host DB initialization | PASS | Migrations 001–029 and security bootstrap passed; runtime and Identity API roles authenticated and passed non-superuser/membership checks. |
| Protected Host config | PASS | Generated database credentials were accepted by the compiled service validator in a LocalMachine DPAPI file; plaintext scan found neither password. |
| PostgreSQL service plan | PASS | `scripts/windows/test-postgres-service-plan.ps1`; no service, system configuration or product data changed. |
| PostgreSQL/database/config integration under Windows PowerShell | PASS | `scripts/windows/provision-postgres-service.ps1 -TestInitDbOnly -TestMigrations`; a temporary SCRAM cluster passed readiness/authenticated SQL, migrations 001–029, security bootstrap, runtime and Identity API least-privilege logins, bootstrap credential retirement, protected DPAPI configuration and compiled service-config validation. Temporary DB/config removed; no service registered. |
| Host config writer security regression | PASS | `scripts/windows/test-host-service-config-writer.ps1`; restrictive ACL, DPAPI validation and plaintext fixture-secret absence passed. |
| Inno Setup compilation | PASS | `scripts/windows/build-windows-installer.ps1 -SkipFlutterBuild`; artifact checksum recorded above. |
| Host/Client installation path contract | PASS | `scripts/windows/test-unified-installer-path-contract.ps1`; Host all-users path is fixed to `%ProgramFiles%\Ventio`, matching the PostgreSQL provisioner; Client per-user path remains under LocalAppData; Host per-user mode is guarded in installer code. |
| Host per-user privilege guard | PASS | Builder ran `scripts/windows/test-unified-installer-host-privilege-guard.ps1`; the current artifact returned nonzero, logged `HOST_INSTALL_REQUIRES_ADMIN_MODE`, created no installation directory, and left Ventio service state unchanged. |
| Historical Client per-user install/uninstall | PASS | Earlier validator/source checkpoint installed the Client-only payload into a unique temporary per-user directory; Host payload was absent, the uninstaller removed app files, and an external marker remained. This is not evidence for the 2026-11-02 unified artifact or its current validator. |
| Host all-users type install/uninstall | BLOCKED / NOT RUN | Requires an already elevated PowerShell session and the fixed `%ProgramFiles%\Ventio` directory to be absent. No Host installation or Windows service was attempted with the current artifact. Earlier file-selection checks on the previous per-user installer do not verify this changed elevation/path mode. |

Client validation runs in a unique temporary per-user directory. The Host validator targets `%ProgramFiles%\Ventio`, refuses to run if that directory already exists, and requires an already elevated PowerShell session; it has not been run on this artifact. No validator registers or starts Windows services. The Host-per-user guard was verified separately on the current artifact without elevation. An attempt to launch the elevated validator was rejected by the execution policy before creating a UAC prompt or starting a process; no system state changed.

## Deployment path finding

The previous installer design put both types under `%LOCALAPPDATA%`, which did not match the PostgreSQL provisioner's `%ProgramFiles%\Ventio\...` requirement. The current source changes the installer to use `{autopf}`, permits per-user override for Client, blocks Host selection in per-user mode, locks Host's directory to `%ProgramFiles%\Ventio`, and launches the shared Flutter app as the original non-elevated user. The static path-contract test, executable Host-per-user rejection guard, Inno compilation and current-artifact Client install/uninstall pass. The Host all-users install/uninstall remains unverified. This resolves the source-level path mismatch only; it does not provision services or pass the operational Host gate.

## Remaining acceptance work

Host first-run setup, actual elevated Host installation, isolated PostgreSQL service installation, initial administrator bootstrap, Host service registration/start/reboot recovery, authenticated API readiness, Client pairing against the installed Host, upgrade with database backup, explicit service/data-retention uninstall choices and diagnostics export are not implemented or verified. The installer is unsigned. Stage 10 remains IN PROGRESS and contributes zero accepted weight.

The latest database/config run also corrected compatibility gaps with the Windows PowerShell/.NET Framework runtime: secure test-byte creation, quoted process arguments, SQL process input, absolute Windows path checks, DPAPI assembly loading and ACL application. These changes make the isolated integration executable on the Windows host; they do not prove production SCM/service installation.
