# Wave 2 scope and acceptance contract

Implementation baseline: `7d74a70`, latest `origin/main` fetched 2026-11-13.
Development branch: `feature/wave-2-a`. Wave_2_A is source implementation only;
all behavior delivered here remains unverified. Wave_2_B and Wave_2_C are separate assignments.

## Evidence and reuse

Reviewed `README.md`, `docs/wave1/final-acceptance-report.md`, the closure and final
audit reports, Core metadata/permissions/extension contracts, SQLite extension and
command persistence, Host command/query/identity/recovery code, PostgreSQL bootstrap,
RLS and migration profile. The current Wave 1 ledger records internal closure on
2026-11-11 and retains signing, distribution and sole-owner recovery limitations.
Historical earlier audit percentages do not override that ledger. Capability Audit
v2 and the detailed audit of 39 partial capabilities were not found in tracked main;
the owner's mission is the fixed authoritative Wave 2 scope. No 113-capability audit
has been restarted. Uncommitted work in the owner's original checkout is excluded.

## Capability ownership and acceptance

Ownership names identify architectural responsibility within this assignment,
not additional people or agents. Acceptance criteria below are future Wave_2_B gates.

| Capability | Current baseline | Required implementation | Owner / dependencies | Security invariants | Wave_2_B acceptance |
|---|---|---|---|---|---|
| A12 | Immutable extension field metadata, field ACL, generic records | Governed optional custom fields, versioned definitions, safe upgrade restrictions | Core metadata / Host control plane, SQL proof, SQLite, native editor | Never modify package bytes; no permission weakening; shared changes require Host | Create/read/update custom fields across two clients; unauthorized and stale revisions denied; old records survive |
| A11 | DocType labels/UI declared inside packages | Supported label/layout property overlays, deterministic base merge | Core metadata / A12 foundation | Operations, field types, permissions and lifecycle cannot be overridden | Deterministic merge; invalid properties and destructive changes rejected; explicit base digest mismatch |
| K09 | Local declarative builder, approved registry | Owner-scoped drafts, versioned Host synchronization and package-compatible overlays | Client persistence / A11/A12, immutable package digest | Local drafts never imply Host publication | Reopen drafts offline; publish/retry/conflict; approved package remains byte-identical |
| D08 | Generic operation and field authorization | Permission-aware CSV export and import access | Host transfer / existing command/query gateways | Operation plus field ACL at execution; exact scope | Negative read/create/field grants, revocation mid-transfer and cross-scope attempts |
| J01 | Single authenticated command route | Bounded declarative CSV mapping/preview/validation and authoritative row writes | Core transfer / metadata, jobs | No direct bulk SQL; no scripts; fixed limits | Quoting/newlines/BOM/invalid UTF-8; data types, required fields, row errors, batch bounds |
| J03 | Durable command receipts/idempotency | Import duplicate detection, per-row stable command IDs, retries/progress | Host jobs / J01, command executor | Retrying must never create a second effect | Duplicate IDs, lost receipt, worker restart/lease race; existing-record conflict and partial failures |
| K08 | Approved metadata transfer and query filters/sort/cursors | Reuse query pagination for bounded field-safe export; metadata-compatible transfer | Host/client transfer / query gateway | Export projection validated; no hidden-field filtering or sorting side channel | Query/export equivalence, stable page boundaries, permissions changed between pages |
| M01 | Tenant-scoped identity branches, first-admin broker | Governed organization/company/branch administration within existing identity trust | Host administration / Recovery Authority, scoped user administration | No new tenant bootstrap or cross-branch grants via convenience API | Exact scope, branch membership, parent hierarchy, concurrent updates and audit |
| M02 | Host endpoint/profile settings, readiness | Bounded scoped configuration and operational settings | Host control plane / M01 | Never accept credentials, SQL, executables or arbitrary paths as settings | Persist/reopen; unauthorized edits denied; secret redaction; configuration effect |
| M05 | Trusted installed schema-upgrade backup safeguards | Backup policy/schedule, trusted execution, integrity metadata and retention | Trusted operations / private files, PostgreSQL tools, witness protocol | Never expose DB credentials or weaken independent recovery witness | Private ACLs, quiesced cluster consistency/checksums, schedule failure, retention safety, tamper detection |
| M09 | Guarded Recovery Authority/schema upgrade flows | Controlled restore planning/execution and safeguards, operational audit and diagnostics | Trusted operations / M05, identity recovery | No live database overwrite in Wave_2_A; restored credentials remain fail-closed | Disposable restore only in B; stale witness rejection; compatibility and identity recovery; no automatic production restore |
| B09 | Generated native lists with query/filter/sort | Persistent user-owned saved searches/filters and record views | Native workspace / Core views, SQLite, Host definitions | Current Host ACL governs every business-data read | Persist/reopen, change scope/user, revoke permission; filter/sort/columns round trip |
| C08 | Extension cards/navigation and generated forms | Permission-aware module/workspace organization | Native workspace / B09 | Visibility comes from current Host session, not stored grants | Different roles/scopes; no-data, offline, denial and stale-session states |
| C09 | Per-screen query state | User-owned density/theme/navigation preferences | Native persistence / SQLite migration | User and endpoint separation; no secrets in prefs | Upgrade old DB, restart, switch actor/Host, Windows/Android narrow layout |
| C12 | Approved report execution and generated UI | Declarative native dashboard presentation | Native workspace / existing report metadata/query | Reports always execute under current Host identity | Report cards, denied filters/fields, bounded tables, loading/error/empty states |
| F05 | Report metadata and execution | Workspace integration with installed approved report metadata | Native workspace / C12, approved package hash | Installed package must match Host release | Report compatibility across releases, revocation and unavailable package |
| H04 | Immutable audit/journal/outbox and diagnostics | Document history and audit-oriented activity UI | Host/native history / record read ACL, audit projection | No hidden values in history; current field visibility | Revision chronology, deleted/restricted records, cross-tenant denial, redaction |
| B02 | Typed versioned command, metadata, management contracts | Published versioned developer platform interfaces | Core / existing extension engines | Compatibility and explicit version refusal | Old packages still load; unknown new contract versions rejected |
| K10 | Declarative lifecycle and approved business operations | Reusable governed APIs, safe lifecycle behaviors | Core/Host / B02 | No uploaded handlers/code/SQL/scripts | Existing submit/cancel/amend/governed operations preserved; malformed extensions rejected |
| L01 | SQLite client command queue; no general Host job engine | Host-owned durable jobs, identity/state/retry/cancel/audit/visibility | Host jobs / authoritative executor, SQL persistence | Distinct from client queue; reauthorize every effect; fenced claims | Concurrent workers/crashes, stable IDs, revocation, bounded retries/cancellation and audit |
| D09 | Opaque tokens, scoped credentials, pairing, TLS pinning | Bounded compatibility evaluation; reuse existing identity | Security boundary / persistent authentication | No third-party identity runtime without a concrete requirement | Documented accepted/deferred scope and denial coverage; no auth bypass |
| J04 | Bounded authenticated HTTP command/query/package APIs | Bounded transfer/contract integration only | Host API / B02/J01/L01 | No arbitrary outbound URL, webhook code or general integration runtime | Reject unknown routes, handlers, executable fields, oversize payloads and tenant spoofing |

