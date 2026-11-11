# Historical Wave 1 Engineering Audit & Windows Release Candidate

> **Historical scope correction (2026-11-02):** This 2026-10-28 report belongs to the earlier Extension Builder / 23-capability acceptance checkpoint. Its statement that “Wave 1 dashboard's 100%” was accepted does **not** describe the current Host/Client Wave 1, which has eleven weighted stages and is formally accepted at **50%**. The authoritative current ledger is [`docs/wave1/final-acceptance-report.md`](wave1/final-acceptance-report.md); do not use this historical report to infer current Host/Client stage acceptance.

Date: 2026-10-28
Branch: `codex/extension-platform`
Reviewed implementation baseline: `59037f708cc565ee31b605e3a9c10065fcb855b9`
Initial audit checkpoint: `6ef9ca7747ec81236a7c3ed7a79a53a824b41fe9`
Latest reviewed code/test checkpoint: `35100a159b917319be76df6259c91019bdc10fb2`
The final audit report and progress dashboard are published in the following documentation checkpoint on this branch.

This historical audit does not start Wave 2 and does not declare commercial production readiness. Its 100% value referred to the prior capability checkpoint only; it is not a current Host/Client release-readiness statement.

## Branch and review scope

- The branch was `codex/extension-platform`, and its pre-audit HEAD matched `origin/codex/extension-platform` at `59037f708cc565ee31b605e3a9c10065fcb855b9`.
- `origin/main` was `da3b13851e1b4e210618755d5eab93f02b4dfa48`; that reviewed baseline is an ancestor of the development branch. No changes were made to `main`.
- Review covered the Core/Host/Host API/PostgreSQL boundaries, metadata and extension-package execution, SQLite offline persistence and reconciliation, generated Flutter UI, permission scope, transaction/idempotency/recovery paths, and prior capability evidence.
- No inventory-specific behavior was added to the generic engine during this audit. Inventory Operations remains a declarative extension using governed operations and ordinary extension authorization; uploaded executable code, Dart, SQL, and scripts are not part of its package model.

## Engineering assessment

The reviewed design retains a Windows-first Flutter native client, local SQLite command queue, and PostgreSQL Host authority. Local provisional changes and receipts are reconciled through durable commands; Host acceptance remains transactional and scope-bound. Existing extension and Host tests exercise tenant/company/branch/actor enforcement, role and field permissions, RLS, atomic rollback, retry idempotency, numbering, Amend races, and restart recovery.

The audit found no confirmed architecture defect requiring a broad refactor. Targeted test-harness, source-formatting, package-verifier, and child-process import issues were corrected. All eight GitHub Actions workflows pass on the reviewed code/test checkpoint; see GitHub Actions.

## Changes made during the audit

1. Fixed the phone-sized DocType Builder test to scroll the builder's own field list rather than the first unrelated route scrollable. The focused regression passes.
2. Narrowed the crash-recovery helper import to the local command queue module. A standalone Dart child process now reaches the intended crash scenario rather than failing in the Dart FFI transformer with exit 252; the recovery regression passes.
3. Corrected the Windows app integration test's scroll helper to identify the active page scrollable and return to its top before finding an above-the-fold action. The native Windows app integration test passes.
4. Guarded the PostgreSQL-dependent Flutter integration case behind the explicit test-only `VENTIO_ALLOW_DATABASE_TESTS=yes` opt-in. It remains separately enabled and executed against the disposable test cluster; it is not removed or counted as an acceptance without runtime evidence.
5. Applied the repository's pinned Dart formatter to the files failing its CI formatting gate and fixed two analyzer brace infos. The inventory acceptance note's queued-command count was corrected from seven to eight based on the scenario evidence.
6. Actions exposed Dart formatting failures in Host API and Host Durable Commands files that were outside the Flutter formatter invocation. Formatted the two Host API files and `packages/ventio_host/test/durable_integration.dart` without logic changes. Host API's full format check and analyzer pass locally alongside its 45 API checks and six isolated PostgreSQL numbering checks; Host's format check and analyzer also pass locally.
7. The next Actions run exposed one formatter failure in Core and two issues in the static package verifier. Formatted `ventio_core/lib/src/report_metadata.dart`; kept the Arabic user-data renderer fixture while expressing it as Dart Unicode escapes so the English-only source scanner sees English source and the runtime input remains Arabic. Made `verify_package.py` decode Dart source explicitly as UTF-8. Core format/analyzer pass, the focused print renderer test passes, and the static verifier passes against a clean tracked-source snapshot.

