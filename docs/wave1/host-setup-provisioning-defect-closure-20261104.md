# Host Setup Provisioning Defect Closure

**Status:** Implementation defect closed; Stage 3 and Stage 10 acceptance remain open.<br>
**Evidence date:** 2026-11-04 (Asia/Beirut)<br>
**Formal Wave 1 acceptance:** 50 / 100<br>
**Fix source commit:** `9bb95852c46eb6159bb56419d03cef2ce7d32259`<br>
**Source tree:** `7c38fcf4480b08de3ca6b21bcb34ae0079a8b501`

## Incident and root cause

The original observed Host Setup event was `HOST_SETUP_PROVISIONING_FAILED`, component `client.host_setup.postgres_service_provisioning`, correlation ID `cor_206a9a891024560b031a3f437e30e1d8`. That exported event exposed only a generic error and a UI component label; it did not identify the failing operation.

A later retry generated a separate event, correlation ID `cor_25f49980d8c563052b40101f164856e0`. Its protected installer diagnostic record, recorded at 2026-11-03 20:41:52 UTC, identifies phase `DATABASE_INITIALIZATION`, failure `HOST_DATABASE_MIGRATION_LEDGER_INVALID`, source `initialize-host-database.ps1`, line 234. The PostgreSQL service had already been registered and was running at 20:41:36 UTC. The retry record is follow-up evidence for the same first-run defect; it is not the original event and the two correlation IDs are not represented as one event.

The source at the failing revision compared the migration ledger count to the hard-coded value `29`, while the packaged migration directory contained 30 SQL migrations, `001` through `030`. Initialization therefore applied all 30 migrations and then rejected the valid 30-row ledger as invalid. The application event's `postgres_service_provisioning` component was misleading: the Setup Broker wrote a null failure phase, and the Flutter page fell back to its last displayed setup step. Thus the service-registration label did not locate the failure. The root cause is supported by the protected retry diagnostic, the exact source check, the 30-file package, and a passing regression run through the same initializer; it is not inferred from the original generic event code.

## Correction

- `initialize-host-database.ps1` now derives the expected ledger count from the packaged `*.sql` migrations and rejects an empty migration package.
- The setup broker allowlists and forwards the specific safe ledger error and retains the latest setup phase in failure status. The Flutter setup page displays an actionable explanation.
- Stop/removal recovery recognizes this exact protected diagnostic for a PostgreSQL-only partial install, allowing safe cleanup while preserving Host data unless the explicit data-removal option is selected.
- The broker test now asserts that `HOST_DATABASE_MIGRATION_LEDGER_INVALID` remains an allowed safe failure code.

## Verification

The automated PostgreSQL regression ran `provision-postgres-service.ps1 -TestInitDbOnly -TestMigrations` against a disposable PostgreSQL 16.15 cluster with all 30 migrations. Database initialization and the 30-entry ledger check passed, followed by migration upgrade, backup verification, least-privilege role authentication, DPAPI configuration validation, and fixture teardown.

Additional checks passed:

- Flutter Host setup tests: **26/26**; `flutter analyze`: no issues.
- Setup Broker .NET tests passed, including the new safe-code assertion.
- Host Service .NET tests passed. The elevated actual `VentioHost` service-SID integration subtest was skipped because this process was not elevated.
- `test-host-new-install-state.ps1`, `test-host-provisioning-failure-record.ps1`, `test-host-removal-diagnostic-archive.ps1`, `test-host-service-config-writer.ps1`, and `test-host-product-data-root.ps1` passed.
- `test-unified-installer-path-contract.ps1` and the builder's Host privilege guard passed. The changed PowerShell scripts parsed successfully and `git diff --check` passed.
- Windows Release and Host payload builds passed. Inno Setup 6.7.3 compiled `dist/windows/host-setup-defect-closure-9bb9585/Ventio-Setup-0.1.1.exe` (**84,868,040 bytes**, SHA-256 `e5f5b206c50230283baad4cc35a5f4fed82f42bd360cf78dbc38000e52da3f66`). The payload manifest contains 1,694 files / 287,248,965 bytes and declares no database or credentials. The four modified provisioning/recovery PowerShell files in the payload have the same SHA-256 values as their files in source commit `9bb9585`.

The installer embeds these setup scripts byte-for-byte from the source commit:

| Packaged script | SHA-256 |
|---|---|
| `initialize-host-database.ps1` | `85588dd2b6e297e14f68408283537ce3fe916733403d0b11db1c8331d56dda92` |
| `provision-host-installation.ps1` | `93f9854c38e36e5af60d8e0647a357295f7a9bdecbd5faade3b54132e13d8fa60` |
| `remove-host-installation.ps1` | `fd1f186218ce9a10737684bad32f47478ebc2e2bc9788944c660d6b6915abf6e` |
| `stop-host-services.ps1` | `7cb0e85d78fa61ad3093f7f7def493351b6f4a1995dca8a14c02de186da46a18` |

`test-postgres-service-plan.ps1` correctly refused to run because a `VentioPostgres` service is already registered on this development workstation. The actual Host installer lifecycle was not run here because the workstation already has Ventio services and product paths; no service or product data was changed by these checks.

The project owner confirms that Host installation now succeeds after the fix. This is owner-provided operational confirmation, not an independently repeated clean-VM lifecycle test in this session.

## Stage evidence and acceptance boundary

This closure supports Stage 3 evidence for the real 30-migration database initialization path, safe failure-code/phase reporting, partial-install recovery, and the owner-confirmed successful setup. It supports Stage 10 evidence for the source-linked Windows Release, Host payload and installer build, verified payload inventory, static installer guards, and the owner-confirmed installation.

Stage 3 remains **IN PROGRESS** and Stage 10 remains **IN PROGRESS** with **zero accepted points**. Mandatory installed lifecycle evidence is still outstanding: clean elevated installation from the unified artifact, actual SCM identity/ACL and service start/readiness, first-administrator and Recovery Authority flow through the installed app, repeat/resume/interruption recovery, reboot persistence, uninstall/data-retention choices, and installed failure-diagnostic export. The elevated service-SID case and clean-host installer lifecycle also remain unverified. The installer is unsigned. No Wave 1 points are awarded by this defect closure; formal acceptance remains **50 / 100**.
