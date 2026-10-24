# Ventio Framework

Standalone, English-first extension platform prototype, separate from the original Ventio application. It builds a framework for future extensions; it is not a ready-made ERP. Host is the final authority; offline client changes remain provisional until accepted by Host.

The stable Core Foundation tag is `v0.2.0`. Host Engine v0.1 was accepted on `feature/host-engine-v0.1`. Extension Builder development is isolated on `codex/extension-platform`, based on `feature/native-flutter-offline-proof` at `b60530a`. Neither `main`, `v0.2.0`, nor the original Ventio application is modified by this work.

## Current release gate

Host Engine v0.1 passed its bounded development engineering gate. The separate Flutter client now provides a declarative Extension Builder for packages, DocTypes, fields, relationships, generated list/form layouts, permission keys and allowed generic operations. It persists metadata and dynamic records in SQLite, previews and installs package files, manages local activation, submits a package for Host review, and browses the exact-scope Host-approved registry before installing a verified release.

Dynamic records now have a Host-authoritative path: authenticated clients can query an approved package's records at the selected exact tenant/company/branch scope, enqueue generic create/update commands while offline, and reconcile only Host command receipts. Local edits remain provisional until Host accepts them. The app checks that its installed declarative package digest matches the Host-approved release before displaying shared records.

This is a development platform foundation, not a production multi-device deployment. The Windows Release executable and Android Release APK build locally. The Host database integration was exercised on Windows using a disposable PostgreSQL container; no persistent Host database is configured. A physical Android install and a separate LAN-device end-to-end run have not been demonstrated. See [implementation status](docs/IMPLEMENTATION_STATUS.md) for test evidence and remaining gates.

- [Final engineering audit](docs/HOST_ENGINE_V0_1_FINAL_ENGINEERING_AUDIT.md): acceptance criteria, findings, evidence and limitations.
- [Operations and recovery](docs/HOST_ENGINE_V0_1_OPERATIONS.md): separate OS/database identities, schema compatibility, witness upgrade, startup, shutdown and restore.
- [Current implementation status](docs/IMPLEMENTATION_STATUS.md).
- [Native Flutter and Offline-first proof plan](docs/NATIVE_FLUTTER_OFFLINE_FIRST_PROOF_PLAN.md).
- [Native Flutter Phase 1 implementation notes](docs/NATIVE_FLUTTER_OFFLINE_FIRST_PHASE_1.md).
- [Extension Builder device-local foundation and remaining security gates](docs/EXTENSION_BUILDER_FOUNDATION.md).

## Packages and ownership

| Package | Responsibility |
| --- | --- |
| `ventio_core` | Pure Dart contracts, immutable envelopes/receipts, metadata, English fallback, module preflight and trusted capability validation; in-memory reference Host |
| `ventio_postgres` | Vetted transactional migrations and scoped record adapter; no independent authentication system |
| `ventio_host` | Durable command transaction, idempotency receipt, record, audit and outbox |
| `ventio_host_api` | Loopback HTTP, persistent credential authorization, recovery admission and trusted local administration |
| `ventio_native_client` | Separate Windows/Android Flutter client with a responsive Extension Builder, persistent extension/DocType/record storage, metadata-driven screens, exact-scope Host reads, and offline generic record commands |

PostgreSQL forced RLS and narrowly scoped database functions reinforce Host authorization. RLS does not validate the entire business payload or replace command handling. Generic operational create cannot post financial/inventory effects or execute uploaded code. The external recovery witness is independently writable by a trusted OS account; matching rollback of both witness and database remains a documented production blocker.

## Verification

CI pins Dart 3.13.7 and PostgreSQL 16. From each Dart package, resolve dependencies, check formatting and analyze; test harnesses are executable Dart programs, not `dart test` suites. Database tests require explicitly guarded disposable fixtures. Never point them at original Ventio or customer databases.

```sh
cd packages/ventio_core
dart pub get
dart format --output=none --set-exit-if-changed lib bin test
dart analyze .
dart run test/all_tests.dart
dart run bin/maintenance_demo.dart
dart run bin/two_module_demo.dart
```

Migration checksum line-ending regression test:

```sh
cd packages/ventio_postgres
dart analyze .
dart run test/migration_checksum_test.dart
```

From repository root:

```sh
python scripts/verify_package.py
python scripts/check_schema_profile.py
python spec/v1.2/scripts/validate_contracts.py
python -m unittest discover -s spec/v1.2/tests -v
```

The eight Actions workflows cover Core/contracts, PostgreSQL persistence, durable commands, API/identity/SQL security, crash/restore, credential lifecycle, the final engineering audit, and native Flutter client tests plus Windows/Android builds. The final engineering gate records actual fingerprint growth, concurrent HTTP latency, RLS read cost and OS witness separation in an isolated PostgreSQL fixture. Reported sample latency is not an enterprise performance guarantee.

All code, documentation, fixtures and base UI text are English. Optional translation modules, production sync and financial modules, AI Builder and Marketplace are future work.

## Native client

The app is in `packages/ventio_native_client`. On a fresh checkout without `android/` or `windows/` folders, generate standard runner scaffolding with the matching `scripts/prepare_native_client_platforms` script; it refuses to overwrite existing platform folders. Run `flutter pub get`, `flutter analyze` and `flutter test` before building. The client workflow builds Windows and Android targets. Host sync uses the authenticated command transport and keeps retryable/failed commands provisional; fixtures in tests do not represent Host acceptance.
