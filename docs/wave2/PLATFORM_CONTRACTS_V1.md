# Wave 2 platform contracts v1

Status: implemented source / unverified. This supplements existing Wave 1
manifest, command, query, report and lifecycle contracts; it does not replace them.
The platform HTTP API remains `/api/v1`; the new namespace additionally requires
`contractVersion: 1`. Unknown properties and unsupported contract versions are
refused. Extension packages still cannot declare executable handlers, SQL or scripts.

Every operation is `POST /api/v1/platform/<action>` with the existing Bearer
credential and the selected `companyId` / `branchId`. Tenant, actor and device
come from current Host authentication. The native client reuses the existing
credential vault, pinned certificate validation, redirect refusal and bounded
JSON transport. No generic outbound integration or third-party identity runtime
is introduced.

| Action | Additional request fields | Result |
|---|---|---|
| `definitions/list` | `kind` | `DEFINITIONS`, definitions with id/revision/body/updatedBy/time |
| `definitions/save` | `kind`, `id`, `expectedRevision`, `requestId` (UUID), `body` | `SAVED` with revision, or conflict; same request/body is idempotent |
| `metadata/effective` | `moduleId`, `moduleVersion`, `docType` | Validated effective package and immutable `baseSha256` |
| `imports/preview` | metadata identifiers, `csv`, `mapping` (header to field), `recordIdHeader` | Row number, record ID, values, errors, schema version and valid-row count |
| `records/query` | metadata identifiers, `columns`, optional `recordId`, search/filters/sortField/descending/cursor, `limit` | Existing record-query result and current field grant sets, with custom fields enabled |
| `exports/page` | Same query fields except `recordId` | Header plus CSV for one authorized query page, hasMore/nextCursor/baseSha256 |
| `jobs/submit` | `jobId` (UUID), `commands` (existing command envelopes) | Durable job identity and current state, not business acceptance |
| `jobs/list` | None | Latest 100 visible jobs with bounded progress and redacted per-command outcomes |
| `jobs/cancel` | `jobId` | Current state; cancellation fences progress for future rows |
| `history/list` | metadata identifiers and `recordId` | Latest 100 source-document activity events, without field values |

Response envelope: `apiVersion`, `contractVersion`, correlation ID and `result`.
The body uses the existing JSON/time/concurrency safeguards. CSV preview has a
separate bounded upload allowance for JSON escaping; decoded CSV is capped at
512 KiB, 500 data rows, 100 columns and 65,535 characters per cell. Normal job
submissions remain within the existing request limit, with a 48 KiB canonical
command-array limit and at most 25 independent commands per job. Dependencies and
delete commands are intentionally not admitted to this initial job executor.
Governed business-operation commands continue to use their existing approved
operation ID/version, input validation, permissions and effect allowlist.

## Definition kinds and authorization

`saved_view`, `preferences` and `dashboard` are user-owned within the exact Host,
tenant/company/branch context and require `platform.workspace.use`. Stored views
never grant business permissions: execution revalidates current DocType and field
ACLs. Dashboard cards reference approved report metadata, never query SQL.

`customization` is shared within one exact tenant/company/branch and requires
`platform.customizations.manage`; package inspection additionally requires the
existing `extension.package.read`. Its ID is `moduleId:moduleVersion:docType`.
`configuration` is shared within the selected scope, requires
`platform.configuration.manage` to edit and `host.status.read` to read. Its
supported settings are a scope display name and operational notice; these affect
the workspace header/notice, not identity routing or database configuration.

Definition bodies are at most 32 KiB canonical JSON, with 100 definitions per
kind/owner/scope. Saving uses optimistic revision checks, a stable request ID and
an immutable revision log. The Host performs these mutations through the existing
separate scoped Identity API connection and Recovery Authority change protocol.
Offline drafts are user-owned SQLite entries. Editing generates a new request ID;
an unchanged retry preserves it. Host refresh retains dirty drafts, marks a stale
revision as a conflict, and supports explicit user-directed rebase with another
Host compare-and-swap on publication.

## Customization and package compatibility

The source schema is `contracts/wave2_customization.schema.json`; the executable
validator is `MetadataCustomization`. Version 1 adds optional `custom_` scalar
fields and label/list/form/detail/page presentation overrides. Custom fields
inherit the DocType's read/update permissions. Required fields, references,
child tables, calculations, operations, permissions, naming and migrations cannot
be injected through this overlay. Total effective fields remain within the
existing package limit. Custom label keys use the extension's `.custom.` namespace;
the native localization adapter versions those fallback renderings by text digest
to preserve immutable base catalogs during an in-session label change.

