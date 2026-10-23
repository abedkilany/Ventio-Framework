> Current feature-branch update (2026-10-23): Core Foundation v0.2.0 is closed.
> Core has 47 verified assertions; the prior durable-command CI run has 26.
> PostgreSQL persistence and durable operational-create processing are implemented.
> A separate loopback-only authenticated development HTTP package now wraps that
> engine. See HOST_API_V0_1.md and packages/ventio_host_api/README.md for its scope,
> tests and remaining production/security gates. The sections below are historical
> foundation-stage notes, not the current Host completion claim.

# Core Foundation v0.2.0 — Implementation Status

**Release stage:** candidate. v0.1.0 was tested successfully by the user on Dart 3.12.1 (37/37, clean analyzer, Maintenance demo). New v0.2.0 Dart changes have not been executed in the packaging environment; see the closure gate.

## Implemented in v0.2.0

- Preserved V1.2 wire schemas; updated Dart package version to 0.2.0.
- English-only metadata, labels, localized key contracts; no optional Translation Module implementation.
- `DeclarativeModuleInstaller` validates module metadata, trusted capabilities, DocType uniqueness, English catalog coverage and catalog integrity before changing registered state.
- Original Maintenance module retained, installed through the common installer.
- Independent Equipment Inspections fixture with its own DocType, catalog, command and Host-approved capability. Host can process both without changes to the Core runtime for the fixture.
- Added tests covering two-module processing, permission boundaries, offline capability restrictions, dependency success and safe install rejection.
- Maintained in-memory command idempotency, immutable state update, audit and outbox proof; no persistence and no real external code execution.
- GitHub Actions workflow includes Dart formatter check, analyzer, test harness and both demos; Python schema/English checks.

## Validation status

- Original v0.1 Dart validation: **user-confirmed 37 tests passing, analyzer clean**.
- New v0.2 Dart tests: **not executed yet** in this environment (Dart SDK unavailable).
- v0.2 Python V1.2 contract tests: run by packaging environment; see closure gate.
- Release approval: **pending** v0.2 Dart execution and passing CI.

## Architectural limits

- In-memory only: no PostgreSQL, SQLite, durable journal, ACID transaction, crash recovery, concurrency controls across processes or Host HTTP server.
- Declarative modules may register schemas and use vetted Host capabilities; they cannot upload independent executable business algorithms. Generic create rejects sensitive DocTypes and decimal fields.
- Module installation is synchronous preflight within one Dart isolate. It is not an atomic database migration or a production deployment and update system.
- Optional Offline Engine, real translation, dynamic Flutter UI, platform-scale multitenancy, ERP financial modules, AI Builder and Marketplace remain outside scope.

See `CORE_FOUNDATION_V0_2_RELEASE_GATE.md` for specific sign-off commands and future work.

