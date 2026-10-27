# B04 Lifecycle Architecture Review

Date: 2026-10-27

This is a read-only review of the current B04 design and source before its implementation checkpoint. K06 is already accepted; this review does not claim B04 acceptance.

## Current behavior

- `document.transition` currently permits Draft (0) to Submitted (1), then Submitted (1) to Cancelled (2), using the K06 operation transaction and receipt path.
- Studio exposes Submit and Cancel operations. Its operation button supports exactly one transition and no declared inputs.
- The durable local queue already persists operation commands and reconciles status and official-number outputs.
- No amend command, effect, UI action, local draft-copy flow, or amend-specific runtime test exists.
- A correctness gap exists for B04: the Host checks that deletes target drafts but does not reject a generic `record.update` when the current record is Submitted or Cancelled. PostgreSQL's record update policy also permits the resulting status to remain non-draft. Both Host and RLS must reject that write.

## Proposed governed amendment design

Use a Core-owned `document.amend` effect inside the same approved, versioned K06 business-operation contract. The declaration names a self-reference field and a required text output. That field is ordinary DocType metadata (`referenceTo` the same DocType), with Host-owned/read-only semantics; it adds no inventory-specific behavior.

The Host derives the new draft ID from the amendment command ID, so retrying the same durable command addresses the same draft. In the source record's exact-scope transaction, it must:

1. Resolve the approved operation and exact amend plus create authority before journal replay or effects.
2. Require the source's expected revision and Cancelled status.
3. Refuse a second active amendment for the same source; serialize this check with the source's existing write lock.
4. Copy the source values, including its embedded Child Table rows; clear its official number; set the declared self-reference to the source ID; validate the new values/references; insert a new Draft at revision 1.
5. Commit the amendment draft, journal receipt, audit, outbox, and output ID atomically. It applies no Submit effects. Only a later Submit of the new draft applies its saved rows.

The local client should create a provisional copy keyed by the same command ID, queue the amendment durably against the source revision, and mark both source and copy pending. Receipt reconciliation updates the source and the new draft separately; a rejection preserves the provisional copy for explicit resolution. The Host's returned amendment ID must match the command ID before the client accepts the copy.

## Fixed acceptance scenarios

- Draft Submit succeeds once; draft-only generic updates remain allowed.
- Generic update of submitted or cancelled data is rejected by both Host and PostgreSQL RLS with no value or revision change.
- Submit and Cancel require their exact scoped permissions and legal source statuses; retries do not repeat numbering or child-row effects.
- Amend of a cancelled source creates one linked status-0 copy, retains child rows and other editable values, and does not copy the official number.
- Amend of a draft/submitted source, stale source revision, unauthorized amend/create, invalid link, and an active duplicate amendment fail without partial rows or receipts.
- Concurrent identical Amend retries yield one new row and one saved receipt; distinct concurrent amendment commands cannot create multiple active copies.
- Submit/Cancel/retry of the amended draft applies and reverses its child-row effects once; the cancelled source remains unchanged.
- SQLite restart preserves the provisional amended draft and queued command; acceptance/rejection reconciles both records without losing local rows.
