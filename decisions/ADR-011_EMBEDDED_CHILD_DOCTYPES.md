# ADR-011 — Embedded Child DocTypes

**Decision date:** 2026-10-27  
**Status:** Accepted for Wave 1 implementation; not a public v1 protocol freeze.

## Context

Wave 1 needs declarative child DocTypes and editable ordered rows. Ventio stores an extension record as one bounded JSON document, uses one durable command and receipt per parent mutation, and later routes CRUD and lifecycle effects through the generic governed-operation pipeline in ADR-010. Independent child records or commands could partially persist a document, escape parent permissions, or recover inconsistently after a retry or restart.

## Decision

1. A parent `table` field may contain one nested `childDocType` definition with a stable name, localized label keys, and bounded field definitions. The child schema is part of the extension package and parent field metadata; it is not a separately addressable top-level DocType.
2. Child rows are ordered JSON objects embedded in the parent field value. Their order is the array order. Rows have no independent record IDs, permissions, operation commands, document status, or lifecycle. Parent create/update/delete and later submit/cancel/amend operations carry, validate, and persist the child rows in the same atomic parent transaction and receipt.
3. The parent table field is the security boundary for every child value. Its existing read, write, and create field permissions mask or authorize the complete row array. Child fields cannot declare independent permissions or server-managed read-only values.
4. Child references may target a top-level DocType in the same extension package. Every non-null target must exist in the exact parent tenant/company/branch scope. Safe deletion applies the existing `RESTRICT` rule to references inside child rows as well as parent fields.
5. Child fields may use the supported scalar, enum, and reference types, constraints, and defaults. A child field cannot be another table field, so nesting and recursive schemas are rejected. Rows reject unknown keys, validate required fields and values, apply declared defaults, and remain subject to the existing 500-row bound.
6. Legacy table fields without a `childDocType` retain the existing bounded scalar-row contract for package compatibility. No uploaded code, SQL, handler, or extension-specific Host behavior is introduced.

## Consequences for K06 and B04

K06 resolves an ordinary parent document and its approved DocType metadata, validates the parent payload recursively (including child schema and exact-scope references), and sends the one normalized parent JSON value through the existing transaction/effect/journal/audit/outbox path. It does not dispatch separate child operations. B04 status belongs to the parent; a legal parent transition applies to its embedded rows as one document. Amend copies the source row values into the new draft according to the existing amend contract. Thus child rows do not create another lifecycle design.

## Acceptance evidence

The A07 checkpoint must prove metadata/package round-trip and malformed-schema refusal; typed nested validation/defaults/unknown-field and row-bound behavior; local SQLite atomic save/restart; PostgreSQL Host rejection of invalid rows/references without record, receipt, journal, audit, outbox, or cursor effects; exact-scope reference enforcement and child-reference delete restriction; and that the parent field mask governs all nested values. C03 separately proves grid editing and reorder UX. K06/B04 later verify operation and lifecycle atomicity with the same parent payload.
