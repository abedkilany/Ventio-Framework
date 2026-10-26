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
that attempt. An accepted command returns an opaque scope-local cursor. The
Host takes a transaction-scoped advisory lock for the exact
tenant/company/branch and advances the cursor from committed journal receipts.
The lock is released only at commit or rollback, so concurrent commits in one
scope cannot publish a cursor out of order. A rollback does not consume a
cursor. The durable journal must retain accepted receipts for as long as
clients may resume from a cursor.

## Boundaries

- Only accepted commands are journaled; rejections remain transient.
- No financial posting or arbitrary third-party executable code.
- The cursor orders accepted commands within a scope; this does not yet provide
  an authorized snapshot/delta feed or complete record synchronization.
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


## Transactional authorization provider

`executeAuthorized` resolves a current Principal through trusted server code in
its own READ COMMITTED transaction before reading even an accepted stored receipt.
The persistent API adapter locks current identity and exact-scope permission state
through commit. The older `execute(command, principal)` entry point remains for
trusted development/internal callers and does not itself load persistent policy.
Use the persistent assembly for durable identity enforcement; see
[Persistent Identity](../../docs/PERSISTENT_IDENTITY_V0_1.md).