## Shared constraints

Native Flutter remains Windows-first/Android-compatible. PostgreSQL is shared-data
authority; SQLite drafts and pending commands remain provisional. Core stays pure
Dart. Metadata extension packages contain no executable code. All shared writes
must revalidate current identity, exact tenant/company/branch scope, operation and
field grants within the authoritative transaction. No compatibility claim may be
inferred from code inspection. Safe additive migrations must preserve versions
001-036 and their historical checksums. Newly introduced private tables require
forced RLS and owner-only policies; callers receive fixed vetted functions only.

## Implementation order and delivery status

Core contracts precede persistence and Host authorization, then CSV/jobs,
administration, native UI and handoff. The progress ledger and handoff describe
actual delivered behavior and its explicit safety/data-availability boundaries. A definition, interface or test specification alone is not completion.


## Final A implementation evidence (2026-11-14)

**WAVE_2_A - IMPLEMENTATION COMPLETE / UNVERIFIED**. The baseline column above
continues to describe accepted main; it is not a claim that the delivered code
has runtime acceptance. Source checkpoint:
`a46307f9b15a3d38d469dce642d3f38b985eb4dd`, branch `feature/wave-2-a`, Draft PR #6.
Architectural owners, dependencies and future acceptance criteria above remain
applicable. The following are actual integration points, not interfaces alone.

