# Host Setup Diagnostics Hardening — 2026-11-01

## Result

The assigned Host Setup diagnostics hardening work is implemented and verified on the Windows development computer. This is completion of the bounded diagnostics assignment; it does **not** accept Stage 6 (Diagnostics Center), Stage 3 (First-Run Setup), or Stage 10 (Windows Installer). Formal Wave 1 acceptance remains **20 / 100**.

## Changes

- Host Setup failures now receive a stable safe category, phase, action, and local correlation reference. Safe technical context is retained in the device-local SQLite diagnostics store, including exception type and allowlisted stack symbols; raw messages and paths are not stored in these fields.
- SQLite diagnostics schema migration 1→2 adds nullable protected-context columns without replacing existing records. Public event JSON and sanitized setup export omit this protected context, Host/device/scope identifiers, and credentials.
- The Flutter Host Setup failure screen offers a sanitized report copy action before Host API readiness. If local persistence is unavailable, it still creates an in-memory safe report, displays the persistence failure, and allows export.
- Added regression coverage for schema upgrade, protected-context persistence and export omission, failure categories, successful report copy, and diagnostic-storage failure.
- During diagnostic archive coverage, a real removal-path helper defect was found: safe ACL/reparse inspection rejected valid product-owned descendant paths. The helper now allows descendants only beneath the exact Ventio product-root boundary, continues checking ancestor reparse points, and retains exact-root deletion enforcement. A sibling-outside-root rejection case and the static installer contract were updated.

## Verification evidence

- `flutter test test/host_setup_test.dart test/local_diagnostics_test.dart`: **31 passed**.
- Full Flutter suite: **210 passed, 2 skipped**. The skipped cases are opt-in isolated PostgreSQL integration tests.
- `flutter analyze`: **no issues found**.
- `flutter build windows --release`: passed; current Release executable rebuilt from the changed Flutter sources.
- `scripts/windows/test-host-removal-diagnostic-archive.ps1`: passed, including partial-installation state, safe diagnostics archive, sibling boundary rejection, and unknown-state refusal.
- `scripts/windows/test-unified-installer-path-contract.ps1`: passed.
- `dotnet run --project installer/windows/setup-broker.tests/VentioSetupBroker.Tests.csproj -c Release`: passed.
- `dotnet run --project installer/windows/host-service.tests/HostService.Tests.csproj -c Release`: passed; the ordinary run skipped its elevated installed-service SID integration. A separate authorized elevated rerun passed the real `NT SERVICE\VentioHost` ACL integration in a disposable temporary directory.
- `scripts/windows/test-host-provisioning-failure-record.ps1`: passed redaction, protected ACL, path-boundary, and safe-resume checks.
- The final unsigned development installer was built at `dist/windows/host-setup-diagnostics-hardening-20261101-b/Ventio-Setup-0.1.0.exe`, SHA-256 `b9a63b2906b229eb020d2a024d1b2d6f14642c7d6d9b4724855283b00722d1b2`. Inno Setup reported successful compilation; Host machine-wide privilege and deferred-provisioning guards passed. Authenticode status is `NotSigned`. No installer lifecycle was run and no system services or production data were changed.

## Acceptance boundary

Diagnostics persistence across Host service restart, full operational failure injection, authorized Host-side retrieval, and end-to-end export from an installed Host remain part of the broader Stage 6 gate and have not been accepted here. The assignment does not explain or resolve the separate `HOST_FIRST_ADMIN_RECOVERY_AUTHORITY_FAILED` report from the inaccessible domain-joined office computer. Stage 6 remains **IN PROGRESS** and earns no additional weight.
