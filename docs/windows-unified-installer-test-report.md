# Windows Unified Installer Test Report

**Date:** 2026-10-30 (UTC)  
**Artifact:** `dist/windows/Ventio-Setup-0.1.0.exe`  
**SHA-256:** `730f597f58c2497e310587009e72645311f6e1993aac2edabcfeedd908a2b0f3`  
**Size:** 63,333,166 bytes  
**Build:** Inno Setup 6.7.3; reproducible source in `installer/windows/ventio.iss` and `scripts/windows/build-windows-installer.ps1`.

## Evidence

| Check | Result | Evidence |
|---|---|---|
| Host payload inventory and critical hashes | PASS | 1,680 files / 212,081,806 bytes; 16.15 version and all critical hashes validated before compilation. No credentials or database files in payload. |
| PostgreSQL runtime payload | PASS | Temporary SCRAM cluster initialized, started on loopback, passed readiness/authenticated SQL, then stopped and removed. |
| Host DB initialization | PASS | Migrations 001–029 and security bootstrap passed; runtime and Identity API roles authenticated and passed non-superuser/membership checks. |
| Protected Host config | PASS | Generated database credentials were accepted by the compiled service validator in a LocalMachine DPAPI file; plaintext scan found neither password. |
| PostgreSQL service plan | PASS | `scripts/windows/test-postgres-service-plan.ps1`; no service, system configuration or product data changed. |
| Inno Setup compilation | PASS | `scripts/windows/build-windows-installer.ps1 -SkipFlutterBuild`; artifact checksum recorded above. |
| Client type install/uninstall | PASS | `scripts/windows/validate-unified-installer.ps1 -InstallerPath dist/windows/Ventio-Setup-0.1.0.exe -SetupType client`; installed app present, Host payload absent, uninstaller removed app files, external marker retained. |
| Host type install/uninstall | PASS | Same validator with `-SetupType host`; Flutter app, Host Engine, migration runner, service executable, PostgreSQL binaries and migrations installed; pgAdmin/StackBuilder absent; uninstaller removed app files, external marker retained. |

The validator runs both types in unique temporary per-user install directories. These tests do not register or start Windows services. They prove installer type selection and file inclusion only; they do not pass the operational Host installation gate.

## Deployment path finding

The Host component is installed below `{app}\host-payload`; `{app}` defaults to `%LOCALAPPDATA%\Programs\Ventio` and the installer uses `PrivilegesRequired=lowest`. The production `provision-postgres-service.ps1 -Apply` path currently accepts the PostgreSQL payload only under `%ProgramFiles%\Ventio\...`. As a result, the current Host installer output cannot be passed directly to the production PostgreSQL provisioner. The test runs above did not detect this because they validate temporary file selection and separately test PostgreSQL process/database behavior. A fixed elevated staging bridge or a revised installer path/elevation design and an end-to-end path-contract test are required before Host provisioning can be accepted.

## Remaining acceptance work

Host first-run setup, elevation boundary, isolated PostgreSQL service installation, initial administrator bootstrap, Host service registration/start/reboot recovery, authenticated API readiness, Client pairing against the installed Host, upgrade with database backup, explicit service/data-retention uninstall choices and diagnostics export are not implemented or verified. The installer is unsigned. Stage 10 remains FAIL and contributes zero accepted weight.
