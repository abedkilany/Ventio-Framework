# B01 — Safe Record Deletion Acceptance

**Status:** Accepted  
**Capability:** B01 — CRUD with safe deletion semantics  
**Acceptance checkpoint:** `90e415d`  
**Date:** 2026-10-27

## Accepted behavior

- Generic `extension.record.delete@1` is available through DocType metadata and requires the exact-scope delete permission, read permission, and a positive expected revision.
- Host deletion is draft-only. Submitted documents are rejected, and live inbound references prevent deletion under `RESTRICT` semantics.
- Accepted deletes create a tombstone that retains the record ID and business values, advances the Host revision, and is omitted from record reads. A tombstoned ID cannot be reused.
- The delete receipt, audit entry, outbox event, and tombstone commit atomically. An identical retry returns its saved receipt and produces exactly one journal, audit, and outbox entry.
- SQLite persists the provisional delete command across restart, hides the pending deletion locally, and restores the row when Host receipt resolution rejects/conflicts the delete.
- Extension Studio exposes the governed delete action with catalog-backed confirmation text.

## Evidence

- `packages/ventio_host_api/test/extension_package_integration.dart` against the isolated PostgreSQL 17.11 `ventio_host_test` database: **98 passed, 0 failed**. Includes permission denial, submitted and referenced-record refusal, tombstone contents/revision/visibility, idempotent retry and one-time effects, ID reservation, cross-scope reference checks, query/pagination regression, and RLS/recovery/security regression checks.
- Core harness: **69/69**; `flutter test test/extension_store_test.dart`: **34/34**; durable delete-command queue restart test: **1/1**.
- Host API integration analyzer: no issues. Host durable command analyzer: no issues.
- Localization gate: passed; delete confirmation/action uses stable English catalog keys.
- The PostgreSQL stale-revision regression discovered during B01 verification was fixed by relying on the existing exact-scope advisory transaction lock instead of `FOR UPDATE`. The latter was filtered by the RLS expected-revision policy and hid the current revision from stale updates. The full integration now verifies stale commands return `REVISION_CONFLICT` with the current Host revision.

## Acceptance decision

All B01 criteria in `WAVE1_EXECUTION_PLAN.md` are demonstrated by the implementation and evidence above. B01 is accepted as completion of the gaps in a previously partial capability (`Work Performed: Completed Gaps`).
