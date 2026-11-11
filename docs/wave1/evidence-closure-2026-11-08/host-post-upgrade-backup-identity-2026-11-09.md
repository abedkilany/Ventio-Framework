# Host pre-upgrade backup identity comparison — 2026-11-09

**Result:** `PASS — VERIFIED` for PostgreSQL cluster identity continuity only. This is not proof that business rows were preserved.

## Procedure and observed output

Using authenticated read-only SSH, inspected the existing Host backup created before the 2026-11-08 installer run and ran the installed `pg_controldata.exe` against the backup data directory and the current PostgreSQL data directory.

```text
BACKUP_MANIFEST_FIELDS=formatVersion,createdAtUtc,postgresVersion,dataDirectory,fileCount,bytes
BACKUP_formatVersion=1
BACKUP_createdAtUtc=2026-11-08T19:35:12.2490423Z
BACKUP_dataDirectory=data
CONTROL_BACKUP=Database system identifier: 7705548262546041680; Database cluster state: shut down; Latest checkpoint location: 0/1BD1CA0
CONTROL_CURRENT=Database system identifier: 7705548262546041680; Database cluster state: in production; Latest checkpoint location: 0/1FDC310
```

The backup and current cluster have the same PostgreSQL system identifier. The backup is a valid shut-down cluster; the current cluster is in production. This corroborates that the installed upgrade retained the same PostgreSQL cluster lineage.

## Limits and acceptance disposition

The manifest contains file-count/byte metadata but no logical table counts or content checksum. No table rows were read in this procedure. Therefore Host business-data preservation remains **unverified** and Stage 10 remains open. No database, configuration, or service state was changed.

## Preserved backup location and manifest consistency — 2026-11-09

Read-only SSH located the pre-upgrade backup at:

C:\ProgramData\Ventio\Backups\ventio-postgresql-before-upgrade-20261108T193506653Z-16dabf5cda154b8fbec9ee8bbd00cf77

The Host data directory inventory returned 1,379 files totaling 51,093,333 bytes. These values match the preserved backup-manifest.json exactly. This verifies the copied backup matches its file-count and byte-total manifest; it does not provide per-file cryptographic integrity or prove logical database rows were preserved in the live upgrade. No files, services, or database state were changed. No acceptance counts or stage weight changed.
