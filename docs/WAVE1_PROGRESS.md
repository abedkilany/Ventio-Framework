# Ventio Framework Wave 1 Progress

Canonical execution dashboard. Percentages count accepted deliverables only.

## Overall

**23.90%** `████▊░░░░░░░░░░░░░░░` (20% Stage 0 + 3.90% accepted Wave 1)

- Stage 0 Localization Foundation: **PASS — 100% accepted** — **7/7 implementation steps complete** (20% overall)
- Stage 1 Wave 1: **2 / 23 accepted** — A01 `IN_PROGRESS` (65% overall)
- Final Acceptance — Ventio Inventory Operations: **NOT_STARTED** (15% overall)

Progress formula: Stage 0 gate pass contributes 20 points; accepted Wave 1 effort points contribute `65 × points / 100`; final acceptance gate pass contributes 15 points. Overall is capped below 100 until all three gates pass.

## Capability ledger

Effort points and proportional Wave 1 weights were fixed before implementation in [the execution plan](WAVE1_EXECUTION_PLAN.md). Statuses: `NOT_STARTED`, `IN_PROGRESS`, `COMPLETED`, `BLOCKED`. Evidence and checkpoint commit are required for `COMPLETED`.

| # | ID | Capability | Points | Status | Evidence / checkpoint |
|---:|---|---|---:|---|---|
| 01 | K01 | Metadata-driven module creation and registration | 3 | COMPLETED | Core 66-check harness; native ExtensionStore 31 tests; Extension Studio package-authoring/import/export tests; Windows module creation integration. Invalid/duplicate IDs now fail closed. |
| 02 | K02 | Extension installation, activation, disabling, and safe removal | 3 | COMPLETED | ExtensionStore 31 tests cover atomic package install/upgrade, restart persistence, activation/disable, dependencies, data preservation/removal refusal. Added queue scan and Extension Studio UI test proving unresolved commands block removal. |
| 03 | A01 | Metadata-driven DocType creation | 3 | IN_PROGRESS | Reviewing DocType metadata validation, persistence, and generated record registration before closing the capability. |
| 04 | A03 | Field types required by business documents | 5 | NOT_STARTED | — |
| 05 | A04 | Field properties, constraints, and validation | 4 | NOT_STARTED | — |
| 06 | A05 | Record references and relationships | 4 | NOT_STARTED | — |
| 07 | D01 | User identity and authentication | 5 | NOT_STARTED | — |
| 08 | D02 | Roles and scoped role assignments | 4 | NOT_STARTED | — |
| 09 | D04 | Field-level permissions | 5 | NOT_STARTED | — |
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

- Current task: A01 — verify metadata-driven DocType creation, validation, persistence, and registration.
- Last successfully completed capability: K02 — extension installation, activation, disabling, and safe removal.
- Next task: Finish A01 source review and focused acceptance evidence.
- Blockers: The unrelated abrupt-child queue recovery test currently hits a Dart FFI compiler transformer crash (exit 252) before the test body. Queue guard, standard queue recovery, SQLite persistence, and Windows acceptance checks pass; no Wave 1 acceptance depends on that subprocess case.
- Branch: `codex/extension-platform`.
- Baseline: `da3b13851e1b4e210618755d5eab93f02b4dfa48`.
- Latest checkpoint commit: `b53f38a` — K02 queue-safe removal and acceptance evidence, pushed to `codex/extension-platform`.
- Timed live updates: Not available as a guaranteed background service; dashboard is updated at persisted checkpoints.

## Meaningful work since previous checkpoint

- Flutter first-party UI messages now resolve through the shared catalog, including parameterized extension metadata, confirmation, conflict, queue, role, form and validation copy. English fallbacks are in `native_english_messages.dart`; stable IDs and user-entered business values remain data.
- The CI localization gate validates fallback keys and English text, rejects duplicate/invalid/empty entries, checks catalog references, scans UI text widgets, and has four positive/negative unit cases. The Windows workflow runs both the new gate and the existing schema/language contract checks.
- Core analysis and all 65 Core harness checks passed. Flutter analysis and 23 focused localization/Extension Studio/role/maintenance tests passed. Windows integration acceptance (1/1), debug build, and release build passed. Localization gate unit cases passed, including deliberately invalid UI/catalog inputs.
- Stage 0 implementation checklist: (1) English-only built-in/default; (2) ADR-009/Core contract reuse; (3) shared Flutter/metadata resolver; (4) catalog-backed user-facing Flutter copy; (5) stable IDs/business data preserved; (6) rebuild, pseudo-locale restore and RTL readiness; (7) automatic CI gate — all implemented and verified. Formal gate evidence is complete.
- K01 acceptance passed: Extension Studio creates and exports declarative modules; SQLite persists metadata and imports packages; Core registry validates version, dependency, catalog, DocType, capability and duplicate registration. Added independent Core and local-store fail-closed checks for malformed and duplicate module IDs. PostgreSQL runtime integration was not run because the required disposable database URLs and explicit opt-in are not configured in this environment.
- K02 acceptance passed: package install/upgrade, activate/disable, restart persistence, dependency refusal, record preservation, and safe removal are covered by ExtensionStore 31 tests. Added a durable queue module scan and UI regression test that leaves a module installed when its queue contains an unresolved Host command. Flutter analysis passes; the queue guard and removal UI tests pass. One existing child-process recovery check is blocked by a Dart FFI compiler crash before its test body.
- A01 source review is underway; it is not accepted yet.
- No Wave 1 capability or final-extension acceptance is claimed.
