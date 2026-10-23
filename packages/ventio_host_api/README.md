> Current launcher requires a separate trusted witness owner and `VENTIO_RECOVERY_AUTHORITY_OWNER_UID`. Use the [current operations guide](../../docs/HOST_ENGINE_V0_1_OPERATIONS.md) for deployment and upgrade; examples below retain their historical stage context. API remains loopback-only.

> Credential lifecycle update: production Host now requires an independent recovery
> authority file and reviewed scoped provisioning. See [Credential Lifecycle and
> Recovery Admission](../../docs/CREDENTIAL_LIFECYCLE_AND_RECOVERY_ADMISSION_V0_1.md).

> Recovery verification: [Crash Recovery](../../docs/HOST_CRASH_RECOVERY_V0_1.md)
> covers real process kills, lost commit acknowledgements and isolated restores.
> This does not certify physical power-loss durability or production deployment.

> Database security update: the persistent Host now requires the restricted
> runtime database profile, protected identity functions and credential-checked
> forced RLS. Administration and migrations use separate connections/capabilities.
> See [Database Security](../../docs/DATABASE_SECURITY_V0_1.md) for setup and explicit limits.

> Persistent identity update: the new `bin/local_host.dart` assembly uses
> PostgreSQL identities, exact-scope grants and permanent device/credential
> revocation, rechecked inside each command transaction. See
> [Persistent identity](../../docs/PERSISTENT_IDENTITY_V0_1.md). The development
> identity-file provider and launcher described below remain test-only; they are
> not used by the persistent assembly. External network deployment remains blocked.

# Ventio Host API v0.1 development slice

This package adds an authenticated HTTP boundary to the existing durable,
trusted operational-create engine. It is an **internal loopback-only prototype**,
not a deployable production authentication system or ERP server.

- `POST /api/v1/commands`: API v1 wrapper around the existing **protocolVersion 0**
  command envelope. The accepted receipt is returned unchanged under `receipt`.
- `GET /healthz`: unauthenticated process liveness only, not database readiness.
- Authorization: one `Authorization: Bearer <opaque-token>` header. No query
  credentials, cookies, browser CORS access, JWT parsing, or anonymous bypass.
- 64 KiB body limit (including chunked requests), depth limit 32, 128 dependencies,
  bounded identifiers, UTF-8 JSON only, no compressed request bodies.
- 10-second total upload deadline; at most 16 admitted requests per process.
- Every response disables caching. Errors contain codes, localization keys and
  English fallbacks. No exception details, request contents or tokens are logged.
- Accepted: HTTP 200. Scope/permission denied: 403. Record/command ID conflict or
  pending dependency: 409. Other business rejection: 422. Invalid wire input: 400.
  Missing/invalid credentials: 401; media: 415; size: 413; upload deadline: 408.
  Infrastructure/ambiguous outcome: 503. A receipt's status remains authoritative.

## Authentication boundary

`HostAuthenticator` is independent of routing, request JSON and persistence.
`DevelopmentTokenAuthenticator` stores only SHA-256 token digests and immutable
server-created Principals. It checks expiry and in-process revocation on every
request. Provision tokens externally with at least 32 random bytes, encoded as
unpadded base64url (43 characters). Expiry is exclusive. Tokens bind actor, device,
tenant, companies, branches and exact permission names. Client claims must match;
they cannot establish identity or grant permissions. The durable engine rechecks
permissions before returning even previously saved receipts.

Development revocation is not persistent or distributed. Existing admitted work
may finish when a token is revoked. Principal company/branch sets grant their
cross-product; provision only intended combinations (prefer one company per
credential). Device identity here is token-bound, not hardware attestation.

`HostApi.bind` always binds `127.0.0.1`; it has no external-bind switch, production
mode, or unauthenticated default. Do not expose it through a public proxy or tunnel.
There is no TLS on this local development listener. Production authentication,
TLS, durable policy/device lifecycle and deployment configuration are future gates.

## Run locally

Run commands from this package directory after `dart pub get`.
Provision the schema separately using the PostgreSQL adapter migration runner.
The API never automatically migrates a database.

Set these private environment variables:

- `VENTIO_ENVIRONMENT=development`
- `VENTIO_ENABLE_DEVELOPMENT_API=yes`
- `VENTIO_HOST_DATABASE_URL`: server-only database URL; include
  `connect_timeout=5&query_timeout=20` as connection parameters. Use TLS verification
  for remote PostgreSQL; local disposable CI uses `sslmode=disable` only.
- `VENTIO_DEVELOPMENT_IDENTITY_FILE`: absolute path to a private JSON file outside
  the repository. Restrict access using operating-system file permissions.
- `VENTIO_HOST_PORT`: optional, defaults to 8080; 0 chooses an available port.

Private identity file structure (all values are illustrative, not credentials):

```json
{
  "tokenDigest": "<64 lowercase hex SHA-256 characters of your random token>",
  "expiresAt": "2026-10-24T00:00:00Z",
  "actorId": "user-001",
  "deviceId": "device-001",
  "tenantId": "tenant-001",
  "companyIds": ["company-001"],
  "branchIds": ["branch-001"],
  "permissions": ["maintenance.create"]
}
```

Then `dart run bin/development_host.dart`. The launcher installs the maintenance
proof module only, never logs secrets, and rejects production or implicit startup.
SIGINT/SIGTERM stop admission and wait for admitted commands to finish before exit.

## Connection ownership and failures

`PostgresCommandExecutor` owns and closes a new connection per command. Routing
limits bound concurrent connections; pooling is intentionally deferred. Server-side
statement and lock limits are 15 and 5 seconds. Configure connection and driver
query timeouts in the server-owned URL. No HTTP timeout cancels a running command
and then pretends it failed to commit. An execution exception always returns 503,
with an unknown-outcome warning: retry the **identical ID and envelope**.

The record, accepted journal receipt, audit and outbox still commit in one
transaction in `ventio_host`; no duplicate journal or alternative command engine
is introduced. No fake sync cursor is exposed. Rejected receipts remain transient.

## Verification

```sh
dart pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib bin test
dart analyze .
dart run test/api_tests.dart
# Only with a disposable database named ventio_host_test and explicit opt-in:
# VENTIO_ALLOW_DATABASE_TESTS=yes VENTIO_TEST_DATABASE_URL=... dart run test/api_integration.dart
```

The original API tests cover authentication, scope forgery, malformed/oversized/slow requests,
concurrency admission, graceful drain, durable replay, conflicting IDs, atomic
rollback, closed DB failure, simulated loss after commit, and actual graceful
server-process restart. Fault injection and simulated result loss are explicitly
not hard in-transaction process-kill or infrastructure failure proofs.

Separate suites now cover persistent authorization/revocation, least-privilege RLS,
and real process kills/restore. See the updates above for their limits. Remaining
gates include production TLS/identity provider, full header/slowloris limits,
rate limiting by identity, pooling, telemetry,
safe sync ordering, financial capabilities and offline
client reconciliation. Do not merge to stable on this slice alone.
