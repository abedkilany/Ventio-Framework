# Host 0.1.18 Upgrade Failure — Root Cause and Correction

## Status

Root causes: **confirmed and reproduced** on the designated Host (`192.168.1.102`). The original failure was the PowerShell/.NET call that atomically replaced PostgreSQL's configuration file. A second occurrence of the same null-backup overload blocked Recovery Authority request rotation after the first fix. A subsequent controlled upgrade advanced through migration and Recovery Authority handling, then exposed an invalid function signature in the trusted helper's post-upgrade verifier. The first two failures were not caused by permissions, DPAPI encryption, or service identity; the follow-on is a verifier defect, not a migration or Recovery Authority protocol failure.

## Preserved pre-repair state

- Physical identity: computer UUID `4C4C4544-0051-5A10-8042-C4C04F343032`; account `abedkilany\abedkilany`.
- Installed application: Ventio `0.1.18`, install root `C:\Program Files\Ventio`.
- `VentioPostgres`: Running, Automatic, service identity `NT SERVICE\VentioPostgres`.
- `VentioHost`: Stopped, Automatic, service identity `NT SERVICE\VentioHost`.
- Original PostgreSQL config file: `C:\ProgramData\Ventio\PostgreSQL\data\postgresql.conf`; size 30,981 bytes; timestamp 2026-11-07 21:42:53 UTC. The failed operation did not change this file.
- Config ACL contains full control for SYSTEM, Administrators, and the VentioPostgres service SID. ACL inspection did not indicate a permissions failure.
- The failed run created the preserved pre-upgrade PostgreSQL 16.15 backup `ventio-postgresql-before-upgrade-20261108T193506653Z-16dabf5cda154b8fbec9ee8bbd00cf77`. Its manifest records 1,379 files / 51,093,333 bytes. The backup was retained.
- Sanitised Host diagnostics and backup manifest were copied to this evidence directory. No database payload, DPAPI file, Recovery Authority witness, credential, or private certificate key was read or copied.
- A targeted search found no installer log or matching Windows Application event retaining the original exception. Therefore the exact exception came from a controlled reproduction of the failing call, not from the installer log.

## Root cause evidence

At `scripts/windows/upgrade-host-database.ps1`, stage `DATABASE_POSTGRES_CONFIG_REPLACE` called:

```powershell
[IO.File]::Replace($temporaryConfig, $postgresConfig, $null, $true)
```

The same four-argument call was run on Host against disposable files in `C:\ProgramData\Ventio\Installer`, with the same ACL copied from the production PostgreSQL config. It failed:

```text
REPLACE_RESULT=FAIL
EXCEPTION_TYPE=System.Management.Automation.MethodInvocationException
EXCEPTION_MESSAGE=Exception calling "Replace" with "4" argument(s): "The path is not of a legal form."
INNER_TYPE=System.ArgumentException
INNER_MESSAGE=The path is not of a legal form.
```

The four-argument `File.Replace` overload does not accept a null backup path on the Host's Windows PowerShell/.NET runtime. The safe wrapper surfaced the generic stage code `HOST_DATABASE_POSTGRES_CONFIGURATION_REPLACE_FAILED`, which concealed that argument error.

## Follow-on failure found during the corrected installer retry

The first retry initially stopped before updating files because the existing Host-session process `ventio_native_client.exe` held `C:\Program Files\Ventio\flutter_secure_storage_windows_plugin.dll`. The Inno log records four `DeleteFile failed; code 5. Access is denied.` retries, then rollback. The process ran as `ABEDKILANY\AbedKilany`, Session 1, with no main-window handle; it was terminated under the authorized test-machine app-restart scope. The installer then completed file installation.

The corrected config replacement passed, but the database helper safely stopped at `HOST_SCHEMA_UPGRADE_REQUEST_CREATE_FAILED`, stage `RECOVERY_AUTHORITY_REQUEST_CREATE`. The existing DPAPI-protected request was retained without reading its contents. The code review showed the same invalid call in `New-HostSchemaUpgradeRequest` when rotating an existing request:

