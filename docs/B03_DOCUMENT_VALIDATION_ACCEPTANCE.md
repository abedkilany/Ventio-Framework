# B03 Document Validation and Lifecycle Foundation Evidence

Date: 2026-10-27

## Acceptance result

**PASS — B03 accepted.** Acceptance follows the clarified scope in [the execution plan](WAVE1_EXECUTION_PLAN.md#stage-1-the-23-authoritative-capabilities): the PostgreSQL Host validates approved metadata and create/update commands, validates payloads and exact-scope references, enforces optimistic revisions, and commits all command effects atomically. This is the foundation for lifecycle behavior; Submit/Cancel/Amend transitions remain B04.

## Verification

- `packages/ventio_core`: `dart run test/all_tests.dart` — **69 passed, 0 failed**. Coverage includes DocType operation metadata, typed payloads, defaults/read-only fields, command permission/scope checks, invalid payloads, and supported operational module registration.
- `packages/ventio_host`: `dart run test/durable_integration.dart` against an isolated PostgreSQL 17.11 `ventio_host_test` database — **43 passed, 0 failed**.
- `packages/ventio_host`: `dart analyze lib test/durable_integration.dart` — **No issues found**.
- PostgreSQL extension integration passed **87/87**, including approved package and DocType version enforcement, metadata filters, exact-scope reference rejection, operation permissions, and exact-record revision behavior.

## PostgreSQL durable Host evidence

The durable integration verified:

- Only registered and approved module/DocType/schema versions execute; invalid payloads and duplicate records are rejected without a journal reservation or business record.
- Omitted defaults are stored; decimals outside declared precision and client overrides of read-only fields are rejected.
- Same-module, same-company, same-branch references are accepted; missing and cross-branch/company/tenant references are rejected without storing the referencing record.
- Expected revisions, duplicate command IDs, dependencies, permission rechecks, concurrent identical retries, and competing record creation behave consistently.
- An injected pre-commit failure leaves no record, command journal entry, audit entry, outbox entry, or consumed scope cursor. Retrying the same command ID succeeds once; committed effects and cursors remain consistent under concurrency.

## Lifecycle boundary

This acceptance establishes validation and atomic create/update foundations. It does not accept business Submit/Cancel/Amend states; those transitions are B04 scope and will be assessed after K06's governed operation design is resolved.