| Capability | Delivered implementation evidence |
|---|---|
| A12 | Core customization parsing/merge; SQL save/effective policy; native field/form editor and governed writes; SQLite drafts; cross-release preparation/activation |
| A11 | Supported label/layout/title/icon/order validation and deterministic Core/SQL overlay merge; native presentation editor and collision-safe catalog keys |
| K09 | Owner-isolated drafts, CAS requests/revisions, current-authorized publication, explicit conflict/release rebase, old-overlay revision retention |
| D08 | Host preview/command authorization and field-aware query/export; current permissions inside every effect |
| J01 | Core structured CSV and declarative mapping; native preview/mapping; bounded durable Host execution |
| J03 | Stable import/job/command IDs; SQLite/SQL original row labels; redacted outcomes including cancellation; durable retries and journal reuse |
| K08 | Existing filter/sort/cursor gateway reused; projected/formula-safe CSV pages; existing package builder/registry metadata transfer preserved |
| M01 | Core organization change contract; SQL entity mirrors, parent/CAS/idempotency/archive checks; archive-aware identity; Host/native administration |
| M02 | Shared scoped settings and native editor; business admission/claim guards; page/import bounds and job archival consumers |
| M05 | Core backup policy; Host private operations/scheduling; native UAC approval; fixed SYSTEM task; quiesced BackupOnly, hashes, exact policy pins, bounded retention |
| M09 | Protected compatibility/hash plans; explicit local restore; staged verification, preserved cluster, independent journals/witness, reconciliation and delivery health |
| B09 | User-scoped saved views/search/filter/sort/columns, native editing/publication, SQLite persistence and current Host queries |
| C08 | Permission-aware installed module navigation, current session checks, metadata-only offline drafts and error/denial/loading states |
| C09 | Endpoint/tenant/company/branch/actor preference ownership; persisted theme/density/module order, responsive native navigation |
| C12 | Declarative native report cards and dashboard persistence; current-approved report queries and denial/empty states |
| F05 | Existing report contracts/metadata integrated with installed approved package digests |
| H04 | Transactional record mutation trigger plus source command capture; retained legacy source seed; current-authorized chronological pages and native deleted-ID lookup |
| B02 | Core v1 validators, strict Host/native route contracts and PLATFORM_CONTRACTS_V1.md; original Wave 1 envelopes and package formats retained |
| K10 | Existing fixed declarative lifecycle/effect engine reused through authoritative commands/jobs; no uploaded handlers |
| L01 | Host-owned durable jobs, fenced claims/results, current execution grants, retries/cancel/ambiguity/audit/diagnostics and terminal payload archival |
| D09 | Existing identity/pairing/reissue/TLS/ceilings reused; no general third-party identity framework introduced |
| J04 | Concrete bounded authenticated declarative transfer/extension/job/operations APIs; arbitrary connectors/scripts/outbound endpoints refused |

Primary source files are `customization.dart`, `data_transfer.dart`,
`workspace.dart`, `platform_administration.dart`, `wave2_platform.dart`,
`persistent_identity.dart`, `durable_command_host.dart`, `workspace_store.dart`,
`local_command_queue.dart`, `workspace_page.dart`, `platform_administration_page.dart`,
`host_operations_page.dart`, `document_activity_page.dart`, PostgreSQL
`wave2*.sql`/`administration_change.sql`/migrations 037-040, and installed Windows
`manage-host-operations.ps1`/`HostOperationStorage.psm1`/backup/restore helpers.
The handoff maps these names to package roots and explains the trust boundaries.

Compatible, non-destructive customization release migration is implemented.
Arbitrary destructive custom-field conversions are refused. Organization identity
and new tenant provisioning stay inside existing trust boundaries; company/branch
creation never grants credentials or access. Physical operations need local
Windows approval because they affect the entire cluster. No real backup, restore,
scheduler, schema migration or production action was executed in A.

Legacy source history is backfilled from retained authoritative metadata. Old
cross-record target events and prior field values were not recorded by Wave 1;
they cannot be reconstructed without additional original evidence. H04 captures
all new affected targets/source operations and declares the historical boundary.
D09/J04 intentionally defer general federation, executable integrations, webhooks
and SQL connectors without a concrete bounded requirement. These are explicit
architecture/data limits; no missing implementation is represented by a placeholder.
