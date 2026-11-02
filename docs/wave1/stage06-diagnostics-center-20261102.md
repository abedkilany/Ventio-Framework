# Stage 6 — Diagnostics Center Evidence

**Status:** IN PROGRESS — 0% accepted<br>
**Weight:** 10%<br>
**Accepted Wave 1 total:** 50%<br>
**Workspace source:** `codex/extension-platform` at `fb0a1a0`; source changes are committed

This record updates the locally executable Stage 6 evidence. The bounded Host Setup Diagnostics Hardening assignment is supporting work and does not itself close this stage.

## Verification completed

The latest isolated Windows PostgreSQL/Host diagnostics run `20261102175242706-1` passed **11/11 Host/process assertions** and **1/1 native Windows Flutter integration test**. The runner created PostgreSQL 16.15 under its run-specific local data directory, applied migrations and security roles, then stopped and removed that fixture.

The process test injected a bad password into the disposable runtime database URL. Host startup failed closed, initialized a previously absent protected diagnostics file, and persisted a Host startup event with a stable category, correlation ID and protected failure type. Two later independent Host process generations returned the same safe event. Both generations denied retrieval without the exact-scope diagnostics grant and denied a request for a branch outside the credential scope. The public event and HTTP responses omitted the protected exception type, test database credential and other private fields.

The native Flutter test used the real local Host HTTP API and a temporary device SQLite diagnostics store. It rendered the injected Host startup event and its correlation reference alongside a device-local setup event, then exercised the Diagnostics Center export action. The exported JSON contained both event sources and the Host correlation ID, while excluding protected failure fields, exception type, the injected test credential, local secret-shaped text and the local filesystem path. This proves the live UI/export path against a running Host process; it is not an installed SCM service test.

Additional checks:

- `flutter test test/host_diagnostics_test.dart test/local_diagnostics_test.dart` — **16/16 passed**.
- `dart run test/api_tests.dart` — **70/70 passed**, including bounded authorized diagnostic retrieval, exact-scope denial, stable errors and correlation.
- `dart run test/private_files_windows.dart` — passed with missing and ACL-inaccessible protected diagnostic files; the failure response did not expose the protected path or test value. The test's temporary ACL was restored before cleanup.
- `flutter analyze integration_test/host_diagnostics_ui_test.dart` and `dart analyze test/local_host_role_process_integration.dart test/private_files_windows.dart` — no issues.

## Stage gate still open

The following mandatory operational evidence is not available on this development workstation:

- Persistence under the installed `VentioHost` Windows service SID across an actual SCM service stop/start and Windows reboot.
- A real installed Host setup failure captured and exported by the pre-API Flutter setup-failure screen. The live integration used a real Host startup failure for the Host event, but seeded the device-side setup event into a disposable SQLite store; it did not induce a failure through the installed setup wizard.

At the read-only environment check, `VentioHost` and `VentioPostgres` were stopped with `Automatic` startup, and the current token was medium integrity with Administrators in deny-only state. Starting or reconfiguring the existing services would cross the user's explicit no-service-mutation boundary. No service or product database was touched. These gaps leave Stage 6 open at **0 accepted points**; no partial weight is assigned.

## Changes and preservation

The work added a native Windows Diagnostics Center integration test and extended the disposable Host process runner to launch it against an injected protected startup failure. The Windows protected-file integration now also checks that an inaccessible diagnostic file fails safely. No application code changed during this Stage 6 verification; the current consolidated branch subsequently rebuilt the Windows Release from the exact committed source used for the unified installer. The Stage 6 test and diagnostics source is included in the consolidated development commits. The pre-edit snapshot remains available outside the repository.
