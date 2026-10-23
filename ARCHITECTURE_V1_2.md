# Ventio Core Architecture Specification — V1.2

**Date:** 2026-10-23  
**Status:** Proposed implementation baseline, not a production release or approval to rewrite the existing Ventio application.  
**Basis:** Ventio Platform Architecture V1, Core Architecture V1.1, and the newly confirmed English-first localization requirement.

## 1. Product goals and architecture principles

Ventio will be an extensible ERP framework supporting installed Flutter applications on Windows and Android. The Core must be independent of Flutter, specific databases, and business domains. The Host is the sole logical authority for finalized shared business state, with automatic command approval. Offline operation is supported through an optional adapter. A mature developer extension experience comes before the AI Builder and Marketplace.

**Language policy:** The entire initial product, repository, default UI, technical documentation, metadata display strings, logs, and built-in user-facing content are written in English. There are **no bundled alternative user languages** in the base app. The system must nevertheless be localization-ready from day one. A separately installed Translation Module may later provide language packs without modifying Core or rebuilding the installed Flutter application for each translation.

### Decision status

| Decision | Status | Implication |
|---|---|---|
| Installed Windows/Android Flutter app | Product principle | Not a WebView-only application |
| Pure Dart Core, independent of Flutter and business modules | Architecture principle | Enforce package boundaries with tests |
| Host-authoritative command acceptance | Product principle | Client-local commands are provisional |
| Offline-ready Core, optional Offline Engine | Product principle | Not every module or operation is eligible for offline mode |
| English-only base product; optional Translation Module later | **Accepted product principle** | English catalogs and stable localization keys now; no alternative languages shipped |
| Metadata-based external extensions; no arbitrary Dart execution | Security principle | Does not imply unrestricted custom business logic |
| Modular Monolith and a reliable Host transaction boundary | Proposed | Verify with the ERP proof of platform |
| Trusted capability catalog and bounded rules | Proposed for proof | Extension expressiveness is an open product risk |
| PostgreSQL Host and SQLite client | Proposed for testing | Validate performance and failure behavior |
| Dart Host runtime | Candidate | Benchmark before large-scale commitment |
| Isolated WASM/advanced DSL runtime | Open research | Not part of the starter implementation |
| JSON Schema v0 contracts | Draft | May evolve after proof-of-platform tests |

## 2. Component boundaries

```text
Flutter Shell (Windows / Android)
  Dynamic Renderer / Navigation / Directionality / Formatting
  Built-in English UI messages
              |
        Application SDK
              |
        Ventio Core (pure Dart)
  Identity / Scope / Policy / Module Registry
  Metadata / Capability / Command / Query Contracts
  Localization Contract (key + English fallback, no dependency on Flutter)
  Transaction / Event / Audit / Outbox Contracts
           ^                      ^
           |                      |
 Business Modules          Infrastructure Adapters
 Sales / Inventory /         SQLite / PostgreSQL / HTTPS
 Accounting / Maintenance    Optional Offline / Translation
           \                      /
             Host Runtime
      Authority and transactions
```

- `ventio_core` never imports Flutter, a database driver, or a business module.
- `flutter_shell` renders validated metadata; it never executes Dart, JavaScript, SQL, or arbitrary remote URLs from manifests.
- Business modules expose versioned commands, capabilities, read models, and events. They do not modify another module's private tables directly.
- The Host enforces final authorization and transaction invariants; local validation is advisory only.
- The optional Offline Engine cannot grant Host acceptance or modify the CommandEnvelope's authority semantics.
- Multiple Host API instances share a single logical authority enforced through transactional persistence, not process-local locks.
- The optional Translation Module supplies **message data and locale services**, never executable business logic or permissions.

## 3. Extension capability model

| Tier | Mechanism | Expressiveness | Offline behavior | Security boundary |
|---|---|---|---|---|
| L0 Metadata | DocTypes, lists, forms, filters | Data models and UI | Module-specific cache policy | Validated schema, field-level access checks |
| L1 Bounded Rules | Deterministic arithmetic, comparisons, validation | Simple rules | Only when inputs are available locally | Type safety and strict resource limits; no general I/O |
| L2 Workflow Composition | Orchestrate registered, trusted capabilities | Limited business workflows | Explicitly declared provisional steps | Registry checks, permissions, transactions |
| L3 Trusted Native | Reviewed code bundled with approved releases/deployments | Advanced algorithms | Client support must be explicitly bundled | Signed/reviewed delivery; no dynamically loaded Dart AOT code |
| L4 Sandboxed Runtime (future research) | Restricted WASM or advanced DSL | Potentially downloadable algorithms | Platform compatibility unproven | Strong sandbox, capabilities and CPU/memory limits |

