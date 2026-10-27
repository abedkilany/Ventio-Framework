# ADR-010 — Governed Operations and Document State

**Decision date:** 2026-10-27  
**Status:** Accepted for Wave 1 implementation; not a public v1 protocol freeze.

## Context

Wave 1 needs generic record deletion and later document Submit/Cancel/Amend behavior. Those features must work for ordinary extension packages, preserve offline retries, and share Host authorization and transaction guarantees. Adding independent delete or lifecycle paths before K06 would risk incompatible command, permission, receipt, audit, and state rules.

## Decision

1. **Declarative operation definitions.** An operation has a stable namespaced ID, version, permission, bounded input/output contract, and a list of effects selected from a Core-owned trusted vocabulary. Extension packages can declare and compose only validated operations; they cannot upload Dart, SQL, scripts, or arbitrary executable handlers.
2. **One Host mutation pipeline.** Every mutation, including CRUD and lifecycle operations, runs through the same authenticated transaction path. The Host resolves the approved operation and exact-scope permission before journal access, validates inputs and current revision, then commits business effects, receipt, audit, and outbox together. Retries use the original command ID and never repeat accepted effects.
3. **CRUD as standard operations.** `record.create@1`, `record.update@1`, and `record.delete@1` are generic built-in operations available to ordinary extensions through DocType operation declarations and permissions. Read remains a separately authorized query. K06 generalizes the current create/update Host path rather than creating an extension-only route.
4. **Host-owned document status.** Each operational document has an integer status outside extension-editable business fields: `0` draft, `1` submitted, `2` cancelled. New records start as draft. Only governed operations may transition status. B04 implements submit, cancel, and amend after K06; amend creates a new draft linked to its source. Ordinary update cannot change status.
5. **Safe delete tombstones.** `record.delete@1` requires delete permission and an expected revision. It marks a record deleted while retaining its identity, last business values, and incremented revision as a Host-only tombstone. Normal reads/searches hide tombstones; IDs remain reserved and cannot be recreated. The Host rejects deletion of submitted documents and any record with an inbound reference. Reference deletion remains `RESTRICT` with no cascade. A later retention/erase policy is separate and must preserve audit and replay safety.
6. **Offline behavior.** SQLite may hide a locally deleted draft as a provisional change, but retains a durable delete command and the original record until Host reconciliation. Acceptance finalizes the tombstone; rejection or conflict restores the visible record and requires explicit resolution. A Host receipt, not a local flag, is authoritative.

## Consequences

- B01 may add the generic delete primitive and tombstone representation before K06, but must use the command/permission/transaction contracts above and must not add business-specific behavior.
- K06 must provide the reusable declaration, validation, authorization, effect dispatch, audit/outbox, and receipt pipeline that hosts the existing CRUD operations and the later lifecycle operations.
- B04 must use the Host-owned status and the same governed operation pipeline. It cannot add client-writable `docstatus`, a separate lifecycle transaction, or an extension-only handler.
- Stored status and deletion state are independent of English labels and other user-facing localization.

## Acceptance evidence

The decision will be verified through the B01 delete/replay/reference tests, K06 generic operation tests, and B04 transition/rollback tests. Existing D03, B03 and A05 evidence validates exact-scope authorization, atomic command effects, durable receipts, and the `RESTRICT` reference rule that this decision reuses.