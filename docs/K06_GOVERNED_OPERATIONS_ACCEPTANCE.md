# K06 Governed Business Operations Acceptance Evidence

Date: 2026-10-27

## PostgreSQL runtime environment

- Reused the disposable Windows PostgreSQL **17.11** cluster under the current user's temporary directory, listening only on `127.0.0.1:55439`.
- Used only the disposable `ventio_host_test` database. Migration `024_document_number_series.sql` had already been applied to this cluster; the guarded `security/postgres/bootstrap.sql` was reapplied twice with `expected_database=ventio_host_test` to install the current security functions and policies.
- The Host integration used the dedicated runtime and restricted identity-administration logins over SCRAM. The isolated allocator test used the temporary cluster administrator only for its direct transaction fixture.
- No service or Docker container was used. The temporary PostgreSQL process was stopped after the checks. No production database was contacted.

## Governed multi-row operation checks

From `packages/ventio_host_api`:

```powershell
$env:VENTIO_TEST_DATABASE_URL = 'postgres://postgres@127.0.0.1:55439/ventio_host_test?sslmode=disable'
$env:VENTIO_TEST_ADMIN_DATABASE_URL = 'postgres://ventio_admin_test:<test-password>@127.0.0.1:55439/ventio_host_test?sslmode=disable'
$env:VENTIO_TEST_RUNTIME_DATABASE_URL = 'postgres://ventio_runtime_test:<test-password>@127.0.0.1:55439/ventio_host_test?sslmode=disable'
$env:VENTIO_ALLOW_DATABASE_TESTS = 'yes'
dart run test/extension_package_integration.dart
```

Result: **119 passed, 0 failed**. The ordinary extension package declares a typed `Movement.lines` Child Table and bounded `record.increment_rows` Submit/Cancel effects. Two saved rows that reference the same Product are deterministically combined and applied as one target update. The operation does not receive or trust a second client-supplied copy of those rows.

The runtime integration verifies:

- Missing exact-scope Submit permission rejects before number allocation, product mutation, status change, or journal acceptance.
- A failed effect rolls back target data/revision, parent status/revision, official number allocation, journal, audit, and outbox transaction effects; a corrected command can retry.
- Two concurrent identical Submit commands return the same accepted receipt, allocate `INV-000001` once, and apply the saved rows once.
- Replaying accepted Submit does not repeat any target effect; Cancel reverses the rows once and preserves the official number; replaying Cancel does not repeat the reversal.
- Target record and field permissions, exact-scope authorization, RLS, recovery admission, and tamper rejection remain enforced.

## Supporting checks

- Core contract harness: **73/73**.
- PostgreSQL document-number allocator integration: **6/6**, including rollback without number consumption, unique concurrent numbering, immutable live series configuration, and branch partitioning.
- `flutter test test/extension_store_test.dart`: **37/37**, including governed-operation receipt reconciliation for status/official number, offline edits, restart persistence, and typed child rows.
- `flutter test test/extension_studio_test.dart`: **27/27**, including typed child-row editing, parent queueing, durable operation-command recovery, and ordinary Builder authoring.
- Targeted Dart analysis of the Core contract, bundle validator, Host interpreter, and PostgreSQL integration test: no issues.

K06 is accepted as **COMPLETED / Newly Implemented**. The separate B04, F02, F01, G01, and Ventio Inventory Operations acceptance gates remain open.
