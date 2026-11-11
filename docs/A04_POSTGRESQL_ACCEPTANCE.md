# A04 PostgreSQL Host Acceptance Evidence

Date: 2026-10-27

## Environment

- PostgreSQL 17.11 Windows binaries from the EDB archive linked by the [PostgreSQL Windows download page](https://www.postgresql.org/download/windows/).
- A disposable cluster and `ventio_host_test` database were created under the current user's temporary directory.
- The server listened only on `127.0.0.1:55439`, used trust authentication for this temporary local cluster, and was stopped after the test completed.
- No credentials, service installation, or repository data were changed.

## Command

From `packages/ventio_host`:

```powershell
$env:VENTIO_TEST_DATABASE_URL = 'postgres://postgres@127.0.0.1:55439/ventio_host_test?sslmode=disable'
$env:VENTIO_ALLOW_DATABASE_TESTS = 'yes'
dart run test/durable_integration.dart
```

Result: **35 passed, 0 failed**.

## A04-specific evidence

- PostgreSQL Host stored a declared default when the client omitted the field.
- PostgreSQL Host rejected a decimal value beyond declared precision.
- PostgreSQL Host rejected a client override of a read-only field.
- The Host also rejected invalid DocType payloads without persisting business records.

The same integration run verified durable receipt replay, idempotent retries, permission rechecks, tenant isolation, transaction rollback, shared scope cursors, and concurrent retries. These results exercise the durable PostgreSQL Host path rather than only the in-memory Core Host.
