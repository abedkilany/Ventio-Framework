# Installed Host Upgrade Integration Review — 2026-11-06

## Result

The Ventio 0.1.8 installer did **not** execute `upgrade-host-database.ps1` when updating an existing Host. In `installer/windows/ventio.iss`, `PrepareToInstall` stopped both services, then `CurStepChanged(ssPostInstall)` ran `enable-host-lan-listener.ps1 -RestartServices` directly. The database-upgrade script contained the pairing SQL application and verification, but the installed installer lifecycle did not reach it. This was a deployment integration defect.

The installer path is corrected for the new development version 0.1.9. When both existing Host and PostgreSQL services are present, the lifecycle now:

1. Stops both services before replacing files.
2. Starts PostgreSQL only using the installed-service recovery helper; Host stays stopped.
3. Runs `upgrade-host-database.ps1 -Apply` against the existing Host data directory.
4. Requires the script's restricted data backup verification, migration ledger verification, pairing SQL application, and pairing contract verification to return success.
5. Only after that success runs the HTTPS/LAN listener setup that restarts Host.

If PostgreSQL cannot start, the database helper is missing, or backup/migration/contract verification fails, the installer does not call the Host restart path. Its deinitialization path resumes PostgreSQL only and leaves `VentioHost` stopped for recovery. The database upgrade script is responsible for restarting PostgreSQL after its backup attempt; the recovery call is idempotent for the service. No database reset, Recovery Authority rewrite, credential regeneration, certificate replacement, or service identity change is introduced by this integration.

## Evidence

| Requirement | Result | Evidence |
|---|---|---|
| Old 0.1.8 installer calls the database upgrade before Host restart | **FAIL (confirmed historical defect)** | Source lifecycle review of `installer/windows/ventio.iss` showed only the LAN helper after file replacement. |
| Updated installer invokes database upgrade before Host restart | **PASS (source contract)** | `scripts/windows/test-unified-installer-path-contract.ps1` asserts PostgreSQL-only resume precedes `upgrade-host-database.ps1 -Apply`, which precedes LAN `-RestartServices`. |
| Upgrade requires a verified restricted backup and complete migration ledger | **PASS (upgrade script + disposable DB test)** | `upgrade-host-database.ps1` verifies backup inventory, migration output/ledger, and pairing function definition before returning success. The pairing integration runner applies the function as the restricted migration login and verifies the installed SQL contract in a disposable PostgreSQL 16.15 cluster. |
| Host is not restarted on upgrade failure | **PASS (source contract / installer build)** | The Inno Setup path marks database upgrade failure, exits before LAN setup, and `DeinitializeSetup` chooses `-ResumePostgresOnly` when that flag is set. The Host-restart ordering and failure branch are covered by the installer path contract. |
| Actual Windows service upgrade on isolated service names/data | **BLOCKED** | This development computer currently has `VentioHost` and `VentioPostgres` running, existing `Program Files\Ventio` and `ProgramData\Ventio` directories, and the current shell is not elevated. Running the fixed-name installer or service lifecycle test here would modify the active installation, so it was not attempted. An isolated Windows VM or clean disposable Windows machine with Administrator access is required for service-level proof. |
| Physical Host/Client acceptance | **NOT RUN** | No physical deployment, pairing, enrollment, or Host-authoritative business sync was performed for this installer integration follow-up. |

The prior Crash Recovery integration suite remains an explicitly open verification item. Its earlier run passed the crash/restart checks through `after_commit` but stopped at the duplicate-worker wait while the shared Recovery Authority witness was pending. No claim is made that this suite passed.

## Safe owner upgrade procedure

Do not uninstall Ventio or delete anything under `ProgramData\Ventio`. Before installation, compare the version and SHA-256 supplied with the 0.1.9 development installer. Run it elevated over the existing installation. The installer makes a restricted PostgreSQL data backup and verifies it before migration. If backup, migrations, or pairing function verification fail, it displays a failure message, leaves `VentioHost` stopped, and keeps PostgreSQL available for repair; do not manually start `VentioHost` until the upgrade is repaired and verified.

After a successful update, verify both services retain their existing service identities, all four Host readiness components are READY, HTTPS certificate validation succeeds from the separate Client, pairing creation succeeds, and an enrolled Client receives Host-authoritative synchronization receipts. The development installer remains unsigned and is not a production-signed release.
