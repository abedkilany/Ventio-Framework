# Ventio Framework Wave 1 Progress

Canonical execution dashboard. Percentages count accepted deliverables only.

## Overall

**40.15%** `████████░░░░░░░░░░░░` (20% Stage 0 + 20.15% accepted Wave 1)

- Stage 0 Localization Foundation: **PASS — 100% accepted** — **7/7 implementation steps complete** (20% overall)
- Stage 1 Wave 1: **8 / 23 accepted** — D04 `IN_PROGRESS` (65% overall)
- Final Acceptance — Ventio Inventory Operations: **NOT_STARTED** (15% overall)

Progress formula: Stage 0 gate pass contributes 20 points; accepted Wave 1 effort points contribute `65 × points / 100`; final acceptance gate pass contributes 15 points. Overall is capped below 100 until all three gates pass.

## Capability ledger

Effort points and proportional Wave 1 weights were fixed before implementation in [the execution plan](WAVE1_EXECUTION_PLAN.md). Statuses: `NOT_STARTED`, `IN_PROGRESS`, `COMPLETED`, `BLOCKED`. Evidence and checkpoint commit are required for `COMPLETED`.

| # | ID | Capability | Points | Status | Evidence / checkpoint |
|---:|---|---|---:|---|---|
| 01 | K01 | Metadata-driven module creation and registration | 3 | COMPLETED | Core 67-check harness; native ExtensionStore 31 tests; Extension Studio package-authoring/import/export tests; Windows module creation integration. Invalid/duplicate IDs now fail closed. |
| 02 | K02 | Extension installation, activation, disabling, and safe removal | 3 | COMPLETED | ExtensionStore 31 tests cover atomic package install/upgrade, restart persistence, activation/disable, dependencies, data preservation/removal refusal. Added queue scan and Extension Studio UI test proving unresolved commands block removal. |
| 03 | A01 | Metadata-driven DocType creation | 3 | COMPLETED | Added Core boundary validation for stable DocType and field IDs; Core 67 checks and ExtensionStore/Extension Studio 51 tests pass. Existing tests cover persistent metadata, package export/import, registry installation, and generated records. |
| 04 | A03 | Field types required by business documents | 5 | COMPLETED | Added `long_text` and bounded flat-row `table` types across Core metadata, JSON Schema, generated editors and SQLite records. Core 68 checks, ExtensionStore 32 tests and Extension Studio 21 tests pass; field type and record value export/restart round-trips verified. Child DocType row schema/linkage remains A07 scope. |
| 05 | A04 | Field properties, constraints, and validation | 4 | COMPLETED | Core/SQLite/Host coverage plus PostgreSQL 17.11 durable integration: defaults, decimal precision rejection, read-only override rejection, and invalid payload persistence rejection. Full durable Host integration 35/35 passed; [acceptance evidence](A04_POSTGRESQL_ACCEPTANCE.md); checkpoint `cac747e`. |
| 06 | A05 | Record references and relationships | 4 | COMPLETED | Core bundle validation and Host exact-scope checks; SQLite scoped reference test (1/1); PostgreSQL 17.11 durable acceptance 43/43 covering valid, missing, cross-branch/company/tenant references and no record persistence on rejection. `RESTRICT`, no-cascade deletion policy fixed for B01. [Evidence](A05_RELATIONSHIP_ACCEPTANCE.md); checkpoint `f61fe7f`. |
| 07 | D01 | User identity and authentication | 5 | COMPLETED | PostgreSQL 17.11 persistent identity integration 79/79 under SCRAM with restricted runtime/admin roles; invalid/revoked/expired token denial, exact identity/scope, forged claims, rechecks across HTTP and Host process restart. Host API analysis clean; Flutter credential tests 4/4. [Evidence](D01_IDENTITY_ACCEPTANCE.md); checkpoint `9118310`. |
| 08 | D02 | Roles and scoped role assignments | 4 | COMPLETED | PostgreSQL 17.11 role API integration 16/16 plus D01 identity integration 79/79. Direct scoped managers, effective permissions, exact branch assignments, privilege ceilings, shared-role protection, revocation, and persisted role audit with database actor verified. [Evidence](D02_ROLE_ACCEPTANCE.md); checkpoint `76f831b`. |
| 09 | D04 | Field-level permissions | 5 | IN_PROGRESS | Existing Host policy and cache regressions under PostgreSQL/Flutter verification. |
| 10 | D03 | Operation-level permissions | 4 | NOT_STARTED | — |
| 11 | B03 | Document validation and lifecycle foundations | 5 | NOT_STARTED | — |
| 12 | B01 | CRUD with safe deletion semantics | 4 | NOT_STARTED | — |
| 13 | B05 | Record search, filtering, sorting, and pagination | 4 | NOT_STARTED | — |
| 14 | C01 | Generated List View | 3 | NOT_STARTED | — |
| 15 | C02 | Generated Form View | 3 | NOT_STARTED | — |
| 16 | A07 | Child / Table DocTypes | 5 | NOT_STARTED | — |
| 17 | C03 | Editable child-row Grid View | 5 | NOT_STARTED | — |
| 18 | A10 | Safe document naming and numbering series | 3 | NOT_STARTED | — |
| 19 | K06 | Governed business operations engine | 8 | NOT_STARTED | — |
| 20 | B04 | Draft / Submit / Cancel / Amend lifecycle | 7 | NOT_STARTED | — |
| 21 | F02 | Aggregations and calculated totals | 4 | NOT_STARTED | — |
| 22 | F01 | Declarative Report Builder | 5 | NOT_STARTED | — |
| 23 | G01 | Standard printable document formats | 4 | NOT_STARTED | — |