The published package row and digest never change. SQL resolves and signs an
effective authorization policy; Dart validates the effective bundle and verifies
the separate immutable base package digest. The Wave 1 record-query route keeps
projecting base fields so older clients do not receive unknown customization fields.
The new record-query route explicitly opts into effective fields. Old writes
continue through the same generic engine and preserve optional custom data.

Field deletion/type/constraint changes are refused. A package approval that would
strand custom fields from another release is blocked by a database trigger.
This is a safety refusal, **not** a completed cross-release rebase/migration tool.
Presentation-only overlays are pinned to their release and do not block upgrades.
The explicit cross-release migration workflow remains an implementation gap.

## Data transfer and durable jobs

CSV parsing supports quoted delimiters, escaped quotes, CRLF/LF, embedded newlines
and an optional BOM. Headers must be unique and nonempty. Mapping is declarative;
the record ID is explicit and never guessed from a display field. Preview detects
duplicates within the file and readable existing Host IDs. Integer, exact scaled
decimal, boolean, date/datetime, enum/reference strings and bounded child-table
JSON use existing metadata validation. Reference existence and the final current
permissions are authoritative at command execution. No financial posting bypass
is introduced. Decimal conversion rejects values that cannot round-trip through
the existing safe JSON number representation at the declared scale.

Export reuses the existing field-aware filters, sort and cursor gateway. Requested
columns must all be readable; hidden fields cannot be used to filter or sort.
Each page reauthorizes independently. String cells that could be spreadsheet
formulas are prefixed with an apostrophe. Numeric negative values remain numeric.
That protective string transformation is intentional and is not silently undone
by import. Extension metadata import/export remains the existing approved builder
and package registry workflow.

SQLite durably stages stable Host job and command IDs before submission. HTTP
acceptance acknowledges only that a Host job exists. The Host worker claims one
row under a two-minute fenced lease, reauthorizes current identity and
`platform.jobs.run` inside the command transaction, and invokes the existing
durable command executor. It supports record create/update and approved business
operations. `platform.jobs.manage` permits exact-scope job visibility/cancellation;
ordinary submitters can see/cancel their own jobs. No plaintext token is stored;
the credential digest is private and never returned by user-facing list APIs.

States: `QUEUED`, `RUNNING`, `RETRY_WAIT`, `SUCCEEDED`,
`COMPLETED_WITH_ERRORS`, `FAILED`, `CANCELLED`. Retries keep the original command
identity, with at most five attempts per row and bounded backoff. A crash after a
command commits but before job progress commits replays the durable command
receipt. Cancellation can race an already claimed operation; it never promises
to roll back accepted effects. Revocation may prevent receipt replay, so a failed
job is not evidence that no effect committed. Error details expose stable codes,
not payloads or exception strings. Worker infrastructure failures go to the
existing protected Diagnostics Center. This queue is distinct from the offline
SQLite command queue; native form edits continue using that existing queue.

## Bounded D09 / J04 disposition

Accepted: existing opaque-token identity, credential ceilings, exact-scope grants,
pairing/reissue, current per-request authentication, TLS pinning, versioned
declarative extension APIs and bounded transfer/job requests. These have concrete
uses in the delivered scope. Existing approved lifecycle effects remain reused.

Partially implemented: native/Host data-transfer and operational visibility are
source-integrated but have no Wave 2 runtime evidence. Historical document
activity is not backfilled; source-command activity does not yet cover every
cross-record effect target.

Intentionally deferred: third-party authentication federation, arbitrary webhook
destinations, uploaded integration handlers, SQL connectors, executable scripts,
unrestricted service credentials and a general integration runtime. No defined
requirement justifies expanding those trust boundaries in this wave.

## SQLite compatibility note

The existing command queue migrates from schema 1 to 2 by adding a default-1
projection flag, preserving prior pending commands and receipts. Effective-schema
workspace form commands use flag 0, so ordinary record reconciliation does not
project custom values through base-package metadata. Their receipts still persist
in the same durable command queue. The workspace database is separate (schema 1,
WAL/FULL). Binary downgrade after queue migration remains unproven.

The workspace form adapter restricts edits to currently readable and writable
fields so an untouched redacted field cannot be implicitly cleared. Dedicated
native write-only editing remains an implementation gap. Multi-page exports
observe current Host state and may reflect concurrent updates.
