# Host Engine v0.1 operations

Scope: controlled prototype deployment on Windows or Linux. The listener defaults to loopback. A non-loopback listener requires TLS, the persistent authenticator and the authoritative command executor; this guard does not certify a production network deployment. Windows protected-file operations have a local ACL integration test, but the complete Windows Host plus PostgreSQL and remote-device path has not been end-to-end verified.

## Identities and protected paths

Use separate OS accounts for the Host service and trusted recovery administrator. Use a group whose members may read the witness; Host must not control group membership. Do not put administrator database secrets in Host environment or readable service configuration.

On Linux, `local_host.dart` requires `VENTIO_RECOVERY_AUTHORITY_OWNER_UID`, pinned by trusted deployment configuration to the administrator UID. It refuses a witness owned by Host, the wrong UID, a writable witness/parent, symlinks and unsafe permissions. Host cannot overwrite, unlink or rename the witness.

On Windows, set `VENTIO_RECOVERY_AUTHORITY_OWNER_SID` to the separate writer account SID and `VENTIO_RECOVERY_AUTHORITY_READER_SID` to a dedicated local group SID containing the Host service account. Provision the authority directory before starting either process. Give its trusted writer, `SYSTEM` (`S-1-5-18`) and local Administrators (`S-1-5-32-544`) full control, and give only the reader group read/traverse (`RX`). Disable inherited entries and remove unexpected explicit entries. The writer must own the directory and witness; Host must be a member of the reader group and must not be the writer. The runtime checks the owner, explicit ACL, reader-group membership, local fixed-volume path and path chain, and refuses reparse points or ancestors that an untrusted principal can delete or replace. It does not create or repair authority directories or ACLs.

For example, a trusted Windows administrator can provision a new directory using the SIDs above (replace the two placeholders with verified SIDs):

```powershell
$authorityDirectory = Join-Path $env:ProgramData 'Ventio\authority'
$writerSid = '<trusted writer SID>'
$readerGroupSid = '<Host reader group SID>'
New-Item -ItemType Directory -Path $authorityDirectory
icacls.exe $authorityDirectory /inheritance:r
icacls.exe $authorityDirectory /setowner ('*' + $writerSid)
icacls.exe $authorityDirectory /grant:r ('*' + $writerSid + ':(OI)(CI)F') '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' ('*' + $readerGroupSid + ':(OI)(CI)RX')
icacls.exe $authorityDirectory
```

The protected-file implementation verifies the resulting ACL and fails closed on any unexpected entry. These ACLs do not protect against the trusted writer, a local administrator/SYSTEM, Host executable/configuration replacement, or a compromised OS account. Use a local fixed NTFS volume; no Windows service installer or automatic certificate rotation is supplied.

Example path layout (provision by the trusted OS administrator):

- `/var/lib/ventio-authority`: writer owned, witness-reader group, 0750.
- `/var/lib/ventio-authority/authority.json`: writer owned, same group, 0640.
- `/var/lib/ventio-operator`: writer owned, 0700; private requests/deliveries 0600.
- Read-only deployment tree containing the compiled Host and `spec/v1.2`.
- Windows: `%ProgramData%\Ventio\authority`, with the writer-owned protected DACL described above.

The operator CLI accepts one private request-file path. Include `witnessReaderGid` (numeric reader group ID) on Linux or `witnessReaderSid` (reader-group SID) on Windows, alongside `authorityFile`, `operatorLabel`, `administrationDatabaseUrl` and action-specific fields. Run the Windows operator CLI as the trusted writer account. Never place JSON contents or raw tokens on a shell command line. Initial `reset-for-reenrollment` establishes a new authority, revokes every device/credential and removes every grant. Enroll identities/grants again, then provision scope-limited credentials. Never use reset merely to make a mismatching backup look current.

The actual credential delivery is a private local file, not an implemented remote pairing protocol. Recipient verification, trusted physical transfer/import, deletion of delivery copies and platform keystore integration are still required. The runtime supports no administrative HTTP endpoint.

## Database deployment and compatibility

1. Confirm a dedicated Framework database, never the original Ventio database.
2. Stop/drain Host and block admission for the deployment.
3. Use the migration capability/login, explicitly assuming `ventio_owner` where required. Never migrate through runtime credentials.
4. Apply vetted migrations with `packages/ventio_postgres/bin/migrate.dart`. The whole new batch and ledger updates run under one advisory lock and one transaction. Missing/changed/unknown applied files and duplicate numeric versions fail before DDL is committed. Files must each contain one transaction-compatible SQL statement; concurrent index creation and other transaction-prohibited operations require a separately reviewed migration design.
5. As the trusted PostgreSQL cluster administrator, apply `security/postgres/bootstrap.sql` with `-v expected_database=EXACT_NAME`. It is transactional, moves the prior private `pgcrypto` extension into the isolated crypto schema when upgrading, then installs owner-only identity operations, forced RLS, restricted ACLs, schema checks and recovery functions. `test_logins.sql` is CI-only and must never be used for deployment.
6. `schema_profile.sql` pins all approved migration names/checksums; `python3 scripts/check_schema_profile.py` verifies it against sources. Add reviewed entries when introducing migrations. Runtime refuses unsupported ledger entries. The recovery fingerprint includes the ledger; a running Host fails closed after an uncoordinated ledger change.
7. The current recovery profile hashes the protected recovery state and migration ledger. Statement triggers advance the protected generation for identity, credential, scope, audit, approved/revoked package and registry-event changes; RLS verifies a transaction-bound HMAC proof without rehashing history per row. A recovery fingerprint format/schema change requires a controlled authority upgrade. The generation-based profile invalidates existing witnesses from the full-row profile. Preserve that evidence, apply the reviewed bootstrap while stopped, then use explicit reset/re-enrollment, which withdraws former devices, credentials and grants. There is no automatic witness migration or automatic restoration of old credentials.
8. Recheck database privileges and recovery admission before starting service.

