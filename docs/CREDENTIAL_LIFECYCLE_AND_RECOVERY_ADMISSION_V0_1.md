> Historical stage evidence. Current launcher settings, separate OS witness ownership, schema compatibility and witness upgrade requirements are defined in [Host operations](HOST_ENGINE_V0_1_OPERATIONS.md). See the [final engineering audit](HOST_ENGINE_V0_1_FINAL_ENGINEERING_AUDIT.md) for the current acceptance boundary.

# Secure credential lifecycle and recovery admission v0.1

Historical local-operator workflow. No public network deployment is
approved. The Host API defaults to `127.0.0.1`; any external listener requires
TLS and persistent identity. No client receives PostgreSQL administration
credentials or an administrative HTTP endpoint.

## One identity system

Lifecycle operations use the existing opaque 256-bit credentials, SHA-256 digest
storage, persistent identities, exact-scope grants, audited identity RPC and
permanent device/user revocation. There is no parallel password/JWT authority.
Apply the full ordered migration set, then rerun the vetted PostgreSQL security
bootstrap with the separate migration/installation capability. Runtime and
identity-administration connections remain separate. Runtime cannot read private identity/recovery state,
obtain a recovery snapshot, reset admission, issue credentials or rotate secrets.

A new credential has an immutable ceiling of explicit company/branch/permission
triples. Provisioning validates that every permission currently exists in the
user's exact server-side scope. Authentication intersects that ceiling with the
current grants. Broadening user grants later does not broaden the credential.
Commands and journal retries resolve the exact requested scope under transaction
locks; client actor/device/scope claims never establish authority. Global
revocation, user disablement and expiry are still checked on each use.

The local operator issues a credential with at most 30 days of validity. Rotation
and renewal require the current credential ID and proof digest, an active user
and device, and a non-expired, non-revoked scoped credential. They atomically retire
the old credential and insert a fresh ID/secret with the original scope ceiling.
Renewal never extends the lifetime of a stolen old secret in place. Concurrent
rotations have one winner; old, losing, expired or revoked secrets cannot revive
a credential. Expired credentials require a new reviewed enrollment. IDs cannot
be reused. Device revocation also defeats a replacement issued concurrently.

The earlier `issueCredential` SDK method is a historical trusted-fixture API.
PostgreSQL refuses that unscoped operation once recovery enforcement is enabled.
Production operator tooling uses only scoped file provisioning/rotation.

## Trusted local provisioning and delivery

`packages/ventio_host_api/bin/identity_admin.dart` accepts exactly one absolute
path to a private JSON request file. Run it on the trusted administration host:

```sh
dart run bin/identity_admin.dart /private/operator/request.json
```

The request contains `administrationDatabaseUrl`, `authorityFile`, `operatorLabel`,
`action` and, except for reset, `tenantId`. Those secrets are not command arguments.
The request and delivery directories must already be operator-owned mode 0700;
files are operator-owned mode 0600. Python 3 and Linux `O_NOFOLLOW`, exclusive
creation, file fsync, atomic replacement and directory fsync are required. Symlinks,
unsafe permissions, relative paths, existing output files and oversized private
inputs are refused. The CLI writes only a generic completion/failure message.
Exceptions, request bodies, tokens, credential digests and database URLs are not
printed by it. It never sends a raw token to PostgreSQL or identity audit.

Supported `action` values:

| Action | Additional request fields |
| --- | --- |
| `reset-for-reenrollment` | None; destructive security reset described below |
| `create-user` | `actorId` |
| `register-branch` | `companyId`, `branchId` |
| `register-device` | `actorId`, a new `deviceId` |
| `grant`, `revoke-grant` | `actorId`, `companyId`, `branchId`, `permission` |
| `disable-user` | `actorId` |
| `revoke-device` | `deviceId` |
| `revoke-credential` | `credentialId` |
| `provision` | `actorId`, `deviceId`, new `credentialId`, UTC `expiresAt`, `allowedScopes`, absolute new `outputPath` |
| `rotate` | `actorId`, `deviceId`, `previousCredentialFile`, new `credentialId`, UTC `expiresAt`, absolute new `outputPath` |

