# Ventio Framework

Standalone, English-first modular ERP framework prototype, separate from the original Ventio application. Host is the final authority; future offline client changes remain provisional until accepted by Host.

The stable Core Foundation tag is `v0.2.0`. Host Engine v0.1 was accepted on `feature/host-engine-v0.1`. Native client foundation work is isolated on `feature/native-flutter-offline-proof`, based on the accepted Host commit. Neither `main`, `v0.2.0`, nor the original Ventio application is modified by this work.

## Current release gate

Host Engine v0.1 passed its bounded development engineering gate. The Native Flutter Client Phase 1 adds a local SQLite command queue and a fixture-only transport; it does not connect to Host. **Production readiness remains blocked.** The Host API is hard-coded to `127.0.0.1`. No network exposure or production deployment is authorized by passing prototype tests.

- [Final engineering audit](docs/HOST_ENGINE_V0_1_FINAL_ENGINEERING_AUDIT.md): acceptance criteria, findings, evidence and limitations.
- [Operations and recovery](docs/HOST_ENGINE_V0_1_OPERATIONS.md): separate OS/database identities, schema compatibility, witness upgrade, startup, shutdown and restore.
- [Current implementation status](docs/IMPLEMENTATION_STATUS.md).
- [Native Flutter and Offline-first proof plan](docs/NATIVE_FLUTTER_OFFLINE_FIRST_PROOF_PLAN.md).
- [Native Flutter Phase 1 implementation notes](docs/NATIVE_FLUTTER_OFFLINE_FIRST_PHASE_1.md).

## Packages and ownership

| Package | Responsibility |
| --- | --- |
| `ventio_core` | Pure Dart contracts, immutable envelopes/receipts, metadata, English fallback, module preflight and trusted capability validation; in-memory reference Host |
| `ventio_postgres` | Vetted transactional migrations and scoped record adapter; no independent authentication system |
| `ventio_host` | Durable command transaction, idempotency receipt, record, audit and outbox |
| `ventio_host_api` | Loopback HTTP, persistent credential authorization, recovery admission and trusted local administration |
| `ventio_native_client` | Separate Windows/Android Flutter client proof, immutable Core command contracts and durable SQLite provisional queue |

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

From repository root:

```sh
python scripts/verify_package.py
python scripts/check_schema_profile.py
python spec/v1.2/scripts/validate_contracts.py
python -m unittest discover -s spec/v1.2/tests -v
```

The seven Actions workflows cover Core/contracts, PostgreSQL persistence, durable commands, API/identity/SQL security, crash/restore, credential lifecycle and the final engineering audit. The latter records actual fingerprint growth, concurrent HTTP latency, RLS read cost and real OS witness separation in an isolated PostgreSQL fixture. Reported sample latency is not an enterprise performance guarantee.

All code, documentation, fixtures and base UI text are English. Optional translation modules, production sync and financial modules, AI Builder and Marketplace are future work.

## Native client proof

The app is in `packages/ventio_native_client`. Generate its standard native runner files with `scripts/prepare_native_client_platforms.ps1` on Windows or `scripts/prepare_native_client_platforms.sh` on Linux, then run `flutter pub get`, `flutter analyze` and `flutter test` in the app directory. The Native Flutter Client workflow builds a Windows desktop app and an Android debug APK. The fixture response is visibly simulated and cannot change a command from Pending to Host-accepted.