```powershell
[IO.File]::Replace($tempPath, $requestPath, $null, $true)
```

An existing pending request had been left by the just-failed corrected installer run. A direct supported helper run with `-ExecutionPolicy Bypass -FailureCodePath` captured:

```text
HOST_DATABASE_UPGRADE_SAFE_FAILURE=HOST_SCHEMA_UPGRADE_REQUEST_CREATE_FAILED
HOST_SCHEMA_UPGRADE_REQUEST_CREATE_FAILED
STAGE=RECOVERY_AUTHORITY_REQUEST_CREATE
```

The helper had completed the protected backup, PostgreSQL restart, prepared-transaction preflight, migrator-profile preflight, migration payload inventory, and connection configuration before failing while attempting to atomically refresh that existing encrypted request. It had not yet started the Host service to process the request or applied schema migrations.

## Correction

All affected Windows setup paths now provide a unique same-directory `*.replace-backup` path to `File.Replace`: PostgreSQL config, Recovery Authority request, migration credential, and Host service config. This keeps each replacement on the same volume, preserves the old file in the atomic operation, and removes the transient backup after success or failure. The existing PostgreSQL config is only updated by the normal upgrade flow after verified backup and service stop.

Regression procedure:

1. `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/windows/test-host-postgres-config-replace.ps1`
   - Observed: `HOST_POSTGRES_CONFIG_REPLACE_PASS`.
2. Repeat the corrected call on Host with disposable files and the PostgreSQL config ACL.
   - Observed: `HOST_CONFIG_REPLACE_WITH_BACKUP=PASS`, `BACKUP_CONTENT=baseline`, `DESTINATION_CONTENT=replacement`.
3. Repeated replacement contracts and the credential/config writer regression tests passed on the elevated Host:
   - `HOST_POSTGRES_CONFIG_REPLACE_PASS`
   - `HOST_MIGRATION_CREDENTIAL_REPLACE_PASS`
   - `HOST_CONFIG_PROTECTED` twice, then `HOST_CONFIG_WRITER_EXISTING_FILE_REPLACE_PASS`
4. Original failed Host config, backup, PostgreSQL database, and Recovery Authority files were not reset. The Host service remains stopped pending successful completion of the upgrade.

## Follow-on verifier failure and correction

The `wave1fix2` installer replaced the PostgreSQL config and rotated the protected Recovery Authority request. The trusted Host helper then reported `UPGRADE_FAILED` at `POST_UPGRADE_CONTRACT_VERIFICATION`. Its result is preserved in `host-wave1fix2-service-start/schema-upgrade-result.json`; the installer log, PowerShell transcript, and backup manifest are alongside it. The backup records PostgreSQL 16.15, 1,384 files, and 68,435,592 bytes.

Read-only verification using the protected migration credential (without outputting the credential or database contents) established:

- `ventio_security.assert_schema()` passed.
- The migration ledger count was 35; the installed payload contains 35 migration files.
- Host upgrade receipt RLS and forced RLS were both enabled.
- The required credential-reissue RLS flags and both recovery triggers were present.
- The pairing contract verifier returned `t`.
- The credential-reissue verifier query failed because `trusted_windows_host_upgrade.dart` queried `credential_reissue_pending_claim(text,text)`, while the declared function signature is `credential_reissue_pending_claim(text)`. PostgreSQL returned `function ... does not exist`.

The trusted helper now uses the declared one-argument signature. `test-unified-installer-path-contract.ps1` has a regression assertion that rejects the incorrect signature. The correction is included in the new `wave1fix3` Host payload candidate. The prior pending request and database state are preserved for idempotent retry with the same operation identifier.

The `wave1fix3` retry completed the preserved operation (`status: complete`) and supported post-upgrade database checks passed. Host service startup then failed. The first check lacked a precise safe stage. A new `wave1fix4` service diagnostic recorded only:

```json
{"formatVersion":1,"occurredAtUtc":"2026-11-08T22:59:03.7583406+00:00","stage":"HOST_ENGINE_READINESS","exceptionType":"InvalidOperationException","hresult":-2146233079}
```

