# Stage 1 — Foundational Management Contracts

**Weight:** 8%<br>
**Status:** **PASS — 2026-11-02 (Asia/Beirut)**<br>
**Formal accepted total at the time Stage 1 was accepted:** **28 / 100** (Stages 0, 1, 4, and 7). The current formal accepted total is maintained in the final acceptance report and progress dashboard.

## Acceptance evidence

- Host API contract suite: `dart run test/api_tests.dart` — **70 passed, 0 failed**. Covers legacy liveness/session/command compatibility, versioned readiness, stable correlated errors, safe error projection, exact-scope authentication, denial-before-execution, graceful shutdown, and rejection of unsafe external listener dependencies.
- User-management API contracts: `dart run test/management_users_api_test.dart` — **15 passed, 0 failed**. Covers versioned scope, correlation, safe audit projection, unauthorized/cross-branch rejection, caller-identity rejection, permission ceilings, and safe error envelopes.
- Device-management API contracts: `dart run test/management_devices_api_test.dart` — **12 passed, 0 failed**.
- Core management contracts: `dart run test/all_tests.dart` — **81 passed, 0 failed**, including readiness, diagnostics, device inventory, synchronization and secret-exclusion contracts.
- Disposable PostgreSQL 16.15 Host security run `20261101215055510-1`: migrations **001–029**, security bootstrap and test-login provisioning completed; database security/RLS/Recovery Authority **118/118**, user administration **28/28**, role administration **20/20**, and pairing/device lifecycle **24/24** passed. The fixture was stopped and removed.
- Real Host API/PostgreSQL integration run `20261101215718326-1`: **34/34** passed, including transactional record/journal/audit/outbox behavior, authorization and payload rejection, ambiguous outcome retry, independent process restart, and stable persisted receipts. The fixture was stopped and removed.
- Recovery Authority/first-administrator integration run `20261101215731649-1`: **11/11** passed, including first-install witness initialization, takeover refusal, interruption reconciliation, exact-request retry, one-time administrator creation, and cross-tenant refusal. The fixture was stopped and removed.
- Persistent identity and revocation integration run `20261101220129466-1`: **79/79** passed across authentication, permission ceilings, tenant/company/branch boundaries, revocation, disabled users, audit redaction, independent Host processes, restart persistence, and replay behavior. Its first run exposed only a fixture-cleanup ordering defect after all 79 assertions had passed; the test now deletes the dependent device-activity rows before devices, and the full rerun plus fixture cleanup passed.
- PostgreSQL migration checksum verification passed across Windows/Unix line endings. `dart analyze .` passed for `ventio_core`, `ventio_postgres`, and `ventio_host_api`.
- Windows Host service suite passed its startup/readiness, configuration, broker, and TLS certificate tests. The normal unprivileged run skipped the service-owner case; an authorized elevated rerun passed that case using a disposable directory, verified the actual `NT SERVICE\VentioHost` owner/DACL, and removed the temporary fixture. Setup Broker validation also passed.
- The local PostgreSQL runner now accepts `api_integration.dart` and `identity_integration.dart` as explicit `-OnlyHostSuite` choices. Both ran successfully through separately protected, loopback-only disposable PostgreSQL fixtures.

## Boundaries and remaining work

This stage accepts the management contract and security boundary, not the complete deployment lifecycle. A read-only state check on the development workstation on 2026-11-02 found registered `VentioHost` and `VentioPostgres` services stopped and `GET http://127.0.0.1:8080/healthz` refused; no service state was changed. Earlier owner-provided evidence on a separate Windows 11 Host records successful setup and reboot recovery. Installed-service upgrade, uninstall, retention, and end-to-end deployment remain open under Stage 10; broader first-run and installed Host/Client requirements remain under Stages 3, 5, 6, and 8.

The acceptance was originally verified against the working tree based at `9d53ea0`. Its implementation is now preserved in the consolidated development commits `0d164bd`, `f613f96`, and `fb0a1a0`. The pre-edit snapshot remains available outside the repository at `%LOCALAPPDATA%\VentioFramework\codex-snapshots\wave1-before-20261101-232856`; no pre-existing work was discarded.
