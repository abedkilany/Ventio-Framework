# Wave 2 A engineering handoff

**WAVE_2_A - IMPLEMENTATION COMPLETE / UNVERIFIED**

Date: 2026-11-14. Repository: `abedkilany/Ventio-Framework`.
Branch: `feature/wave-2-a`. Draft PR: [#6](https://github.com/abedkilany/Ventio-Framework/pull/6), targeting `main`.
Base: `7d74a706ef4bb7f9994d151af486eaa38066e633`.
Source checkpoint: `a46307f9b15a3d38d469dce642d3f38b985eb4dd`.
Documentation-only commits may follow this checkpoint; the final PR head is recorded in the final handoff response.

All feasible mandatory implementation paths have source evidence. This replaces
and supersedes the earlier partial engineering checkpoint. It is a source
handoff for independent owner review, not compilation, runtime, security, test,
or platform acceptance. Wave_2_B and Wave_2_C have not begun.

## Closure of the requested implementation gaps

| Requirement | Implementation and integration evidence |
|---|---|
| M01 organization/company/branch administration | Core `platform_administration.dart`; SQL `wave2_administration.sql`, `wave2_identity_base.sql`; Host `wave2_platform.dart`; native `platform_administration_page.dart`. Versioned creation/rename/archive/reactivation, fixed parents, scoped current authority, credential ceilings, idempotent requests, CAS and audit. Archiving retains data/grants and removes effective access; it never silently provisions users or grants. |
| M02 operational settings | Core configuration validation; versioned shared definitions; native settings editor. Maintenance blocks new business effects after receipt replay; job pause prevents new claims and is rechecked inside execution; import row bounds, default record/export page sizes and terminal job payload retention have real consumers. |
| M05 scheduling/execution/retention | Core `BackupPolicy`; `wave2_operations.sql`; `windows_operations_delivery.dart`; native `host_operations_page.dart` and `host_operations_windows.dart`; installed `manage-host-operations.ps1`, `HostOperationStorage.psm1`. Host offers require current direct authority; UAC independently approves a policy. A fixed SYSTEM task checks exact local policy/revision, UTC due time, daily limits and fresh offers. Quiesced BackupOnly execution reuses the existing backup engine. Retention verifies eligible copies, keeps minimum copies/age/pins, and never selects upgrade/recovery/partial/foreign backups. |
| M09 controlled recovery | Protected one-hour restore plans pin backup hashes, machine and schema profile. Explicit native confirmation plus local elevation is required. Existing staged restore preserves and hashes the current cluster, verifies incoming copies, and retains the external witness. The Host stays stopped for existing Recovery Authority-coordinated recovery. Independent local journals survive the restore; admitted results can be reconciled into the restored Host without recreating credentials or grants. |
| A12/K09 cross-release migration | Core `MetadataCustomization.rebase`; SQL `wave2_customization_rebase.sql`; preview/prepare routes and native review. Preserve every custom field, constraint, ACL and stored value; use target layouts plus custom fields. Preparation pins source revision and target digest. Package approval atomically rechecks every affected scope, credential and overlay before activation. Existing base-field migration DSL remains responsible for base fields. Retired overlays remain in immutable revisions. |
| CSV source correlation | Workspace SQLite v2/v3 and Host jobs preserve `importId` plus original preview `sourceRows` alongside stable command IDs. Mixed invalid/skipped rows and batch boundaries do not renumber them. Outcomes, retries and in-flight cancellation results carry the source row. Labels remain after terminal payload archival. |
| Authorized history | `wave2_activity.sql` captures actual source/target/amendment mutations and schema migrations; source operations without a source mutation are also recorded transactionally. Retained legacy source history is seeded idempotently from outbox/journal metadata. History uses chronological keyset pages under current exact-scope DocType read authorization and returns no field values. Native `document_activity_page.dart` includes deleted-ID lookup. |
| Write-only editing | Native shared form has explicit per-field protected replacement, omitted untouched values, and dirty-field patches for governed updates. It never initializes a protected control from a Host value. Governed calculations use the Host's stored inputs. Current permissions are rechecked at Host acceptance. |
| Offline reconciliation | The durable command queue v3 retains original receipts and exact-owner replacement lineage. Customized terminal drafts can be reviewed against a fresh Host revision and requeued under a new command ID, without projecting through base-package caches. Cached metadata supports offline customization drafts; user preferences and pending imports/operations persist separately. |

Abbreviated paths above are under `packages/ventio_core/lib/src`,
`packages/ventio_host_api/lib/src`, `packages/ventio_native_client/lib/src`,
`security/postgres`, and `scripts/windows`. Host source activity is integrated in
`packages/ventio_host/lib/src/durable_command_host.dart`. The detailed fixed-scope
mapping is in `WAVE_2_SCOPE_AND_ACCEPTANCE.md`.

## Architecture and authorization decisions

PostgreSQL remains authoritative. SQLite metadata, interface preferences and
pending commands are provisional until genuine Host acknowledgement. Workspace
business reads require current Host authorization; cached metadata is not a grant.
Local profile checks include endpoint, tenant, actor, device, company and branch.

Approved package bytes and digests remain immutable. Shared customizations are
separately owned, versioned overlays. Core validates merged metadata; SQL binds
and signs the effective authorization policy. Label collisions with base or other
customizations are rejected. Native label keys include their fallback digest.
Wave 1 query routes retain base-field projection, and old writes preserve custom
values through the existing authoritative merge. Definition/rebase/entity changes
participate in the existing Recovery Authority mutation protocol.

Platform organization, customization, configuration and operational management
permissions require direct trusted grants plus the credential ceiling. Business
role administration cannot manufacture these privileges. Ordinary workspace/job
and business permissions continue to support the existing scoped roles. Creating
a company/branch grants nobody access. Branch parents and tenant identity remain
immutable; the active source scope cannot be archived, and tenant archival cannot
strand existing users. Tenant creation/deletion and identity recovery remain in
the existing trusted provisioning boundary.

Host jobs use fenced leases and the existing durable command executor, separate
from the SQLite queue. Each effect reauthorizes current identity, scope, operation,
fields and `platform.jobs.run`. Maintenance does not prevent an identical accepted
receipt replay. Cancellation prevents future claims but cannot undo an accepted
in-flight effect. A cancelled ambiguous attempt reports `CANCELLED_OUTCOME_UNKNOWN`;
it does not claim rejection or rollback. Terminal payload/digest references are
scrubbed after the configured retention period; identities, hashes, source labels,
outcomes and immutable command receipts remain available.

Physical backups contain the entire PostgreSQL cluster. A scoped HTTP permission
alone therefore cannot stop services, read physical backups, restore data or
install a scheduler. A fixed local elevated operator consumes a private Host
offer; remote/Android clients can prepare/review requests, and local Windows
administrators execute them. Offers are bounded two-minute accepted capabilities;
revocation prevents subsequent offers, while an already issued valid offer can
be claimed within its lease. No database authorization lock is held across a
PostgreSQL stop. Exact policy revisions, an admin-only active-policy pin, UTC time,
daily retry journals and a shared maintenance mutex also constrain automation.
No credential, database URL, executable, script, SQL or arbitrary path enters this
protocol. Lease identities are omitted from public operation results.

## Persistence and migration inventory

No migration was executed during A. Source migrations are additive and historical
checksums are unchanged:

- `037_wave2_platform.sql`: private definitions/revisions/jobs/events and RLS.
- `038_wave2_administration.sql`: organization/company/branch mirrors, administrative
  request receipts, operations and prepared rebases; durable CSV labels; legacy
  branch backfill without changing a grant or credential.
- `039_wave2_operation_execution.sql`: private operational authority references,
  offers, schedule/attempt metadata and indexes.
- `040_wave2_job_archival.sql`: preserved job totals, archival metadata and the
  chronological history index.

`schema_profile.sql` includes all four canonical checksums. Bootstrap and the
trusted `wave2_upgrade.sql` install owner-only private tables, precise function
ACLs and the exact supported RLS policy set. The accepted schema migration
validator is reused with a narrow owner context for scoped approval. The common
`administration_change.sql` is installed by both bootstrap and the upgrade path.
The installed payload includes all vetted SQL and the new Windows helpers.

SQLite command queue 1 -> 2 adds the default-1 projection flag; 2 -> 3 adds an
optional unique reconciliation reference, preserving old envelopes and receipts.
Workspace database 1 -> 2 adds CSV labels; 2 -> 3 adds pending operational request
identities. Both retain WAL/FULL durability. New customized form entries use
projection 0. Binary downgrade after these migrations is not established.

## Operational handoff and recovery safeguards

Use the current trusted Setup/upgrade path to install the schema, security
contracts and protected `Ventio/Host/Operations` directory. No installed service
or customer database was changed by this assignment. New management grants must
be provisioned explicitly through existing trusted identity administration; old
credentials do not gain new scopes or permissions automatically.

On the Windows Host, the native backup/recovery page supports policy drafts,
Host publication, operation requests, local approval, results and delivery health.
The fixed installed operator is `host-payload/setup/manage-host-operations.ps1`.
Its scheduler is `\Ventio\VentioHostBackups`, running as SYSTEM. Local policy,
daily execution, restore plan and operation journals live in the admin-only
`ProgramData/Ventio/Installer/Operations` directory. They are independent of the
database and Recovery Authority witness. Never delete an uncertain RUNNING claim
to force replay; inspect its protected journal and actual services/backups first.

BackupOnly does not read the migrator credential or run migrations. A new backup
must verify before retention runs. Retention supports at most 2,000 eligible
inventory entries per execution and a bounded 128 MiB manifest; exceeding a bound
fails safely. The Host result includes the deletion count and at most 100 names;
the complete local journal retains the full deletion list. Restore plans expire
after one hour and pin their backup against retention. The native workflow
requires the same machine/PostgreSQL/schema profile; legacy backups remain in the
existing explicit elevated restore path, including its legacy-integrity opt-in.

Restore preserves the current data and quarantine and leaves the Host stopped
with service recovery suppression recorded. Complete the existing trusted Setup
Recovery Authority-coordinated recovery before reopening it. Do not reset/adopt
a witness automatically, resurrect grants/credentials, or start the Host merely
because PostgreSQL starts. A restored scope missing from the old snapshot requires
trusted identity administration before its result can be reconciled; private
journals remain intact and delivery reports reconciliation required.

## Inherited limits, risks and unverified assumptions

- Wave 1 did not record target-document events for historical cross-record
  effects. Its audit/outbox contain source aggregate/command metadata; its journal
  stores a fingerprint/receipt, not the original target inputs or prior values.
  Therefore old cross-target events cannot be reconstructed authoritatively.
  Available legacy sources are imported; all new effects are captured. The API
  explicitly reports this historical coverage boundary. No inferred events or
  invented field-value history are presented.
- Destructive custom-field type/removal/constraint changes are refused. Compatible
  release rebasing is implemented; arbitrary data conversion is not introduced.
- General third-party authentication, outbound webhooks, uploaded handlers, SQL
  connectors and unrestricted integration runtimes are intentionally outside the
  bounded D09/J04 requirement. The delivered bounded APIs are real implementations.
- Source review cannot establish SQL/Core merge equivalence, lock/race behavior,
  grants/proofs, ACL semantics, service recovery, filesystem atomicity, backup
  completeness, platform compilation or responsive UI correctness. These need B.
- Export pages observe current Host state and can reflect concurrent updates.
  Permission/reference validity can change after import preview. Untouched
  protected values are preserved; explicit replacement/clear remains provisional.
- Automatic CI reported Windows development-host shutdown timeouts with no
  confirmed A source cause. B must investigate. The logical-restore fixture's
  prior name-only ordering was corrected to use full overloaded function identity;
  that source correction was not executed locally.

## Source review findings and phase boundary

Reviewed Core/Host/native boundaries, missing integrations, effective/base metadata,
current scope/field permissions, forced RLS and grants, migration preservation,
retry/receipt/cancellation/crash windows, label collisions, archived scopes,
private physical execution, restore compatibility and old-client behavior.
Corrected confirmed source issues, including the undefined receipt getter,
package-language formatting, non-ASCII handoff text, stale RLS policy expectations,
reserved SQL parameter naming, native localization, source-row correlation,
protected-field patches, non-mutating source activity and cancelled row outcomes.

Only source inspection/editing, Dart source formatting, PowerShell parser
inspection, Git diff hygiene and read-only automatic-CI inspection were performed.
No local analyzer, dependency resolution, unit/integration/regression suite,
Flutter/Android/Windows build, database migration, backup, restore, deployment,
workflow dispatch or self-hosted runner execution occurred. Automatic checks from
pushes are reported separately and do not constitute formal B acceptance.
No branch protection/required check was changed. PR #6 remains Draft and unmerged;
no changes were merged into main. Stop after this A handoff.

## Continuation commits

| Commit | Source purpose |
|---|---|
| `1cf8e35` | Recorded receipt/format/English-only source defects |
| `340d73672b629b7c70172a47616e8b7003d323f7` | Scoped administration, prepared release overlays, durable correlation and history |
| `91c54ac60c558cdd4683c261955c086899e1e250` | Locally approved backup policy/scheduling/retention/restore, native operations and exact security profile |
| `8e37a71ac0cefd0e68af9903bc66e57b26c109cf` | Offline record reconciliation, complete current history, label safety, job retention and integration fixes |
| `db83db541c324b999dc4bac3a067295a4828652d` | Original authority binding for operational results and catalog cleanup |
| `34a166c3d8844c38a36c0b84865f42d3bf88a996` | Reserved SQL parameter correction |
| `a8e7e5d642f5b42e0adb3e9c84c152f70b4a9020` | Native braces/null-aware source style corrections from automatic CI |
| `a46307f9b15a3d38d469dce642d3f38b985eb4dd` | Locale-independent UTC backup policy parsing and daily journals |

Earlier implementation commits remain in the PR history. The original dirty
checkout was preserved. See `WAVE_2_B_VERIFICATION_PLAN.md` for the independent
verification and negative-security gates; none were executed locally in A.
