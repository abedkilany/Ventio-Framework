# Stage 2 — User Identity, Roles and Permissions

**Weight:** 12%<br>
**Status:** **PASS — 2026-11-02 (Asia/Beirut)**<br>
**Formal accepted total:** **40 / 100** (Stages 0, 1, 2, 4, and 7)

Stage 2 added 12 points when accepted; Stage 5 was accepted afterward, bringing the current formal Wave 1 total to **50 / 100**.

## Acceptance evidence

- A disposable native Windows PostgreSQL 16.15 Host security run, `20261101221155604-1`, applied all **30** migrations and security bootstrap. Database security, forced RLS and Recovery Authority passed **118/118**; Host user administration passed **39/39**; role administration passed **20/20**; and pairing/device lifecycle passed **24/24**. The runner stopped PostgreSQL and removed the isolated fixture.
- Latest complete rerun `20261102174121596-1` applied migrations 001–030 and security bootstrap in a disposable PostgreSQL 16.15 cluster. Database security, forced RLS and Recovery Authority passed **118/118**; user administration passed **40/40**; role administration passed **20/20**; and pairing/device lifecycle passed **24/24** (**202/202 total**). The isolated fixture was stopped and removed.
- The focused Host user-administration rerun, `20261101222210370-1`, applied the same 30 migrations and passed **40/40**, including exact-scope Host HTTP requests, user creation/grant/revoke/disable/enable, persistent authentication denial during disablement, reactivation of an unrevoked exact-scope credential, audited re-enablement, scope-ceiling revalidation, indistinguishable missing/cross-branch results, audit redaction, and fixture cleanup. The first attempt exposed an assertion attached to the wrong fixture identity; the assertion was corrected and this full rerun passed.
- Host user API contract tests passed **16/16**. They cover version and correlation contracts, allowlisted audit projection, invalid caller identity fields, reserved-permission denial, exact-scope checks, unauthorized-user denial, and stable safe errors.
- Flutter user-management and role-administration tests passed **13/13**. The UI tests cover permission gating, generated user IDs, grant/revoke request flows, role creation/assignment, and confirmation/cancellation for both disable and enable.
- `dart analyze` for `ventio_host_api` and `flutter analyze` for `ventio_native_client` reported no issues. `flutter build windows --release` succeeded and rebuilt `packages/ventio_native_client/build/windows/x64/runner/Release/ventio_native_client.exe` after the application changes.
- `python scripts/check_schema_profile.py` passed after correcting the verifier to compare the active migration list separately from the historical checksum-compatibility list. Migration `030_identity_user_enable.sql` is covered by the reviewed schema profile and the isolated database runs.

## Implemented changes

- Added scoped Host API route `/api/v1/management/users/enable`, client support, and a permission-gated Flutter action with explicit confirmation. The UI explains that previously granted permissions and unrevoked, unexpired credentials can become usable again; compromised credentials require separate device or credential revocation.
- Added the append-only PostgreSQL migration `030_identity_user_enable.sql` with a scoped audit index for user-state transitions. The scoped mutation function accepts `USER_ENABLED` only for a currently disabled, visible user, revalidates the live manager grant and exact credential ceiling, preserves cross-scope non-disclosure, and writes a durable allowlisted audit event. Existing expired or revoked credentials stay unusable.
- Added real Host API/PostgreSQL coverage for allow/deny behavior, scoped inventory, disable/enable authentication transitions, and redacted audit retrieval. Updated the unified-installer payload validator to require migration 030.
- Fixed `scripts/check_schema_profile.py` so historical compatibility hashes for migrations 026–028 do not cause the current-schema comparison to fail.

## Acceptance boundary

Stage 2 is accepted for human-user lifecycle, role authorization, permission ceilings, tenant/company/branch isolation, forced RLS, least privilege, Host API authorization, device-versus-human authority, and audited/redacted user changes. The Flutter widget tests exercise the management flows and request contracts; a full live Flutter UI session against a running Host remains part of Stage 5. First-run setup, installed-service behavior, the separate domain-joined office first-admin failure, and physical-device synchronization are not claimed as Stage 2 evidence.

The implementation is preserved in the development branch commits `0d164bd`, `f613f96`, and `fb0a1a0`. The verified pre-edit snapshot remains at `%LOCALAPPDATA%\VentioFramework\codex-snapshots\wave1-before-20261101-232856`.
