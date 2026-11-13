# Wave 2 A engineering handoff

**WAVE_2_A â€” PARTIAL IMPLEMENTATION / BLOCKED**

Date: 2026-11-13 (Asia/Beirut). Repository: `abedkilany/Ventio-Framework`.
Branch: `feature/wave-2-a`. Base: `7d74a706ef4bb7f9994d151af486eaa38066e633`.
Implementation checkpoint: `059541a0354dba54983880a4e0243bb8ea27efd8`.
The documentation commit follows this code checkpoint; the final branch head and
Draft PR URL are reported in the handoff message / GitHub PR.

## Decision and implementation blockers

The complete assignment is unfinished. This checkpoint contains real integration
across Core, PostgreSQL, Host, SQLite and native Flutter, but is not a complete
Wave_2_A submission. No compilation, runtime correctness or test result is claimed.

Remaining in-scope engineering prevents completion:

1. **M01/M02:** Full organization/company/branch entity administration and native
   CRUD are absent. Existing trusted branch registration and identity management
   remain available. New scoped configuration supports a display name and notice;
   it cannot create identity scopes or change database/credential configuration.
2. **M05/M09:** Backup scheduling/policy application, retention and full native
   operational management are absent. The existing elevated, quiesced upgrade
   backup/controlled restore path now verifies hashes; this is not a general
   scheduled backup service. A reviewed maintenance lifecycle is still needed.
   No runtime-login backup shortcut, new superuser, automatic witness reset or
   HTTP live-restore endpoint was substituted.
3. **A12/K09:** Cross-release custom-field rebase/migration is absent. SQL refuses
   package approvals that would strand custom fields from another release.
   Optional additive scalar fields are supported; field removal/type/constraint
   changes require additional migration engineering. Safety refusal preserves data.
4. **J03/H04:** Host outcomes correlate by command ID; original CSV line numbers
   exist only in preview. Activity covers new source-document commands, latest
   100 events; legacy backfill, complete pagination and every cross-record effect
   target are not integrated.
5. **Native field boundary:** Workspace edits exclude redacted write-only fields,
   preventing untouched blank controls from clearing unseen values. A dedicated
   native write-only editing interaction remains outstanding. Host/API field
   authorization remains active.

These are engineering gaps, not requests for permission. They must be addressed
before a complete Wave_2_A submission. The B plan retains their acceptance gates;
documentation and interfaces do not replace the missing implementation.

## Implementation evidence

| Area | Relevant files and actual behavior |
|---|---|
| Customization | Core `src/customization.dart`, `contracts/wave2_customization.schema.json`: immutable overlay, optional scalar fields, label/layout/page overrides, inherited field ACLs, full bundle validation, structural-change refusal |
| Transfer | Core `src/data_transfer.dart`: bounded CSV, mapping, per-source-row validation/errors/duplicates, exact decimal conversion, existing metadata/default/child validation, formula-safe string export |
| Workspace contracts | Core `src/workspace.dart`: saved view, preference, dashboard and bounded configuration validation; v1 contract and named permissions |
| Persistence/SQL | `migrations/postgres/037_wave2_platform.sql`, `security/postgres/wave2.sql`: definitions, immutable revisions, durable jobs/events, effective package merge, scoped CAS/idempotency, fenced job lifecycle, upgrade guard and redacted activity |
| Security installation | `bootstrap.sql`, `wave2_upgrade.sql`, `runtime_check.sql`, `schema_profile.sql`; installed `bin/trusted_windows_host_upgrade.dart` applies the vetted contract, with owner-only private tables and recovery admission |
| Host integration | Host API `src/wave2_platform.dart`, `host_api.dart`, `command_validation.dart`: bounded authenticated routes, existing query/export and command admission reuse, preview, job worker and protected diagnostics |
| Authority | Host API `identity_store.dart`, `persistent_identity.dart`, Host `src/durable_command_host.dart`: immutable base digest verification; effective Dart metadata and signed SQL policy; job authorization inside the effect transaction; atomic activity/effect/receipt/audit/outbox |
| Host lifecycle | Host API `bin/local_host.dart`: platform gateway requires the trusted Identity API connection; starts/drains worker; binds existing report gateway to persistent listeners |
| SQLite | Native `src/workspace_store.dart`: exact owner/Host/scope isolation, WAL/FULL durability, drafts, CAS request identities, conflict retention/rebase, cached metadata and stable pending job submissions |
| Native UI | Native `src/workspace_page.dart`: module navigation/order, saved searches/views, preferences, approved report cards, CSV mapping/Host preview, job progress/cancel/retry, field/layout/page editor, scoped settings and source activity details |
| Form and queue reuse | Native `extension_studio_page.dart`, `local_command_queue.dart`, `queued_record_reconciliation.dart`: optional governed persistence/reference adapters reuse existing form/child controls; queue v2 preserves old entries and separates effective-metadata edits from immutable-base record caches |
| Transport/catalog | Native `host_extension_packages.dart`, `app_localization.dart`: existing credential vault/pinned TLS/redirect refusal; versioned platform requests; custom fallback labels versioned without replacing base catalogs |
| Backup/restore | Windows `HostBackupIntegrity.psm1`, `upgrade-host-database.ps1`, `restore-host-upgrade-backup.ps1`: source/copied-file SHA-256 comparison, restricted v2 manifest, manifest trust/path checks, staged-copy verification, explicit legacy opt-in and unchanged external witness separation |
| Packaging | Windows `build-host-payload.ps1`: includes integrity helper in the existing verified payload and ships the new vetted SQL contracts |

