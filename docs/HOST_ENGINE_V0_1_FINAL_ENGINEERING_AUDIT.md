# Host Engine v0.1 final engineering audit and release gate

Audit date: 2026-10-24. Branch: `feature/host-engine-v0.1`.

**Development acceptance: ACCEPTED for this bounded v0.1 scope, valid only with all seven workflows green on the final commit. Production readiness: BLOCKED.** This report is not a production approval, a penetration-test certification or a numerical quality rating. The stable Core `v0.2.0` tag and `main` are unchanged. No original Ventio application code/data is used. Host remains bound exclusively to `127.0.0.1`.

## Acceptance contract

| Gate | Required evidence | Decision |
| --- | --- | --- |
| E1. Contracts and package compatibility | Core assertions, both module demos, Python wire contracts, formatter/analyzer and pinned dependencies | PASS; final HEAD must retain green CI |
| E2. Durable storage and migrations | Atomic journal/record/audit/outbox/receipt, idempotent concurrent retry; checksum/missing/newer/invalid-batch migration rejection | PASS; final HEAD must retain green CI |
| E3. Authorization and SQL isolation | Current server identity/grants on execution AND replay; tenant/company/branch direct-SQL and overprivilege tests; credential lifecycle regressions | PASS; final HEAD must retain green CI |
| E4. Recovery and trust separation | Actual Host/PG process kill, ambiguous commit, fresh-cluster restore; compiled Host under separate UID unable to alter witness/read admin secrets | PASS; final HEAD must retain green CI |
| E5. Bounded performance and shutdown | 10-fixture-user/100-audit-row profile: all eight commands accepted without retry, concurrency four, sample p95 below 10 seconds, scoped read completes; larger profiles measured; real SIGTERM drain/restart | PASS: 75 engineering assertions; measured limits below |
| E6. Honest operational boundary and next phase | Explicit joint-rollback limitation, deployment/restore/witness-upgrade instructions, production blockers and native offline proof plan | Documents included |
| E7. Final commit | All seven Actions workflows green on the final committed tree; protected refs unchanged | Required final publication check; see Actions for the exact commit |

E5 is a predeclared small laboratory envelope for a prototype, not an ERP capacity target. Its larger 100/1000-user profiles are observational: timeout/overload must fail closed and every original command must reconcile without duplicates. Any inability to reconcile a profile fails the test. A larger-profile timeout is reported as a production blocker, not converted to an acceptance claim for that capacity.

## Review coverage and ownership

| Area | Review conclusion and evidence boundary |
| --- | --- |
| Core contracts and metadata | JSON envelopes and outputs are recursively detached/immutable; caller mutation cannot change execution versus fingerprint or corrupt cached receipts. Shared trusted-create validation prevents InMemory/Durable registration drift. Metadata cannot grant capabilities or execute uploaded code. |
| Package dependencies | Core stays pure Dart. PostgreSQL adapter does not depend on HTTP or identity administration. Durable Host owns transaction sequencing. API owns transport/admission and current identity resolution. SQL duplicates scope enforcement deliberately as defense in depth. Pinned CI Dart 3.13.7; database packages accurately require Dart >=3.9 because the resolved driver requires it. Stable Core tag is untouched. |
| Migrations | Entire preflight and new batch share one advisory lock/transaction. Unknown/newer/missing/modified ledger entries and duplicate numeric versions fail closed; later SQL failure rolls back earlier new DDL and ledger inserts. A trusted approved manifest prevents startup on unsupported schemas; recovery fingerprint detects ledger changes for a running Host. Actual schema/function integrity still trusts owner/deployment administration. |
| Durable commands | Reservation, operational record, audit, outbox and saved receipt commit atomically. Original-ID retries reconcile ambiguous outcomes. Replay rechecks current authority. Exactly one database effect is scoped to this vetted transaction, not arbitrary external side effects or client sync. |
| API and identity | Loopback only, bounded body/depth/dependencies/admission and generic errors. Client-supplied actor/device/scope is checked against persistent server identity. Opaque secrets are stored as digests; expiry, disable/revoke and exact grants apply inside the command transaction. |
| PostgreSQL security | Runtime is separate from owner/admin/migrator, cannot directly read/write private identity tables or call admin functions; forced RLS revalidates credential/scope. Runtime can write its permitted business rows and receipt column, so Host remains responsible for full business validation. Owner/superuser can change protections. |
| Credential lifecycle | Reviewed exact-scope provisioning and atomic old-digest rotation preserve ceilings, reject revoked/expired credentials and serialize concurrent administration. Local private delivery avoids raw token stdout/argv. No remote recipient/pairing protocol or platform keystore integration is claimed. |
| Recovery | Pending witness is durable before DB mutation; ready only after acknowledged commit. Database-only/witness-only rollback mismatches quarantine. Matching rollback of both copies is intentionally reproduced and remains fundamentally undetectable by this local design. Separate OS ownership prevents ordinary Host mutation, not writer/root rollback. |
| Operations | Compiled launcher requires read-only independently owned witness plus restricted DB/schema checks before listening. Health is liveness. Graceful shutdown drains actual admitted work. Restore includes roles/sequence ACL evidence and full logical manifest. No production HA/PITR/power-loss guarantee. |

