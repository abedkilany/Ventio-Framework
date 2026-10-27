# Ventio Framework Localization Gate and Wave 1 Plan

## Mission and baseline

Deliver the mandatory English-first localization foundation, then verify and close the 23 ordered Wave 1 capabilities, then prove them through the official **Ventio Inventory Operations** extension. Reuse existing implementations where they meet the acceptance criteria; a capability is not accepted merely because related code or tests exist.

- Reviewed baseline: `da3b13851e1b4e210618755d5eab93f02b4dfa48`.
- Development branch: `codex/extension-platform`, fast-forwarded from its ancestor to the reviewed baseline before this plan was recorded.
- `main` is not a target for implementation, commits, or merges.
- Existing local untracked deliverables are preserved.

## Architecture and scope rules

- Windows-first native Flutter client; SQLite is the local offline workspace and queue.
- PostgreSQL Host is authoritative for shared data and accepted business operations.
- Offline writes are durable provisional commands with stable IDs; Host receipts determine acceptance. Conflicts are explicit and recoverable.
- Every Host operation is authorized for the exact tenant, company, branch, actor, device, operation, and fields involved.
- Business capabilities are metadata-driven and reusable by ordinary extension authors. No inventory-only Core or Host shortcut is allowed.
- Packages remain declarative data. No uploaded Dart, SQL, scripts, or arbitrary executable extension behavior.
- All new UI messages use the Stage 0 localization mechanism.
- Follow ADR-009: English is the only built-in language. User-entered business data may be in any language. No production non-English translation is in this mission.
- Keep changes scoped; preserve atomicity, idempotency, recovery, and existing security guarantees.

## Stage 0 — Localization Foundation Gate (20% overall)

### Required work

1. Keep English as the only built-in/default language and keep first-party UI, code, documentation, and developer-facing artifacts English-only. Do not restrict the language of user-generated business data.
2. Reuse ADR-009, `EnglishCatalog`, `LocalizationProvider`, metadata translation keys, and existing English catalogs.
3. Introduce one coherent resolver used by Flutter UI and dynamic extension metadata. Every user-visible message has a stable key and meaningful English fallback.
4. Replace hardcoded user-facing Flutter strings with catalog-backed messages, including dialogs, labels, validation, empty/loading/error states, accessibility labels, and user-visible status text.
5. Preserve language-independent command IDs, enum IDs, permissions, persisted business values, and accounting values.
6. Make locale changes observable by the UI so it rebuilds, and carry text direction through layout so a future optional translation module can exercise RTL. Do not add actual production translations.
7. Add an automatic CI gate for newly introduced hardcoded UI strings, missing keys, invalid catalogs, and localization contract violations. The scanner must distinguish technical constants, identifiers, test-only material, and user-entered data from user-facing UI copy.

### Stage 0 acceptance gate

- The app boots and all first-party screens resolve to English with no translation module installed.
- A test-only pseudo-localization pack can be applied at runtime, visibly changes catalog-backed UI and dynamic metadata, triggers a rebuild, and can be removed to restore English without changing stored data or queued commands.
- Missing/invalid messages resolve deterministically to meaningful English fallback; invalid catalogs are rejected.
- RTL direction can be exercised in tests without shipping a production RTL translation.
- Stable identifiers, authorization, user-entered content, command payloads, and numeric/accounting values are unchanged by display locale.
- CI automatically fails a deliberately introduced hardcoded user-facing UI string and a missing/invalid key while allowing documented technical constants and user-entered data.
- Focused localization tests, Flutter analysis/tests, and relevant Windows checks pass. Save evidence and checkpoint commit before marking the gate passed.

## Stage 1 — Wave 1 capabilities (65% overall)

The numbered acceptance checks below are the minimum functional bar, informed by Frappe's metadata-driven DocTypes, generated views, role/field permissions, child tables, naming, reports, and print formats. They deliberately exclude script-based customization and unbounded ERP scope. Public functional references: [Desk](https://docs.frappe.io/framework/user/en/desk), [Child / Table DocType](https://docs.frappe.io/framework/user/en/basics/doctypes/child-doctype), [Users and Permissions](https://docs.frappe.io/framework/user/en/basics/users-and-permissions), [Naming](https://docs.frappe.io/framework/user/en/basics/doctypes/naming), and [Print Format Editor](https://docs.frappe.io/framework/user/en/printing/print-format-editor).

Effort points are relative complexity estimates fixed before implementation; they sum to 100 and are used as the Wave 1 weights. A capability earns weight only after its acceptance evidence is saved. Stage 1 contribution is `65% × accepted effort points / 100`.

