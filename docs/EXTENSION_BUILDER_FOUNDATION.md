# Extension Builder — Device-Local Foundation

## What is implemented

The Windows/Android Flutter client now opens on an Extension Builder workspace. It can create an extension draft; define operational DocTypes, typed fields, enum choices and relationships; generate stable namespaced permission keys; configure and reorder generated list columns and form fields; preview metadata-driven lists and forms; activate or disable a definition on the current device; and remove an extension only when it has no local records. Required fields stay visible in generated forms. Hidden optional values remain intact when an existing record is edited.

Active local DocTypes render generated list, search, filter, sort, detail, create and update screens. The form handles text, integer, decimal, boolean, date, date-time, enum and same-scope record references. Metadata, records and revisions persist in a separate SQLite database using WAL and `synchronous=FULL`. Local record updates use optimistic revision checks.

Persisted extension drafts can be exported as a bounded, declarative `ExtensionBundle` and atomically installed or upgraded in another local store. Bundles are limited to 1 MiB, 64 DocTypes and 100 fields per DocType; nested JSON has structural limits. The package contract rejects unknown metadata, executable commands/capabilities, scripts, SQL, UI code and out-of-namespace permissions or localization keys. A new install remains a draft until explicitly activated. Package version changes must be monotonic; schema updates preserve existing DocTypes and fields and allow only reviewed non-destructive changes supported by the local engine. Local export/import stays device-local unless the user explicitly sends or fetches the package through the authenticated Host flow.

Schema updates reject field removal, type or relation changes, enum value removal, making existing optional fields required, and adding required fields without a migration. A compatible update advances the extension patch version and records' schema version in one local transaction. Existing business values are preserved.

Each DocType can declare which of the built-in read, create and update operations it supports. The local engine rejects undeclared operations and the generated UI hides those actions. An extension can declare permission keys only inside its own namespace. These declarations do not create Host grants or authenticate a user; Host authorization remains a separate boundary. Definition content is parsed as JSON metadata. The client loads no extension-supplied Dart, SQL, JavaScript or scripts.

The persisted maintenance-command queue has an authenticated Host HTTP transport adapter. Credentials are kept behind a platform-secure-storage backend contract, remote origins require HTTPS, and cleartext is limited to exact loopback origins. Requests have bounded time and response size, use bearer auth, validate API and command IDs, refuse redirects, and use the platform TLS verifier. Only a response marked as coming from Host can resolve a queued command. `RETRY_LATER` receipts preserve the same command ID and remain eligible for idempotent retry; transport failures leave the command provisional. Extension definitions move through the separate approved-package routes; dynamic record commands are not implemented yet.

## Authority and security boundary

`DRAFT`, `ACTIVE_LOCAL`, and `DISABLED_LOCAL` describe this device only. Local activation is not Host installation or approval. The extension database and generated records are not currently sent through the command queue and do not appear on another device. The existing Maintenance command queue remains a separate proof, and its fixture receipt cannot imply Host acceptance.

The app can now store a Host-issued credential in Windows/Android secure storage, discover the authenticated tenant and exact company/branch grants, and save a selected package-transfer scope. Credential provisioning is still a manual operator step; the app does not yet enroll devices or rotate credentials. Local preview records still use the sample workspace scope. SQLite queries and relationship checks include organization, company and branch IDs, but a user with access to the local device/database can bypass them. They are not a security boundary. Host authorization, exact role grants, row-level isolation and audited changes must be enforced by the Host before shared records are used.

The Host API defaults to `127.0.0.1` and rejects external listeners unless they use TLS and a persistent authenticator. The `local_host.dart` launcher accepts explicit interface and certificate/key paths for that mode. Protected private-file and recovery-witness operations have Linux and ACL-backed Windows implementations. The Windows ACL integration test passed on the development machine, but the complete Windows Host/PostgreSQL service and remote-device path has not been end-to-end verified. Remote certificate provisioning/rotation, device enrollment/pairing, credential rotation, and production service lifecycle remain incomplete. Client transport tests use local test servers; they do not establish secure connectivity to a real multi-device Host. Do not treat a configured listener as a production deployment until those pieces are tested together.

