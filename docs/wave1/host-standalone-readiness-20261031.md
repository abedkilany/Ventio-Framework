# Host Standalone Readiness Verification

**Verification date:** 2026-11-01
**Status:** **PASS**
**Source branch:** `codex/extension-platform`
**Source HEAD:** `c127827` (`Bind Host settings to authenticated device identity`)

## Summary

The device identity defect that prevented the first administrator from opening Host Settings is fixed and passed focused regression tests. The owner then installed the development installer on a separate Windows 11 PC and completed the graphical Host setup. After restarting Windows, screenshots showed all six setup steps complete, both services running under their intended service SIDs, Host Overview reporting `READY`, and Host Settings showing a verified administrator session with the exact scope and six management grants. The owner then closed Flutter and confirmed both services remained `Running`; after reopening Flutter, Host Overview remained `READY` and Host Settings showed the verified administrator session.

Host Standalone Readiness is **PASS**. Evidence combines the owner-provided fresh graphical Host setup, authenticated administrator session, service identities, Flutter close/reopen and reboot persistence with the updated LAN listener. On 2026-11-01, the updated installer completed a conservative update on the engineering workstation's existing Host without database reinitialization. PostgreSQL and Host ran under their intended identities; the Host listener bound to `0.0.0.0:8443`, and local HTTPS `GET /healthz` returned `200`. The setup path performs a certificate-pinned local TLS self-check before enabling the listener; the separate curl probe used `--insecure` and did not independently validate the certificate. On the owner's Windows 11 Host, post-reboot screenshots show both services `Running`/`Automatic` under the intended service identities and Host Settings displaying the authenticated session, LAN endpoint `https://HOST_PRIVATE_LAN_IP:8443`, and certificate fingerprint. The owner then ran `Test-NetConnection` from a second device (`CLIENT_PRIVATE_LAN_IP`) to the Host (`HOST_PRIVATE_LAN_IP:8443`) after reboot; `TcpTestSucceeded` was `True`. This confirms post-reboot LAN TCP reachability. Actual Ventio Client pairing and client-side certificate trust remain separate and were not required for this milestone. Owner-provided elevated PowerShell output verifies the Recovery Authority witness file and its immediate directory: both are owned by `NT SERVICE\VentioHost`, have protected ACLs, and grant explicit non-inherited `FullControl` only to that service, `SYSTEM`, and `Administrators`. The owner also verified the ancestor `C:\ProgramData\Ventio`: it is owned by `BUILTIN\Administrators`, has a protected ACL, grants `FullControl` to `SYSTEM` and `Administrators`, and grants only `ReadAndExecute` to the two Ventio services. No ordinary-user entries were present. The unresolved `HOST_DATABASE_RECOVERY_ROLE_ROTATION_FAILED` from the earlier partial installation remains open for recovery and database-upgrade acceptance; it does not invalidate a fresh Host setup.

## LAN reachability update (2026-11-01)

After installing the matching development installer and restarting the Host PC, the owner ran `Test-NetConnection HOST_PRIVATE_LAN_IP -Port 8443` from a second Windows device. The reported source address was `CLIENT_PRIVATE_LAN_IP`, the remote address was `HOST_PRIVATE_LAN_IP`, and `TcpTestSucceeded` was `True`. Post-reboot screenshots show both Ventio services running automatically under their intended identities and Host Settings preserving the LAN endpoint and authenticated session. This confirms the required standalone LAN and persistence checks. TCP testing does not test client-side certificate trust, Ventio pairing, or synchronization; no Client pairing is required for Host Standalone Readiness.

