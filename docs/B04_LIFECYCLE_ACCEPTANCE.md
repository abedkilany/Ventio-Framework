# B04 Lifecycle Acceptance

Date: 2026-10-28

Status: **ACCEPTED** on `codex/extension-platform`.

B04 extends the generic K06 declarative operation pipeline. Extensions provide metadata and bounded effects only; Core and Host own document-state transitions and amendment behavior.

## Acceptance evidence

- **PostgreSQL 17.11 Host integration: 128/128 passed** against a disposable loopback-only `ventio_host_test` database. Migration `024_document_number_series.sql` and the security bootstrap were applied; the bootstrap was reapplied idempotently. The temporary cluster was stopped after testing. No production database was used.
- Runtime coverage includes exact-scope Submit, Cancel, Amend, and create authorization; legal-state and stale-revision checks; generic update rejection for submitted/cancelled records; atomic rollback; concurrent identical Submit and Amend idempotency; transactional official numbering; cancellation reversal; amend-copy linkage and child-row preservation; omission of the source official number; invalid/duplicate amendment rejection; amended Submit/Cancel effects; and distinct concurrent Amend commands resulting in at most one active draft.
- **A10 numbering allocator integration: 6/6 passed**, including transaction rollback, concurrent allocation, configuration protection, and branch isolation.
- **Core contract harness: 74/74 passed**, including bounded Amend effect shape and its required Host-owned read-only self-reference field.
- **Native SQLite ExtensionStore: 38/38 passed**, including local linked draft copies, copied rows, provisional local numbering, duplicate-active amendment refusal, durable queue/restart behavior, accepted/rejected reconciliation, and prevention of edits to submitted records.
- **Focused Extension Studio Amend flow: 1/1 passed**, including enqueueing a local amendment, reconciling the source with its Host receipt and the new draft at revision 1, and preserving a rejected provisional copy without a false Host revision.
- **Focused lifecycle builder: 1/1 passed** for generated self-reference metadata and `document.amend` operation declaration.
- Flutter analysis of the changed client lifecycle files/tests and Dart analysis of the Host changes passed. The English localization gate passed.

## Design and security properties

- `document.amend` is a versioned, bounded Core effect and must be the sole effect in its operation. The DocType declares an optional read-only self-reference and create permission.
- Host serializes writes by exact scope, verifies operation and create permissions, requires a cancelled source at its expected revision, and uses the command ID as the new draft ID. It copies stored values and child rows, removes the source's official number, sets the self-reference, and commits the draft, receipt, audit, and outbox atomically.
- PostgreSQL RLS restricts amendment inserts to the authorized operation and command ID. Generic updates cannot mutate submitted/cancelled documents.
- SQLite creates and queues the provisional copy atomically. Host reconciliation applies the source receipt to the source and constructs the accepted copy at its own initial revision. Rejections retain local content for explicit resolution.
- Repeated identical commands return the saved receipt. Distinct concurrent amendment commands cannot create multiple active drafts for the same source.

## Verification commands

Commands were run from the corresponding package directories:

- `dart run test/extension_package_integration.dart` with explicit test-only PostgreSQL URLs and `VENTIO_ALLOW_DATABASE_TESTS=yes`.
- `dart run test/document_number_allocator_integration.dart` with the disposable PostgreSQL admin URL.
- `dart run test/all_tests.dart` (Core).
- `flutter test test/extension_store_test.dart` (native client).
- Focused `flutter test test/extension_studio_test.dart --plain-name "Amend queues a local draft copy for a cancelled document"` and the lifecycle builder test.
- `dart analyze` on changed native client and Host files; `python scripts/check_localization_gate.py`.

No secrets or production connection details are recorded here.