Compatibility note: V1.2 schemas and command protocol 0 / HTTP API v1 remain unchanged. The feature branch deliberately removes direct public `CommandEnvelope` construction: callers must use `fromJson` so scalar fields and the immutable original cannot disagree. This is a source-level restriction for hypothetical external consumers; all repository callers already use the factory. It does not rewrite the stable Core tag. Immutable receipt output is likewise an intentional caller restriction. The new writer UID setting and witness-fingerprint format require the controlled upgrade described in operations.

## Proven defects fixed in this audit

| ID | Defect | Repair and regression |
| --- | --- | --- |
| A1 | Nested envelope values and receipt outputs could be mutated after construction | Recursive immutable JSON and private envelope constructor; mutation/fingerprint and saved-receipt regressions |
| A2 | Trusted-create rules existed in separate Host implementations | One shared Core validator, exercised by both existing suites |
| A3 | Returned PostgreSQL record nested data could expose internal mutable state | Detached deep copy on access; nested mutation regression |
| A4 | Applied migrations missing from an older checkout were not fully rejected; later migration failure could leave a partial batch | Full manifest preflight and atomic batch; real SQL failure/rollback, unknown/checksum/missing/version regressions |
| A5 | Private-file helper could block opening a FIFO and timed-out helpers could remain alive | Nonblocking open then regular-file check; whole-operation timeout, kill/reap; real FIFO and sleeping-process regressions |
| A6 | A same-UID Host/operator could rewrite the recovery witness | Mandatory pinned independent writer UID; protected 0750/0640 group-readable witness; compiled separate-UID deny-write/unlink/rename/admin-read tests |
| A7 | Host startup lacked exact schema compatibility; an active witness did not cover the migration ledger | Owner-pinned schema manifest plus ledger in fingerprint; unknown-ledger startup and running-admission regressions |
| A8 | Floating SDK and stale historical status weakened reproducibility and review | Pinned SDK, locked DB dependencies, nonmutating format checks, current README/status/operations/report |

The audit uncovered fixture/setup defects while strengthening CI (Dart language-version formatting, local snapshot extra trailing newlines versus exact upstream migration bytes, sudo run-as policy). Those failures were retained as ordinary CI history and corrected rather than weakening production checks. Historical migrations were not rewritten on GitHub.

## Measured performance

