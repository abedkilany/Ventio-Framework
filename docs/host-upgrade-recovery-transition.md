# Recovery Authority coordinated Host upgrade

## Status

The 0.1.12 physical Host upgrade failure is reproduced in an isolated PostgreSQL 16.15 environment and corrected in the 0.1.13 development release. The physical Host and its live PostgreSQL cluster were not accessed or changed. Physical acceptance remains open.

## Confirmed failure mechanism

The Host recovery fingerprint includes the ordered `ventio_schema_migrations` ledger. The 0.1.12 installer migration path applied migrations 031 and 032 directly, then updated SQL security contracts without coordinating the independent Recovery Authority witness. Those migrations advance the database fingerprint while the witness remains at its prior fingerprint. `ventio_security.admit_recovery()` correctly rejects that mismatch with SQLSTATE `28000`; this is the field-reported `ServerException`, not a PostgreSQL password or SCRAM failure.

The regression fixture starts from a migration-030 Host database, bootstraps a first administrator through the actual Recovery Authority flow, and persists its user, device, and credential before cloning the database. Applying 031 and 032 through the old direct migration path reproduces the mismatched fingerprints and `28000` denial.

## Upgrade transition

Production Host upgrades now pass through the existing Host Windows service identity and Recovery Authority. The installer first creates and verifies a restricted PostgreSQL data backup. It then enables one bounded PostgreSQL prepared transaction slot (`max_prepared_transactions = 1`) and verifies the running setting. It does not edit the Recovery Authority witness directly.

The trusted upgrade helper applies only the release-bundled migration batch inside a uniquely named PostgreSQL prepared transaction. The batch includes a durable receipt containing the operation id, old and new database fingerprints, and migration-manifest hash. It contains no identity or credential material.

The transition uses these durable states:

1. The independent witness records a pending `prepared` operation and its prior fingerprint.
2. PostgreSQL prepares the migration transaction. Changes and the receipt remain invisible until commit.
3. The independent witness records `commit_authorized` for that exact operation.
4. The Host commits the prepared transaction, verifies the exact receipt and resulting fingerprint, then finalizes the witness.

After a restart, an operation still in `prepared` has not been authorized to commit. A matching prepared transaction is rolled back, the unchanged prior fingerprint is verified, and the same operation can be retried. An operation in `commit_authorized` is completed by committing the matching prepared transaction or reconciled from its exact committed receipt. If the authorized transaction and its receipt are both missing, the Host stays quarantined; it never adopts an unproven database state.

This is a narrow two-phase transition for vetted schema upgrades, not a general remote transaction API. PostgreSQL documents prepared transactions as a mechanism for an external transaction manager and warns that they must be closed promptly; the Host helper owns and reconciles its uniquely identified operation. See the [PostgreSQL 16 `PREPARE TRANSACTION` reference](https://www.postgresql.org/docs/16/sql-prepare-transaction.html).

## Database and installation impact

- Migration 033 adds `public.host_schema_upgrade_receipts`. It stores only schema-upgrade evidence.
- Fresh bootstrap and the reviewed schema profile set the receipt table owner to `ventio_owner`, enable and force RLS, add an owner-only policy, and revoke access from runtime and identity API roles.
- Existing migrations 001–032 and all existing identity, device, credential, record, and audit rows remain in place.
- The installer backs up the cluster before adding the PostgreSQL setting or applying migrations. The existing service identity remains `NT SERVICE\VentioPostgres`; the Host service performs the upgrade as `NT SERVICE\VentioHost` through its protected request file and bundled helper.
- TLS certificate and Recovery Authority files are outside the PostgreSQL restore path and remain untouched. Client SQLite databases and their pending queues are not accessed by the Host installer.
- An old or mismatched witness is never overwritten, regenerated, or bypassed. Database rollback after a finalized upgrade remains rejected by Recovery Authority admission.

## Owner recovery for the failed 0.1.12 Host

Use the new versioned Setup package and the already verified backup made by 0.1.12 **before** it applied migrations 031 and 032. Do not select a later backup of the already-migrated, witness-mismatched cluster. If there is any uncertainty about which backup is the pre-migration one, stop and preserve the machine for support review.

1. Run the new Ventio Setup 0.1.13 package as an administrator and allow it to update the installed Host components. If the Host upgrade fails closed on the known stale witness, keep `VentioHost` stopped.
2. Open an elevated PowerShell window. Confirm `VentioHost` is stopped. Run the recovery script bundled at `C:\Program Files\Ventio\host-payload\setup\restore-host-upgrade-backup.ps1` with the exact original pre-migration backup directory:

   ```powershell
   Stop-Service -Name VentioHost -Force
   & 'C:\Program Files\Ventio\host-payload\setup\restore-host-upgrade-backup.ps1' `
     -BackupDirectory 'C:\ProgramData\Ventio\Backups\ventio-postgresql-before-upgrade-<original timestamp and id>' `
     -ConfirmRestore
   ```

   The script validates the restricted backup manifest and data inventory, preserves a second copy of the current failed cluster, restores the selected cluster through a same-volume directory swap, starts PostgreSQL, and leaves `VentioHost` stopped. It does not modify certificates, the witness, device rows, credentials, or Client files.
3. Run the same Ventio Setup 0.1.13 package again. It will create a fresh verified backup, coordinate migrations 031–033 with the independent witness, apply the reviewed security contracts, and start the Host only after contract verification.
4. Verify Host Readiness reports API, Database, Schema, and Recovery Authority READY. Verify the original Client still presents the same device identity and its local records and pending command ids remain present. Then exercise normal Host-authoritative synchronization.

If Setup reports `HOST_SCHEMA_UPGRADE_OUTCOME_UNKNOWN`, `HOST_SCHEMA_UPGRADE_RECOVERY_ADMISSION`, or leaves `VentioHost` stopped, do not restore another backup or edit the witness. Preserve the operation result and both verified backup directories and escalate for controlled reconciliation.

## Test evidence

The disposable migration-030 regression verifies persisted identities, direct-upgrade fingerprint mismatch, SQLSTATE `28000`, coordinated upgrade and identity preservation, pre-commit interruption and same-operation retry, a crash after database PREPARE but before witness authorization, a lost commit acknowledgment, recovery from an authorized prepared transaction, rollback rejection, and quarantine when an authorized transaction has no receipt. The test operates only on generated disposable databases and temporary witness files.

The Postgres recovery witness remains independent and protected. No live Host database, real credential, device identity, certificate, Recovery Authority file, or Client SQLite data is used in tests.
