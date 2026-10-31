# Host Standalone Readiness Verification

**Verification date:** 2026-10-31
**Status:** **BLOCKED**
**Source branch:** `codex/extension-platform`
**Source HEAD:** `c127827` (`Bind Host settings to authenticated device identity`)

## Summary

The device identity defect that prevented the first administrator from opening Host Settings is fixed and passed focused regression tests. A Windows Release build from the current working tree was used against the existing Host installation. The authenticated administrator session, Host Settings, Host Overview, local API readiness, and service state were verified. Closing and reopening Flutter restored the administrator's access while both Host services remained running.

This does not complete Host Standalone Readiness. The new installer was built but not run, the current Host installation was not reinitialized, and a clean-machine Host setup with UAC, a Windows reboot, and an externally reachable TLS listener were not verified. The current Host listener is loopback-only. These are mandatory runtime checks, so the overall result is BLOCKED.

## Device identity and administrator session

`HostConnectionProfile.deviceId` may be absent in older local profiles. Host Settings now binds such a profile to the `deviceId` returned by the authenticated Host session endpoint. The operation also verifies persistent authentication, the expected tenant and actor, and exactly one matching company/branch grant. If the stored device ID is present and differs from the Host response, the profile remains unverified. Host Setup validates the first administrator's required Host-management grants before persisting the connection profile. Tokens and credentials are not logged.

On the current Host installation, the first administrator successfully opened Host Settings. The UI showed a verified Host session, the Host-reported actor and device IDs, the `Test-Project / Test-Company / Test-Branch` scope, and links for Users & permissions, Roles & access, Devices & pairing, and Host Overview. The six exact-scope permissions were visible; no user, role, or device write operation was invoked during this verification:

- `host.diagnostics.read`
- `host.status.read`
- `identity.devices.manage`
- `identity.pairing.manage`
- `identity.roles.manage`
- `identity.users.manage`

Host Overview reported `READY` for the authenticated Host API, PostgreSQL connection, schema/runtime profile, and Recovery Authority. The workspace build was closed and reopened; the session and Host access were restored. Tests reject a different registered device, tenant, actor, missing scope, nonpersistent session, and an administrator session missing required grants.

## Runtime evidence on the current machine

The current system is Windows 11 Pro build `26300`. These read-only checks passed after the Flutter lifecycle check:

| Check | Observed result |
|---|---|
| `VentioPostgres` | `Running`, `Automatic`, `NT SERVICE\VentioPostgres` |
| `VentioHost` | `Running`, `Automatic`, `NT SERVICE\VentioHost` |
| Flutter process privilege | Normal, non-elevated user token |
| PostgreSQL readiness | `pg_isready` accepted `127.0.0.1:54329` |
| Host liveness | `GET http://127.0.0.1:8080/healthz` returned `200` |
| Unauthenticated session discovery | `GET /api/v1/session` returned `401`, as expected |
| Network listener | Bound to `127.0.0.1:8080`; no external TLS listener was configured or tested |
| Recovery Authority | Host Overview reported `READY`; the protected witness ACL could not be independently re-read from this non-elevated session |

These checks describe the existing, previously provisioned Host. They are not evidence of a fresh installation. No database, credential, or Recovery Authority reset was performed. The installer was not run on this machine.

## Automated verification

| Verification | Result |
|---|---|
| Flutter Host Setup, Host Settings, and Host Settings page tests | `63 passed, 0 failed` |
| Flutter analysis | `flutter analyze --no-pub`: no issues found |
| Host API contracts and authorization tests | `70 passed, 0 failed` |
| Host service and first-administrator broker tests | Passed, including service readiness/stop paths, Named Pipe ACL, strict protocol, caller/request binding, same-caller retry, and DPAPI receipt confidentiality |
| Setup broker validation tests | Passed, including ACL rights, fixed Host operation, scope, caller SID, operation ID, and arbitrary-argument rejection |
| Host payload manifest | PostgreSQL `16.15`; no database or credentials included |
| Dashboard consistency | `python scripts/wave1/validate_progress_dashboard.py`: PASS; 11 stages, 100% weight, 20% accepted |

Automated broker and service tests do not prove UAC behavior, Windows SCM behavior after reboot, or a clean graphical Host installation.

## Development installer artifact