**Explicit limitation:** V1.2 does not provide arbitrary new algorithms through metadata alone. If L0–L2 cannot express a core business case, the general-purpose extension claim fails until a secure mechanism is demonstrated. An external module *requests* a capability but cannot grant itself execution privileges.

A capability declares `id`, provider, execution location, execution kind, permission requirements, transaction policy, offline policy, effects, input/output schemas, and determinism. The Host rechecks actor identity, tenant membership, requested capability, and business preconditions before committing any final effects. Financial posting spanning multiple modules must be orchestrated through one trusted Host transaction; unrelated asynchronous events are not a substitute for atomicity.

## 4. Command and transaction lifecycle

### 4.1 CommandEnvelope

A draft envelope contains `protocolVersion`, immutable `commandId` (UUID), command `type` and `typeVersion`, tenant/company/branch claims, aggregate ID, expected revision, dependency IDs, typed payload, and client context. Client-supplied actor, tenant, and device identifiers are **not** trusted authorization facts; the Host derives scope from verified credentials and membership. The Host calculates and stores a canonical payload hash with `(tenant_id, command_id)`.

### 4.2 Host processing

1. Authenticate the user, device, and session; determine authorized tenant/company/branch scope.
2. Validate protocol, module, DocType and command compatibility.
3. Authorize the command and required capabilities; recheck sensitive permissions as appropriate.
4. Begin a database transaction. Claim or read the unique `(tenant_id, command_id)` key. If a finalized receipt exists for an identical payload, return it without repeating business effects. A changed payload under the same ID is rejected as `COMMAND_ID_REUSED`.
5. Acquire database locks or use conditional writes appropriate to the domain invariant; do not rely on locks held only in a Host process.
6. Validate the domain rules, execute trusted handlers and commit relevant financial, inventory, receipt, audit, and outbox records **together** when atomicity is required.
7. Commit before issuing an `ACCEPTED` receipt, official document number, or authorized change cursor.
8. Deliver later sync and notifications from the outbox. Any non-transactional external services require their own idempotency and reconciliation policy.

`REJECTED` and `CONFLICT` are final business decisions for that command identity; corrections receive a new command ID. `RETRY_LATER` is transient. Network delivery is not exactly-once: the **business outcome** must be idempotent. After a response timeout, the client enters `UNKNOWN_RESULT`, looks up its original command ID, and must not silently create a new invoice.

### 4.3 Receipt and error localization

Receipts expose machine-readable `reasonCode`, optional `messageKey`, and typed `messageParams`. Any `publicMessage` is an **optional English fallback** and must not be the only way to determine the error. The client resolves keys through the active locale provider, falling back to bundled English. Error formatting must not leak private server details or sensitive identifiers. The underlying validation/permission logic never depends on translated text.

### 4.4 Atomic ERP posting

Posting a sales invoice can atomically update inventory, create balanced accounting entries using precise decimal values, persist the invoice, assign the official number where applicable, and store its receipt, audit entry and outbox record. Failure of any invariant rolls back the entire transaction. Handlers must not invoke unbounded external APIs while holding database locks. Posted financial movements must have controlled reversal/correction processes rather than arbitrary deletion.

## 5. Optional Offline Engine

Client states: `DRAFT`, `PENDING_LOCAL`, `SENDING`, `UNKNOWN_RESULT`, `ACCEPTED`, `REJECTED`, and `NEEDS_RESOLUTION`. The local queue and provisional projections are persisted atomically and presented separately from Host-confirmed projections.

- Offline support is allowed per module, command, version, device authorization, required cached inputs, and expiry/risk policy.
- On reconnect, the Host revalidates all permissions and rules. Local success never implies final acceptance.
- When a command is rejected, a corrected command gets a fresh ID; the UI retains a clear and auditable outcome.
- Snapshots and deltas are scoped by tenant, branch and module, with opaque cursors, integrity checks and resumable transfer.
- Module upgrades preserve queued original payload and schema versions; use tested upcasters or non-destructive recovery/export when incompatible.
- Do not disable Offline or a required module when pending operations may be lost.
- Benchmark SQLite/WAL behavior and power-loss durability on physical Android and Windows devices; configure sync modes based on evidence.
- Local encryption, device revocation, recovery/export and secret storage require a threat-model-driven design before deployment.
- Optional downloaded translations are cached independently of the command queue. Their absence or corruption must **never** block operational data recovery.

