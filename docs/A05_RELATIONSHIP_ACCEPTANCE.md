# A05 Record Reference and Relationship Acceptance Evidence

Date: 2026-10-27

## Declarative contract

- A reference field declares `referenceTo` as a stable DocType ID.
- An extension bundle must include every referenced DocType in the same module package; a bundle targeting a DocType outside the package is rejected by Core.
- Host reference resolution is exact to tenant, company, branch, module, DocType, and record ID.
- Missing or out-of-scope references are rejected before the new business record is persisted.
- Reference deletion policy is **RESTRICT**, with no cascading deletion. No record-delete operation is exposed before B01; the B01 Host delete operation must refuse deletion while an inbound reference exists.

## Verification

- Core executable harness: **69 passed, 0 failed**. It covers missing and cross-branch, cross-company, and cross-tenant reference rejection; the source records/effects remain unchanged. It also checks bundle rejection for references outside the declarative module.
- Native SQLite store: the focused `Relationships cannot cross organization, company or branch scope` test passed (1/1), covering local target existence and scope isolation.
- Durable PostgreSQL Host: `dart run test/durable_integration.dart` against an isolated PostgreSQL 17.11 `ventio_host_test` database: **43 passed, 0 failed**. It accepts a same-module/same-scope reference and rejects missing targets and targets from another branch, company, or tenant without persisting the source record.
- PostgreSQL record lookup predicates include tenant, company, branch, module, DocType, and record ID. Bundle validation prevents declarations that target another module.
- The temporary PostgreSQL server was stopped after the run.