## Verification results

All PostgreSQL tests below used a temporary Windows PostgreSQL 17.11 cluster bound to loopback and the disposable `ventio_host_test` database. The migrations and guarded security bootstrap were applied there. The cluster was stopped after verification. No production database was used.

| Area | Command / evidence | Result |
|---|---|---|
| Contract and schema validation | `python scripts/validate_contracts.py` | PASS; 7 schema fixtures and catalog/cross-contract checks |
| Localization gate | `python scripts/check_localization_gate.py` | PASS; 120 text/source/JSON files scanned |
| Localization gate unit tests | `python -m unittest scripts.test_check_localization_gate` | PASS; 6/6 |
| CI drop-to-nobody helper tests | `python -m unittest scripts.ci.test_ventio_ci_drop_to_nobody` | PASS; 5/5; this is helper coverage, not the complete Linux host audit |
| Core | `dart run test/all_tests.dart` in `packages/ventio_core` | PASS; 78/78; analyzer clean |
| Host API | `dart run test/api_tests.dart` in `packages/ventio_host_api` | PASS; 45/45; analyzer clean |
| Host package analysis | `dart analyze` in `packages/ventio_host` | PASS; no issues |
| PostgreSQL migration checksums | `dart run test/migration_checksum_test.dart` in `packages/ventio_postgres` | PASS |
| Durable PostgreSQL Host | `dart run test/durable_integration.dart` | PASS; 43/43, including atomic rollback, journal/audit/outbox rollback, idempotent retries, and concurrent receipts |
| PostgreSQL identity | `dart run test/identity_integration.dart` | PASS; 79/79, including restart, revocation, replay, and scope enforcement |
| PostgreSQL database security | `dart run test/database_security_integration.dart` | PASS; 110/110, including RLS and restricted SQL/schema behavior |
| PostgreSQL numbering | `dart run test/document_number_allocator_integration.dart` with the isolated cluster admin test URL | PASS; 6/6, including rollback, concurrency, series and branch separation |
| PostgreSQL role administration | `dart run test/role_administration_integration.dart` | PASS; 16/16 |
| PostgreSQL extension package | `dart run test/extension_package_integration.dart` | PASS; 137/137, including authorization, governed operations, rollback, numbering, concurrency, idempotency, Amend and recovery |
| Official extension cross-layer integration | Flutter `official_inventory_host_sqlite_integration_test.dart`, explicit disposable DB opt-in | PASS; 1/1 against PostgreSQL 17.11 and Windows SQLite |
| Windows Host process integration | `flutter test integration_test/local_host_role_process_integration.dart -d windows` | PASS; 24/24, including process restart, scoped records/roles/packages, offline retry and TLS address behavior |
| DocType Builder phone regression | Focused `extension_studio_test.dart` test | PASS; 1/1 |
| Child-process recovery regression | Focused `local_command_queue_test.dart` test | PASS; 1/1 |
| Flutter full unit/widget suite | `flutter test --reporter expanded` | PASS; 116 passed, 2 skipped by explicit environment/platform guards; both skipped scenarios were executed separately as listed above |
| Windows app integration | `flutter test integration_test/extension_builder_app_test.dart -d windows --no-pub --reporter expanded` | PASS; 1/1 |
| Dart formatting | `dart format --output=none --set-exit-if-changed lib test integration_test` | PASS; clean, 38 files |
| Flutter analysis | `flutter analyze` | PASS; no issues found |
| Diff hygiene | `git diff --check` | PASS; no whitespace errors |

The localization scanner's stated coverage is static text/source/JSON inspection and catalog rules; it is not runtime verification of Flutter, Host, sync, security or database behavior.

