# F01 Declarative Report Builder Acceptance

Date: 2026-10-28

Status: **ACCEPTED** on `codex/extension-platform`.

## Acceptance criterion

An ordinary extension creator can define and save a bounded report over an extension DocType using declared scalar equality filters, one optional grouping field, deterministic sorting, and count/sum outputs. The Host uses approved package metadata and enforces exact identity scope, current DocType and field read permissions, and bounded execution without returning partial results.

## Implementation

- Core `ReportDefinition` and `ReportAggregateDefinition` validate stable IDs, namespaced English labels, report source, scalar filter/group fields, sort targets, numeric sum fields, unique outputs, and structural limits.
- Extension bundles carry report declarations as ordinary declarative package data. The local SQLite Extension Store persists drafts, applies version immutability checks, and exports the report and its labels with the package.
- Extension Studio provides an ordinary report builder and displays saved reports. The Host package client has a bounded report query API and parses exact count/sum strings.
- The PostgreSQL Host resolves the authenticated identity and approved package in a transaction, rechecks exact scope and current field permissions, and only reads declared report metadata. Equality values are parameters; callers cannot select query structure.
- Candidate reads are limited to 10,000 records and 512 KiB of projected fields. Results are limited to 100 groups. The Host rejects exceeded limits instead of returning partial totals. Sum accumulation uses shared fixed-point `ExactDecimal`/`BigInt` arithmetic.
- Contract choices are recorded in [ADR-013](ADR-013_DECLARATIVE_REPORTS.md).

## Evidence

- **Core contract harness: 76/76 passed**, including valid bundle round-trip and rejection of invalid report filters, labels, and sum fields.
- **Native SQLite persistence/export: 1/1 passed** for restart persistence, report version advancement, package round-trip, and English catalog labels.
- **Extension Studio: 1/1 passed** for ordinary report creation, local save, and exported package metadata.
- **Host package client: 1/1 passed** for fixed report selectors, scalar filters, and exact string aggregate parsing.
- **PostgreSQL 17.11 Host integration: 137/137 passed** against the disposable loopback-only `ventio_host_test` database with `VENTIO_ALLOW_DATABASE_TESTS=yes`. Added runtime scenarios prove exact count/sum and grouping, deterministic aggregate sorting, declared equality filtering, field-permission denial, out-of-scope denial, rejection above 100 groups, and rejection above 10,000 candidate records. The same run retained the existing A10/K06/B04 authorization, numbering, rollback, concurrency, Amend, and idempotency cases.
- `dart analyze` on the changed Host implementation and integration test reported no issues. The localization gate passed.
- The PostgreSQL cluster was the temporary Windows PostgreSQL 17.11 setup on loopback. Tests used only the disposable database; no production database was contacted.

## Acceptance

F01 meets its fixed Wave 1 criterion and is accepted as **Newly Implemented**. Reports are package data available through the same review and authorization path as other extension metadata; no extension-specific Host exception was introduced.
