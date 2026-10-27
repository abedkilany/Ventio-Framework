# D04 Field-Level Permission Acceptance Evidence

Date: 2026-10-27

## Acceptance result

**PASS — D04 accepted.** Host enforces field-level read, create, and update authority in the exact authenticated scope. Unreadable values are removed from Host query results; predicates on unreadable fields are rejected. Unauthorized writes do not persist, and permitted partial updates preserve protected fields omitted from the patch. The native client's persisted field masks scrub values after Host policy is learned.

## PostgreSQL Host evidence

Against the isolated PostgreSQL 17.11 `ventio_host_test` database on loopback, `dart run test/extension_package_integration.dart` completed with **87 passed, 0 failed** (including the D03 additions). The field permission checks verified:

- A field-granted identity can create and update the protected value.
- A principal without field read permission cannot discover the protected sentinel through search; Host omits the field from `readableFields`, returns no matching records, and a direct record read omits the protected value entirely.
- Host rejects filters and sorting on unreadable protected fields with `PERMISSION_DENIED`.
- Host rejects creation of a protected value without the field write grant and a privileged readback confirms no record was stored.
- Host reports that a read-only field is not writable.
- Host rejects a forged protected-field write and preserves the prior value.
- A permitted partial update succeeds and preserves protected values not included in its patch.

Host constructs each record's `values` map only from `readableFields`; the PostgreSQL integration directly verifies protected-value omission and denial of unreadable filters and sorting. `dart analyze test/extension_package_integration.dart` reported no issues.

## Native client evidence

In `packages/ventio_native_client`:

- `flutter test test/extension_store_test.dart --plain-name "Host field masks scrub cached values and constrain partial edits"` — **1 passed**. It verifies that learning Host masks removes the protected cached value, unauthorized local edits fail, and allowed edits retain other values.
- `flutter test test/extension_studio_test.dart --plain-name "Host field masks hide details and persist per identity"` — **1 passed**. It verifies masked UI details and identity-scoped persistence.

## Scope and compatibility

Permission identifiers remain stable metadata. Authorization is rechecked by Host in the authenticated tenant/company/branch scope. UI masks are presentation and offline safeguards; Host remains authoritative. No production translation or business-specific permission exception was introduced.