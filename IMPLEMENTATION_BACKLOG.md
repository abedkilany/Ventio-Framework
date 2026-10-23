# Implementation Backlog — V1.2

**Completed in the V1.2 architecture package:** Updated design, six draft schemas (including the new language-pack schema), Maintenance and English catalog fixtures, versioned ADR, and contract/English-only tests. **Production Dart Core code is not started.**

| Task | Deliverable | Dependency | Exit criteria |
|---|---|---|---|
| T01 | Dart workspace: `ventio_core`, `ventio_contracts`, `host_runtime`, `flutter_shell`, `maintenance_module` | Confirm V1.2 boundaries | `dart analyze`, enforced package boundaries |
| T02 | `ModuleRegistry`, `CapabilityRegistry`, `MetadataRegistry` | T01 | Reject duplicates, missing capabilities and incompatible versions |
| **T02L** | Built-in English catalog resolver interface, key registry, namespace checks and English fallback | T01–T02 | Missing translation module/key cannot break English rendering |
| T03 | Trusted operational record command handler and safe dynamic form/list metadata | T02, T02L | Maintenance module without Core edits; English UI labels resolved |
| T04 | `CommandEnvelope` + `CommandReceipt` + authenticated Host API | T01–T03 | Contract compatibility, structured reason codes and params |
| T05 | PostgreSQL Unit of Work, dedup, receipt persistence and outbox | T04 | Crash/retry/response-loss tests pass |
| T06 | Tenant/company/branch policy and role authorization | T04–T05 | Cross-tenant and forged-scope cases denied |
| T07 | Installed Flutter Windows and Android shells with English dynamic UI | T03–T04, T02L | English UI demo; no Translation Module needed |
| **T07L** | Optional Translation Module boundary and test-only pseudo-pack injection | T07 | Runtime switch/fallback/restart without recompilation or data mutation |
| T08 | SQLite pending command queue, recovery and provisional overlays | T04–T07 | Offline crash recovery; reuse same command ID |
| T09 | DocType migration and command upcasting proof | T02, T08 | Old pending command remains recoverable |
| T10 | Atomic Sales + Inventory + Accounting command | T05, T06 | No partial posting; 1,000 identical-command retries |
| T11 | Sync observability, workload profile and restore exercises | T05, T08, T10 | Published baseline and measured recovery objectives |
| T12 | Code-based audit and reuse/migration decision for current Ventio | After proof gates | Evidence-based migration plan; no assumptions |

**Stop points:** T03 extension expressiveness; T05/T10 transaction safety; T06 tenancy; T08/T09 offline integrity; T02L/T07L built-in English and optional translation separation. Never move core accounting functionality before these gates pass.

**Deferred intentionally:** Production Translation Module, additional language packs, AI Builder, Marketplace, and unrestricted executable extensions.
