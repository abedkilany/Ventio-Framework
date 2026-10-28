# ADR-013: Declarative Reports

- Status: Accepted for Wave 1 F01
- Date: 2026-10-28
- Scope: bounded reports over approved extension DocTypes

## Context

Wave 1 F01 requires ordinary extension creators to define and save reports with filters, sorting, grouping, and count/sum aggregations. The Host already provides permission-aware bounded record queries, but a report must also compute authoritative aggregates without disclosing fields or escaping exact scope. The K06 and B04 design fixes business effects and document transitions in the Core-owned transactional Host path; reports remain read-only queries and do not execute extension code or business operations.

## Decision

1. A report is data in the extension bundle, alongside its DocTypes. The local Extension Studio persists drafts and exports them with the same package that ordinary creators submit for Host review. Approved package version and digest govern report availability.
2. A report declares a stable ID, English label and catalog key, one source DocType, up to ten permitted equality-filter fields, an optional single scalar grouping field, one sort target and direction, and one or more count/sum outputs. Sum sources must be integer or decimal fields. No SQL, expression language, custom handler, or executable template is accepted.
3. The report request names the approved module and version, a source DocType selector, report ID, exact company/branch scope, and scalar values for declared filters. The Host resolves the approved bundle and verifies that the selector matches the report's declared DocType; callers cannot choose source tables, fields, grouping, aggregations, sort expressions, or limits.
4. The PostgreSQL Host resolves the approved package and persistent identity inside an authenticated transaction. It enforces DocType read permission and read permission for every report output, filter, grouping, sort, and sum-source field. Every query is constrained by the principal's tenant and the requested authorized company/branch.
5. The Host reads one exact-scope, bounded candidate set from PostgreSQL and computes sums with the shared `ExactDecimal` integer-scaled arithmetic; no binary floating-point addition is used. The execution limit is 10,000 matching records and 100 result groups. Exceeding either limit returns a stable bounded-query rejection; it never returns a partial aggregate as if complete. The selected fields are capped at 512 KiB before transfer to the Host process.
6. Sorting is deterministic and limited to the declared grouping key or aggregate output, with stable tie ordering. Count and sum results are returned as exact integers/decimal strings; the client formats them for display without changing stored business values.
7. Bundle and report metadata have fixed structural limits and reject unknown keys, duplicate IDs, unknown fields, non-scalar filters/grouping, nonnumeric sum sources, and incompatible DocTypes. Field visibility is determined by Host grants at query time, not the saved report author's identity.

## Consequences

- Report definitions are portable, reviewable package data and are covered by the existing package digest/approval workflow.
- A creator can build a report with the ordinary local authoring tools; readers need no privileged extension exception.
- Host authorization and resource limits remain authoritative even if a client modifies the request.
- Report queries require Host connectivity. SQLite remains the offline record workspace and command queue; this F01 criterion does not claim offline aggregate reports.
- Initial scope intentionally uses one grouping field and equality filters. More expressive report semantics require a later contract version.

## Acceptance mapping

- Builder/store/bundle round-trip proves an ordinary creator can define and save a report.
- Core validates report IDs, fields, operations, bounds, and labels.
- PostgreSQL integration proves authorized results, exact-scope filtering, field-permission rejection, equality filters, sorting, grouping, exact count/sum, and both row and group limit rejection. Projected results are capped at 512 KiB.
- Localization gate covers all first-party report-builder and result messages.
