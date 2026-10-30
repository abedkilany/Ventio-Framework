# Windows Unified Installer Test Report

**Date:** 2026-10-30 (UTC)  
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
| Client type install/uninstall | PASS | `scripts/windows/validate-unified-installer.ps1 -InstallerPath dist/windows/Ventio-Setup-0.1.0.exe -SetupType client`; current artifact installed into a unique temporary per-user directory, Host payload was absent, uninstaller removed app files, and external marker remained. |
| Host all-users type install/uninstall | BLOCKED / NOT RUN | Requires an already elevated PowerShell session and the fixed `%ProgramFiles%\Ventio` directory to be absent. No Host installation or Windows service was attempted with the current artifact. Earlier file-selection checks on the previous per-user installer do not verify this changed elevation/path mode. |

Client validation runs in a unique temporary per-user directory. The Host validator targets `%ProgramFiles%\Ventio`, refuses to run if that directory already exists, and requires an already elevated PowerShell session; it has not been run on this artifact. No validator registers or starts Windows services. The Host-per-user guard was verified separately on the current artifact without elevation. An attempt to launch the elevated validator was rejected by the execution policy before creating a UAC prompt or starting a process; no system state changed.

## Deployment path finding

The previous installer design put both types under `%LOCALAPPDATA%`, which did not match the PostgreSQL provisioner's `%ProgramFiles%\Ventio\...` requirement. The current source changes the installer to use `{autopf}`, permits per-user override for Client, blocks Host selection in per-user mode, locks Host's directory to `%ProgramFiles%\Ventio`, and launches the shared Flutter app as the original non-elevated user. The static path-contract test, executable Host-per-user rejection guard, Inno compilation and current-artifact Client install/uninstall pass. The Host all-users install/uninstall remains unverified. This resolves the source-level path mismatch only; it does not provision services or pass the operational Host gate.

## Remaining acceptance work

Host first-run setup, actual elevated Host installation, isolated PostgreSQL service installation, initial administrator bootstrap, Host service registration/start/reboot recovery, authenticated API readiness, Client pairing against the installed Host, upgrade with database backup, explicit service/data-retention uninstall choices and diagnostics export are not implemented or verified. The installer is unsigned. Stage 10 remains IN PROGRESS and contributes zero accepted weight.

The latest database/config run also corrected compatibility gaps with the Windows PowerShell/.NET Framework runtime: secure test-byte creation, quoted process arguments, SQL process input, absolute Windows path checks, DPAPI assembly loading and ACL application. These changes make the isolated integration executable on the Windows host; they do not prove production SCM/service installation.
