# Wave 2 B verification plan  -  NOT EXECUTED

This is a specification for a future explicit Wave_2_B assignment. No commands
or scenarios below were executed during Wave_2_A. A remains partial; missing
scope must be implemented before it can earn the corresponding acceptance gate.
Do not infer acceptance from source presence, formatter output or automatic CI.

## Admission and fixture gates

1. Owner reviews the exact branch/head and outstanding A gaps. Record candidate
   commit, Dart/Flutter/PostgreSQL versions, OS/device versions and package hashes.
2. Use dedicated disposable PostgreSQL fixtures and isolated SQLite/app-support
   directories. Do not target installed/customer databases or preserved Wave 1
   evidence. No production restore/overwrite. Use GitHub-hosted runners or a
   separately approved isolated verification environment, not the owner's
   workstation or self-hosted runners.
3. Provision explicit v1 permissions using trusted fixture identity administration.
   Include separate tenants, multiple company/branch pairs, actors/devices, role
   grants and restricted credential ceilings. Do not widen old tokens implicitly.
4. Resolve pinned dependencies, run formatting and analyzer/static contract gates,
   then the existing Core/Host/PostgreSQL/API/native suites. Record every command,
   exit status, skipped case and fixture cleanup. Add/run focused tests below;
   repeat broader checks only after relevant changes/failures.

## Capability acceptance matrix

| Capability | Required positive evidence | Required negative/failure evidence |
|---|---|---|
| A12 | Add each supported scalar custom field; native create/update/detail through the same effective schema; old record preservation | Unknown properties, required fields, permission overrides, duplicate/base field names, type/removal/constraint changes, total field limits denied |
| A11 | Deterministic Core/SQL merge for list/form/detail/page label/title/icon/order; required form fields retained | Invalid/duplicate layout fields, unsupported icons, order bounds, key namespace and mismatched base digest denied; repeated label change during one app session |
| K09 | Draft reopen offline, stable request retry, Host publication across two clients, explicit stale-revision rebase | Lost response; edit during publication; concurrent owners; conflict survives restart; immutable package bytes/digest unchanged; cross-release migration gap blocks acceptance until implemented |
| D08 | Import create/update API permissions and readable-column export | Missing DocType/operation/field grants, role removal, disabled actor/device, expired/revoked/ceiling-limited token, tenant/company/branch spoofing; no hidden values in errors |
| J01 | CSV quotes, escaped quotes, multiline fields, BOM, CRLF/LF; decimal/integer/bool/date/enum/reference/child values; defaults/calculations; mappings | Invalid UTF-8/NUL/quotes/headers/column counts/types/required fields; size/row/column/cell bounds; overflow, rounding, exponent/hex inference; malformed or forbidden child fields |
| J03 | Duplicate file and readable-Host IDs; mixed valid/error rows; stable command/job identities; row outcomes and progress after restart | Same ID/different payload conflicts; crash/lost response at every commit boundary; references/permissions changed after preview; original source-line mapping gap must be implemented/tested |
| K08 | Export matches approved query/filter/sort/pagination and chosen fields; extension import/export retains base digest | Hidden field filter/sort/projection denied; cursor replay across scope/query/release; revoked permissions between pages; response bounds; formula strings escaped, numeric negatives preserved; concurrent updates documented |
| M01 | Complete organization/company/branch model, native CRUD and trusted provisioning | Cross-tenant hierarchy edits, branch reparenting, invented scope grants, orphan/duplicate/concurrent entities; no acceptance while implementation absent |
| M02 | Scoped setting persistence/revisioning and actual header/notice effect; complete intended operational settings after A completion | Arbitrary SQL/scripts/paths/URLs/credentials refused as setting structure; unauthorized/conflicting edits; no identity-routing changes via display settings |
| M05 | Quiesced consistent backup; per-file hashes/bytes/counts; private manifest; future schedule and retention policy/executor | Same-size content tamper, missing/extra files, junction/symlink ancestors, broad ACLs, disk/copy/hash/restart failures; scheduler restart/time/change/catch-up; retention never removes live data, partial/quarantined/last good or recovery evidence |
| M09 | Disposable staged restore, version/profile checks, preserved current cluster, coordinated recovery and diagnostics | No confirmation/elevation, running Host, wrong service/root/PG version, tampered or writable manifest, staging failure; legacy opt-in; stale witness rejected; no automatic credential resurrection or production restore |
| B09 | Saved searches, exact filters, columns, sorting and revision sync across restart/devices | Hidden/stale fields denied, deleted package/report, unsupported contract version, concurrent view edits and oversized definitions |
| C08 | Current-permission module links and saved workspaces; module ordering | Role/scope/user/endpoint changes; old metadata never grants business access; unavailable/unapproved/mismatched installed package |
| C09 | Per-user/Host/scope theme/density/order persists, including offline edits | Actor/Host/scope isolation; corrupted preferences; empty state; old queue migration; preference publication failure/retry/conflict |
| C12 | Declarative report cards, aggregates/groups, saved metadata and loading/empty states | Unknown report/module/version/filter, hidden report fields, revocation, over-limit cards/groups; no query code or web UI |
| F05 | Existing approved report metadata integrated with matching installed package | Package supersession/revocation, digest mismatch, missing dependency, unauthorized report and invalid filter |
| H04 | Current-authorized source-document event order/revisions/actors and latest bounded history | No field values leaked; same record ID in another tenant/module/DocType; deleted/restricted records; legacy/cross-effect coverage gap must be closed or explicitly rejected by owner |
| B02 | v1 route/schema/contract examples and old Wave 1 wire/package compatibility | Unsupported versions/properties; direct job envelopes receive the exact HTTP wire admission restrictions |
| K10 | Existing submit/cancel/amend/calculation/numbering/governed effects via approved metadata and jobs | Executable handlers, SQL/script fields, undeclared operations/effects, invalid operation versions/inputs; no financial/inventory shortcut |
| L01 | Job submit/list/current ownership; fenced workers; retry/backoff; cancellation; diagnostics and audit | Two workers claim same row, expired lease/stale finish, five-attempt exhaustion, DB/witness outage, actor/device revocation at claim and inside effect transaction, cancel before/during/after acceptance; no credential digest/lease/payload exposure |
| D09 | Existing opaque identity/pairing/reissue/TLS behavior preserved | No new third-party authentication bypass; scope/ceiling/revocation/TLS/redirect negative cases |
| J04 | Bounded authenticated declarative integration requests | Unknown routes, arbitrary outbound endpoints/handlers/SQL/scripts, nested/oversized bodies, method/content-type/auth errors and tenant spoofing |