This establishes that service configuration, bootstrap broker startup, Recovery Authority request processing, and receipt read completed far enough for the service to launch the Host Engine process. It did not report `VENTIO_HOST_READY` before the Host process exited or readiness timed out. `wave1fix4` also completed its new schema-upgrade operation (`upgrade_801537f1f84f4a80b134377437aeb9c0`) with status `complete`; its backup manifest, installer log, sanitized result, and startup diagnostic are preserved under `host-wave1fix4-readiness/`. The current source refines this boundary to distinguish early child exit, readiness timeout, broker exit, or service cancellation and records the Host process exit code when available. It does not log child output, exception text, database URLs, or file paths.

The `wave1fix5` retry confirmed an early child-process exit, rather than a readiness timeout:

```json
{"formatVersion":1,"occurredAtUtc":"2026-11-08T23:08:49.1540366+00:00","stage":"HOST_ENGINE_EXITED_BEFORE_READY","exceptionType":"InvalidOperationException","hresult":-2146233079,"hostProcessExitCode":2}
```

Its upgrade operation (`upgrade_e53a6210ce914d52a1cc6fea4228ef95`) completed, but the spawned `ventio_host.exe` exited with code 2 before emitting the readiness marker. The source refinement in `wave1fix6` enables the existing Host test diagnostic output internally, but stores only the failure type and a validated five-character SQLSTATE in the service diagnostic; it discards the diagnostic text. This should separate authentication, permission, and other Host startup failures without exposing connection strings or PostgreSQL messages.

## Remaining verification

The corrected verifier and repeated upgrade requests complete, but Host Engine readiness remains unresolved. Full Host readiness, data-preservation acceptance, reboot persistence, clean first-run setup, and physical Host–Client acceptance remain open. Do not mark the installer upgrade accepted until startup succeeds and the supported readiness checks pass.

## Closure follow-up — 2026-11-09

Wave1fix6 captured PostgreSQL SQLSTATE 42883 for the Host Engine exit. Wave1fix7 exposed a mismatch between the child diagnostic format and service parser; Wave1fix8 corrected the punctuation and confirmed SQLSTATE capture. Its safe diagnostic still did not identify a function/operator name. Wave1fix9 adds allowlisted routine/operator metadata capture and built successfully, but its Host transfer/installation is unverified. A correction was appended to the execution history because an earlier pending command was initially mistaken for successful Wave1fix9 installation; the last verified Host checkpoint is Wave1fix8.

The exact Host Engine undefined-function source remains unresolved. On the last successful Host inspection, VentioHost was stopped with exit code 2, VentioPostgres was running, and schema operation upgrade_f02bfc8366c543778995177a00ed842c had status complete. Subsequent SSH requests timed out during banner exchange; no more recent service state is claimed. Computer Use could enumerate the Host RDP window but reports it minimized and cannot activate it, so visual Host Overview evidence is unavailable.

## Closure follow-up — 2026-11-09, Wave1fix11

The exact undefined routine was established from PostgreSQL Application event record 2783 (`missing-extension-function-postgres-event.xml`). Host startup ran a `has_function_privilege` probe for `ventio_security.list_extension_submissions(text,text,text,text,integer)` and PostgreSQL returned SQLSTATE `42883`: that function did not exist. The routine definition was already present in `security/postgres/extensions.sql`, included by fresh-install `bootstrap.sql`, but absent from the in-place migration sequence. Thus fresh setup and upgraded installations diverged: an upgraded database could pass the schema assertion and migration ledger checks yet fail the Host role-profile probe at startup.

The correction adds migration `036_scoped_extension_runtime.sql`. It conditionally replays the ten current extension runtime function definitions and their intended ACLs only when the extension schema and package table exist, so a new empty database that runs migrations before bootstrap safely skips the migration. Migration 036 is included in the approved schema-profile manifest. A recovery-authority regression removed `list_extension_submissions`, coordinated migration through 031–036, and verified function restoration, intended execute grants, no PUBLIC execute, and identity-row preservation. **22 checks passed.** The test also exercises stale-witness fail-closed behavior, interruption, lost acknowledgement, and prepared-transaction reconciliation. Canonical migration SHA-256: `50147943077d691d9ac9685eb34efaf062c2022fe88a652de2cd480211fa5244`.