Paths abbreviated above are under `packages/ventio_core/lib`,
`packages/ventio_host_api/lib`, `packages/ventio_host/lib`,
`packages/ventio_native_client/lib`, `security/postgres`, and `scripts/windows`
as indicated. The full API and supported boundaries are in
`PLATFORM_CONTRACTS_V1.md`; capability-by-capability baseline/ownership/dependencies/
security/future gates are in `WAVE_2_SCOPE_AND_ACCEPTANCE.md`.

## Architecture and compatibility

Approved package bytes/digests remain immutable. Customization is separately
owned by one exact tenant/company/branch, pinned to a release digest. SQL signs
effective authorization metadata; Dart validates that effective bundle while
checking the separate original package digest. Wave 1 query routes project base
fields; the new platform query explicitly includes custom fields. Existing
commands, packages and lifecycle/business-operation engines retain their contracts.

Definition mutations reuse the separate scoped Identity API connection and
`RecoveryAuthority.change`. Worker claim/result routines use that trusted
connection under recovery admission. **This role expansion requires independent
B security review**, including proof that no HTTP route exposes digests/leases.
Every effect re-resolves current identity, exact scope, operation and field grants
and `platform.jobs.run` inside its authoritative command transaction.

Host jobs remain separate from the offline SQLite command queue. Stable UUIDs and
the existing journal bridge the command-commit/progress-commit crash window.
Claims have fenced leases and at most five attempts per row. Cancellation does
not roll back an already claimed effect. Revocation may prevent replay of an
already committed receipt: `FAILED` is not proof that no effect committed.

Native metadata/preferences/drafts/import submissions are keyed by endpoint,
tenant/company/branch/actor. Cached metadata supports offline draft editing;
workspace business data requires fresh Host reads. Native form intents use the
existing command queue and genuine Host receipts. Their projection flag prevents
customized values from being interpreted through base-package record metadata.

New privileges are **not automatically granted** to old roles, administrators or
credential ceilings. Future fixtures/operators must use existing trusted identity
administration to provision the named v1 permissions and an appropriate credential.
Old tokens are not widened. Hosts without the trusted scoped Identity API connection
do not expose platform routes; existing functionality remains available.

## Migrations and operations

No migration, backup or restore was executed in this assignment.

- PostgreSQL **037** adds four forced-RLS private tables and a claim index.
  Versions 001â€“036 and their hashes are unchanged. `schema_profile.sql` adds the
  canonical checksum. Fresh bootstrap establishes owner-only ACLs/policies;
  installed upgrades apply `wave2_upgrade.sql` through the existing trusted bridge.
