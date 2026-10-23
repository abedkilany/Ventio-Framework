# Proof of Platform — Test Plan and Gates (draft)

## Scope and implementation order

**P0 – Contracts & safety baseline** (this package): validate schemas/examples; decide capability API and receipt semantics. Coverage is structural only.

**P1 – Generic operational module:** Implement ModuleRegistry + MetadataRegistry + trusted `records.operational.create@1` + Flutter forms/list. Install the `MaintenanceRequest` example, add a custom field, issue create command, modify permission, disable/reenable, apply versioned migration, all **without editing Core or Flutter renderer**. Verify no arbitrary runnable data in manifests. Negative test: reject sensitive ledger type via generic CRUD.

**P2 – Host command & DB:** PostgreSQL transactions with unique `(tenant_id,command_id)`, immutable canonical payload hash and stored receipt. Inject response loss after commit, retry x1000 and concurrent x1000, payload change with same ID, duplicate receipt lookup, transaction interruption, outbox crash/restart. Record official number once.

**P3 – ERP atomicity:** `sales.post_invoice`: inventory and accounting in **one transaction**. Test stock=15; two offline invoices qty=10 both: exactly one accepted if negative inventory forbidden. Stock=100, two qty=10: both accepted. Simulate failure at every write stage; DB must never contain half-posted invoice/ledger movement.

**P4 – Offline queue:** Windows and physical Android SQLite queue. Kill app during queued command, file/storage edge cases, network failure before/after Host commit, restart, resend same ID, reconcile only confirmed data. Measure `WAL + synchronous=FULL` write latency vs NORMAL, without assuming identical durability on power-loss. Lost-device encrypted data test; scope-based sync and revoked-device handling.

**P5 – Evolution:** Schema v1 -> v2 with old client 2 weeks disconnected and 10 queued commands; upcast+replay or non-destructive incompatibility with export and clear UI. Never silently drop pending journal.

**P6 – Enterprise baseline:** 10/100/1000 parallel client load shapes using production-like amounts of data, measure p50/p95/p99, queue size, DB locks, host CPU/RAM, and tenant isolation. No absolute throughput claim until baseline results observed.

## Deterministic acceptance conditions

| Gate | Test | Pass criterion |
|---|---|---|
| G1 | New Maintenance DocType/UI/permissions | No changes to Core/Flutter source for fields, form and workflow supported by capability catalog |
| G1b | Advanced business-rule challenge | Document exactly what can/cannot be implemented; if essential new logic needs Core modification, fix capability architecture before commercialization |
| G2 | Command replay 1000x | One business effect and stable receipt/official serial |
| G2b | Same ID, differing payload | Command rejected as ID reuse; original business effect unchanged |
| G3 | Crash before/after DB commit | No partial ERP postings, no orphan outbox; Client result eventually determinable |
| G4 | Stock concurrent | No oversell with negative inventory disabled; independent valid orders both accepted |
| G5 | Schema upgrade with offline queue | Safe replay or preserved rejected commands for resolution, no silent loss |
| G6 | Tenant isolation and forged identity | No cross-tenant read/write even with fake tenantId/actorId |
| G7 | Flutter Windows/Android | Actual installed apps, not WebView; both show pending/confirmed states correctly |
| G8 | Durability / backups | Restore test from real backups and power/interruption scenarios passes documented RPO/RTO objectives |

## Severity policy

- Any G2/G3/G4/G5/G6 failure blocks migration of core POS/accounting functionality.
- G1 or G1b failure blocks treating the platform as generally extensible; update architecture, not marketing claims.
- Slow p95 is a measurement and prioritization input, not proof Dart is unsuitable by itself.

## Work not claimed completed

No Dart/Flutter project was compiled here; no production Host, SQL transaction, native signing, security assessment, Android device test, live migration or actual DB files have been reviewed. This plan intentionally separates **implemented validation tools** from **planned end-to-end tests**.

## P7 — English-first localization proof (V1.2 addition)

**Current structural checks:** Every manifest and DocType label has an English fallback and a stable localization key; a module English catalog provides each metadata key; command receipts can carry `reasonCode` and typed `messageParams`; the starter ships no alternative natural-language UI content.

**Later runtime proof:** Without a Translation Module, an installed Windows/Android build renders all generated forms, lists, validation errors and accessibility labels in English. A test-only pseudo-language pack can be installed and removed without recompiling the Flutter binaries or changing any business data. Missing/invalid pack entries return English. Exercise longer strings, placeholders, RTL layout, offline cache, dynamic updates, export and printing.

**Gate G9:** Translation must remain optional; normal operation and pending Offline commands never depend on a language pack or network translation service.

**Not implemented:** No runtime locale switch, additional natural-language content, Flutter test, or language-pack signing exists in this package.