From the same `CLIENT_PRIVATE_LAN_IP` workstation, an HTTPS `GET /healthz` to `https://HOST_PRIVATE_LAN_IP:8443/healthz` returned `200` with `{"apiVersion":1,"status":"alive"}`. The probe used `curl --insecure`, so it did not validate the self-signed certificate fingerprint. This workstation also has its own `VentioHost` and `VentioPostgres` services running; it is valid for LAN/API reachability tests but is not a clean Client-only installation. No pairing or Host device registration was performed.

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
| Network listener before update | Bound to `127.0.0.1:8080`; no external TLS listener was configured or tested |
| Network listener after 2026-11-01 update | `0.0.0.0:8443`; local HTTPS `GET /healthz` returned `200`; inbound TCP 8443 is scoped to `LocalSubnet` on `Private` profile. |
| Owner Host after reboot | Screenshots show PostgreSQL and VentioHost `Running`/`Automatic` under intended identities and Host Settings retaining authenticated session and LAN HTTPS endpoint. |
| LAN reachability after reboot | From second device `CLIENT_PRIVATE_LAN_IP`, `Test-NetConnection HOST_PRIVATE_LAN_IP -Port 8443` returned `TcpTestSucceeded: True`. |
| Recovery Authority | Host Overview reported `READY`; the protected witness ACL could not be independently re-read from this non-elevated session |

These checks describe the engineering workstation's previously provisioned Host. No database, credential, or Recovery Authority reset was performed on it. They are distinct from the owner-provided fresh-install evidence below.

## Owner-provided clean Windows 11 installation and reboot evidence

The owner provided screenshots from a separate Windows 11 PC after installing development artifact `dist/windows/host-standalone-readiness-20261031/Ventio-Setup-0.1.0.exe` (SHA-256 `4697ae82da0993494b14979a842c9a2083312b9fef5ea5e8f18aaceb6234c6f7`). The screenshots are direct visual evidence, reviewed on 2026-10-31; they are not machine-collected logs.

| Check | Screenshot evidence |
|---|---|
| Fresh installation and first-run Host setup | Owner reported installer success. The Host Setup screen showed all six setup steps complete, including Windows setup approval, PostgreSQL, Ventio Host, first administrator, secure credential storage, and readiness. |
| Windows services after restart | Services console showed `Ventio Host Engine` and `VentioPostgres` as `Running`, `Automatic`, under `NT SERVICE\VentioHost` and `NT SERVICE\VentioPostgres`, respectively. |
| Host readiness after restart | Host Overview reported `READY`; authenticated Host API, PostgreSQL connection, schema/runtime profile, and Recovery Authority were each `READY`. |
| Administrator session after restart | Host Settings showed a verified Host session, protected credential-vault storage, the configured tenant/company/branch scope, and six Host-management grants. Identifiers and credential material are intentionally omitted from this report. |
| Flutter close/reopen | After restart, the owner closed Flutter and confirmed in Services that both Host services remained `Running`, then reopened Flutter. Host Overview reported `READY` and Host Settings showed a verified administrator session. |
| Local network binding | Host Settings showed `http://127.0.0.1:8080`. No LAN-facing listener, TLS certificate, or firewall exposure was shown or tested. |
| Recovery Authority witness ACL | Owner-provided elevated `Get-Acl` output for `C:\ProgramData\Ventio\Host\recovery.witness` and `C:\ProgramData\Ventio\Host` showed owner `NT SERVICE\VentioHost`, protected ACLs, and only explicit, non-inherited `Allow FullControl` entries for `NT SERVICE\VentioHost`, `NT AUTHORITY\SYSTEM`, and `BUILTIN\Administrators`. The parent product data root ACL is recorded in the next row. |
| Product data root ACL | Owner-provided elevated `Get-Acl` output for `C:\ProgramData\Ventio` showed owner `BUILTIN\Administrators`, a protected ACL, explicit non-inherited `FullControl` for `SYSTEM` and `Administrators`, and `ReadAndExecute` for `NT SERVICE\VentioHost` and `NT SERVICE\VentioPostgres`; no ordinary-user entries were present. |