| # | ID | Capability | Effort points / Wave 1 weight | Minimal acceptance criteria |
|---:|---|---|---:|---|
| 01 | K01 | Metadata-driven module creation and registration | 3 / 3% | An ordinary creator can author, validate, persist, export/import, and register a versioned declarative module with stable ID, dependencies, catalog, and DocTypes; invalid or duplicate IDs fail closed. |
| 02 | K02 | Extension installation, activation, disabling, and safe removal | 3 / 3% | Install a validated package, activate/disable it without data loss, and refuse removal when records/dependencies/pending commands make removal unsafe; state survives restart. |
| 03 | A01 | Metadata-driven DocType creation | 3 / 3% | Create a DocType from metadata, validate its stable fields and labels, persist it, and generate a usable record definition without custom code. |
| 04 | A03 | Field types required by business documents | 5 / 5% | Support and round-trip the agreed bounded set: text, long text, integer, decimal, date, boolean, enum/select, reference, and child table; validation and storage preserve type semantics. |
| 05 | A04 | Field properties, constraints, and validation | 4 / 4% | Required, length/range, precision, enum, default, read-only, and field presentation properties are validated consistently on client and Host; invalid writes are rejected by Host. |
| 06 | A05 | Record references and relationships | 4 / 4% | Define reference targets within the extension module; Host checks target existence and exact tenant/company/branch/module scope on create/update and rejects invalid links without changing the business record. Referenced-record deletion is `RESTRICT` (no cascade): B01 Host delete operations must refuse deletion while inbound references remain; no record-delete operation is exposed before B01. |
| 07 | D01 | User identity and authentication | 5 / 5% | Authenticate a persistent user/device identity through Host credentials, bind sessions to authoritative identity/scope, reject invalid/revoked credentials, and never trust client identity claims. |
| 08 | D02 | Roles and scoped role assignments | 4 / 4% | Assign roles to identities at exact authorized scope; resolve effective permissions server-side; changes are audited and cannot grant beyond trusted authority. |
| 09 | D04 | Field-level permissions | 5 / 5% | Enforce read/write/create field masks at Host; omit unreadable fields, reject unauthorized predicates and writes, preserve protected values during partial updates, and scrub cached values after a learned denial. |
| 10 | D03 | Operation-level permissions | 4 / 4% | Declare stable operation permissions and enforce them for each exact scope on every Host request, including retries; UI visibility alone never grants authority. |
| 11 | B03 | Document validation and lifecycle foundations | 5 / 5% | PostgreSQL Host accepts only the approved module/DocType/schema and supported create/update operations; validates required/type/default/read-only constraints, exact-scope references, and optimistic update revisions; invalid commands leave no record, journal, audit, outbox, or cursor effect; an injected pre-commit failure rolls back all effects and the same command ID can safely retry. This establishes the atomic create/update foundation. Business Submit/Cancel/Amend transitions are B04 scope. |
| 12 | B01 | CRUD with safe deletion semantics | 4 / 4% | Implement generic `record.delete@1` under [ADR-010](../decisions/ADR-010_GOVERNED_OPERATIONS_AND_DOCUMENT_STATE.md): require exact-scope delete permission and expected revision; tombstone instead of freeing the ID; hide tombstones from reads; reject deletion of submitted or inbound-referenced records (`RESTRICT`, no cascade); atomically journal/audit/outbox the accepted deletion; retry returns the same receipt. SQLite retains the durable provisional command and restores the row on Host rejection/conflict. |
| 13 | B05 | Record search, filtering, sorting, and pagination | 4 / 4% | Provide bounded deterministic search/filter/sort/keyset pagination using only permitted fields, with stable ordering and exact-scope isolation. |
| 14 | C01 | Generated List View | 3 / 3% | Generate a localized list from DocType metadata with configured columns, stable empty/loading/error states, authorized filters/sort, and paging. |
| 15 | C02 | Generated Form View | 3 / 3% | Generate create/edit/view forms from field metadata, show validation and permissions correctly, preserve partial edits, and work with local provisional records. |
| 16 | A07 | Child / Table DocTypes | 5 / 5% | Define a bounded child DocType schema inside exactly one parent `table` field. Validate each row's known child fields, required/type/constraint/default rules, same-scope references, maximum row count, and declared order. Persist rows embedded in the parent record so create/update/delete and governed lifecycle operations are atomic with the parent; child rows have no independent record IDs, permissions, commands, status, or orphan state. Allow one child level only; retain legacy untyped `table` compatibility. See [ADR-011](../decisions/ADR-011_EMBEDDED_CHILD_DOCTYPES.md). |
| 17 | C03 | Editable child-row Grid View | 5 / 5% | Add/edit/remove/reorder multiple child rows in a generated form; validate each row and totals; save/queue the parent and rows atomically and recover them together. |
| 18 | A10 | Safe document naming and numbering series | 3 / 3% | Configure a bounded declarative series; allocate unique sequential official numbers atomically on Host submit, keep offline names provisional, and ensure retries never consume/duplicate a number or business effect. |
| 19 | K06 | Governed business operations engine | 8 / 8% | Implement [ADR-010](../decisions/ADR-010_GOVERNED_OPERATIONS_AND_DOCUMENT_STATE.md): versioned declarative operation IDs/permissions/contracts over a Core-owned bounded effect vocabulary, deterministic validation, exact-scope authorization, atomic Host transactions, audit/outbox, and idempotent receipts. Prove a generic operation applies a bounded effect across multiple persisted Child Table rows, including rollback and permission enforcement, without extension-specific handlers. Reuse the pipeline for generic CRUD and B04 lifecycle operations; extensions supply data only, never executable handlers. |
| 20 | B04 | Draft / Submit / Cancel / Amend lifecycle | 7 / 7% | Use ADR-010 Host-owned document status (`0` draft, `1` submitted, `2` cancelled) through K06 operations. Host enforces legal transitions, operation permissions, submitted-data immutability, atomic effects and idempotent receipts. Amend creates a new draft linked to the cancelled source; cancellation/amendment cannot duplicate effects. |
| 21 | F02 | Aggregations and calculated totals | 4 / 4% | Declaratively calculate bounded decimal line and parent totals using exact decimal semantics; Host recomputes/validates totals and persists/reconciles the same result for online and offline submissions. |
| 22 | F01 | Declarative Report Builder | 5 / 5% | Ordinary users can define/save a bounded report from authorized DocTypes/fields with filters, sort, grouping, and count/sum; Host enforces permissions, scope, and resource limits. |
| 23 | G01 | Standard printable document formats | 4 / 4% | Define a safe declarative print layout for fields, child rows, totals, and page breaks; render a stable printable/PDF output from an authorized document without executable templates. |

