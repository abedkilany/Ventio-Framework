# Ventio Framework Wave 1 Progress

Canonical execution dashboard. Percentages count accepted deliverables only.

## Overall

**21.95%** `████▍░░░░░░░░░░░░░░░` (20% Stage 0 + 1.95% K01)

- Stage 0 Localization Foundation: **PASS — 100% accepted** — **7/7 implementation steps complete** (20% overall)
- Stage 1 Wave 1: **1 / 23 accepted** — K02 `IN_PROGRESS` (65% overall)
- Final Acceptance — Ventio Inventory Operations: **NOT_STARTED** (15% overall)

Progress formula: Stage 0 gate pass contributes 20 points; accepted Wave 1 effort points contribute `65 × points / 100`; final acceptance gate pass contributes 15 points. Overall is capped below 100 until all three gates pass.

## Capability ledger

Effort points and proportional Wave 1 weights were fixed before implementation in [the execution plan](WAVE1_EXECUTION_PLAN.md). Statuses: `NOT_STARTED`, `IN_PROGRESS`, `COMPLETED`, `BLOCKED`. Evidence and checkpoint commit are required for `COMPLETED`.

| # | ID | Capability | Points | Status | Evidence / checkpoint |
|---:|---|---|---:|---|---|
| 01 | K01 | Metadata-driven module creation and registration | 3 | COMPLETED | Core 66-check harness; native ExtensionStore 31 tests; Extension Studio package-authoring/import/export tests; Windows module creation integration. Invalid/duplicate IDs now fail closed. |
| 02 | K02 | Extension installation, activation, disabling, and safe removal | 3 | IN_PROGRESS | Reviewing transactional install, activation/disable, dependency guards, data preservation, and pending-command removal semantics. |
| 03 | A01 | Metadata-driven DocType creation | 3 | NOT_STARTED | — |
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

- Current task: K02 — verify extension install, activation/disable, and safe removal under records, dependencies, and pending commands.
- Last successfully completed capability: K01 — metadata-driven module creation and registration.
- Next task: Finish K02 evidence review and implement any safety gaps.
- Blockers: None. Plan source supplied by project owner; reviewed baseline ancestry verified.
- Branch: `codex/extension-platform`.
- Baseline: `da3b13851e1b4e210618755d5eab93f02b4dfa48`.
- Latest checkpoint commit: Pending K01 implementation and acceptance checkpoint.
- Timed live updates: Not available as a guaranteed background service; dashboard is updated at persisted checkpoints.

## Meaningful work since previous checkpoint

- Flutter first-party UI messages now resolve through the shared catalog, including parameterized extension metadata, confirmation, conflict, queue, role, form and validation copy. English fallbacks are in `native_english_messages.dart`; stable IDs and user-entered business values remain data.
- The CI localization gate validates fallback keys and English text, rejects duplicate/invalid/empty entries, checks catalog references, scans UI text widgets, and has four positive/negative unit cases. The Windows workflow runs both the new gate and the existing schema/language contract checks.
- Core analysis and all 65 Core harness checks passed. Flutter analysis and 23 focused localization/Extension Studio/role/maintenance tests passed. Windows integration acceptance (1/1), debug build, and release build passed. Localization gate unit cases passed, including deliberately invalid UI/catalog inputs.
- Stage 0 implementation checklist: (1) English-only built-in/default; (2) ADR-009/Core contract reuse; (3) shared Flutter/metadata resolver; (4) catalog-backed user-facing Flutter copy; (5) stable IDs/business data preserved; (6) rebuild, pseudo-locale restore and RTL readiness; (7) automatic CI gate — all implemented and verified. Formal gate evidence is complete.
- K01 acceptance passed: Extension Studio creates and exports declarative modules; the transactional SQLite store persists metadata and imports packages; the Core Host registry validates version, dependency, catalog, DocType, capability and duplicate registration; Postgres package gateway/migrations persist versioned package candidates and approvals. Added independent Core and local-store fail-closed checks for malformed and duplicate module IDs. Focused evidence: Core analysis + 66 checks, ExtensionStore 31 tests, Extension Studio 19 tests, Windows integration 1/1. PostgreSQL runtime integration was not run because the required disposable database URLs and explicit opt-in are not configured in this environment.
- K02 source review is underway. It is not accepted yet; safe removal with unresolved queued commands is being checked.
- No Wave 1 capability or final-extension acceptance is claimed.
