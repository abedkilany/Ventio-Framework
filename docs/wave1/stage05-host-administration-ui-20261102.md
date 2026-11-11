# Stage 5 — Integrated Host Administration UI Acceptance

**Status:** PASS — 10 / 10 points accepted on 2026-11-02.<br>
**Formal Wave 1 progress:** 50 / 100 (Stages 0, 1, 2, 4, 5, and 7).<br>
**Source checkpoint:** `fb0a1a0` on `codex/extension-platform` (the tested UI source is committed).

## Acceptance evidence

The native Windows Flutter application was exercised against a real persistent local Host process and an isolated disposable PostgreSQL 16.15 instance. The Host process used separate runtime and scoped Identity API database logins, persistent Host API authorization, and a temporary Recovery Authority witness. Flutter used independent temporary SQLite files for its client profile, command queue, and diagnostic events. The PostgreSQL runner removed its fixture after the test.

Run `20261102010615881-1` passed **8/8 Host/process assertions** and the Windows Flutter integration test passed **1/1**. The scenario covered:

- A reader without the exact Host status and user-management grants did not see Host administration navigation.
- An authorized administrator opened Host Overview and Settings and saw the authenticated Host session and exact scope.
- The application retrieved the Host diagnostics feed and displayed its valid empty state; the synchronization page displayed its Host-backed empty queue.
- The Devices & Pairing screen read the real Host device inventory and generated a Host pairing code.
- The Roles screen created a role through the real Host API and PostgreSQL.
- The Users & Permissions screen read the real user list and administrative audit, created a Host-generated unprivileged user, granted a normal permission, displayed it after refresh, revoked it, and verified the Host audit and returned inventory.
- Unauthorized user listing and a request outside the authenticated branch were rejected by the Host with the expected stable authorization codes.
- Changing the local profile to another branch or to an unavailable Host hid Host administration actions. Host Settings showed an unverified session while local Diagnostics and Synchronization remained reachable.

The runner also made an independent real Host grant/list request before launching Flutter. This verifies the scoped Host route and PostgreSQL projection separately from the screen flow. The complete live UI path then verified the actual permission chip and revoke result after allowing the asynchronous dialog submission to settle.

## Changes included

- The Flutter audit client now accepts only the two fixed sanitized labels produced by Host (`[redacted]` and `Host administrator`) while continuing to reject unsafe free-form labels and audit detail fields. This closes a real contract mismatch that previously prevented safe Host audit events from loading in the administration UI.
- The user audit request follows the strict Host v1 request contract, and successful management responses retain explicit API-version validation.
- Added a Windows Flutter integration test that uses temporary SQLite files, a real local Host API, and disposable PostgreSQL instead of relying only on widget fakes.
- Added live checks for Host denial without the permission and for cross-branch rejection.

## Verification

- `flutter test test/host_user_management_test.dart test/host_readiness_test.dart test/host_diagnostics_test.dart test/synchronization_page_test.dart`: **34/34 passed**.
- `flutter analyze`: no issues.
- `dart analyze test/local_host_role_process_integration.dart`: no issues.
- Windows Release build: passed; executable at `packages/ventio_native_client/build/windows/x64/runner/Release/ventio_native_client.exe`.
- Windows live Host/PostgreSQL/Flutter integration run `20261102010615881-1`: **8/8 Host assertions and 1/1 Flutter integration test passed**.
- No physical second Windows/Android device was used. This Stage 5 acceptance does not close Stage 6's installed-service diagnostics gate, Stage 8's physical-device/installed lifecycle criteria, or Stage 10's installer lifecycle gate.

## Repository and data handling

The acceptance was originally verified against the working tree based at `9d53ea0`; the implementation is now preserved in the consolidated commits `0d164bd`, `f613f96`, and `fb0a1a0`. The pre-edit snapshot remains at `%LOCALAPPDATA%\VentioFramework\codex-snapshots\wave1-before-20261101-232856`; the existing Release output was separately preserved before rebuilding. No installed Host/PostgreSQL service or product database was changed; all test database operations used a disposable local fixture.