Total Wave 1 effort points: **100**.

## Execution checkpoint

- Current task: D04 — field-level permissions; PostgreSQL Host integration and local cache/UI regressions are running. Source review confirms server masks, predicate denial, protected-value omission, and partial-update preservation.
- Last successfully completed capability: D02 — roles and scoped role assignments.
- Next task: Finish PostgreSQL integration review, capture D04 evidence, and accept only after all criteria pass.
- Blockers: The unrelated abrupt-child queue recovery test currently hits a Dart FFI compiler transformer crash (exit 252) before the test body. Queue guard, standard queue recovery, SQLite persistence, and Windows acceptance checks pass; no current Wave 1 acceptance depends on that subprocess case.
- Branch: `codex/extension-platform`.
- Baseline: `da3b13851e1b4e210618755d5eab93f02b4dfa48`.
- Latest implementation checkpoint: `76f831b` — D02 role administration audit regression and acceptance evidence. Dashboard update for D04 in progress is being committed now.
- Timed live updates: Not available as a guaranteed background service; dashboard is updated at persisted checkpoints.

## Meaningful work since previous checkpoint

- Flutter first-party UI messages now resolve through the shared catalog, including parameterized extension metadata, confirmation, conflict, queue, role, form and validation copy. English fallbacks are in `native_english_messages.dart`; stable IDs and user-entered business values remain data.
- The CI localization gate validates fallback keys and English text, rejects duplicate/invalid/empty entries, checks catalog references, scans UI text widgets, and has five positive/negative unit cases. The Windows workflow runs both the new gate and the existing schema/language contract checks.
- Core analysis and all 65 Core harness checks passed. Flutter analysis and 23 focused localization/Extension Studio/role/maintenance tests passed. Windows integration acceptance (1/1), debug build, and release build passed. Localization gate unit cases passed, including deliberately invalid UI/catalog inputs.
- Stage 0 implementation checklist: (1) English-only built-in/default; (2) ADR-009/Core contract reuse; (3) shared Flutter/metadata resolver; (4) catalog-backed user-facing Flutter copy; (5) stable IDs/business data preserved; (6) rebuild, pseudo-locale restore and RTL readiness; (7) automatic CI gate — all implemented and verified. Formal gate evidence is complete.
- K01 acceptance passed: Extension Studio creates and exports declarative modules; SQLite persists metadata and imports packages; Core registry validates version, dependency, catalog, DocType, capability and duplicate registration. Added independent Core and local-store fail-closed checks for malformed and duplicate module IDs. PostgreSQL runtime integration was not run because the required disposable database URLs and explicit opt-in are not configured in this environment.
- K02 acceptance passed: package install/upgrade, activate/disable, restart persistence, dependency refusal, record preservation, and safe removal are covered by ExtensionStore 31 tests. Added a durable queue module scan and UI regression test that leaves a module installed when its queue contains an unresolved Host command. Flutter analysis passes; the queue guard and removal UI tests pass. One existing child-process recovery check is blocked by a Dart FFI compiler crash before its test body.
- A01 acceptance passed: Core DocType/field IDs now fail closed at metadata parse and registry boundaries; SQLite saves the validated JSON transactionally; Extension Studio creates, previews, activates, and uses generated definitions; export/import and restart persistence are covered. Core analysis + 67 checks and ExtensionStore/Extension Studio 51 focused tests passed.
- A03 acceptance passed: Core validates text, long text, integer, decimal, date, boolean, enum, reference and bounded table row shapes; generated forms preserve long text and table data, and SQLite restart plus declarative package round-trip are covered. Core analysis + 68 checks, ExtensionStore 32 tests, Extension Studio 21 tests and localization/contract/schema gates pass. Row DocType linkage and child-row schema validation remain A07 scope.
- A04 implementation checkpoint: Core enforces decimal scale (0–9 places) and field defaults, and treats omitted defaults consistently during complete client/Host validation. SQLite and both Host paths apply defaults and reject client changes to read-only fields. Decimal precision cannot be tightened over saved records. Extension Studio authors defaults, scale, read-only, and localized field descriptions; generated forms show defaults/descriptions and validate decimal scale. Added contract schema edge checks and PostgreSQL integration scenarios. Core analysis + 69 checks, ExtensionStore 33 tests, Extension Studio 22 tests, Windows integration 1/1, Host analysis, 9 contract tests, localization gate and schema profile pass. PostgreSQL runtime evidence remains unverified in this environment; A04 is still in progress.
- A04 environment recheck: `VENTIO_TEST_DATABASE_URL` and the explicit database-test opt-in are absent, TCP port 5432 has no listener, and no PostgreSQL service or installation is present. Starting the installed Docker Desktop service was denied by Windows service access. This confirms the outstanding PostgreSQL runtime check needs an enabled/accessible PostgreSQL service; it does not change accepted progress.
- Localization/A04 hardening checkpoint: a source review found hardcoded user-facing validation sentences in generated forms and role administration that the previous localization gate did not detect. Replaced those messages with stable English catalog keys; extended the CI scanner to reject hardcoded sentence returns from field validators and added a regression test. Localization gate and its 6 tests pass, Flutter analysis has no issues, Extension Studio 22/22 and role administration 1/1 tests pass, and the Windows builder integration passes 1/1. Stage 0 remains accepted; A04 remains in progress until PostgreSQL Host runtime evidence is available.
- A04 accepted: ran `dart run test/durable_integration.dart` against a temporary, isolated PostgreSQL 17.11 `ventio_host_test` database: 35 passed, 0 failed. The durable Host applied omitted defaults, rejected decimals beyond declared precision and client overrides of read-only fields, and rejected invalid DocType payloads without persisting records. The integration also exercised retry idempotency, receipt replay, scope/tenant permissions, transaction rollback and concurrency. Evidence is in [A04_POSTGRESQL_ACCEPTANCE.md](A04_POSTGRESQL_ACCEPTANCE.md); the temporary server was stopped. Wave 1 is now **5/23 accepted** and overall progress is **31.70%**; A05 is next.
- A05 accepted: Core bundle validation confines relation targets to the same declarative module. Core and local SQLite checks cover target existence and scoped links; PostgreSQL durable integration now verifies valid same-module/same-scope references plus missing and cross-branch/company/tenant rejection with no source record persisted (43/43 total checks). The plan now fixes the relationship deletion rule as `RESTRICT` with no cascade; B01 must enforce it when Host record deletion is introduced. Evidence: [A05_RELATIONSHIP_ACCEPTANCE.md](A05_RELATIONSHIP_ACCEPTANCE.md). Wave 1 is **6/23 accepted**, overall progress **34.30%**, and D01 is next.
- D01 accepted: persistent Host API integration passed **79/79** on PostgreSQL 17.11 with the repository's security bootstrap, SCRAM-authenticated restricted runtime/admin roles, and a confirmed `ventio_runtime_test` database identity. Coverage includes opaque credentials/digest-only persistence, server-owned actor/device/scope, forged claim rejection, expiry and individual credential/device/user revocation, per-request and in-transaction permission rechecks, audit redaction/atomicity, fail-closed database failures, and multi-process restart/recovery. Host API analysis is clean; Flutter Host credential tests pass 4/4. Evidence: [D01_IDENTITY_ACCEPTANCE.md](D01_IDENTITY_ACCEPTANCE.md). Wave 1 is **7/23 accepted**, overall progress **37.55%**, and D02 is next.
- D02 accepted: PostgreSQL role administration integration passed **16/16**, including direct manager exact-scope access, reader and cross-branch denial, role permission/assignment administration, reserved management-permission escalation refusal, shared-role scope checks, effective permission resolution, revocation, and durable audit entries with exact assignment scope and database actor. The D01 integration independently contributes 79/79 checks for permission enforcement at command execution and credential ceilings. Evidence: [D02_ROLE_ACCEPTANCE.md](D02_ROLE_ACCEPTANCE.md). Wave 1 is **8/23 accepted**, overall progress **40.15%**, and D04 is next.
- Both root CI and V1.2 DocType schemas now carry the same A03 field types and A04 property constraints.
- D04 verification is now in progress. PostgreSQL Host acceptance is running; Flutter cache and Studio field-mask regressions passed 1/1 each.\n- The final reference extension remains unstarted; Wave 1 capability acceptance is **8/23**.