Measured on [engineering run 40039937764](https://github.com/abedkilany/Ventio-Framework/actions/runs/40039937764), source commit `93554db972650ba8ff7b80626c67f3e719068d72`: Dart 3.13.7, PostgreSQL 16.15, Linux x86_64, two visible logical processors. [Sanitized machine-readable evidence](../evidence/host_engine_v0_1_benchmark.json) is retained in git; the run also uploads a JSON artifact. These are measurements of the implementation, not a quality score.

| Fixture users / audit rows | Actual users / devices / credentials / grants / audit | Fingerprint median / max (ms) | HTTP median / sample p95 (ms), concurrency 4 | Accepted without retry | RLS read rows / elapsed (ms) |
| --- | --- | --- | --- | --- | --- |
| 10 / 100 | 11 / 21 / 21 / 11 / 105 | 6.426 / 8.029 | 786.388 / 806.807 | 8 / 8 | 9 / 96.393 |
| 100 / 5000 | 101 / 201 / 201 / 101 / 5005 | 96.181 / 97.891 | 5009.396 / 5131.653 | 8 / 8 | 17 / 1816.641 |
| 1000 / 20000 | 1001 / 2001 / 2001 / 1001 / 20005 | 400.450 / 452.573 | 19627.656 / 19894.018 | 8 / 8 | 20 / 8791.240 |

Each profile has five fingerprint samples and eight real HTTP requests in two waves of four. Actual row counts include the operational test identity and administration audit. Every original envelope was replayed and each record/journal/audit/outbox count was exactly one. All measured RLS reads completed before their ten-second SQL deadline. Users, devices, grants and audit history co-vary; this experiment does not isolate their individual causal contributions. The full 75-assertion gate also passed separate-UID protection, FIFO/helper timeout, schema quarantine, administrative pending state, actual lock timeout/retry, SIGTERM drain/restart and isolated rollback/restore checks.

### Recovery proof follow-up (Windows local PostgreSQL)

On 2026-10-24, the repeatable Windows integration created 1,000 users, devices,
credentials and grants plus 20,000 identity-audit rows in a disposable
PostgreSQL 16.15 container. Across five samples it measured a 1.818 ms median
recovery snapshot, 632.218 ms median RLS read for 20 rows, and 1,375.098 ms
median authenticated Host query for 20 rows. The same run passed 43 package,
branch-isolation, migration-rebootstrap, proof replay/forgery, recovery
generation monotonicity, and recovery invalidation assertions. It simulated
`pgcrypto` in the previous private schema before applying the current bootstrap.
Runtime access to the isolated crypto schema was denied.

This is not a direct before/after comparison: the earlier 400 ms snapshot,
19.6-second HTTP command, and 8.8-second RLS read came from a two-CPU Linux
GitHub runner, while the follow-up ran on the Windows development machine with
Docker PostgreSQL. The fixture directly measures the recovery and read paths;
it does not remeasure concurrent command throughput or a customer workload.

The follow-up replaces repeated full identity/audit serialization with a
protected generation advanced by database triggers and an HMAC proof bound to
one admitted transaction. The recovery-state row forces every update to advance
the generation and rejects delete/truncate. RLS verifies that proof without
rescanning all identity history. The HMAC primitive lives in the separate `ventio_crypto`
schema, which runtime and identity-administration roles cannot use. The HMAC
key is the owner-only authority ID, supplied from the independent witness and
compared with protected database state. The database fingerprint still includes
its protected state and migration ledger, so covered row changes fail closed
while the installed triggers remain active. The trusted database owner can
alter those triggers or functions and remains in the trust boundary. Existing witness files from the previous
fingerprint profile require the controlled reset/re-enrollment transition in
operations documentation.

**Production capacity gate remains open.** These local results show that the
specific 1k-user/20k-audit hot path is no longer dominated by full history scans,
but a 1.2-second authenticated page query is not an enterprise SLO. Repeated
authorization and HMAC checks, global recovery locks, command throughput,
backpressure and larger/concurrent workloads still need measured targets and
soak tests. Do not replace these guarantees with client-controlled cached
permissions or fingerprints.

Sample p95 for eight requests is effectively the maximum; it is not a statistically stable tail estimate. GitHub shared-runner CPU count is visible logical processors, not reserved cores. No customer workload, throughput SLA, multi-host load or long-running soak is represented.

## Regression and CI evidence

All seven implementation workflows passed on commit `93554db972650ba8ff7b80626c67f3e719068d72`; the final documentation/evidence publication must pass the same seven again before closure is announced. Run links below pin the measured implementation rather than a moving branch.

| Workflow | Evidence | Results |
| --- | --- | --- |
| Core Foundation | [40039937811](https://github.com/abedkilany/Ventio-Framework/actions/runs/40039937811) | 50 Core assertions, both demos; 20 Python contract tests and static package/schema checks |
| Host Persistence | [40039937780](https://github.com/abedkilany/Ventio-Framework/actions/runs/40039937780) | 19 PostgreSQL assertions including migration regressions |
| Durable Commands | [40039937933](https://github.com/abedkilany/Ventio-Framework/actions/runs/40039937933) | 26 assertions |
| Host API | [40039937794](https://github.com/abedkilany/Ventio-Framework/actions/runs/40039937794) | API 38, HTTP/PG 34, persistent identity 71, direct SQL/RLS 84 |
| Crash Recovery | [40039937772](https://github.com/abedkilany/Ventio-Framework/actions/runs/40039937772) | 110 crash/restore assertions; restored-cluster identity 71 and SQL/RLS 84 rerun |
| Credential Lifecycle | [40039937786](https://github.com/abedkilany/Ventio-Framework/actions/runs/40039937786) | 117 provisioning/rotation/revocation/recovery assertions |
| Engineering Gate | [40039937764](https://github.com/abedkilany/Ventio-Framework/actions/runs/40039937764) | 75 real PostgreSQL/Linux engineering assertions; benchmark artifact |

Local validation independently passed the four Dart analyzers, Core 50, API 38, both demos, 20 Python tests, package/schema checks and migration-profile consistency. Real PostgreSQL tests ran in isolated Actions PostgreSQL 16 containers; PostgreSQL/Docker were unavailable locally. No database-test simulation is represented as real power failure.

Protected refs checked: `main` commit `f6296d9b40d9a8aa0c2bfc3dc697fc681a3e1bd2`; annotated tag `v0.2.0` object `c63f8026fb33c0f5ab9088c8b18d963ba92c9e76`. Final changes must preserve both values. No new stable release/tag or merge to main is part of this gate.

## Production blockers and unproved properties

1. Independently anchored monotonic recovery authority/fencing and tested compromise/rollback procedures. A local hash, signature without latest-state anchoring, file permissions or a matching old backup cannot prove freshness after joint rollback. Until solved, trusted evidence unavailable means quarantine and conservative re-enrollment, not automatic reopening.
2. Production-scale current authorization and recovery proof. The 1k/20k local read profile now avoids full-history scans, but throughput, pooling/backpressure, larger histories, concurrent tenants and the 1.2-second Host query still have no SLO or soak evidence.
3. Audited secure transport, remote enrollment/recipient authentication, keystore-backed device credentials, rotation delivery, abuse/DoS defense and independent security testing. Existing HTTP must stay loopback-only.
4. Production schema/function/policy attestation, controlled migrations/upgrades and service packaging. Runtime checks are narrow privilege/ledger checks, not a complete defense against compromised trusted deployment administrators.
5. Physical/WAL/PITR restore policy, independently protected backup/witness history, measured RPO/RTO, HA/fencing and actual storage/power-failure evidence. Process kills and logical restore cannot certify hardware durability or prevent loss of commands committed after the chosen backup snapshot.
6. Resource limits, readiness/monitoring, bounded service stop deadlines, log/crash-report secret review and tested operational incident procedures.
7. A consistent authorized snapshot/delta client protocol, cursor/commit-order design, native queue conflict/receipt reconciliation and real Windows/Android install/offline integration proofs. Internal outbox existence does not imply completed synchronization.
8. Financial/inventory posting, decimal arithmetic, domain invariants and external side-effect delivery guarantees. Generic operational create intentionally cannot supply these.

## Next stage

Follow [Native Flutter Client and Offline-first Proof](NATIVE_FLUTTER_OFFLINE_FIRST_PROOF_PLAN.md). Deliver an installed client with a transactional SQLite queue, explicit pending versus confirmed projections, original-envelope retry and authoritative Host receipts. The Linux/loopback transport limitation is an explicit integration gate; do not open the network to make the client demo work.

Current operational instructions: [Host operations](HOST_ENGINE_V0_1_OPERATIONS.md). Earlier stage reports remain useful evidence for their slice; current OS separation/settings and witness-format upgrade requirements supersede their older launcher examples.