### Capability closure rule

Before closing a capability, verify existing source and record the relevant implementation paths, focused test/acceptance evidence, and limitations in the progress dashboard. A partial implementation stays `IN_PROGRESS` (or `BLOCKED`) until the entire listed criterion passes. Avoid repeated full-suite runs; run focused checks as work proceeds and essential security/persistence/recovery checks at meaningful integration points.

## Final Acceptance — Ventio Inventory Operations (15% overall)

Build the first official extension using the same declarative, governed tools available to ordinary extension creators. No inventory-specific Core/Host branch, privilege, or implementation shortcut is acceptable.

### Final acceptance gate

Demonstrate in one reproducible Windows-first scenario:

1. Create Products and Inventory Movement DocTypes, with multiple movement line items, through the ordinary extension authoring path.
2. Generate unique official movement numbers on Host acceptance; offline labels remain provisional.
3. Exercise Draft → Submit → Cancel → Amend. Verify exact inventory effects and calculated totals at every transition, including that cancellation reverses the original movement once and amendment applies only the amended movement once.
4. Enforce ordinary role, operation, field, and scope permissions; produce a report and printable document from the extension metadata.
5. Create and edit movements offline in Windows SQLite, persist durable provisional commands across restart, then submit to PostgreSQL Host and reconcile authoritative receipts.
6. Retry identical command IDs and simulate/recover an interrupted/ambiguous outcome without duplicate numbering or inventory effects.
7. Verify restart/recovery preserves extension metadata, records, command queue, accepted Host state, and audit evidence.
8. Inspect the official extension package and Host/Core changes to confirm no privileged inventory-specific path exists.

Save a step-by-step run record, command receipts/revisions, database assertions, and relevant automated test output before accepting the 15% final stage.

## Git and checkpoint policy

- Work only on `codex/extension-platform` (or a clearly named child development branch if the current branch is unavailable); never push or merge into `main`.
- Commit the plan and initial dashboard before Stage 0 implementation.
- For Stage 0 and every accepted capability, first save the implementation and evidence, update `docs/WAVE1_PROGRESS.md`, then commit and push that checkpoint. Never mark work accepted before its evidence and checkpoint are saved.
- Keep commits resumable and narrowly scoped. Do not overwrite or stage unrelated pre-existing work.
- If the environment cannot provide timed progress, make no claim that monitoring is running; persist status at each checkpoint and resume from Git.