- SQLite queue **1 â†’ 2** adds `project_local_records INTEGER NOT NULL DEFAULT 1`
  with a 0/1 constraint. Old entries retain behavior/receipts; workspace entries
  use 0. No queue rows are discarded. Binary downgrade after this schema change
  is unproven and needs a B rollback fixture/policy.
- Separate workspace SQLite schema **1** stores metadata, preferences, drafts and
  submissions. Existing extension-store schema/package metadata is unchanged.
- Backup manifest **2** adds SHA-256 file entries and excludes the external
  Recovery Authority. Legacy manifest **1** restores require explicit
  `-AllowLegacyInventoryOnly`, acknowledging missing hash evidence. Restore still
  requires elevation, `-ConfirmRestore`, exact service identity and a stopped Host;
  subsequent Recovery Authority-coordinated recovery remains necessary.

## Source review and unverified assumptions

Reviewed architecture, missing integrations, contracts, migrations/RLS, offline
intent and receipts, authorization, failure handling, recovery and Wave 1 reuse.
Confirmed issues corrected during source review:

- Job admission now shares the existing HTTP command wire validator.
- CSV decimal conversion uses exact-scale arithmetic and safe JSON bounds.
- Base digests remain distinct from effective package metadata and old-client reads.
- Changed custom labels no longer collide in the immutable process-wide catalog.
- Scoped notices belong to workspace state; current field redaction is respected.
- Native form reference data is authorized by Host; customized queue entries do
  not mutate base-package record caches or fabricate local acceptance.
- Backup content and staged restore copies are hashed; manifest trust and explicit
  legacy/restore choices preserve the independent witness boundary.

SQL/Dart merge equivalence, grants/RLS/proofs, recovery triggers, SQLite migration
preservation, lease/crash races, actual Windows ACL/path/hash behavior and native
Windows/Android layouts remain unverified. Source review does not establish
compilation, runtime security, or absence of defects. CSV reference/permission
validity can change after preview; export pages observe current Host state and
may reflect concurrent updates.

Only inspection, source editing/formatting and Git diff hygiene were performed.
No analyzer, dependency resolution, tests, builds, database migration, backup/
restore, deployment, workflow dispatch or self-hosted runner execution occurred.
The formatter warned that local `flutter_lints` resolution was unavailable in
the fresh worktree; dependencies were not installed. Automatic PR checks are
reported separately and cannot count as Wave_2_B acceptance.

## Commits and stop point

| Commit | Contents |
|---|---|
| `638dd36234fb887b94d34bf434c633809e3ab87f` | Core contracts and fixed scope baseline |
| `3f89820e54335b39240a5d0587ff8858de728645` | PostgreSQL/Host overlays and durable jobs |
| `8b3fd7dc8d0d91df7f7e6db1b93ef27152dd8fc5` | Admission/customization/schema corrections |
| `295f3670ec93988a16be24674637e149091287fc` | Native workspace, transfer, forms and SQLite migration |
| `50ffdfb2824a0d2b60052de3da353f30de5fe381` | Backup integrity and restore safeguards |
| `059541a0354dba54983880a4e0243bb8ea27efd8` | Scoped notice/redacted-field adapter correction |

All source commits were pushed without force. No protection, required check or
workflow configuration changed; nothing was merged into `main`. The original
dirty checkout was preserved. Stop at the Wave_2_A partial handoff. B/C require a
new explicit assignment after owner review; neither phase has begun.

## GitHub handoff checkpoint

Draft PR: https://github.com/abedkilany/Ventio-Framework/pull/6 (target `main`).
GitHub returned `draft: true`, `merged: false`; no merge was performed.
At the first PR inspection, all eight automatically triggered workflow runs on
`3466020a95ce12ed053a96b674e9c6cc77ece4ba` were `in_progress`, with no conclusions
and no combined commit-status entries. This is a time-specific automatic-CI
snapshot, not acceptance evidence. A documentation-only handoff follow-up comes
after that snapshot; consult the PR for later automatic status. No workflow was
dispatched or rerun by the agent.
