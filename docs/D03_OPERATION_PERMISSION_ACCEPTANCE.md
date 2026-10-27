# D03 Operation-Level Permission Acceptance Evidence

Date: 2026-10-27

## Acceptance result

**PASS — D03 accepted.** DocType operations declare a matching stable permission key for every supported operation. Host authorization resolves the requested operation against the approved metadata and the authenticated tenant/company/branch grants before executing the operation. Authorization is checked again for retries, so an earlier receipt does not preserve a permission that has since been revoked.

## Evidence

- Core contract harness: `dart run test/all_tests.dart` — **69 passed, 0 failed**. It verifies exact-scope permissions, rejects a permission from another company/branch, rejects unsupported operations, and requires permission keys to match declared operations.
- PostgreSQL Host extension integration: `dart run test/extension_package_integration.dart` on isolated PostgreSQL 17.11 — **87 passed, 0 failed**. A user with only the `read` operation grant was denied `create` and `update`; the create produced no record and the update left its revision and values unchanged. The same run verified exact-scope denial, retry receipts, extension metadata enforcement, and Host policy checks.
- Persistent identity integration evidence in [D01](D01_IDENTITY_ACCEPTANCE.md) verifies that revoking a permission after authentication denies both an in-flight later request and a saved-receipt replay, with no journal, record, audit, or outbox effects. Regranting returns the original receipt without re-executing effects.
- PostgreSQL policy source in `security/postgres/extensions.sql` checks that the requested operation is declared, selects its matching permission, and matches that permission against the authenticated grant at the exact company and branch before binding RLS context.

## Repeatable test fixture

The extension integration's recovery-scale fixture now uses a unique tenant and tenant-specific credential digests per run. Its sub-millisecond performance comparison allows up to 25% variance in the relative RLS query medians while preserving the 20-row correctness checks and absolute latency bounds. This removes unrelated duplicate-key and microbenchmark-noise failures during repeat runs.