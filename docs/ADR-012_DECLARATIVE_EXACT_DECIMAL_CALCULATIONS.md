# ADR-012 — Declarative Exact Decimal Calculations

**Decision date:** 2026-10-28  
**Status:** Accepted for Wave 1 F02 implementation; not a public v1 protocol freeze.

## Context

F02 requires bounded line and parent totals, exact decimal calculation, Host recomputation, and consistent offline/online values. K06 and B04 already persist one parent record and its embedded child rows through the shared command, transaction, journal, and receipt pipeline. An extension must not upload executable formulas or a custom Host handler.

## Decision

1. Calculation declarations are data-only field metadata. The Core interpreter supports exactly two operations: `multiply` two numeric sibling fields within a typed child row, and `sum` one numeric child field over a parent table field. No expression strings, arbitrary code, cross-record reads, recursive formula graphs, or unbounded functions are accepted.
2. A calculation target is a decimal field with declared precision. Source decimal fields must declare precision; integer sources have scale zero. Multiplication and summation use scaled `BigInt` arithmetic. A product that cannot be represented exactly at the target scale, a non-finite input, an out-of-bound row set, or a result that cannot round-trip through the JSON numeric representation is rejected. No implicit rounding occurs.
3. Calculated values are derived and cannot be supplied as authoritative user input. SQLite computes them before local persistence and durable command creation. Host independently recomputes them before persistence and rejects a supplied stale or forged value. Accepted Host snapshots and receipts remain authoritative during reconciliation.
4. For a child line amount and parent total, calculation dependencies are one-way: source quantity/price fields -> calculated row amount -> parent sum. Cycles, missing fields, mismatched types, and precision expansion are rejected during metadata validation.
5. Generated forms display calculated values read-only and recalculate from the bounded input values. The parent `table` field remains the single permission boundary for all nested values. Child fields still cannot declare independent permissions or the `readOnly` flag; their derived status comes only from the bounded calculation declaration. This supersedes ADR-011 only for calculated child values.
6. Calculation metadata is included in extension package serialization and schema validation. No SQL, Dart, scripts, or extension-specific Core/Host exceptions are introduced.

## Acceptance interpretation

The fixed F02 criterion in `WAVE1_EXECUTION_PLAN.md` is demonstrated with a typed child row containing quantity, unit price, and calculated line amount, plus a calculated parent total. Core rejects malformed/cyclic/unsupported formula metadata and validates exact results. SQLite computes and persists the same totals offline and across restart. PostgreSQL Host recomputes totals, rejects altered results atomically, and accepts the matching command; receipts and reconciliation expose the Host values. Cases include fractional arithmetic, maximum supported scale/bounds, overflow, and retry idempotency.

## Consequences

- The calculation contract is shared by Studio, SQLite, and Host through Core metadata and exact-decimal utilities.
- Calculations are pure and deterministic from the submitted parent payload; no separate child commands or totals side effects are needed.
- Rejection remains inside the existing safe command and receipt behavior. Submit/Cancel/Amend continue to operate on the same calculated parent document, and Amend copies the persisted child rows.