## Windows Release Candidate

- `flutter build windows --release --no-pub` succeeded from an isolated copy of the reviewed workspace under a short path (`a short temporary path`) to avoid Windows MAX_PATH failures in generated MSBuild paths. Exit code: **0**.
- The Release output includes `ventio_native_client.exe`, Flutter runtime DLL, secure-storage / printing / SQLite plugin DLLs, `pdfium.dll`, and `data` with Flutter assets, `app.so`, and `icudtl.dat`.
- Packaged at `deliverables/Ventio-Wave1-RC-20261028.zip` (17,747,631 bytes). SHA-256: `EEA867650BE6BB57DE4F979C7A98B93CC26E78294A635BFA24A06A8592A92EE5`.
- The ZIP was extracted to a fresh temporary directory. Launching the extracted EXE left the process alive after eight seconds and produced a native window handle with title `ventio_native_client`. This is a startup smoke test, not a full interactive/manual application acceptance run.
- Initial staging attempts exposed duplicate copied Flutter ephemeral plugin links and Windows path-length/build-under-TEMP issues. These were avoided by building from a clean short-path source copy; no repository workaround or product-code change was introduced for those environment issues.

## GitHub Actions

At the pre-audit commit `59037f708cc565ee31b605e3a9c10065fcb855b9`, GitHub reported no combined commit statuses and no workflow runs through the connected GitHub integration. A draft validation PR (#4) was opened against `main` to trigger the event-gated checks; it remains unmerged.

The first validation PR runs exposed real formatter failures in the Flutter, Host API, Host and Core packages, plus the static verifier's handling of the Arabic user-input fixture and Windows default text encoding. The source formatting was fixed without functional changes; the Arabic test value remains Arabic at runtime through Dart Unicode escapes, and the verifier reads Dart files as UTF-8. Those failures are recorded here rather than hidden. On the exact reviewed checkpoint `35100a159b917319be76df6259c91019bdc10fb2`, all eight workflow runs and all nine jobs passed: Native Flutter Client and Extension Builder (including localization, full Flutter suite, native Windows integration, Windows Debug/Release, Android Debug/Release and cleanup); Ventio Core Foundation (format, analyze, 78 core checks and both demos) and its Architecture Contracts job (`verify_package.py`, V1.2 contracts and Python suites); Host API (unit, HTTP/PG, identity/revocation, RLS/direct SQL, roles, extension approval/authorization/recovery); Host Engineering Gate (Linux PG16, privilege helper, migration/recovery/performance audit); Host Persistence (PG16); Host Crash Recovery (kill/retry/restore into fresh PG16 cluster); Durable Commands (PG16); and Credential Lifecycle (PG16). All disposable PostgreSQL fixtures were cleaned up by their jobs.

The Linux Host Engineering workflow was not runnable locally because Docker Desktop's Linux engine was unavailable and its privilege helper is Linux-only. GitHub's designated Linux self-hosted runner executed the exact gate on the reviewed checkpoint and passed. Windows CI also emitted a non-blocking Node.js 20 deprecation warning for `actions/checkout@v4`; it does not fail any job.

CI verification on `35100a159b917319be76df6259c91019bdc10fb2`: **8/8 workflows PASS**. Pull request #4 remains draft and unmerged; no changes were made to `main`.

## Open items and residual risks

- No blocking engineering or CI items remain for the reviewed code checkpoint. The workflow emits a non-blocking `actions/checkout@v4` Node.js 20 deprecation warning for future CI maintenance.
- Startup smoke validation confirms process/window creation only; it does not replace interactive user acceptance or broader deployment testing.
- This release candidate is for evaluation. It is not a declaration of commercial production readiness.

## Merge recommendation

**Engineering recommendation: ready for owner-reviewed merge to `main`.** All eight required GitHub Actions workflows passed on the exact code/test checkpoint; the disposable PostgreSQL 17.11 and 16 integrations, Windows Release build, and extracted-app startup smoke passed. Pull request #4 is still draft and unmerged; no merge was performed or authorized. This is a Wave 1 release candidate and not a commercial production-readiness declaration.
