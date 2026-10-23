# ventio_core 0.2.0 (release candidate)

Pure Dart, English-first Host-authoritative Core prototype.

Run from this package's directory:

```sh
dart pub get
dart format lib bin test
dart analyze .
dart run test/all_tests.dart
dart run bin/maintenance_demo.dart
dart run bin/two_module_demo.dart
```

This prototype uses an executable standalone test runner rather than `package:test`.

The `DeclarativeModuleInstaller` performs in-memory preflight checks across module, DocType and English catalog registries. The second module in `../../fixtures/inspection/` demonstrates approved declarative extensibility but **not** arbitrary external business-code execution. No database, actual Host API, runtime translations or offline operations are implemented.
