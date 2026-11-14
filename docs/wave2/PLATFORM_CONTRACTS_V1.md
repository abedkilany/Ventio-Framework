# Wave 2 platform contracts v1

Status: implemented source / unverified. Existing Wave 1 command, manifest,
query, report, identity and lifecycle contracts remain supported. New operations
use `POST /api/v1/platform/<action>` with `contractVersion: 1`, `companyId`,
`branchId` and the existing Bearer credential. Tenant/actor/device come from
current Host authentication. Unknown properties/versions are refused. Native
transport reuses the credential vault, TLS pinning and redirect/body limits.

## Routes

| Action | Additional request fields | Result |
|---|---|---|
| `definitions/list` | `kind` | Versioned definitions visible to the current owner/scope |
| `definitions/save` | `kind`, `id`, `expectedRevision`, UUID `requestId`, `body` | CAS/idempotent `SAVED`, conflict or denial |
| `metadata/effective` | `moduleId`, `moduleVersion`, `docType` | Effective package plus immutable `baseSha256` |
| `imports/preview` | Metadata identifiers, `csv`, header-to-field `mapping`, `recordIdHeader` | Original logical CSV row numbers, IDs, values, errors and schema version |
| `records/query` | Metadata identifiers, `columns`, optional `recordId`, search/filters/sortField/descending/cursor/limit | Existing field-redacted records and current field grant sets, with custom fields enabled |
| `exports/page` | Same query fields except `recordId`; nonempty readable `columns` | CSV page and existing cursor/hash metadata |
| `jobs/submit` | UUID `jobId`, existing `commands`, optional UUID `importId` and aligned integer `sourceRows` | Durable job identity/state, not business acceptance |
| `jobs/list` | None | Latest 100 visible jobs, totals/archival metadata and redacted outcomes |
| `jobs/cancel` | `jobId` | Stop future claims; an in-flight effect can still finish |
| `history/list` | Metadata identifiers, `recordId`, optional `cursor` and `limit` 1-100 | Chronological metadata-only events, hasMore/nextCursor and coverage boundary |
| `organization/list` | None | Manageable organization/company/branch entities and revisions |
| `organization/change` | `change` | Governed versioned entity mutation and request receipt |
| `settings/read` | None | Current scope's nonsecret operational settings/defaults |
| `customizations/rebase/preview` | `moduleId`, `sourceVersion`, `targetVersion`, `docType` | Current source/revision, submitted target/digest and deterministic candidate body |
| `customizations/rebase/prepare` | Same binding, `sourceRevision`, reviewed `body` | Prepared compatible rebase; package approval is separate |
| `operations/prepare` | UUID `operationId`, fixed `operation`, bounded `body` | Durable request awaiting independent local approval |
| `operations/list` | None | Current-scope requests/results and local delivery availability/status |

Responses contain `apiVersion`, `contractVersion`, `correlationId` and `result`.
Denials/conflicts use existing transport handling. Empty `columns` on record
queries can obtain redacted records/grant masks; they never bypass field ACLs.
Filters and sort fields always pass the existing query authorization. Omitted
page limits use the bounded scoped default. Each export page reauthorizes;
pages observe current Host state and may reflect concurrent changes.

## Definition ownership and settings

`saved_view`, `preferences`, `dashboard` are user-owned and require
`platform.workspace.use`. Stored views and dashboard report cards confer no
business permissions. `customization`, `configuration`, `backup_policy` are
shared within one exact tenant/company/branch. Shared management requires the
corresponding direct trusted grant and current credential ceiling; role-only
management cannot expand platform authority. Definition writes use the separate
Identity API connection and existing Recovery Authority change protocol.

Customization IDs are `moduleId:moduleVersion:DocType`; current configuration and
backup policy use `scope`. Definitions have bounded bodies/counts, optimistic
revision checks, stable request identities and immutable revision history.
Offline edits remain private drafts. An unchanged retry preserves request/body;
a new edit generates a new request ID. Refresh preserves dirty/conflicted drafts
and removes retired synced metadata without discarding local intent.

Configuration supports `displayName`, `maintenanceNotice`, `maintenanceMode`,
`jobsPaused`, `defaultPageSize` 1-100, `maxImportRows` 1-500 and
`completedJobRetentionDays` 1-3650. Defaults are false/false/50/500/30. New business
effects honor maintenance after accepted-receipt replay; job claims/execution honor
pause. No credentials, SQL, arbitrary URLs, paths or service identities are settings.

Backup policy is `{contractVersion:1, enabled, utcTime, retainDays, retainCopies,
maximumAttempts, retryMinutes}`. UTC time is HH:mm; bounds are respectively
1-3650 days, 2-1000 minimum copies, 1-5 attempts and 5-1440 retry minutes.
A policy write is not local scheduler approval.

## Customization and release migration

`contracts/wave2_customization.schema.json` and Core `MetadataCustomization`
define the overlay. V1 supports up to 20 optional scalar `custom_*` fields with
inherited DocType read/update ACLs, supported labels and list/form/detail/page
presentation. Required/reference/table/calculation/security/operation injections
are refused. Full package validation remains active. Package bytes/digests never
change; SQL signs effective metadata while Dart checks the original base digest.
Old query routes retain base-field projection and old writes preserve custom data.

Labels use separate customization keys; collisions with another metadata label
are refused. Native keys include the fallback digest. Structural custom-field
removal/type/constraint changes are refused; presentation changes remain supported.

