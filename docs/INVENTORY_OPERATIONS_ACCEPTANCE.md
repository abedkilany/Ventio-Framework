# Ventio Inventory Operations Final Acceptance

Date: 2026-10-28

Status: **ACCEPTED** on `codex/extension-platform`.

## Acceptance package

The official reference is the ordinary data-only package in `examples/ventio_inventory_operations/extension.json`. It uses the same declarative records, child rows, calculation, naming series, governed operations, report and print-format capabilities available to extension authors. It contains no executable handlers, SQL, uploaded code, inventory-only Core/Host path, or privileged exception.

## Windows SQLite to PostgreSQL Host result

The cross-layer Flutter integration passed **1/1**, exit code **0**, in **1:48** on Windows. It used the disposable PostgreSQL **17.11** cluster bound to `127.0.0.1:55439` and the exact official package JSON. The test guarded every configured connection to loopback and the disposable `ventio_host_test` database. It used no production database.

Before the scenario, the migration runner verified that all reviewed migrations were current and returned no pending migrations. The isolated database security bootstrap had already been successfully applied twice, as recorded in [A04 PostgreSQL acceptance](A04_POSTGRESQL_ACCEPTANCE.md) and [D01 identity acceptance](D01_IDENTITY_ACCEPTANCE.md). The previously completed A10 allocator run passed **6/6**; the generic Host integration using this package passed **137/137**; Core package validation passed **78/78**.

The cross-layer test exercised:

- Normal extension submission and operator approval, then local Windows SQLite installation and activation.
- Offline Product creation and a Movement containing two typed line items; exact calculated total `0.8`; durable queued commands and provisional local values.
- PostgreSQL Host acceptance and SQLite receipt reconciliation for both records.
- Governed Submit with official number `INV-000001`, exact Product quantity change from `90` to `95`, and an identical retry without a duplicate effect or number.
- Host-authorized Product read and a grouped Movement report returning one row and exact sum `0.8`.
- Authenticated Host-record printing through the declarative PDF renderer, producing a valid `%PDF-` document.
- Governed Cancel and reversal to quantity `90`, followed by Amend, a linked local draft, official number `INV-000002`, resubmission, and cancellation of the amended movement. Final quantity returned to `90`; the source and amendment retained their respective official numbers.
- Closing and reopening both SQLite databases, reconciling all seven queued commands as Host-confirmed, and verifying the accepted amendment at Host revision `3`.
- Rebinding a fresh Host API instance and rereading the PostgreSQL-backed record and audit history after the restart boundary.

The end-to-end run exposed a generic Amend recovery edge: replaying the original Amend command while a later command on its linked draft was pending. Core now recognizes the already-linked provisional copy while preserving that follow-up command. The focused SQLite lifecycle test passed **1/1** with regression coverage for same-command replay and replay during a later pending command. Dart analysis of the changed client source and tests reported no issues.

## Verification commands

Run from `packages/ventio_native_client` with the guarded disposable URLs and `VENTIO_ALLOW_DATABASE_TESTS=yes`:

```powershell
flutter test test/official_inventory_host_sqlite_integration_test.dart --reporter expanded
flutter test test/extension_store_test.dart --plain-name 'Amend stores and reconciles a durable local draft copy'
dart analyze lib/src/extension_store.dart test/extension_store_test.dart test/official_inventory_host_sqlite_integration_test.dart
```

No production connection was used. No inventory-specific Core or Host modification was needed.