The installed `0.1.18+19` Wave1fix11 upgrade then completed on Host. Before reboot, `VentioPostgres` and `VentioHost` were Running/Automatic under their dedicated virtual service accounts; the installed Host returned HTTPS `/healthz` with `{"apiVersion":1,"status":"alive"}`. The LAN listener helper was applied after stopping the Host service; listener metadata and the Private-profile inbound firewall rule were verified, and the pinned certificate matched. The Host was rebooted to check startup persistence. After reboot, Development could not reach Host TCP 22 or 8443; TCP 3389 was open at the earlier post-reboot probe. The final bounded recheck still found 22 and 8443 unavailable. Therefore reboot persistence is **BLOCKED — ENVIRONMENT** and the current post-reboot service state cannot be asserted.

Client `0.1.18+19` installation succeeded and its installer SHA-256 matched the Host/development artifact. Before Host reboot, Client `curl --cacert` to the pinned Host certificate and IP endpoint returned `{"apiVersion":1,"status":"alive"}`. The supported Windows `trust-host-certificate.ps1` flow failed normal Windows certificate validation; its helper removed the attempted TrustedPeople entry, and the separate Root-store attempt was rejected by Windows as unsupported. No TLS validation bypass was used. This trust-flow failure remains open for Stage 8.

The same installed failure class that Wave1fix11 corrected has not yet been re-observed after reboot because the Host management/HTTPS ports are unavailable. The Host Overview readiness and version remain visually unverified: Computer Use could enumerate the RDP window but could not activate it. Installed version `0.1.18+19` is established from CLI/file evidence only, not the requested visual Overview.

## Closure follow-up — resumed Wave1fix12 checkpoint, 2026-11-09

The previous post-reboot SSH gap is now explained by Host event chronology. System event 1074 records the controlled restart at 02:57:12 with comment `Ventio Wave 1 automatic service startup verification`; `LastBootUpTime` is 02:57:40. OpenSSH Operational logged termination at 02:57:30 and listeners restored at 02:57:53. `sshd`, `VentioPostgres`, and `VentioHost` processes started at 02:57:53, 02:57:53, and 02:57:55 respectively. The `sshd` start mode had been changed from demand-start to Automatic at 2026-11-08 22:29:59 and is currently Automatic/Running. This supports that the failed port probes observed the controlled reboot window, not a persistent service/authentication defect. No failed public-key authentication appears in the sampled events. Current Host HTTPS `/healthz` returns `{"apiVersion":1,"status":"alive"}` with the preserved pinned certificate.

After the Host was reachable, the Windows trust helper’s original `Invoke-WebRequest` failure was reproduced again against live Host HTTPS. A first strict PowerShell callback attempt also failed with an underlying send error and was not retained. The supported approach now uses `curl.exe --cacert` with the fingerprint-confirmed certificate after validating its exact SHA-256, SAN, validity, and ServerAuth EKU. It performs no redirect and requires the alive response; it uses no `-k`, `--insecure`, or permissive callback. Seven disposable certificate checks passed, the installer path-contract suite passed, and the updated helper returned `TRUSTED_AND_VALIDATED` on the physical Client against the live Host.

The Client local queue database snapshot (main DB plus existing WAL/SHM) was inspected read-only after confirming the app process was not running. The only table is `local_commands`; `SYNC-TEST-001` is absent. No queue state was changed. A same-version 0.1.18 Client repeat install then exited 0, with Inno logging installation success/no reboot. SHA-256 of the queue DB and both sidecars was unchanged after reinstall. The Client’s Host certificate remains in its current-user `TrustedPeople` store as intended; temporary helper/certificate/installer copies used for testing were removed from Client `%TEMP%` after their logs were preserved.

