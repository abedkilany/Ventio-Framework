> Historical stage evidence. Current launcher settings, separate OS witness ownership, schema compatibility and witness upgrade requirements are defined in [Host operations](HOST_ENGINE_V0_1_OPERATIONS.md). See the [final engineering audit](HOST_ENGINE_V0_1_FINAL_ENGINEERING_AUDIT.md) for the current acceptance boundary.

> Database hardening supersedes the earlier direct-SQL administration details:
> IdentityAdministration now invokes a protected audited database function, and
> the persistent runtime uses a separate restricted login with forced RLS.
> See DATABASE_SECURITY_V0_1.md for the current deployment boundary.

# Persistent identity, authorization and device revocation

## Implemented boundary

The local Host can now resolve user/device identity and exact-scope permissions
from PostgreSQL. It never uses Client identity/permission JSON as authority. The
new `bin/local_host.dart` assembly uses only `PersistentTokenAuthenticator` and
`PersistentCommandExecutor`; it has no identity-file or development-auth fallback.
The HTTP listener still binds only to `127.0.0.1`. No external bind option, public
login, provisioning route or administration endpoint was added.

Migrations 006-011 add users, device ownership, opaque credentials, registered
company/branch tuples, exact permission grants and security-change audit. Existing
001-005 files and Core contracts remain unchanged. Foreign keys include tenant
and device owner, preventing cross-tenant ownership or mismatched scope grants.
The migration runner remains ordered, checksummed and single-statement. Existing
records and command receipts are not rewritten. Old five-migration persistence
tests now compare the ledger with the actual application-owned migration files.

## Credentials and provisioning

`IdentityAdministration` is a privileged **server maintenance library**, not a
Client API. The authenticated database login is its administrative authority;
`operatorLabel` is an audit label, never a claim to authenticate a human admin.
Use a private server operator connection, not Client database credentials. An
operator must explicitly register the user, device and company/branch tuple,
grant named permissions, and issue a credential. There is no default admin,
automatic enrollment or implicit permission grant.

Issuance generates 32 cryptographically random bytes as an unpadded base64url
bearer token and returns the raw token once to the trusted provisioning caller.
Only SHA-256 digests are stored. Never log tokens or put them in repository files,
command-line arguments, query URLs or audit details. Provision them to the intended
device through a trusted channel. Credentials have a required finite expiration.
A new credential ID cannot overwrite an existing or revoked credential.

Example server-only provisioning sequence (run with a private administrative
connection after applying migrations):

```dart
final admin = IdentityAdministration(
  connection: operatorConnection,
  tenantId: 'tenant-001',
  operatorLabel: 'local-operator',
);
await admin.createUser('user-001');
await admin.registerBranch('company-001', 'branch-001');
await admin.registerDevice('user-001', 'device-001');
await admin.grant('user-001', 'company-001', 'branch-001', 'maintenance.create');
final token = await admin.issueCredential(
  actorId: 'user-001',
  deviceId: 'device-001',
  credentialId: 'credential-001',
  expiresAt: DateTime.now().toUtc().add(const Duration(hours: 8)),
);
// Deliver token through the trusted provisioning channel; never print it.
```

Permanent withdrawal is explicit: `revokeDevice`, `revokeCredential` or
`disableUser`. Revocation tombstones are retained; no delete/re-enable/reassign
operation exists in this library. A revoked device cannot obtain a new credential.
To replace a device, provision a new device ID. Duplicate user/device creation
fails rather than reviving an old identity. Grant removal and regranting are
explicit audited policy changes. Revocation methods are idempotent.

## Transaction and concurrency semantics

HTTP authentication performs a fresh database lookup for every request. The
resulting `AuthenticatedSession` is only an identity snapshot and digest handle;
it is not the final permission authority. `PersistentCommandExecutor` ignores
snapshot grants and calls `DurableCommandHost.executeAuthorized` to resolve the
current identity and exact company/branch permissions **inside the command's own
READ COMMITTED transaction**, before any journal read, reservation or effect.
This applies equally to new commands and saved-receipt retries. No permissions are
cached across requests or Host processes. A development executor explicitly
refuses persistent sessions, and the persistent executor refuses development-only
Principals, preventing accidental fallback during assembly.

Resolution takes shared row locks in a fixed order: user, device, credential,
ordered grants. All administration of an existing user's security state first
takes an exclusive lock on that user. Authorization locks last until command
commit/rollback. Therefore:

- A command that has already obtained valid authorization locks may finish before
  a concurrent revocation. Revocation waits for it; it cannot undo committed work.
- Once revocation or permission withdrawal commits and returns, subsequent
  executions and receipt retries see the new state and are denied.
- An HTTP request authenticated earlier but waiting to execute is rechecked; its
  old Principal does not preserve access.
- Expiration is evaluated with PostgreSQL `clock_timestamp()` after lock waits,
  not the transaction-start time or the Client clock. Validity is checked at the
  transactional authorization point; it does not cancel work already authorized.
- Grants are selected by the complete `(tenant, actor, company, branch)` tuple.
  Grants for `(company A, branch A)` and `(company B, branch B)` never grant the
  unintended pair `(company A, branch B)`.

Database/protocol failure denies access with HTTP 503, never development grants.
Unknown, expired, disabled or revoked identities yield 401; scope/permission denial
is 403. The stored accepted receipt is never returned before current authorization.
Rejected commands retain the engine's existing transient-receipt semantics.

Security changes and their audit records commit in one transaction. Audit records
capture the actual `session_user` database identity, the operator label, action,
subject and non-secret details. A failed audit insert rolls back its policy or
revocation change. This is database durability, not a tamper-proof external audit
archive: trusted database administrators remain privileged.

PostgreSQL semantics consulted:
- https://www.postgresql.org/docs/16/explicit-locking.html
- https://www.postgresql.org/docs/16/functions-datetime.html

## Run the persistent local Host

From `packages/ventio_host_api`, apply migrations separately using the PostgreSQL
adapter. Set `VENTIO_ENABLE_LOCAL_HOST=yes`, a private `VENTIO_HOST_DATABASE_URL`,
and optional `VENTIO_HOST_PORT` (default 8080, 0 for an ephemeral port). Then run:

```sh
dart run bin/local_host.dart
```

The launcher enforces 5-second connection and 20-second driver query timeouts;
authentication and execution connections additionally have 15-second server
statement and 5-second lock limits. It installs the maintenance proof module only.
SIGINT/SIGTERM drain admitted requests. `/healthz` remains process liveness, not
identity-store readiness. `development_host.dart` remains an explicitly enabled
legacy development fixture and is not the persistent runtime.

## Verification and remaining limits

`test/identity_integration.dart` uses an explicitly opted-in disposable
`ventio_host_test` database. It tests persisted grants and identities, scope
forgery, cross-company branch mixing, stale sessions, accepted-receipt permission
rechecks, individual credential and device revocation, user disablement, expiry
while blocked on a lock, audit rollback, revocation/policy races and real separate
Host process restarts. It checks fail-closed behavior and prevents development
fallback. Existing API, durable-command, adapter and Core suites remain required.

This slice does not make the Host production-ready. Remaining gates include
external TLS and trusted enrollment delivery, production administrator identity
and role management, DB role/RLS hardening and enforcement against out-of-band SQL
policy edits, credential storage on Clients, rate limiting, pooling, metrics,
header limits, hard-kill/restore tests and production migration rollout. The
server-only administration library must not be exposed as a Client endpoint.
No change is made to `main`, `v0.2.0`, the legacy Ventio app or live store data.
