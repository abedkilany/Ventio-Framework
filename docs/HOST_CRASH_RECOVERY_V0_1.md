# Host crash recovery and backup/restore verification v0.1

> Updated admission boundary: see [Credential Lifecycle and Recovery Admission](CREDENTIAL_LIFECYCLE_AND_RECOVERY_ADMISSION_V0_1.md).
> The historical atomicity suite now uses an explicitly guarded test-only identity
> launcher for unconfigured databases. The lifecycle suite separately tests the
> current production launcher with enforced independent recovery evidence.

Status: experimental, loopback-only Host. This verification does not authorize
network exposure or production deployment. All destructive tests use disposable
`ventio_host_test` databases, never application databases.

## Recovery contract

An accepted command's record, command-journal reservation/fingerprint/receipt,
business audit and outbox entry share one PostgreSQL transaction. The Host sends
an accepted response only after its driver acknowledges COMMIT. Killing a Host
before commit must leave none of these effects; killing it after commit must
leave all of them. Repeating the **same command ID and unchanged envelope** under
current authorization returns the stored receipt without duplicating effects.
A missing response, connection error or HTTP 503 is an unknown outcome, not proof
of rollback. The client must retain and retry that same envelope, not mint a new
ID. Dependency/revision rules and payload fingerprints continue to apply.

This is atomic, deduplicated application of a retained command in this database.
It is not exactly-once HTTP delivery or exactly-once external side effects.
Authorization is revalidated before journal access on every retry. A revoked or
expired credential, revoked device or withdrawn permission can prevent receipt
retrieval; an operator must reconcile the command through an authorized process.
Restarts do not grant access or recreate identities from client claims.

## Executable evidence

`.github/workflows/host-recovery.yml` runs PostgreSQL 16 and
`packages/ventio_host_api/test/recovery_integration.dart` independently from the
existing Core, PostgreSQL, Durable Host and Host API workflows. Existing suites
remain enabled. The dedicated job checks `fsync`, `full_page_writes` and
`synchronous_commit` are on before crashing anything.

| Failure | Mechanism | Expected evidence |
| --- | --- | --- |
| Host during command | Separate Dart process receives SIGKILL after reservation, record, audit, outbox, or immediately before COMMIT | No committed partial effects; restarted persistent identity fixture applies once |
| Host after commit, before HTTP success | SIGKILL at post-COMMIT barrier | Four effects retained; restarted identity fixture returns identical stored receipt |
| Concurrent failures | Duplicate command waits on real PostgreSQL unique-key lock; precommit and unrelated postcommit workers receive SIGKILL together | Waiting duplicate finishes; both commands reconcile once |
| Commit never sent | Local PostgreSQL wire proxy withholds the actual COMMIT query then destroys sockets | No false success; original-envelope retry applies once |
| Commit acknowledgement lost | Proxy forwards COMMIT, observes PostgreSQL `CommandComplete COMMIT`, suppresses acknowledgement and destroys sockets | No false success; retry returns the already committed receipt |
| Command backend dies | `pg_terminate_backend` while command is paused before commit | No accepted response or partial effects; retry succeeds |
| PostgreSQL server dies | Docker SIGKILL to PostgreSQL PID 1, restart same container/volume with one uncommitted and one committed command | WAL recovery discards the former, retains the latter; retry preserves receipt and single effects |
| Logical restore | Real `pg_dump -Fc`, roles-only/sequence-ACL snapshots, `pg_restore --create --exit-on-error` into a new PostgreSQL container/port | Exact data/security manifest match before any security repair; persistent identity fixture replay and new writes succeed |

The async test barriers are optional `testFaultInjector` callbacks. Production
launchers never supply them or read a crash-stage variable. A test fixture under
`test/recovery/` alone supplies them. Rollback evidence comes from OS/process and
socket failures, not thrown fault-injection exceptions. The proxy is test-only,
binds loopback, requires plaintext PostgreSQL to parse frames and never logs
protocol payloads. Production transport security is a separate requirement.

Destructive test startup requires both explicit test opt-ins, a loopback URL with
the exact test database name, a concrete Docker container ID, the expected
`postgres:16` image, matching mapped port, and the test database in its container
configuration. The restored container publishes PostgreSQL on loopback at a
random port. Each Host API also binds loopback. Cleanup removes the restore
container and volumes and deletes private temporary dump files. No backup is
uploaded as a CI artifact. Fixture passwords are disposable test values only.

## What restore verifies

With all source Hosts stopped and identity/DDL writers quiesced, the test records
a deterministic manifest containing all application/security/migration table
rows, sequence state, object owners and ACLs, FORCE RLS flags and policy
expressions, security function bodies/owners/search paths/ACLs, capability-role
attributes/memberships and database/schema ACLs. Local object OIDs, statistics,
physical storage and password hashes are deliberately excluded. Table/sequence
ACLs are compared as sorted grantee/grantor/privilege/grant-option tuples, with
null ACLs expanded to PostgreSQL defaults. Equivalent ACL array order/default
representations must not hide or falsely report a privilege change. The manifest is
compared on a fresh cluster **before** password provisioning or admin changes.
PostgreSQL 16 gives the cluster bootstrap grantor (OID 10) special membership
semantics. The fresh cluster is initialized with the same bootstrap role name
`ventio`; only the redundant `CREATE ROLE ventio` from the roles dump is omitted
in a separate replay file. Its attributes, all memberships, grantor names and
options are restored unchanged and compared. New fixture passwords are
provisioned separately. A differently named bootstrap role plus `SET ROLE` does
not preserve the original bootstrap grantor semantics and is not used.
The target is not re-bootstrapped to mask missing security settings.