- Path: `dist/windows/host-standalone-readiness-20261031/Ventio-Setup-0.1.0.exe`
- Version: `0.1.0`
- Size: `84,906,485` bytes
- SHA-256: `4697ae82da0993494b14979a842c9a2083312b9fef5ea5e8f18aaceb6234c6f7`
- Authenticode status: `NotSigned`

The build checks confirmed the unified Host/Client payload and deferred database/service provisioning. The PostgreSQL runtime is bundled; the payload manifest states `databaseIncluded: false` and `credentialsIncluded: false`. This unsigned artifact is for development verification only, not commercial distribution. It has not been installed or exercised through its Host first-run path.

## Remaining blocked acceptance checks

1. Install from this artifact in a clean, isolated Windows VM. Verify ordinary-user Flutter launch, Client selection without local Host services, and Host selection without preselecting or initializing a database during installation.
2. Complete the graphical Host setup using actual UAC approval. Capture evidence of the privileged broker identity, PostgreSQL service registration, migrations, Host service registration, first-administrator creation, protected credential handoff, and final authenticated readiness.
3. Close Flutter, verify both services remain running, reopen Flutter, and confirm session restoration or secure reauthentication on the clean VM.
4. Restart the VM. Confirm the PostgreSQL and VentioHost service identities, startup configuration, database and Recovery Authority persistence, and administrator access.
5. Verify the intended future-Client listener, TLS certificate, firewall scope, authenticated health/readiness routes, and protected pairing routes. The existing Host is loopback-only and is not yet shown to accept LAN clients.
6. On isolated copied data, independently diagnose `HOST_DATABASE_RECOVERY_ROLE_ROTATION_FAILED`. Do not reset credentials or reinitialize the existing Host to hide this defect. Recovery and upgrade acceptance remain open until its cause is fixed and verified.
7. Keep installer upgrade, repair, data-retention uninstall, commercial signing, and Inno Setup commercial licensing as separate Stage 10/release checks. They were not accepted by this milestone.

No external Client pairing, multi-device synchronization, or Android test was required or performed for this standalone Host milestone.

## Official Wave 1 progress

Official accepted progress remains **20%**: Stage 0 (4%), Stage 4 (9%), and Stage 7 (7%). Stages 3, 5, and 10 have new implementation/runtime evidence but remain unaccepted and receive no points. Stages 1, 2, 6, 8, and 9 remain open or blocked according to their mandatory gates. This milestone must not be treated as full Wave 1 acceptance.

## External Windows VM evidence checklist

Use a disposable Windows VM snapshot with no existing Ventio Host services or data:

1. Record `winver` and confirm `Get-CimInstance Win32_Service | Where-Object Name -in @('VentioPostgres','VentioHost')` returns no Ventio Host services.
2. Run the installer above as a standard user. Confirm no PostgreSQL or Host database/service is initialized during installation. Launch Ventio normally, choose **Set up this device as Host**, approve the narrowly scoped UAC request, and complete the graphical wizard with a test organization scope and first administrator.
3. Confirm the wizard opens the workspace and Host Settings shows **Verified Host session**, the Host-reported device ID, exact scope, and administrator grants. Open Host Overview and confirm `READY`. Save sanitized setup diagnostics.
4. Close Flutter. Confirm `VentioPostgres` and `VentioHost` remain `Running` under `NT SERVICE\VentioPostgres` and `NT SERVICE\VentioHost`. Check PostgreSQL using the packaged `pg_isready.exe` against `127.0.0.1:54329` and call `GET http://127.0.0.1:8080/healthz` (expected `200`). Confirm unauthenticated `GET /api/v1/session` is rejected (`401`). Reopen Flutter and confirm the administrator session is restored or securely reauthenticated.
5. Restart the VM. Repeat the service, PostgreSQL, Host readiness, and Host Settings checks. Confirm the migration ledger, administrator/device identity, database contents, service identities, and Recovery Authority readiness persist. As an authorized administrator, verify the Recovery Authority witness ACL still grants the intended service SID access and denies ordinary users. Record the actual listener address and TLS status; keep it loopback-only until the approved external TLS and firewall configuration is in place.

Save the installer SHA-256, Windows build, screenshots, a redacted service identity/state export, migration ledger count, sanitized setup status, authenticated readiness output, and post-reboot checks. Do not include access tokens, database passwords, Recovery Authority witnesses, or unredacted diagnostic secrets. Do not run this procedure on the existing Host installation or use any cleanup/reinitialization step against its data.