Host and Client registry entries report product version `0.1.18`; the Host Overview UI’s displayed version/readiness remains unverified. Computer Use has no current RDP window, and activation of the refreshed Explorer target failed; its required recovery attempt returned `GetCursorPos failed: Access is denied. (0x80070005)`. No service, database, or Ventio application settings were changed during this resumed diagnostic checkpoint. The repeat-install case was on Client only and preserved local SQLite hashes.

## Resumed Host access and reboot correlation — 2026-11-09

A fresh SSH login using the existing key now succeeds to `192.168.1.102`. The prior failed probes correlate with the explicitly initiated reboot window in the event timeline above: sshd terminated during shutdown and restored its listeners after startup. Current `sshd`, `VentioHost`, and `VentioPostgres` services are Running/Automatic; service identities and protected service-data ACLs were checked read-only. Pinned HTTPS `/healthz` returned HTTP 200 and the alive response. No current evidence indicates a persistent SSH authentication or configuration failure. The Host Overview and authenticated application readiness have not been visually/authenticatedly checked, so this does not close those UI/readiness gates.

## Resumed Host Wi-Fi outage and management-readiness boundary — 2026-11-09

More complete post-reboot event records supersede the earlier generic reboot-window attribution. OpenSSH listened at 12:47:34 and accepted the Development public key at 12:47:54; the Host Wi-Fi profile disconnected at 12:48:13, briefly re-associated at 13:19:10, disconnected again at 13:19:13, and obtained its current DHCP lease at 13:20:42. The Windows WLAN driver events at the disconnect/reassociation times have no retrievable event message; `NdisImPlatform/Operational` has no matching records. Thus the long reachability loss correlates with Host Wi-Fi disconnection and delayed DHCP, but the adapter/AP/driver trigger remains unknown. No network configuration was changed.

Current read-only SSH checks verify High Integrity SID `S-1-16-12288`, installed 0.1.18, and `sshd`, `VentioHost`, and `VentioPostgres` Running/Automatic, with listeners on 22, 3389, and 8443. Pinned HTTPS `/healthz` returns HTTP 200 `alive`. A pinned TLS request to `/api/v1/management/readiness` without credentials returned HTTP 401 `UNAUTHENTICATED`, correlation `cor_5155fe4fc4906d4d22f06c7019b3ecd6`; this is only an authentication-denial result, not application readiness.

Computer Use opened Host RDP and the remote session is Active for `abedkilany` (`rdp-tcp#0`), but screenshot capture fails with `foreground window did not report a process id`, including after refreshing the target. Therefore Host Overview/version remain visually unverified. Full diagnostic detail is in [Host reboot connectivity investigation](host-reboot-connectivity-investigation-2026-11-09.md).

## Host sleep cause and corrected reboot regression — 2026-11-09

Kernel-Power event 42 identifies the two outages as system sleep transitions with reason `Button or Lid`; Power-Troubleshooter event 1 reports `Power Button` as the wake source on both occasions. NDIS/WLAN low-power and disconnect events align with the transitions. The previous AC/DC idle sleep timeouts were already Never, so inactivity timeout was not responsible. The exact physical lid-versus-button input cannot be distinguished from Windows' combined event reason.

Before correction, the Balanced plan set AC and DC lid-close and power-button actions to Sleep (index 1). Because this is the dedicated Host and it was AC-online, only its AC lid-close and power-button actions were changed to Do nothing (index 0); the DC values remained Sleep (index 1). A controlled reboot then recovered SSH on the first bounded attempt; `sshd`, `VentioHost`, and `VentioPostgres` were Running/Automatic, pinned HTTPS `/healthz` returned HTTP 200/TLS verification 0, the new AC values persisted, and no Kernel-Power sleep event occurred after waiting beyond the previous ~53-second post-boot transition. This verifies the power correction against the prior failure mode. It does not verify authenticated Host readiness or visible Overview. Full evidence: [Host reboot connectivity investigation](host-reboot-connectivity-investigation-2026-11-09.md).
