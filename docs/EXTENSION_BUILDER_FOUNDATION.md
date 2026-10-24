# Extension Builder — Device-Local Foundation

## What is implemented

The Windows/Android Flutter client now opens on an Extension Builder workspace. It can create an extension draft; define operational DocTypes, typed fields, enum choices and relationships; generate stable namespaced permission keys; configure and reorder generated list columns and form fields; preview metadata-driven lists and forms; activate or disable a definition on the current device; and remove an extension only when it has no local records. Required fields stay visible in generated forms. Hidden optional values remain intact when an existing record is edited.

Active local DocTypes render generated list, search, filter, sort, detail, create and update screens. The form handles text, integer, decimal, boolean, date, date-time, enum and same-scope record references. Metadata, records and revisions persist in a separate SQLite database using WAL and `synchronous=FULL`. Local record updates use optimistic revision checks.

Schema updates reject field removal, type or relation changes, enum value removal, making existing optional fields required, and adding required fields without a migration. A compatible update advances the extension patch version and records' schema version in one local transaction. Existing business values are preserved.

Each DocType can declare which of the built-in read, create and update operations it supports. The local engine rejects undeclared operations and the generated UI hides those actions. An extension can declare permission keys only inside its own namespace. These declarations do not create Host grants or authenticate a user; Host authorization remains a separate boundary. Definition content is parsed as JSON metadata. The client loads no extension-supplied Dart, SQL, JavaScript or scripts.

The persisted maintenance-command queue now has an authenticated Host HTTP transport adapter. Credentials are kept behind a platform-secure-storage backend contract, remote origins require HTTPS, and cleartext is limited to exact loopback origins. Requests have bounded time and response size, use bearer auth, validate API and command IDs, refuse redirects, and use the platform TLS verifier. Only a response marked as coming from Host can resolve a queued command. `RETRY_LATER` receipts preserve the same command ID and remain eligible for idempotent retry; transport failures leave the command provisional. These are transport and queue foundations only: the current Extension Builder definitions and dynamic records are not yet converted into Host commands.

## Authority and security boundary

`DRAFT`, `ACTIVE_LOCAL`, and `DISABLED_LOCAL` describe this device only. Local activation is not Host installation or approval. The extension database and generated records are not currently sent through the command queue and do not appear on another device. The existing Maintenance command queue remains a separate proof, and its fixture receipt cannot imply Host acceptance.

The current app has no authenticated identity provider or Host-issued scope. The sample UI uses a fixed local workspace scope. SQLite queries and relationship checks include organization, company and branch IDs, but a user with access to the local device/database can bypass them. They are not a security boundary. Host authorization, exact role grants, row-level isolation and audited changes must be enforced by the Host before shared data is used.

The Host API defaults to `127.0.0.1` and rejects external listeners unless they use TLS and a persistent authenticator. The `local_host.dart` launcher accepts explicit interface and certificate/key paths for that mode. Its private-file and recovery-witness implementation is still Linux-only, so this does not yet provide a supported Windows Host service. Remote certificate provisioning/rotation, device enrollment and pairing, an in-app Host settings flow, and Windows recovery-witness security remain incomplete. Client transport tests use local test servers; they do not establish secure connectivity to a real multi-device Host. Do not treat a configured listener as a production deployment until those pieces are tested together.

## Current limits

- Device-local extension dependencies support minimum compatible semantic versions (patch-only for `0.x`, same-major for `1.x` onward), activation order, cycle rejection and safe disable/remove checks. Host-approved dependency resolution, shared version authority and cross-device distribution are not implemented.
- Local permission keys are not tied to users or roles. The extension cannot grant itself authority, but a Host-controlled role editor is still needed.
- Only the built-in local data renderer is available. No user-defined executable operation or workflow DSL is included.
- Local search loads at most 1,000 recent scoped records before applying the text query. This is a prototype limit, not a scale claim.
- The builder currently uses one fixed local workspace scope; it does not provide organization/company/branch sign-in or a scope selector.
- Compatible metadata upgrades are deliberately additive. Destructive data transformations need a future reviewed, resumable Host migration protocol and offline-command upcasting.
- The generic Host HTTP adapter currently transports the existing maintenance-command contract. It does not publish, approve, install or synchronize extension packages, schemas, dynamic records or extension versions.
- The credential vault and transport are library plumbing; there is not yet an in-app Host enrollment/settings flow or automatic background synchronization policy.
- Decimal fields in this generic local store are data fields; this does not implement exact-money rules or financial posting.
- No local PostgreSQL test fixture, Android emulator, or physical Android device was used for this foundation slice. The PostgreSQL adapter migration and persistence integration suite passed in GitHub Actions against its disposable PostgreSQL 16 service. Android SDK licenses were not accepted locally.

## Verification performed

- `flutter analyze`: passed on Flutter 3.44.1 / Dart 3.12.1.
- `flutter test --reporter compact`: passed all 37 client tests, including close/reopen SQLite persistence, version-one database upgrade, two independent extensions using the same data engine, Builder dependency selection, dependency order/cycle/version checks, child-process queue recovery, Host receipt and retry reconciliation, secure credential endpoint validation, bounded Host transport behavior and redirect refusal, permission-namespace rejection, declared-operation enforcement, organization/company/branch filtering, relationship scope, optimistic conflicts, non-destructive metadata upgrades, configurable list and form layout persistence, hidden optional value preservation, desktop builder-to-record flow, and phone-sized Builder and record-form flows at 360×800.
- `flutter analyze`: passed on Flutter 3.44.1 / Dart 3.12.1 with the transport changes.
- `dart format --output=none --set-exit-if-changed lib test`: passed with no formatting changes.
- PowerShell parser: passed for `scripts/prepare_native_client_platforms.ps1`. The shell script syntax check could not run because this Windows environment's WSL installation lacks `/bin/bash`; the generator change was not executed against a fresh scaffold in this check.
- Windows Debug executable: built successfully from an isolated temporary copy with the installed Windows toolchain. The executable remained alive for a five-second startup smoke check; no visual/manual interaction check was performed.
- Android Debug APK: CI builds the Android debug APK; no APK was installed on a physical device or emulator during this work.
- Core executable suite: 54 passed, including ordered layout validation, required-field visibility and operation declaration validation.
- Host API unit suite: 38 passed.
- PostgreSQL line-ending checksum test: passed without a database.
- Python schema/package checks and V1.2 contract tests: passed (20 unit tests).
- PostgreSQL adapter integration tests ran in CI against a disposable PostgreSQL 16 fixture. No local or existing Ventio database was used.

These results prove the local foundation and its tested behavior. They do not prove Windows/Android installation, Host sync, multi-device operation, remote security, or production readiness.