The tested PG16 dump/restore recreated the identity-audit sequence with only
`USAGE` for its owner, while the source owner ACL also contained `SELECT` and
`UPDATE`. A plain database/roles dump therefore failed strict security equality.
The tested backup bundle includes an explicit sequence-ACL SQL snapshot captured
from the quiesced source alongside the dumps. Restore replays that component
transactionally, including source grantees, grantors and grant options, before
manifest validation. It does not infer privileges, grant blanket permissions or
query a newer source at restore time. Original dumps remain unchanged. This
fixture supports the installed direct-owner sequence grant profile; arbitrary
dependent grant chains require additional restore tooling and validation.

The test then checks restricted-runtime startup, RLS denial without proof,
denial of raw identity UPDATE, pre-backup accepted-receipt replay, single audit
and outbox, successful new writes/sequence advancement, device and credential
revocation, expired credentials, withdrawn grants, manipulated tenant/branch,
and revocation persistence across another persistent identity fixture restart. Identity
administration still uses its separately privileged, audited RPC. RLS remains
defense in depth; Host business/authorization checks remain mandatory. Existing
least-privilege SQL and identity race suites run in their original workflow and
are also rerun against the independently restored cluster.

## Snapshot RPO and revocation rollback

A logical dump is a consistent database snapshot, not an ongoing recovery stream.
An acknowledged command committed after that snapshot is absent from its restore.
The suite deliberately proves this. It also proves that revoking a device after
the snapshot does **not** revoke it in an older restored database. This is a
security rollback as well as a data-loss boundary. The test keeps that target
isolated, reapplies the known later revocation through the audited admin RPC,
and only then starts the loopback verification Host. It does not replay the
missing post-backup command, which might duplicate an already delivered external
effect.

Before resuming a real restored system, reconcile all accepted-command evidence
and the latest trusted revocation/permission changes against the recovery point.
If a complete independent revocation ledger is unavailable, invalidate restored
credentials and require controlled device re-enrollment. Do not trust restored
credentials simply because the snapshot passed a checksum. This stage does not
implement an independent revocation watermark/ledger, WAL archiving, PITR,
replication, zero-RPO failover or automated production restore admission.

## Bounded restore procedure

1. Select and record the recovery point, database version, migration set, trusted
   role definitions and required external changes. Quiesce Host and identity/DDL
   writers for this tested procedure. Keep the target isolated throughout.
2. Use separately authorized backup tooling. The runtime role deliberately cannot
   dump all tenant/security rows or bypass RLS. Back up the database with ownership
   and ACLs and separately capture cluster roles/memberships and the explicit sequence-ACL
   snapshot required by this tested profile. `pg_dump` alone does
   not include those global objects. Protect dumps as sensitive identity/business
   data; use authenticated encrypted storage and transport with access controls.
3. This fixture uses `pg_dumpall --roles-only --no-role-passwords`. Restore trusted
   roles before `pg_restore --create --exit-on-error` into a fresh compatible
   cluster, then replay the saved sequence-ACL component. Provision new login secrets through the deployment secret manager,
   never through a checked-in backup. Do not use `--no-owner`, `--no-acl`, or
   repair RLS before checking that the backup preserved security. A logical restore
   executes SQL; accept backups only from trusted sources.
4. Verify rows, journal receipts/fingerprints, audit/outbox, sequences, migration
   checksums, owners, grants, security functions, role attributes/membership and
   FORCE RLS. Exercise runtime denial, tenant/company/branch isolation, credential
   expiry/revocation and current authorization. Reconcile changes beyond the
   recovery point before reopening access. Validate outbox consumers' independent
   idempotency/delivery state before publishing restored events.
5. Discard the isolated target on any restore/validation failure. `--create` is not
   an all-or-nothing single-transaction restore; an error can leave a partial
   target. Keep source backups immutable and protect the original database.

This fixture verifies same-major-version PostgreSQL 16 logical recovery. It does
not certify cross-version upgrades, extensions, filesystem/tablespace layouts,
large production datasets, backup retention/encryption infrastructure or recovery
time objectives. Production backup tooling and credential lifecycle need separate
operational acceptance; no new backup privileges are granted to Host runtime.

## Limits of crash evidence

SIGKILL of a Host or PostgreSQL process is an actual abrupt process failure. It
does not remove power from storage, flush a hardware cache, test disk controllers,
prove filesystem durability on production hardware, test torn pages on that
hardware, or test physical media loss/corruption. Docker restart retains the same
CI volume and kernel. Power-loss guarantees still depend on PostgreSQL settings,
filesystem/storage flush correctness and suitable hardware. The narrow deterministic
commit boundaries do not exhaust every possible instruction interleaving.

A retained journal/backup is necessary for deduplication. Removing journal rows,
restoring an older journal, bypassing Host through a privileged login, or losing
external delivery state changes the guarantee. Least-privilege/RLS do not stop a
trusted superuser or owner from deliberately changing data/security. The existing
documented ability to issue scoped SQL writes with a valid proof also remains;
RLS cannot enforce the whole trusted four-effect business transaction by itself.

References: [SQL dumps](https://www.postgresql.org/docs/16/backup-dump.html),
[pg_dump](https://www.postgresql.org/docs/16/app-pgdump.html),
[WAL reliability](https://www.postgresql.org/docs/16/wal-reliability.html).
