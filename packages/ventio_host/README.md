# Ventio Host v0.1: Durable Operational Commands

This package implements the first durable Host-authoritative command slice.
It deliberately supports **trusted operational record-create commands only**.
The existing `ventio_core` package is not modified.

`DurableCommandHost` takes an already-authenticated, server-constructed
`Principal`, a vetted command registry and a PostgreSQL connection. Each accepted
command writes its operational record, full command receipt, audit entry and
outbox event inside a **single PostgreSQL transaction**. The unique journal key
`(tenant_id, command_id)` serializes concurrent retries, and receipts remain
identical after reconnecting or restarting the Host process.

On a failure before commit, PostgreSQL rolls back every write. If the commit
outcome is unknown (e.g. network interruption), clients must retry the **same**
command ID and byte-equivalent logical envelope; never generate a new ID for
that attempt. An accepted command returns no sync cursor yet because outbox
identity IDs do not establish commit order across transactions.

## Boundaries

- Only accepted commands are journaled; rejections remain transient.
- No public HTTP API, credential verification, durable permission-store,
  financial posting, arbitrary third-party executable code or sync ordering.
- Tenant/company/branch query scoping is enforced by application SQL, **not**
  by PostgreSQL RLS in this initial slice.
- This first slice is intentionally a generic **operational create** executor,
  and refuses precision-sensitive DocTypes. It is NOT a generic ERP posting
  engine for sales, stock and accounting.
- Dependencies require an accepted journal entry in the same tenant, company,
  and branch. Caller must verify permissions at each retry.
- `testFaultInjector` exists only to exercise atomic rollback in disposable
  integration tests; never use it in a production Host.

## Validate on GitHub Actions

Workflow: `.github/workflows/host-durable-commands.yml`

All PostgreSQL integration tests use the disposable database `ventio_host_test`.
To run locally, provision a dedicated database and set
`VENTIO_TEST_DATABASE_URL` and `VENTIO_ALLOW_DATABASE_TESTS=yes`.

```powershell
cd packages/ventio_host
dart pub get
dart format --output=none --set-exit-if-changed lib test
dart analyze .
dart run test/durable_integration.dart
```

Do not run this test against an existing Ventio database or production store.
