# ADR-012 — Document Naming and Numbering

**Decision date:** 2026-10-27  
**Status:** Accepted for Wave 1 implementation; not a public v1 protocol freeze.

## Context

Wave 1 requires ordinary declarative extensions to define readable document numbers while preserving offline creation, stable references, atomic Host submission, and idempotent retries. Current records use a secure random UUID as their stable aggregate ID. Replacing that ID with a sequential number would make offline allocation, references, and retry recovery unsafe.

## Decision

1. **Keep stable identity separate from display naming.** A record's immutable UUID aggregate ID remains the key for local storage, Host storage, references, commands, and reconciliation. An official document number is a separately declared, read-only text field in the record's business values.
2. **Declare bounded series metadata.** A DocType may declare a series ID, target read-only text field, literal prefix, and bounded zero-padding width. The declaration is data only; it cannot contain templates, scripts, SQL, or executable handlers. The target field must exist, be text, and be unavailable for client writes.
3. **Use provisional offline names.** SQLite may assign a clearly provisional local value to a new draft so users can distinguish drafts offline. It is not an official number, is never used as identity, and cannot be submitted as an official value. Host reads omit the provisional value until submission.
4. **Allocate only during governed Submit.** The future `document.number.allocate@1` built-in effect runs only inside the K06 Host transaction for the B04 submit operation. It allocates the next number for the exact tenant/company/branch/DocType/series scope and writes that value atomically with status, effects, journal receipt, audit, and outbox.
5. **Make retries and failures safe.** The series counter is transactionally updated under a unique scope key, not through a non-transactional sequence. Replaying the same command ID returns the saved receipt and number without incrementing again. A rolled-back submission rolls back its allocation. Distinct concurrent submissions serialize on the counter and receive distinct values.
6. **Reconcile the accepted value.** The Host receipt returns the official field value so SQLite can replace the provisional value for that same UUID record. Conflicts and rejected submissions retain a draft and require explicit resolution; no provisional value is presented as official.

## Consequences

- A10 may define and validate the metadata contract and build the trusted transactional allocator before submit exists, but A10 cannot be accepted until the K06/B04 integration proves Host submit, atomic rollback, concurrent allocation, same-command retry, and offline reconciliation.
- K06 must expose numbering only as a bounded Core-owned effect inside its generic operation pipeline. B04 declares the effect on Submit; no extension-specific Host route or privileged package is allowed.
- Official numbering is not a database identity, permission, enum, or localization value. Its field label uses the Stage 0 catalog mechanism.
- This decision deliberately starts with non-resetting scoped series. Calendar-based resets and arbitrary formatting rules require a later contract decision.

## Acceptance evidence

Verify malformed/unsafe series declarations are rejected; client attempts to set or alter the read-only number are rejected; provisional names never enter Host authority; concurrent submissions allocate unique contiguous accepted numbers; failed transactions do not consume a number; retries return the original number; and SQLite reconciliation replaces the provisional value without changing the UUID or duplicating business effects.