**Offline invoicing:** A stable local ID and visible provisional label differ from the Host-assigned official number. Legal requirements for numbering and offline issuance vary by jurisdiction; if compliance cannot be met, offline documents remain provisional and non-final.

## 6. DocTypes, storage and schema evolution

DocTypes declare field definitions, data types, references, permissions and UI metadata. Generic record creation is only suitable for permitted operational entities; balance-changing ledger and stock movements always flow through trusted business commands.

Module version, DocType schema version and command type version are independent. Host compatibility windows are explicit. Migrations must be resumable and reversible when feasible, with backups before dangerous steps. Previously queued commands retain their original schema and must be upcast or refused **without destructive loss**. Choosing per-DocType relational tables vs. JSONB hybrid storage is a performance and migration design decision, not settled by this starter.

Localization keys are **display metadata**, not database field identifiers. The stable machine identifier `status = "diagnosing"` must not become a translated storage value. The English `label` is always available as a built-in fallback. Additional language packs may change what the user sees but never change command types, role IDs, journal entries or schema names.

## 7. English-first localization contract (new in V1.2)

### 7.1 Required now

- All initial source files, built-in resources, user-facing English strings, developer documentation, UI texts, diagnostics, and sample data must use English. Source code identifiers and internal protocols are language-neutral.
- Each translatable UI concept has a stable namespaced key (for example, `maintenance.request.device_model`). Dynamic module manifests provide an English `displayName` and `displayNameKey`; DocTypes and field declarations provide English `label` and `labelKey`; enum values have stable IDs and separate labels.
- Every business module includes an English catalog identified by its manifest (`englishCatalog`). Built-in shell/Core English messages are packaged with the application; modules cannot rely on the optional Translation Module for their default rendering.
- Presentation resolves through `LocalizationResolver.resolve(key, fallbackEnglish, params)` (conceptual contract, **not** a frozen Dart API). With no translation extension installed, return the bundled English message. If a key is missing, return the approved English fallback and record a developer diagnostic without displaying raw key names to customers.
- Error receipts carry stable codes and optional typed parameters, not just localized phrases; logs and audit records preserve machine codes and English diagnostics.
- Modules must register translation namespaces without collision and validate that their metadata keys exist in the English catalog. The module's full English catalog is versioned with its own module release.

### 7.2 Deferred Translation Module (not implemented yet)

- Optional, explicitly installed Translation Module(s) can supply signed, version-compatible language packs and a language selector. Alternative translations should be loadable/updatable without rebuilding the app, **as data**, subject to integrity and compatibility checks.
- Language packs may target the Core or specific modules, preserving locale, target version, and the same stable keys. A proposed draft format is in `contracts/language_pack.schema.json`.
- Locale resolution order for a translated message: active compatible pack -> module/Core built-in English catalog -> literal English fallback from trusted metadata. Partial translations are allowed.
- Disabling or uninstalling the translation capability returns to English without changing operational records, financial values, permissions, or queued commands.
- Local storage caches authorized language packs so switching language and rendering can work offline after installation. Corrupt/unavailable packs fall back to English.
- Language packs are **untrusted display data**, never commands, SQL, dynamic code, or authority. Sanitize rich content, validate placeholders, protect sensitive interpolation values, and define package signature/revocation strategy before accepting third-party packs.

### 7.3 Platform, formatting, and layout requirements

- Flutter shell must support locale-aware message resolution, text direction, logical padding/alignment, and dynamic rerendering when the active locale changes; do not hardcode layout assumptions tied to English length or left-to-right text.
- Design for plural/gender/parameterized messages. Adopt a standards-based ICU/CLDR-compatible strategy only after testing message syntax and runtime pack loading; **do not interpolate untrusted format strings unsafely**.
- Format dates, times, measurements, counts, and currencies in the **presentation layer**. Do not mutate numeric/decimal values, ISO timestamps, currency codes, or accounting balances according to display locale.
- Support accessibility labels, validation help, dialogs, dynamic UI, reports, exports and printed documents. Custom entered customer/product content is *business data*, not automatically translated by UI language packs.
- Printing and official document language might be regulated by jurisdiction and must remain subject to explicit document policies, separate from the operator's UI locale.