Compatible cross-release migration is explicit. Preview reads a submitted target
under current review/customization authority. Core and SQL produce the same body:
all custom fields/constraints/ACLs remain intact, target layouts adopt custom
fields, and label/page overrides survive. Preparation pins source revision and
both package digests. Every affected scope must prepare. Independent package
approval rechecks preparation credentials and metadata and atomically activates
all overlays with the existing base-field migration DSL. Missing/stale/incompatible
preparations roll back approval. Retired overlays remain in immutable revisions;
no business values are silently converted or dropped.

## Transfer, jobs and local commands

CSV supports quotes, delimiters, escaped quotes, multiline records, CRLF/LF and
BOM. Header/mapping/duplicate/type/default/child validation reuse approved metadata.
Decoded source is bounded to 512 KiB, 500 data rows, 100 columns and 65,535
characters per cell, with a tighter scoped row bound when configured. Decimal
conversion uses existing exact-scale/safe JSON limits. Reference existence and
current write permissions are rechecked at command execution. Extension metadata
transfer reuses the existing builder and approved package registry.

Jobs contain 1-25 independent create/update/approved-operation envelopes within
48 KiB canonical command JSON. Deletes and command dependencies are refused.
Wire validation is shared with the existing command route. Stable IDs plus the
existing journal prevent duplicate effects across submit/commit/progress crashes.
`importId` requires unique aligned source row integers; these preserve the original
logical preview row numbers, including gaps from skipped invalid rows. Reusing a
job ID with altered commands or labels conflicts.

States: QUEUED, RUNNING, RETRY_WAIT, SUCCEEDED, COMPLETED_WITH_ERRORS, FAILED,
CANCELLED. Claims use fenced two-minute leases and at most five attempts per row.
Current `platform.jobs.run` is required at claim and inside the authoritative
command transaction; management grants scope visibility/cancellation. Public
outcomes contain IDs/status/codes/source labels, not payloads/digests/leases.
Cancellation preserves a known in-flight result; ambiguous cancellation reports
CANCELLED_OUTCOME_UNKNOWN and never asserts rollback. Current revocation can
prevent replay, so a failed job does not prove that no effect committed.

Terminal archival removes full commands and executable credential references,
retaining IDs, request hashes, source labels, totals, redacted outcomes and audit.
The immutable command journal remains authoritative. The Host worker/operations
protocol is separate from the offline SQLite queue.

Native governed updates submit dirty patches. Protected fields are not initialized
from Host data and are omitted unless replacement is explicitly selected; optional
clears are deliberate. Host computes against stored protected dependencies. The
queue preserves original receipts; terminal customized drafts can be reviewed
against a fresh authorized revision, then linked to one new exact-owner command.
Hidden/removed fields are not re-exposed during recovery. Local profile changes
cannot redirect a saved draft to another actor/device/endpoint/scope.

## Organization, history and physical operations

Organization change includes kind/id/parentId/displayName/archived/expectedRevision/
UUID requestId. Tenant identity and branch parents are immutable. Company/branch
creation grants nobody access; archive retains data/permissions but filters effective
access. Reactivation requires current target authority from an active source.
Current-scope/last-user safeguards preserve existing identity trust boundaries.

Activity captures all new affected records, amendments, schema changes and source
commands, including operations with no source mutation. Seeded legacy sources use
retained outbox/journal metadata. Pages authorize the current DocType and scope,
contain no field values and sort by original occurrence time plus event identity.
Deleted-ID lookup uses the same authorization. `historicalCoverage` declares that
Wave 1 did not record old cross-target effects; no inferred history is fabricated.

Fixed physical operations are APPLY_POLICY/BACKUP_NOW with an empty client body,
RESTORE_PLAN with `backupName`, and RESTORE with `backupName`, `planOperationId`,
`planSha256`. IDs/names/fields are strictly bounded. Host preparation never starts
services, a scheduler or a restore. A private two-minute accepted offer and an
independent local Windows elevated approval are required. A fixed SYSTEM task
consumes only current offers matching the locally pinned exact policy/revision,
active policy, UTC due time and durable daily retry limit. No uploaded executable
or arbitrary command/path enters this channel.

BackupOnly reuses trusted quiesced physical backup and avoids migration credentials
and migrations. Private SHA-256 manifests, fixed roots, reparse/ACL checks, a shared
maintenance mutex and service recovery journals guard execution. Retention follows
a verified new backup, preserves minimum verified copies/age/restore pins and never
selects upgrade/recovery/partial/foreign backups. Restore plans pin compatibility
and integrity for one hour; explicit confirmation preserves the current cluster,
verifies staging and leaves Host stopped for existing Recovery Authority recovery.
The external witness is never copied/reset/adopted. Private local journals survive
rollback of database request history. Scoped admitted reconciliation can restore
an operational audit result without resurrecting identity state.

## Compatibility and D09/J04 disposition

Command queue SQLite schemas 1->2->3 add projection and reconciliation references;
workspace schemas 1->2->3 add source correlation and operational retry identities.
Old envelopes/receipts remain unchanged. WAL/FULL and owner/Host/scope isolation
remain active. Binary downgrade is not established. Workspace business reads do
not infer permissions from cached metadata; offline metadata/preferences/intent
remain provisional.

Accepted bounded integration: existing opaque credentials, pairing/reissue,
current scope/role/field checks, credential ceilings, TLS pinning, approved
metadata/lifecycle APIs and the concrete transfer/jobs/operations above.
Intentional non-requirements: general third-party identity federation, arbitrary
outbound webhooks, executable handlers, SQL connectors and an unrestricted
integration runtime. Source integration remains unverified; all runtime, security,
OS and platform gates belong to the separate Wave_2_B assignment.
