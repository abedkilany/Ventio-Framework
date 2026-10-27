# Ventio Framework Wave 1 Progress

Canonical execution dashboard. Percentages count accepted deliverables only.

## Overall

**20%** `████░░░░░░░░░░░░░░░░` (20 / 100)

- Stage 0 Localization Foundation: **PASS — 100% accepted** — **7/7 implementation steps complete** (20% overall)
- Stage 1 Wave 1: **0 / 23 accepted** — K01 `IN_PROGRESS` (65% overall)
- Final Acceptance — Ventio Inventory Operations: **NOT_STARTED** (15% overall)

Progress formula: Stage 0 gate pass contributes 20 points; accepted Wave 1 effort points contribute `65 × points / 100`; final acceptance gate pass contributes 15 points. Overall is capped below 100 until all three gates pass.

## Capability ledger

Effort points and proportional Wave 1 weights were fixed before implementation in [the execution plan](WAVE1_EXECUTION_PLAN.md). Statuses: `NOT_STARTED`, `IN_PROGRESS`, `COMPLETED`, `BLOCKED`. Evidence and checkpoint commit are required for `COMPLETED`.

| # | ID | Capability | Points | Status | Evidence / checkpoint |
|---:|---|---|---:|---|---|
| 01 | K01 | Metadata-driven module creation and registration | 3 | IN_PROGRESS | Reviewing installer, local persistence, registration, and export/import coverage. |
| 02 | K02 | Extension installation, activation, disabling, and safe removal | 3 | NOT_STARTED | — |
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

- Current task: K01 — verify metadata-driven module authoring, validation, persistence, export/import and registration; implement only acceptance gaps.
- Last successfully completed capability: None.
- Next task: Close K01 source review and focused acceptance evidence, then address identified gaps.
- Blockers: None. Plan source supplied by project owner; reviewed baseline ancestry verified.
- Branch: `codex/extension-platform`.
- Baseline: `da3b13851e1b4e210618755d5eab93f02b4dfa48`.
- Latest checkpoint commit: Pending the Stage 0 acceptance commit and dashboard checkpoint.
- Timed live updates: Not available as a guaranteed background service; dashboard is updated at persisted checkpoints.

## Meaningful work since previous checkpoint

- Flutter first-party UI messages now resolve through the shared catalog, including parameterized extension metadata, confirmation, conflict, queue, role, form and validation copy. English fallbacks are in `native_english_messages.dart`; stable IDs and user-entered business values remain data.
- The CI localization gate validates fallback keys and English text, rejects duplicate/invalid/empty entries, checks catalog references, scans UI text widgets, and has four positive/negative unit cases. The Windows workflow runs both the new gate and the existing schema/language contract checks.
- Core analysis and all 65 Core harness checks passed. Flutter analysis and 23 focused localization/Extension Studio/role/maintenance tests passed. Windows integration acceptance (1/1), debug build, and release build passed. Localization gate unit cases passed, including deliberately invalid UI/catalog inputs.
- Stage 0 implementation checklist: (1) English-only built-in/default; (2) ADR-009/Core contract reuse; (3) shared Flutter/metadata resolver; (4) catalog-backed user-facing Flutter copy; (5) stable IDs/business data preserved; (6) rebuild, pseudo-locale restore and RTL readiness; (7) automatic CI gate — all implemented and verified. Formal gate evidence is complete.
- K01 source review confirms declarative manifests, trusted capability/dependency validation, DocType validation, catalog validation, local transactional installation, export and import paths exist. It does not yet establish K01 acceptance; remaining criteria and durable registration behavior are being verified.
- No Wave 1 capability or final-extension acceptance is claimed.