Example `allowedScopes` (not client-supplied administrative input):

```json
[{"companyId":"company-001","branchId":"branch-001","permissions":["maintenance.create"]}]
```

The private output artifact contains the new raw token and its tenant/user/device
binding and expiry. It is staged before the DB mutation so a successful issue
cannot lose its only local delivery copy. Do not consume/transfer it unless the
CLI completed successfully and admission is ready. On failure it may represent
an inactive orphan or an unknown committed issue; the file remains private. Do
not infer issuance from file existence or retry with a new ID blindly. Use the
quarantine/re-enrollment procedure when the commit/witness outcome is unknown.

The implemented delivery boundary is an operator-owned local file on a trusted
host. The operator must verify the actual recipient/device out of band before
registering it and delivering that file through an authenticated confidential
channel (for example, a pre-established authenticated SSH/SFTP connection or
controlled local import). Do not place it in a public share, QR log, email,
clipboard history, URL, command argument or chat. No unauthenticated remote
pairing, device attestation, public self-enrollment, external transfer service or
client secure-keystore importer is implemented. An OS administrator/debugger can
read process memory and private files; Dart strings are not guaranteed zeroized.

## Independent recovery authority

A database snapshot cannot prove that no later revocation/permission change
occurred. The production `bin/local_host.dart` therefore requires
`VENTIO_RECOVERY_AUTHORITY_FILE`. It refuses startup without usable independent
evidence. It calls SQL admission before binding HTTP, then both persistent
adapters verify the witness again INSIDE every authentication/command transaction,
including retries returning a previously accepted receipt. A running restored
Host also closes access when its database differs from the latest witness.

The witness is a separate private, fsynced, atomically replaced file outside the
PostgreSQL backup/restore domain. It contains a version, authority generation,
ready/pending state and SHA-256 fingerprint of recovery configuration and all
persistent user/device/credential/scope/grant/identity-audit rows. It contains no
raw credential. The fingerprint is a consistency check against the value supplied by the trusted
Host from independent storage, not a digital signature or a database-only
freshness oracle. A privileged backup holder can reconstruct old snapshot hashes;
never give clients database/runtime credentials or authority-path control.
The fingerprint is confidential admission evidence: do not log
or distribute the file to clients. It must remain the latest trusted linear
record; copying an old witness back with an old DB defeats that assumption.

Lifecycle administration serializes across local processes using an OS file lock
and within one Dart process using a queue. It marks the independent witness
pending and fsyncs it BEFORE any DB mutation. Under an exclusive PostgreSQL
transaction advisory lock it validates the previous fingerprint, executes the
existing audited admin RPC and obtains the new fingerprint. Only after COMMIT
acknowledgement does it fsync a ready witness. Authentication/commands take the
shared counterpart through commit, so administration cannot interleave stale
identity state with an accepted command.

A process kill, unknown commit, I/O error or crash after DB commit but before
witness publication leaves admission closed. It never adopts the restored DB as
its own proof of freshness. A known SQL action rejection before any COMMIT can
restore the prior ready witness only after rollback and a locked comparison with
that exact previously trusted fingerprint. This lets a legitimate losing rotation
fail without unnecessarily quarantining the winner. Unexpected errors remain
pending. Direct admin RPCs that bypass the coordinator change the DB fingerprint
and close subsequent Host access; they cannot silently update independent evidence.

The local witness is an implemented prototype authority provider, not a remote
consensus/immutable ledger. A trusted operator can change paths or roll it back;
a privileged database owner can alter protected functions. Protect deployment
configuration and authority storage independently. For production, isolate the
witness writer/admin secrets from Host (for example, an independently managed
writer with only a read-only witness mount in the Host sandbox). The prototype
same-account integration fixtures do not prove that OS deployment isolation.
Loss/rollback of BOTH the database and the trusted witness cannot be detected
from those copies alone. If latest evidence cannot be guaranteed, use reset.

