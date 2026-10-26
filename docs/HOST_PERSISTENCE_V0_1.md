> Historical stage evidence. Current launcher settings, separate OS witness ownership, schema compatibility and witness upgrade requirements are defined in [Host operations](HOST_ENGINE_V0_1_OPERATIONS.md). See the [final engineering audit](HOST_ENGINE_V0_1_FINAL_ENGINEERING_AUDIT.md) for the current acceptance boundary.

# Ventio Host Persistence — First Slice (v0.1, review candidate)

## Scope

This patch adds `ventio_postgres`, a separate server-side Dart package, and the
first versioned PostgreSQL schema. The stable `ventio_core` package is unchanged.

- Five checksum-verified, ordered, single-statement migrations.
- Composite scope keys on stored operational records.
- Write/read adapter with parameterized SQL.
- Tables reserved for command journal, audit entries, and transactional outbox.
- An integration test that checks migrations, duplicate IDs, scope filtering,
  transaction rollback, and committed-data visibility across connections.
- A dedicated GitHub Actions workflow using an ephemeral PostgreSQL 16 service.

## Not yet implemented

**This patch does not implement a durable Host command processor.** The
in-memory command executor remains unchanged; journal/audit/outbox tables are
not written by commands yet. A later slice must write records, receipt,
audit, outbox, and idempotency key inside ONE database transaction and handle
concurrent retries. It must authenticate principals at the server boundary.

No production API, pooling, row-level security, high availability, sync cursor,
financial posting, or automatic crash recovery is claimed here. Outbox IDs are
not guaranteed commit-order sync cursors.

## Apply patch to the existing feature branch

Extract the supplied patch archive at the **repository root** while on
`feature/host-engine-v0.1`. It only adds new paths and does not replace Core.

```powershell
git status --short
cd packages/ventio_postgres
dart pub get
dart format --output=none --set-exit-if-changed lib bin test
dart analyze .
```

Do not apply migrations to production or the existing Ventio data store.
Use a NEW, disposable PostgreSQL database named `ventio_host_test` for tests.
Configure `VENTIO_TEST_DATABASE_URL` and `VENTIO_ALLOW_DATABASE_TESTS=yes`
for integration tests. CI creates this database automatically on GitHub.

```powershell
# Inside packages/ventio_postgres
$env:VENTIO_TEST_DATABASE_URL = "postgresql://ventio:password@localhost:5432/ventio_host_test?sslmode=disable"
$env:VENTIO_ALLOW_DATABASE_TESTS = "yes"
dart run test/postgres_integration.dart
```

For migrations in an independently provisioned development database, set
`VENTIO_DATABASE_URL`, then run `dart run bin/migrate.dart`. Migration SQL
is committed to source control; every applied file's SHA-256 is recorded in
`ventio_schema_migrations`. Modified migrations cause a hard failure.

## Security notes

Use local/test-only credentials for examples. Never commit passwords or `.env`
files. Use `sslmode=verify-full` with a trusted CA for remote databases.
SQL parameters must be bound; do not interpolate identifiers or payload values
from clients. Database credentials are server-side only.

