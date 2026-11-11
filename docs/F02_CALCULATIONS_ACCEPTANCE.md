# F02 Aggregations and Calculated Totals Acceptance

## Acceptance criterion

Declaratively calculate bounded decimal line and parent totals using exact decimal semantics; the Host recomputes and validates totals and persists/reconciles the same result for online and offline submissions.

## Implementation

- `packages/ventio_core/lib/src/exact_decimal.dart` provides bounded scale-9 decimal parsing and integer-scaled arithmetic without implicit rounding.
- `packages/ventio_core/lib/src/metadata.dart` defines and validates the supported `multiply` child-field and `sum` typed-table calculation declarations; calculated values are recomputed and supplied values can be verified.
- `packages/ventio_native_client/lib/src/extension_store.dart` applies the same metadata calculation rules while creating and updating local records and durable commands.
- `packages/ventio_native_client/lib/src/extension_studio_page.dart` authors the supported declarations and renders calculated child and parent values in generated forms.
- `packages/ventio_host/lib/src/durable_command_host.dart` recomputes values in the authoritative transaction and rejects mismatches before journal, audit, outbox, or cursor changes.
- The root and v1.2 DocType schemas accept the bounded declaration. English catalog keys cover calculation controls and generated totals.
- The design constraints and no-rounding policy are recorded in [ADR-012](ADR-012_DECLARATIVE_EXACT_DECIMAL_CALCULATIONS.md).

## Evidence

- Core harness: **75/75**. Exact decimal test covers `0.1 × 0.2 = 0.02`, `2 × 0.15 = 0.3`, parent sum `0.32`, forged calculated values, implicit-rounding rejection, binary floating-point noise rejection, and invalid formula references.
- SQLite calculated child and parent values persisted after a record update: focused `extension_store_test.dart` case **1/1**.
- Generated Studio calculation grid: focused `extension_studio_test.dart` case **1/1**. Declarative calculation authoring in the DocType Builder: focused case **1/1**.
- Dart analysis over the modified Core, Host, Native Client, and tests reported no issues. Contract fixtures and schema validation passed; the localization gate passed.
- Disposable Windows PostgreSQL **17.11** `ventio_host_test` integration command `dart run test/extension_package_integration.dart` exited **0** with **130 passed, 0 failed**. It verified Host recomputation/persistence of exact child and parent totals, forged-total rejection without record, journal, audit, outbox, or cursor effects, and retained K06/B04 rollback, authorization, numbering, retry, idempotency, and concurrency scenarios.
- The initial full integration run exposed reused command IDs between the newly added F02 fixtures and later Amendment cases. The F02 fixture IDs were moved to their own `76000000-...` namespace. The complete integration rerun then passed all 130 assertions, including the second independent amendment rejection and distinct concurrent Amend race.
- PostgreSQL was an isolated temporary cluster and the test used only the disposable `ventio_host_test` database; no production database was involved.

## Acceptance

F02 passes its fixed functional criterion. Exact calculation declarations use shared Core semantics, local generated records persist calculated values, and PostgreSQL Host independently recalculates and rejects forged totals without partial effects. Capability accepted as **Newly Implemented**.
