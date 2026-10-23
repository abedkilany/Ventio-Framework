# Architecture Decision Records — V1.2

| ID | Decision | Status | Verification / exit |
|---|---|---|---|
| ADR-001 | Pure Dart Core with Flutter application shell | Accepted principle | Package import boundary tests |
| ADR-002 | Host-authoritative, effect-once command processing | Accepted principle; mechanisms proposed | PostgreSQL crash, duplicate and concurrency tests |
| ADR-003 | Hybrid extension tiers L0–L4 with guarded capabilities | Proposed; critical test | Maintenance module plus advanced-rule limits |
| ADR-004 | Offline-ready Core and optional Offline Engine | Accepted principle; mechanisms proposed | Recovery, retries and schema migration |
| ADR-005 | Protocol and schema contracts remain v0 drafts | Proposed | Evolve through contract tests before freezing v1 |
| ADR-006 | Start with a Modular Monolith | Proposed | End-to-end transactional proof |
| ADR-007 | Initial storage and Host language choices | Open | Dart Host, PostgreSQL and SQLite benchmarks |
| ADR-008 | Trusted native extensions vs. isolated runtime | Open | Capability gaps and sandbox threat proof |
| **ADR-009** | **English-only built-in product with optional Translation Module** | **Accepted product principle; implementation proposed** | English without module, pseudo-pack activation, missing-key fallback, unchanged business data |

No ADR in this package approves rewriting the current Ventio POS/ERP or finalizing public v1 APIs before proofs.

See `ADR-009_ENGLISH_FIRST_LOCALIZATION.md` for requirements, constraints and deferred choices.