### 7.4 Localization proof / release gates

1. Start the installed app with no Translation Module and verify **all** built-in and dynamic module UI remains English.
2. Install a *test-only* pseudo-language pack and change locale at runtime; verify UI rerenders without new binaries and without altering stored data.
3. Remove the pack or reference a missing key; verify deterministic English fallback, with no crashes.
4. Verify stable enum values, command receipts, account balances and persistent records are unaffected by language changes.
5. Exercise RTL direction, longer strings, pluralization, offline pack caching and export/print coverage **before** enabling real language offerings.

The starter package only performs static contract/catalog tests, **not** the Flutter runtime tests above.

## 8. Security and tenancy

Host derives trusted identity/tenant/branch context, denies by default, and enforces row/field/command policies. Tenant isolation (potentially including PostgreSQL RLS) must be verified under connection pooling. Modules are versioned, integrity-checked and deny arbitrary executable content. Device-local secrets and business data require protection. Package signing alone does not authorize a requested capability. Security tests must cover cross-tenant access, spoofed scopes, revocation while offline, module tampering, extension downgrade and untrusted translated text.

## 9. Enterprise evolution

The Host is **one logical authority**, not necessarily one physical machine. Start with a single PostgreSQL transactional writer and stateless API replicas; guard domain invariants at the database boundary. Do not assume multi-region active-active writes or automatic sharding. Collect latency, lock contention, memory, tenant isolation, sync queue and recovery evidence before selecting scaling mechanisms.

## 10. Current delivery scope

**Included in V1.2:** Architectural specification, proposed JSON Schemas, examples and English catalogs, language-pack draft contract, cross-contract and English-only checks, ADRs, proposed sequence diagrams and proof-of-platform plans.

**Not included:** A compiled Dart Core, Flutter renderer, PostgreSQL Host, deployed Offline Engine, dynamic locale switching implementation, security certification, real accounting logic, performance benchmark or a tested migration from the current Ventio source.

## 11. Decision gates

| Gate | Acceptance criterion |
|---|---|
| G1 Extension | Install and update the maintenance module without changes to Core or Flutter renderer; expose capability limitations honestly |
| G2 Financial | Atomic invoice/stock/ledger posting and 1,000 retries of the same ID without duplicate business effects |
| G3 Offline | Correct response-loss/restart behavior and durable pending command recovery |
| G4 Versioning | Old queued commands survive schema changes, or fail with safe export/recovery |
| G5 Security | Forged contexts and cross-tenant access are denied |
| G6 Operations | Real backup/restore, instrumentation and load measurements |
| **G7 Localization** | English works without translation module; pseudo-pack and missing-key fallback do not change business data or require Core rebuild |

No migration of the current Ventio POS/ERP into this Framework is authorized by this document. Review the latest application source and prove accounting equivalence before any migration decision.

## 12. Near-term implementation sequence

1. Review V1.2 architectural decisions and provisional extension capabilities.
2. Build a small Dart Core + in-memory Host demonstration; then a PostgreSQL-backed transaction implementation.
3. Install and operate the Maintenance example through metadata and trusted capabilities, without editing Core.
4. Build a Flutter Windows/Android demonstration, with built-in English catalog resolution and dynamic locale capability hooks.
5. Prove invoice/stock/ledger atomicity, idempotency, Offline queue durability and schema upcasting.
6. Use a pseudo-pack to prove translation plug-in boundaries; **do not** build production language packs yet.
7. Audit the current Ventio implementation and choose reuse/migration based on evidence.

## 13. Technical references for later verification

- Flutter architecture and internationalization: https://docs.flutter.dev/ui/accessibility-and-internationalization/internationalization
- Flutter FAQ: https://docs.flutter.dev/resources/faq
- Dart compilation: https://dart.dev/tools/dart-compile
- PostgreSQL constraints: https://www.postgresql.org/docs/current/ddl-constraints.html
- SQLite WAL: https://www.sqlite.org/wal.html
- SQLite PRAGMA: https://www.sqlite.org/pragma.html

These are design references, not claims that the implementation has been verified, benchmarked or approved for any specific regulatory environment.