This supports fresh graphical Host setup, service persistence through one Windows restart, Host access after closing/reopening Flutter, and the audited ACLs for the product data root, witness directory, and witness file on the separate PC. It does not demonstrate a physical Client connection, LAN/TLS readiness, or installer upgrade/repair/uninstall. No external Client was required or used for this standalone milestone.

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

Automated broker and service tests do not prove Windows behavior by themselves. Owner-provided screenshots and elevated PowerShell output provide evidence of one graphical fresh setup, post-reboot service/session checks, the product-data/Recovery Authority ACLs, and LAN TCP reachability after reboot. Client-side TLS trust and actual Client pairing remain untested, outside this milestone.

## Development installer artifact

- Path: `dist/windows/host-lan-ps51-fix-20261101-a/Ventio-Setup-0.1.0.exe`
- Version: `0.1.0`
- Size: `84,923,969` bytes
- SHA-256: `caa3af0261cc9ac1621d4ccd998b4277d90f1847b0e4df08c5c6b951d8212cfa`
- Authenticode status: `NotSigned`

The build checks confirmed the unified Host/Client payload and deferred database/service provisioning. The PostgreSQL runtime is bundled; the payload manifest states `databaseIncluded: false` and `credentialsIncluded: false`. The owner installed and exercised this artifact through Host first-run setup on a separate Windows 11 PC. It is unsigned and for development verification only, not commercial distribution.

## Remaining broader Wave 1 and release acceptance checks

1. Preserve the owner-provided screenshots, post-reboot service evidence, and cross-device TCP result as evidence of Host Standalone Readiness.
2. Validate actual Client pairing, client-side TLS fingerprint verification, and protected pairing routes in their separate acceptance task; no Client pairing was needed for this milestone.
3. On isolated copied data, independently diagnose `HOST_DATABASE_RECOVERY_ROLE_ROTATION_FAILED`. Do not reset credentials or reinitialize the existing Host to hide this defect. Recovery and database-upgrade acceptance remain open until its cause is fixed and verified.
4. Keep Client-only per-user installation, installer repair, data-retention uninstall, commercial signing, and Inno Setup commercial licensing as separate Stage 10/release checks. They were not accepted by this milestone.

No external Client pairing, multi-device synchronization, or Android test was required or performed for this standalone Host milestone.

## Official Wave 1 progress

At this milestone's original verification time, official accepted progress was **20%**: Stage 0 (4%), Stage 4 (9%), and Stage 7 (7%). Stage 1 and Stage 2 subsequently passed on 2026-11-02, so the current official accepted total is **40%**: Stages 0, 1, 2, 4, and 7. Stages 3, 5, 6, 8, 9, and 10 remain open or blocked according to their mandatory gates. This Host readiness milestone must not be treated as full Wave 1 acceptance.

## Owner-provided Windows 11 evidence and remaining checks

The supplied screenshots show successful Host setup, authenticated Host Settings, and post-reboot services on a separate Windows 11 PC. Additional evidence confirms that both services remained running while Flutter was closed and that Host access worked after reopening Flutter. The post-reboot remote TCP probe confirms the Host listener is reachable over LAN. Owner-provided elevated PowerShell output records the product data root, witness directory, and witness file ACLs. These are owner-provided visual and console evidence, not machine-collected logs; no secrets are exposed. Preserve the existing database and backups; do not use cleanup or reinitialization to address the unrelated recovery defect.

## Development-workstation state recheck (2026-11-02)

A later read-only query on the development workstation found the registered `VentioHost` and `VentioPostgres` services in `Stopped` state with `Automatic` start mode. `GET http://127.0.0.1:8080/healthz` was refused. No service was started, stopped, reconfigured, or removed, and no product data was changed. This records the workstation's state at recheck time; it does not erase the earlier owner-provided successful service/reboot evidence from the separate Windows 11 Host. It also does not establish why the development workstation services stopped. Stages 3 and 10 remain open for their full acceptance gates.