## Current limits

- Device-local extension dependencies support minimum compatible semantic versions (patch-only for `0.x`, same-major for `1.x` onward), activation order, cycle rejection and safe disable/remove checks. Host approval enforces compatible approved dependencies and monotonic releases. Package transfer through the Builder is manually initiated; background discovery and automatic upgrades are not implemented.
- Local permission keys are not tied to users or roles. The extension cannot grant itself authority, but a Host-controlled role editor is still needed.
- Only the built-in local data renderer is available. No user-defined executable operation or workflow DSL is included.
- Local search, filtering and sorting run in SQLite before the result limit is applied, so older matching records are not hidden by the page size. Searches use escaped `LIKE` predicates over JSON fields; the engine does not yet build indexes for those paths, so large datasets still need query-plan and indexing work before making scale claims.
- The local record preview still uses one fixed sample workspace scope. A separate Host scope selector is available for package transfers, but dynamic Host records and branch-scoped user sign-in are not wired into the record engine yet.
- Compatible metadata upgrades are deliberately additive. Destructive data transformations need a future reviewed, resumable Host migration protocol and offline-command upcasting.
- The Host persists validated candidates, supports exact-scope package submission and approved reads, and provides recovery-witness-protected local approval/revocation. The Builder now connects to these routes: it can submit a review candidate and fetch an approved package, verify the Host digest, and install it as a local draft. Operator approval remains a separate trusted Host action.
- Dynamic records still do not use Host commands. Record create/update/read synchronization, Host-authoritative conflict resolution, and shared record migration are incomplete.
- The in-app Host connection flow stores credentials securely and selects an exact granted branch scope. Device enrollment/pairing, credential rotation, automated package updates, and background synchronization remain incomplete.
- Decimal fields in this generic local store are data fields; this does not implement exact-money rules or financial posting.
- The Host extension registry integration suite is configured in CI against disposable PostgreSQL 16. It has not been run against a local Host database; a physical Android device/emulator was not used.

## Verification performed

- `flutter analyze`: passed on the isolated native-client workspace.
- `flutter test --reporter compact`: passed all 49 client tests, including close/reopen SQLite persistence, profile migration, Host session and package transport validation, in-app exact-scope selection, declarative package export/install, atomic schema upgrades, offline command recovery, dynamic local DocType rendering, permission and relationship scope checks, SQL-backed search/filter/sort beyond the first 1,000 records, and 360×800 phone layouts.
- `dart format --output=none --set-exit-if-changed lib test`: passed with no formatting changes.
- PowerShell parser: passed for `scripts/prepare_native_client_platforms.ps1`. The shell script syntax check could not run because this Windows environment's WSL installation lacks `/bin/bash`; the generator change was not executed against a fresh scaffold in this check.
- Windows Debug executable: built successfully from an isolated temporary copy with the installed Windows toolchain. The executable remained alive for a five-second startup smoke check; no visual/manual interaction check was performed.
- Windows Host API: API unit tests passed (45). A PostgreSQL service and Host database URL were not available/configured, so the package registry integration suite and full Windows Host startup/remote service path were not exercised locally.
- Android Debug APK: built successfully from an isolated client copy. It has not been installed on an emulator or physical device.
- Core executable suite: 57 passed, including declarative bundle validation, metadata bounds and exact-scope authorization.
- Host API unit suite: 45 passed.
- PostgreSQL line-ending checksum test: passed without a database.
- Python schema/package checks and V1.2 contract tests: passed (20 unit tests).
- Existing PostgreSQL adapter integration tests ran in CI against a disposable PostgreSQL 16 fixture. The new package approval/scope/recovery integration suite is configured in CI but its run for this commit has not yet been confirmed. No local or existing Ventio database was used.

These results prove the local foundation and its tested behavior. They do not prove Android installation, dynamic-extension Host synchronization, multi-device operation, remote deployment security, or production readiness.
