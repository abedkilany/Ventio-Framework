# Implementation status

Current work is on `codex/extension-platform`. It keeps the original Ventio app, `main`, and tag `v0.2.0` unchanged. The product goal is a framework for building future extensions inside Ventio, not a prebuilt sales, accounting, inventory, purchasing, or manufacturing ERP.

## Implemented

| Area | Current capability | Boundary |
| --- | --- | --- |
| Extension Builder | Creates and edits declarative extension packages, dependencies, DocTypes, typed fields, references, validation, list columns, form order, operation declarations, and namespaced permission keys. Supports preview, export/import, package review submission, Host-approved package installation, local activation, disable, and safe removal checks. | Definitions contain metadata only. They cannot execute uploaded Dart, SQL, scripts, or arbitrary UI code. Permission declarations do not grant Host authority. |
| Dynamic data and UI | SQLite persists extension metadata and records. Generated Flutter screens provide list, detail, create, edit, search, filter, sort, field validation, and reference selection without a page per DocType. Additive supported schema changes are guarded; record updates use local optimistic revisions. | Local SQLite is a cache/workspace, not a security boundary. Destructive migrations, tombstones, broad query indexing, and production-scale query tuning remain open. |
| Host records | The Host stores generic extension records in PostgreSQL. Authenticated clients can query bounded pages from an approved package and submit generic create/update commands. The client verifies the installed package digest against the Host-approved release before importing shared records. | Host package and record database paths have PostgreSQL integration coverage in CI, but there is no PostgreSQL service configured on this development machine. |
| Scope and permissions | Host authorization checks current user/device credentials, grants, exact tenant/company/branch scope, package approval, declared operation, and expected revision. PostgreSQL RLS adds a separate database enforcement layer. The client obtains scope from an authenticated Host session instead of trusting a record form's scope. | Device enrollment, role/grant administration UI, and a full organization hierarchy administration experience are not included. A local cache can be altered by someone with access to the device. |
| Offline queue | Dynamic create/update commands are durably queued with stable command IDs, retried through the authenticated Host transport, and reconciled from Host receipts. Accepted, retryable, rejected, and revision-conflict outcomes remain distinguishable. Startup repairs the gap between SQLite record persistence and queue insertion after a process interruption. | No live multi-device network deployment or physical-device offline/reconnect trial has been performed. Local test fixtures are not Host evidence. |
| Host lifecycle/security | The Host API defaults to loopback. Non-loopback listeners require TLS, persistent authentication, and authoritative command/package/query components. Protected credential and recovery-authority file operations have Linux and Windows-specific implementations. SQL, metadata, and package validation reject arbitrary executable behavior. | A Windows Host plus PostgreSQL serving remote Windows/Android clients has not been end-to-end verified. External certificate provisioning, service installation/rotation, and production operations still need deployment evidence. |
| Platform builds | Flutter package has Windows and Android runner scaffolding. Release builds target both platforms. Core and Host remain separate Dart packages with database/filesystem abstractions rather than Flutter or OS-specific dependencies in Core. | Android has not been installed on a physical device or emulator. A successful build does not establish device behavior or production key-storage evidence. |

## Verification evidence

Local checks on the current worktree:

- `flutter analyze` in `packages/ventio_native_client`: passed with no issues.
- `flutter test` in `packages/ventio_native_client`: all 55 tests passed, including persistent SQLite reopen, package digest round-trip, branch-scoped Host query/import, update command revision, offline queueing, interrupted-save recovery, and phone-sized layouts.
- `dart analyze .` and `dart run test/api_tests.dart` in `packages/ventio_host_api`: passed; the API suite reports 45 assertions.
- Windows Release build: `build/windows/x64/runner/Release/ventio_native_client.exe` produced successfully.
- Android Release build: `build/app/outputs/flutter-apk/app-release.apk` produced successfully (55.3 MB).
- PostgreSQL-backed package, record authorization, RLS, and recovery integration are executed by GitHub Actions against disposable PostgreSQL 16; the machine has no local PostgreSQL service configured.

The current CI run exposed a SQL security test-fixture mismatch: its direct scoped insert omitted the now-required module identifier. The fixture was corrected to pass the trusted maintenance module ID explicitly. That correction and the current client/Host record integration are awaiting a fresh CI result; prior green workflows do not prove this latest tree passes.

No physical Android device/emulator run, full interactive Windows UI acceptance session, or Windows Host serving clients on a LAN is claimed here. Local UI widget tests and successful native builds are not substitutes for those checks.

## Remaining production gates

- Complete a real Windows Host deployment with PostgreSQL, protected recovery-authority provisioning, certificates, and remote Windows/Android credential enrollment.
- Run the acceptance scenario through a live Host: create a second distinct extension, approve it, synchronize actual records, restart the app, exercise conflict/rejection, upgrade and disable/re-enable it, then verify on a second device.
- Exercise Windows UI manually and install/run the APK on Android hardware or an emulator.
- Define a conflict-resolution/rebase flow and reviewed resumable migrations for changes beyond the supported additive schema subset.
- Add workload evidence and indexes for large Host/local datasets; current query bounds protect request size, but do not make an enterprise-scale latency guarantee.
- Production recovery still requires rollback protection outside the shared database and witness rollback domain. Matching rollback of both artifacts cannot be detected by the current local freshness design.

See [the final Host engineering audit](HOST_ENGINE_V0_1_FINAL_ENGINEERING_AUDIT.md), [Host operations and recovery](HOST_ENGINE_V0_1_OPERATIONS.md), and [Extension Builder foundation](EXTENSION_BUILDER_FOUNDATION.md) for historical acceptance evidence and operating details. This status describes the current implementation slice and does not declare production readiness.
