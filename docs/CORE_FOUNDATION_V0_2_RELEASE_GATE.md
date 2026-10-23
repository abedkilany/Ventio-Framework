# Core Foundation v0.2.0 — Closure Gate

## Confirmed baseline evidence

The user ran the preceding v0.1.0 on Windows using Dart 3.12.1 on October 23, 2026:

- `dart pub get` — successful.
- `dart analyze` — no issues.
- `dart run test/all_tests.dart` — 37 passed, 0 failed.
- `dart run bin/maintenance_demo.dart` — one accepted Maintenance record, one audit entry and one outbox event; retry replayed original receipt.

**This is v0.1.0 evidence; it is not a v0.2.0 test result.**

## v0.2.0 changes to verify

1. A second, independent `com.ventio.inspection` module has its own manifest, DocType, permissions, capability and English catalog.
2. Installing it after Maintenance requires no change to the Core runtime or to the existing Maintenance module.
3. The generic Host processes both business commands independently and replays accepted retries without duplicate in-memory effects.
4. Failed installs (missing English labels, duplicate DocType, invalid catalog, missing capability, invalid offline declaration) must leave module, DocType and English registries untouched.
5. The installer still requires a Host-approved, `trusted_builtin` capability; arbitrary Business Logic uploaded by an add-on is **not** supported or claimed.
6. V1.2 schema fixtures remain unchanged. The new Inspection fixtures conform to the V1.2 JSON Schemas.
7. The built-in UI messages and all developer artifacts stay English-only. Localization keys remain required.

## Verify locally before closing

From `packages/ventio_core/`:

```sh
dart pub get
dart format lib bin test
dart format --output=none --set-exit-if-changed lib bin test
dart analyze .
dart run test/all_tests.dart
dart run bin/maintenance_demo.dart
dart run bin/two_module_demo.dart
```

From the ZIP root:

```sh
python scripts/verify_package.py
python spec/v1.2/scripts/validate_contracts.py
python -m unittest discover -s spec/v1.2/tests -v
```

Check the GitHub Actions `core-foundation.yml` workflow on the committed package. CI status **is not automatically verified** by these local tests.

## Acceptance checklist

- [ ] Dart format validation passes after formatting the source.
- [ ] Dart analyzer reports 0 issues.
- [ ] All Dart runtime tests report 0 failures.
- [ ] Both demos complete, and the two-module demo prints `Records: 2`.
- [ ] Python contract and English-policy checks pass.
- [ ] GitHub Actions pipeline passes on a repository checkout.
- [ ] Release limitations acknowledged; no Critical/High defects within the in-memory Core Foundation slice.

If these pass, close **Core Foundation (in-memory proof only)** and proceed to separate Host/Persistence phase. Avoid calling the system production-ready.

## V1.2 compatibility and version policy

| Contract/area | v0.2 status | Upgrade policy |
| --- | --- | --- |
| `ModuleManifest` manifestVersion=0 | Unchanged | Unknown versions rejected until deliberate migration support |
| `CommandEnvelope` protocolVersion=0 | Unchanged | Unknown versions rejected; do not silently reinterpret commands |
| `CommandReceipt` protocolVersion=0 | Unchanged | Preserve stable statuses and reason keys |
| DocType schemaVersion=1 fixtures | Unchanged | Exact version currently required; pending older commands require a future upcaster or explicit rejection |
| Module version `0.1.0` fixtures | Unchanged | Exact version currently required for commands, no automatic in-place upgrade |
| Dart package version `0.2.0` | Updated | Package version is separate from wire protocol and platform API version |
| English locale | Required baseline | Missing translation must fall back to English; additional locales optional |
| Dynamic code execution | Not available | Secure DSL/sandbox/trusted module decision remains a separate design gate |

**Known limits:** `DeclarativeModuleInstaller` offers synchronous in-isolate prevalidation only. There is no crash-safe install, multi-isolate transaction, rollback after process failure, signed package loading, versioned migration, revocation, or persistent registry. Trusted capabilities must be built and deployed by the platform; this demo does not prove arbitrary ERP business logic can be introduced by external creators.

## Next phase, explicitly out of scope

Host Engine with PostgreSQL ACID transaction covering record, idempotency journal, audit and outbox; unique constraints and concurrency tests; authenticated Host API; crash recovery and actual offline/online synchronization.
