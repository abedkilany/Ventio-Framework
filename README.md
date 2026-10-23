# Ventio Framework — Core Foundation v0.2.0 Release Candidate

**Status:** Implementation and static checks prepared. The preceding v0.1.0 was run on Windows with Dart SDK 3.12.1: `dart analyze` reported no issues; its 37 Dart tests and Maintenance demo passed. **The additional v0.2.0 Dart tests and new demo have not yet been executed on Dart SDK in this environment.** Do not mark the foundation closed before those commands and CI pass.

This source-only, standalone, English-first Dart proof is separate from the existing Ventio application. It implements a controlled declarative module registry, a minimal DocType validator, Host-supplied permissions and in-memory command processing. A second, independent **Equipment Inspections** module demonstrates installing another business module without changing `ventio_core` runtime code for its specific schema.

## Layout

- `packages/ventio_core/` — Pure Dart package. `DeclarativeModuleInstaller` validates module metadata, English labels and DocType collisions before mutating the registries.
- `packages/ventio_core/test/all_tests.dart` — No-dependency executable test harness (the original 37 plus v0.2 tests).
- `packages/ventio_core/bin/maintenance_demo.dart` — Original Maintenance proof.
- `packages/ventio_core/bin/two_module_demo.dart` — Maintenance + Equipment Inspections proof.
- `fixtures/inspection/` — Independent module JSON manifest, DocType, English catalog, Host-approved capability declaration and sample command.
- `spec/v1.2/` — Retained architecture contract baseline and 20 Python tests.
- `docs/CORE_FOUNDATION_V0_2_RELEASE_GATE.md` — Acceptance criteria, compatibility review and limitations.
- `.github/workflows/core-foundation.yml` — CI steps (Dart format, analysis, tests and examples; Python checks).

## Run the Dart checks on Windows

In PowerShell, enter the extracted folder's Dart package directory (the directory containing `pubspec.yaml`):

```powershell
cd .\packages\ventio_core
dart pub get
dart format lib bin test
dart analyze .
dart run test/all_tests.dart
dart run bin/maintenance_demo.dart
dart run bin/two_module_demo.dart
```

`dart format` will update code style but should not alter behavior. Once formatted, run `dart format --output=none --set-exit-if-changed lib bin test` to verify the CI formatting rule. Tests use a custom executable runner; `dart test` is **not** supported because `package:test` is intentionally not a dependency.

## Optional static and contract checks

From the extracted root:

```sh
python scripts/verify_package.py
python spec/v1.2/scripts/validate_contracts.py
python -m unittest discover -s spec/v1.2/tests -v
```

Python checks require `jsonschema` (`pip install jsonschema`). They cannot substitute for a Dart compiler or runtime.

## Design and security rules

- English text is embedded as the default. Localization keys support a future optional translation extension; no other locale is installed.
- Module manifest files cannot supply executable Dart code or grant themselves Host capabilities.
- Capabilities are preapproved by trusted Host bootstrap; this proof's generic create capability **cannot** post ledger or inventory transactions, execute custom algorithms or handle sensitive DocTypes.
- The Host accepts an authenticated `Principal`; it does not trust tenant, branch, actor, device or permission claims from the command payload.
- In-memory idempotency, audit and outbox **disappear on process restart**; this is not PostgreSQL transactional behavior or fault-tolerant exactly-once effects.
- Offline declarations express design intent only. There is no local queue, offline synchronization, runtime plugin loading, data migration or production Host service.

No original Ventio code or customer data was modified.