## Safe no-evidence recovery admission

On a fresh installation or missing, stale, pending, corrupt or untrusted witness,
keep the restored target isolated. The only supplied initialization/recovery
operation is `reset-for-reenrollment`, using the separately authorized local
identity administration connection. It writes pending evidence first and then,
in one transaction:

1. Permanently revokes every restored credential and device across all tenants.
2. Deletes every restored permission grant across all tenants.
3. Enables SQL recovery enforcement and creates a new random authority generation.
4. Records an identity-audit recovery event for each existing tenant.

Only its acknowledged commit can produce new ready evidence. It does not revive
users/devices, create grants, infer permissions from a client or reuse old IDs.
A reviewed operator must explicitly grant current approved permissions, register
new device IDs and provision new scoped credentials after recipient verification.
An old backup token remains unusable even after another device is re-enrolled.
A crash during reset also leaves the witness pending; repeat the safe reset under
operator control, never synthesize ready state from a DB hash manually.

The security reset does not discard journal, records, business audit or outbox.
It does not recover accepted commands or external effects that occurred after
the database backup. Matching security state does not fence database clones or
prove the business recovery point; a single-active-database lease/fence is not
implemented. Reconcile that business recovery point and external outbox
consumer state independently before any real operational resumption.

## Compatibility and executable evidence

Unconfigured databases retain the old identity/RLS behavior solely for isolated
historical integration fixtures. The production launcher always invokes admission
and rejects unconfigured databases; there is no production opt-out environment
switch. Old identity/crash tests now use an explicitly guarded, test-directory
legacy launcher instead of weakening the production launcher. New lifecycle tests
exercise the actual production launcher and enforced SQL admission.

`.github/workflows/credential-lifecycle.yml` creates its own isolated PostgreSQL16
service and runs `test/lifecycle_integration.dart`. The suite exercises private
file delivery/unsafe modes/symlinks, credential ceilings, privileged RPC denial,
old/revoked/expired token reuse, independent-process rotation and rotation/revoke
races, production Host restarts, actual pg_dump/restore with later source
revocation/permission changes, a running stale restored Host, refusal to reopen,
and reviewed re-enrollment with all old grants/credentials retired.

Separate administration workers receive real SIGKILL before DB work, before
COMMIT and after COMMIT for issuance/revocation. The suite checks committed DB
state, pending-witness denial across actual Host restarts and safe reset. A real PostgreSQL wire proxy also withholds a committed issuance acknowledgement
to verify unknown-outcome quarantine. Audit atomicity and absence of raw tokens
in operator/startup/database logs are checked. No thrown simulated fault
substitutes for those kills. The previous Core, PostgreSQL,
Durable Host, API, identity, hostile SQL/RLS and crash/restore CI jobs remain enabled.

## Remaining production requirements

This stage does not authorize exposing Host through a proxy, LAN or internet.
Production still needs authenticated encrypted recipient delivery/client key
storage, operator identity and approval policy, credential-request rate limits,
rotation scheduling, independently protected authority infrastructure and writer
isolation, audited deployment/reset authorization, credential-retention cleanup,
secret-manager integration, telemetry redaction, hardened DB/OS logging and
backup protection, tested physical-storage power-loss behavior and operational
recovery/RPO acceptance. SQL logging/tracing and OS administrators are outside the
application's log-redaction boundary and must be configured to protect digests,
admission proofs and administration connections too.

Fingerprinting all identity/audit rows and a global advisory lock are deliberate
prototype correctness tradeoffs, not ERP-scale performance claims. Authentication
proof configuration is checked by the production assembly; server programmers
must not create an alternative production assembly using legacy fixture APIs.
RLS continues to enforce exact scope in configured databases without valid
admission proof, and is not a replacement for Host business authorization.