## Database and recovery gates

- Fresh PostgreSQL 16 installation through all migrations/bootstrap; inspect four
  new table owners, forced RLS, owner-only policies, sequence/function ACLs and
  runtime/Identity API capability assertions. Test direct SQL under every role.
- Upgrade representative 001-036 databases through the existing witness-aware
  bridge. Preserve records, audit/journal/outbox, users, credentials, roles/grants,
  branch scope, packages, numbering and pending recovery state. Reapply contracts
  idempotently; reject modified/unknown ledgers and incomplete security contracts.
- Compare Core and SQL effective JSON/policy for absent UI defaults, multiple
  overlays, custom catalogs, field order, old rows and package changes. Exercise
  read/command/customization/release races and lock ordering with time bounds.
- Crash definition mutation before/after witness pending, SQL write, commit and
  witness finalize. Verify no unsafe witness adoption or unauthorized replay.
- SQLite queue v1->v2 with pending/retry/accepted/rejected/conflict/fixture entries:
  exact envelope/receipt/ID preservation and projection default 1. New workspace
  entries use 0 and must not falsely update base caches. Verify fresh DB, WAL/FULL
  crash durability, interrupted upgrade, reopen and documented binary rollback.
- Workspace DB: owner-key isolation, dirty-draft retention, concurrent edit/ack,
  Host revision conflict, explicit rebase, metadata cache without business-read
  authority, stable pending job submissions after crash/retry.
- Backup v2 checks must fail on one-byte same-size tamper and staged-copy mismatch;
  manifest privacy supplies trust, hashes supply content integrity. Legacy v1
  must require explicit opt-in and remain distinguishable from hashed evidence.
  Keep the external Recovery Authority independent throughout disposable restore.

## Native/platform gates

Exercise real Windows and Android native UI at desktop/tablet/320-400 px widths,
large text scaling, long English labels, keyboard/focus/scroll behavior and display
rotation. Cover workspace rail/bottom navigation, dense module actions, dialogs,
CSV mapping, layout ordering, custom fields and child grids, current-authorized
references, write-only values remaining untouched, dashboard/report tables,
history, jobs and all loading/empty/offline/denied/error/recovery states.

Use two devices and two identities: publish metadata, reconnect/sync, edit offline,
lose a response, restart, reconcile genuine Host receipts and conflicts. Confirm
that old clients receive base fields and can preserve optional custom data.
Test a new client against an older Host: new routes fail safely and accepted
Wave 1 workflows remain available. Build Windows/Android only within the future
authorized B environment, and record install/upgrade/launch evidence separately
from unit/widget results.

## Exit gates and evidence

Every fixed-scope capability needs implementation evidence plus passing relevant
positive/negative/runtime/platform gates on the exact candidate. Open A gaps
cannot earn acceptance through a test plan or interface. Record defects, fixes,
reruns, skipped cases, security findings, migration/restore artifacts, sanitized
correlation IDs and cleanup. Never publish credentials or witness secrets.

Automatic PR checks may supply isolated evidence only when their exact commit,
runner and coverage are recorded. They do not constitute formal B acceptance.
Owner acceptance is independent. Do not merge/deploy or begin Wave_2_C from this
plan; C requires its own explicit assignment and protected integration process.
