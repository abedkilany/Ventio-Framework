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
| M05 | Trusted installed schema-upgrade backup safeguards | Backup policy/schedule, trusted execution, integrity metadata and retention | Trusted operations / private files, PostgreSQL tools, witness protocol | Never expose DB credentials or weaken independent recovery witness | Private ACLs, dump consistency/checksum, schedule failure, retention safety, tamper detection |
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
001–036 and their historical checksums. Newly introduced private tables require
forced RLS and owner-only policies; callers receive fixed vetted functions only.

## Implementation order and remaining scope

Core contracts precede persistence and Host authorization, then CSV/jobs,
administration, native UI and handoff. The progress ledger and handoff describe
actual delivered behavior and explicitly retain any unresolved requirement from
this table. A definition, interface or test specification alone is not completion.