A ledger is compatibility evidence, not full schema attestation: an owner can change functions, policies or DDL without recording it. The trusted database/deployment administrator remains in the trusted computing base. No runtime caller can provide its own approved manifest.

## Host startup and shutdown

Set only the restricted runtime connection and service settings in a protected service configuration:

```text
VENTIO_ENABLE_LOCAL_HOST=yes
VENTIO_HOST_DATABASE_URL=<restricted runtime connection>
VENTIO_HOST_PORT=8080
VENTIO_RECOVERY_AUTHORITY_FILE=/var/lib/ventio-authority/authority.json
VENTIO_RECOVERY_AUTHORITY_OWNER_UID=<trusted writer UID>
```

On Windows, use the local path and SID settings instead:

```text
VENTIO_RECOVERY_AUTHORITY_FILE=C:\ProgramData\Ventio\authority\authority.json
VENTIO_RECOVERY_AUTHORITY_OWNER_SID=<trusted writer SID>
VENTIO_RECOVERY_AUTHORITY_READER_SID=<Host reader group SID>
```

Run under the separate Host OS account, from `packages/ventio_host_api` in the deployed tree, so `../../spec/v1.2` resolves. Compile using the pinned Dart SDK 3.13.7. Keep the binary, spec, environment and PATH read-only to that account. Protected file operations use Python 3 on Linux and the Windows system PowerShell runtime with ACL APIs on Windows; the executable is resolved from `SystemRoot`, not from a client path or mutable PATH lookup. Do not log environment, bearer tokens, private request contents or credential delivery files.

For a single Windows device, leave `VENTIO_HOST_BIND_ADDRESS` unset to use loopback. For a separate Windows Host serving other devices, bind to its specific LAN address, configure a certificate whose SAN matches the Host name clients use, and permit only the intended Host port through the Windows firewall. Remote binding is TLS-only. Ventio's Flutter client now has authenticated package submission/installation and generic record query/queued-write paths. The Windows Host serving remote Windows/Android clients over this LAN topology has not been end-to-end verified.

Startup probes restricted privileges, exact schema compatibility and independent recovery admission before listening. `/healthz` is liveness, not database/recovery readiness. Each authenticated command rechecks current identity and authorization inside its database transaction; receipt replay is also authorized. Authentication does not freeze a user's permissions for future requests.

SIGTERM/SIGINT stop admission and drain admitted requests. CI tests an actual command waiting on a PostgreSQL lock during SIGTERM, then verifies its receipt after restart. Abrupt termination still requires reconciliation. There is no production service unit, externally proven bounded shutdown deadline or resource policy yet.

## Unknown outcome, recovery and backups

A timeout, dropped response or HTTP 503 does not prove rollback. Retry the original immutable envelope and command ID after recovery. Do not generate another ID to hide uncertainty. Check current credential/permission state again; a revoked device cannot replay even a formerly accepted command.

The writer fsyncs `pending` before changing security state and publishes `ready` only after acknowledged commit. Unknown commit outcomes and process kills leave quarantine. Preserve the witness and transaction evidence; never clear pending by editing JSON. Re-enroll conservatively if the latest trusted state cannot be proved.

Keep the latest witness outside the database's rollback domain with independent protected history. A latest witness rejects an older database; a current database rejects an older witness. Restoring both matching old copies defeats local freshness detection. This is reproduced in CI and blocks production until an independently anchored, non-rollbackable authority/fencing design exists. A hash or file owner does not solve joint rollback.

CI restores an isolated PostgreSQL 16 logical backup plus roles (without role passwords) and an explicit sequence ACL snapshot into a fresh container. It verifies rows, journal, audit, outbox, identities, revocations, constraints, ownership, policies, functions and ACLs. Preserve required bootstrap-role semantics and restore sequence ACL evidence; do not assume `pg_dump` alone recreates the tested profile. Restore runtime/admin secrets through a separate trusted channel.

This is not physical/WAL point-in-time recovery, real power-loss testing, storage-controller durability certification, high availability, quantified RPO/RTO or a production backup policy. Verify those independently before deployment.
