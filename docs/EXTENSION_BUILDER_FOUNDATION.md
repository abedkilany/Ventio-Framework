# Extension Builder — Device-Local Foundation

## What is implemented

The Windows/Android Flutter client now opens on an Extension Builder workspace. It can create an extension draft; define operational DocTypes, typed fields, enum choices and relationships; generate stable namespaced permission keys; preview metadata-driven lists and forms; activate or disable a definition on the current device; and remove an extension only when it has no local records.

Active local DocTypes render generated list, search, filter, sort, detail, create and update screens. The form handles text, integer, decimal, boolean, date, date-time, enum and same-scope record references. Metadata, records and revisions persist in a separate SQLite database using WAL and `synchronous=FULL`. Local record updates use optimistic revision checks.

Schema updates reject field removal, type or relation changes, enum value removal, making existing optional fields required, and adding required fields without a migration. A compatible update advances the extension patch version and records' schema version in one local transaction. Existing business values are preserved.

An extension can declare permission keys only inside its own namespace. These keys are metadata; they do not create Host grants. Definition content is parsed as JSON metadata. The client loads no extension-supplied Dart, SQL, JavaScript or scripts.

## Authority and security boundary

`DRAFT`, `ACTIVE_LOCAL`, and `DISABLED_LOCAL` describe this device only. Local activation is not Host installation or approval. The extension database and generated records are not currently sent through the command queue and do not appear on another device. The existing Maintenance command queue remains a separate proof, and its fixture receipt cannot imply Host acceptance.

The current app has no authenticated identity provider or Host-issued scope. The sample UI uses a fixed local workspace scope. SQLite queries and relationship checks include organization, company and branch IDs, but a user with access to the local device/database can bypass them. They are not a security boundary. Host authorization, exact role grants, row-level isolation and audited changes must be enforced by the Host before shared data is used.

The current Host API remains bound to `127.0.0.1`. There is no LAN or Internet listener, TLS deployment profile, remote enrollment/pairing, Android keystore integration, Windows Host service package or proof that the Linux recovery-witness ownership model has a safe Windows equivalent. The Host must remain unexposed until these pieces are designed and reviewed.

## Current limits

- Device-local extension dependencies support minimum compatible semantic versions (patch-only for `0.x`, same-major for `1.x` onward), activation order, cycle rejection and safe disable/remove checks. Host-approved dependency resolution, shared version authority and cross-device distribution are not implemented.
- Local permission keys are not tied to users or roles. The extension cannot grant itself authority, but a Host-controlled role editor is still needed.
- Only the built-in local data renderer is available. No user-defined executable operation or workflow DSL is included.
- Local search loads at most 1,000 recent scoped records before applying the text query. This is a prototype limit, not a scale claim.
- The builder currently uses one fixed local workspace scope; it does not provide organization/company/branch sign-in or a scope selector.
- Compatible metadata upgrades are deliberately additive. Destructive data transformations need a future reviewed, resumable Host migration protocol and offline-command upcasting.
- Decimal fields in this generic local store are data fields; this does not implement exact-money rules or financial posting.
- No PostgreSQL test fixture, Android emulator, or physical Android device was available/used for this foundation slice. The Android debug build was attempted in an isolated copy, but the first Gradle build stopped making observable progress during dependency resolution/transforms; no APK was produced. Android SDK licenses were not accepted.

## Verification performed

- `flutter analyze`: passed on Flutter 3.44.1 / Dart 3.12.1.
- `flutter test --reporter expanded`: passed all 23 client tests, including close/reopen SQLite persistence, version-one database upgrade, two independent extensions using the same data engine, Builder dependency selection, dependency order/cycle/version checks, child-process queue recovery, permission-namespace rejection, organization/company/branch filtering, relationship scope, optimistic conflicts, non-destructive metadata upgrades, desktop builder-to-record flow, the full Builder setup flow at 360×800 and a generated record form at 360×800.
- Windows Debug executable: built successfully from an isolated temporary copy with the installed Windows toolchain. The executable remained alive for a five-second startup smoke check; no visual/manual interaction check was performed.
- Android Debug APK: attempted from the same isolated copy; no APK or device run was obtained before the initial Gradle run was stopped after output and artifact progress stalled.
- Core executable suite: 52 passed.
- Host API unit suite: 38 passed.
- PostgreSQL line-ending checksum test: passed without a database.
- Python schema/package checks and V1.2 contract tests: passed (20 unit tests).
- PostgreSQL command/recovery integration suites require an explicitly disposable PostgreSQL fixture and were not run here.

These results prove the local foundation and its tested behavior. They do not prove Windows/Android installation, Host sync, multi-device operation, remote security, or production readiness.
