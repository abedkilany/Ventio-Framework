# A10 Document Numbering Acceptance Evidence

Date: 2026-10-27

## Runtime environment

- PostgreSQL **17.11** Windows binaries ran from the temporary test cluster under the current user's `%TEMP%` directory.
- The cluster listened only on `127.0.0.1:55439`; the only database used was the guarded disposable `ventio_host_test` database.
- No Windows service or Docker container was used. The test cluster was stopped after the run.
- Applied the pending migration `024_document_number_series.sql`, then ran `security/postgres/bootstrap.sql` twice with `expected_database=ventio_host_test`.
- Reused the dedicated test logins already present in that disposable cluster. Runtime and identity-admin connections authenticated with SCRAM-SHA-256 and reported the expected `current_user` values. The local cluster administrator remained available over loopback for test setup and observation.
- The runtime and identity-admin passwords are test fixtures; no credential value is recorded here.

## Acceptance checks

From `packages/ventio_host_api`:

```powershell
$env:VENTIO_TEST_ADMIN_DATABASE_URL = 'postgres://postgres@127.0.0.1:55439/ventio_host_test?sslmode=disable'
$env:VENTIO_ALLOW_DATABASE_TESTS = 'yes'
dart run test/document_number_allocator_integration.dart
```

Result: **6 passed, 0 failed**. This verifies transactional allocation and rollback without consuming a number, distinct sequential numbers under concurrent transactions, rejection of live-series prefix changes without consuming a number, and independent numbering per branch.

The full PostgreSQL extension integration also passed **119/119** with SCRAM-authenticated runtime and restricted identity-admin logins. Its ordinary extension creator submitted declarative `Product` and `Movement` DocTypes, including a naming-series field, a typed multi-row `lines` Child Table, and governed Submit/Cancel operations. It verified that a failed stock effect rolled back product updates, movement status, journal and number allocation; a corrected retry atomically applied the saved rows, changed status, and returned `INV-000001`; concurrent Submit commands shared one receipt and applied once; replay returned the saved receipt without repeating effects; Cancel reversed stock once and preserved the official number; and replaying Cancel did not duplicate the reversal. See [K06 acceptance evidence](K06_GOVERNED_OPERATIONS_ACCEPTANCE.md) for the full operation evidence.

Local client evidence:

- `flutter test test/extension_store_test.dart`: **37 passed**, including accepted governed-operation receipt reconciliation of document status and the official number.
- `flutter test test/extension_studio_test.dart`: **27 passed**, including ordinary DocType Builder numbering/lifecycle authoring and durable operation-command recovery.
- Targeted Flutter analysis of the changed Studio/store files and tests: **no issues found**.

The temporary PostgreSQL server was stopped after the evidence was collected. No A10 acceptance claim depends on elapsed time or test execution alone; the declarative configuration, offline provisional name, server allocation, rollback/concurrency, retry, and client receipt reconciliation all passed their respective checks.

## Checkpoints

- Host numbering primitive and migration: `7b6aaf6`.
- PostgreSQL resolver correction and integration fixture fixes: `0cb5019`.
- Studio lifecycle/numbering authoring and client receipt reconciliation: `78b23ac`.
