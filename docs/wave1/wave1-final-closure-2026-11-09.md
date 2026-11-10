# Wave 1 Final Closure — 2026-11-09

**Final decision (2026-11-11): PASS — Wave 1 internal engineering acceptance is closed at 100%.** Stage 9 passed the scoped audit. See the [formal ledger](final-acceptance-report.md) and [final audit](final-audit-preparation-20261102.md). Production distribution remains blocked. The following is the chronological closure history beginning with the 60% checkpoint on 2026-11-09.

## Closure status

| Stage | Status | Verified evidence / outstanding gate |
|---|---|---|
| 10 — Windows Installer & Host Provisioning | **FAIL — REPRODUCED / OPEN** | The installed 0.1.18 Host upgrade repeatedly completed its Recovery Authority schema-upgrade operation, but the Host Engine exited with code 2 before readiness and PostgreSQL SQLSTATE `42883`. The original config-replacement failure and subsequent verifier signature defect were corrected. Exact startup routine mismatch, Host readiness, service/reboot persistence, repair/retention, and remaining mandatory operational cases are unresolved. |
| 3 — Unified First-Run Setup | **NOT TESTED — OPEN** | No real installed first-admin/setup-resume/interruption/failure-export/reboot lifecycle was completed in this closure run. Existing Stage 3 evidence remains as previously recorded and does not close its installed lifecycle requirements. |
| 8 — End-to-End Validation | **NOT TESTED — OPEN** | No physical Host–Client acceptance sequence was run in this closure. No claim is made for physical multi-device propagation or Android hardware. |
| 9 — Final Engineering Audit & Acceptance | **NOT TESTED — OPEN** | The final audit cannot accept Stages 10, 3, or 8 while their required acceptance evidence is incomplete. |

## Root cause and corrections

The original `HOST_DATABASE_POSTGRES_CONFIGURATION_REPLACE_FAILED` was reproduced on the Host: PowerShell/.NET Framework rejected `[IO.File]::Replace(temp, destination, $null, $true)` with `ArgumentException: The path is not of a legal form.` The same null-backup overload was present in Recovery Authority request rotation, migration-credential replacement, and Host service configuration replacement. These paths now create a unique same-directory backup and clean up the transient backup. Host disposable regression procedures passed, including replacement of an existing protected credential/config file.

A later trusted schema-upgrade verifier queried `credential_reissue_pending_claim(text,text)` while the installed function contract declares `credential_reissue_pending_claim(text)`. That verifier signature was corrected and a source contract regression was added. Subsequent upgrades completed with status `complete`; the migration ledger and read-only schema/security checks passed.

The remaining installed startup failure is separately reproduced as Host Engine exit code 2 / SQLSTATE `42883` (`undefined_function`). `assert_runtime()` and the read-only schema assertions passed. The exact missing function/operator is **not yet established**. A diagnostic formatting mismatch initially prevented SQLSTATE capture; Wave1fix8 corrected it. Wave1fix8 still produced no routine metadata, so Wave1fix9 adds allowlisted routine/operator metadata capture. Wave1fix9 was built and locally validated, but its Host installation and transfer hash verification could not be completed after the Host SSH daemon stopped providing its SSH identification banner. Do not treat Wave1fix9 as installed or as a correction to the startup defect.

## Verified installation and build evidence

- Host physical UUID: `4C4C4544-0051-5A10-8042-C4C04F343032`.
- Client physical UUID: `9EB7F117-F40D-11DE-81D0-B9F76E398C6C`. The duplicated Windows hostname is not evidence of a duplicate machine; UUIDs differ.
- Last verified Host state after Wave1fix8: Ventio version `0.1.18`; `VentioPostgres` Running/Automatic under `NT SERVICE\VentioPostgres`; `VentioHost` Stopped/Automatic under `NT SERVICE\VentioHost`; schema-upgrade operation `upgrade_f02bfc8366c543778995177a00ed842c` reported `complete`; startup diagnostic reported `HOST_ENGINE_EXITED_BEFORE_READY`, exit code 2, SQLSTATE `42883`.
- Wave1fix9 installer candidate: [Ventio-Setup-0.1.18.exe](../../artifacts/ventio-windows-acceptance-0.1.18-wave1fix9-20261109/installers/unified/Ventio-Setup-0.1.18.exe), SHA-256 `ee8ff4e5ea2106f91f703fd557ece54546bea37f1669846f7ff0bd6b8e4f0daf`.
- Wave1fix9 Host payload: 1,706 files / 311,258,609 bytes; PostgreSQL 16.15. Microsoft Visual C++ x64 Redistributable 14.51.36247.0 was Authenticode-verified. Installer machine-wide host setup boundaries, stage-A no-database/no-service provisioning checks, Visual C++ prerequisite checks, and path-contract regression passed.
- The Wave1fix9 installer checksum is verified on Development. Its copy/install state on Host is **unverified**. The prior Wave1fix8 installer log, schema result, startup diagnostic, and protected backup manifest are preserved under `evidence-closure-2026-11-08/host-wave1fix8-readiness/`.

## Access and visual verification limitations

Direct SSH to Host `192.168.1.102` began timing out. A proxy jump through Client `192.168.1.105` briefly allowed read-only Host diagnostics, but later Host SSH connections timed out during banner exchange. From Client, TCP probes observed Host ports 22 and 3389 open and 5985 closed; a raw SSH banner read then timed out. Computer Use enumerated the existing Host Remote Desktop Connection window, but the window is minimized and the documented Computer Use interface could not activate it. Therefore the Ventio Host Overview, visible readiness status, and displayed application version were not visually verified in this closure. SSH/service results are not substituted for that UI evidence.

## Functional implementation vs. acceptance

- **Functional implementation completed:** the original replacement-overload defect and the trusted verifier signature defect were corrected in source; isolated regression coverage was added.
- **Automated verification completed:** focused replacement and installer path/build checks passed; the Host’s post-upgrade schema checks passed read-only.
- **Physical operational acceptance completed:** partial only. An installed Host upgrade reached completed schema-upgrade state, but Host Engine readiness failed. The physical Host–Client enrollment/offline/sync/receipt/readback sequence was not run in this closure.
- **Formal stage acceptance completed:** none of Stages 10, 3, 8, or 9. Formal Wave 1 progress remains **60%**.

## Recommended next action

Restore a responsive Host management channel (SSH banner or usable RDP window), verify whether the Wave1fix9 installer exists on Host and compare its SHA-256, then collect the new allowlisted undefined routine/operator diagnostic. Correct that confirmed startup contract issue and rerun the Host upgrade. Only after Host readiness passes should the installed Stage 3 setup lifecycle and full physical Stage 8 cycle run, followed by Stage 9 audit.

## Superseding checkpoint — Wave1fix11 (2026-11-09)

This section supersedes the Wave1fix9-specific “exact routine unresolved” and “last Host state” statements above. Formal progress remains **60%**, as the accepted stage ledger in `final-audit-preparation-20261102.md` records Stages 0, 1, 2, 4, 5, 6, and 7 accepted; no open-stage weight is credited.

| Stage | Latest disposition |
|---|---|
| 10 — Windows Installer & Host Provisioning | **OPEN — partial pass, reboot persistence blocked.** Wave1fix11 installed as 0.1.18+19; before reboot both Ventio services ran under their dedicated virtual service accounts and the Host HTTPS health endpoint returned alive. The reboot check could not reach Host SSH 22 or HTTPS 8443. Remaining Stage 10 mandatory cases have not all been exercised. |
| 3 — Unified First-Run Setup | **OPEN — NOT TESTED.** The required real installed first-admin, interruption/resume, retry/idempotency, failure-reporting, and restart lifecycle was not completed. |
| 8 — End-to-End Validation | **OPEN — partial physical connectivity only.** Client 0.1.18+19 was installed; pinned-certificate `curl --cacert` health succeeded before Host reboot. Supported Windows certificate trust helper failed normal OS certificate validation. No enrollment-through-receipt-and-independent-readback sequence was completed. |
| 9 — Final Engineering Audit & Acceptance | **OPEN — NOT ACCEPTED.** Requires closure of all mandatory acceptance gates and review of this closure’s changes. |

### Confirmed cause and correction

The original `HOST_DATABASE_POSTGRES_CONFIGURATION_REPLACE_FAILED` was fixed by passing a unique same-directory backup path to .NET `File.Replace`; focused regression passed. Separately, PostgreSQL event record 2783 established the later Host startup cause: SQLSTATE 42883 because `ventio_security.list_extension_submissions(text,text,text,text,integer)` was missing from upgraded databases. The current function existed in fresh bootstrap SQL but not in the installed migration chain. Migration 036 now conditionally restores all ten scoped extension runtime functions with intended ACLs, and the approved manifest includes it. A regression removes the routine, performs the Recovery Authority upgrade, and verifies restoration, ACL boundaries, and identity-row preservation: **22 checks passed**. Analyzer and installer path-contract checks passed. These source and isolated-test results do not by themselves constitute physical acceptance.

### Physical evidence and limitations

- Wave1fix11 installer SHA-256: `89D36270CE0D595286D09EED5FE030182E3A3E2C9B1750A52ABE3410790BB568`; Host and Client copies matched the development artifact.
- Host upgrade completed and returned `{"apiVersion":1,"status":"alive"}` over HTTPS before reboot. LAN listener metadata, Private firewall rule, and certificate fingerprint were verified. After reboot, TCP 22 and 8443 remained unavailable from Development; service state is unknown. The earlier probe found TCP 3389 open.
- Client install succeeded at `0.1.18+19`. Before Host reboot, Client’s pinned-certificate HTTPS health request succeeded. The supported Windows trust helper failed default certificate-chain validation; the helper rolled back the attempted TrustedPeople entry, and a Root-store import attempt was rejected as unsupported. No TLS bypass was used.
- Computer Use could enumerate the Host RDP window but could not activate it (“failed to activate captured window” / unavailable input geometry). Therefore visible Host Overview readiness and version are unverified. `0.1.18+19` is only CLI/file evidence.
- Physical machine UUIDs differ: Host `4C4C4544-0051-5A10-8042-C4C04F343032`; Client `9EB7F117-F40D-11DE-81D0-B9F76E398C6C`, despite duplicate hostname text.

See the [Wave1fix11 evidence record](evidence-closure-2026-11-08/wave1fix11-acceptance-evidence.md), [root-cause follow-up](evidence-closure-2026-11-08/host-upgrade-root-cause-2026-11-09.md), [migration regression log](evidence-closure-2026-11-08/host-schema-upgrade-disposable-regression-wave1fix10.log), and [standalone progress dashboard](../progress/wave1-host-client-progress.html). The dashboard is regenerated with `python scripts/wave1/update_progress_dashboard.py` after updating its JSON state; it is a static HTML file and does not self-refresh.

### Final closure recommendation

**Do not close Wave 1.** Functional corrections and focused automated verification are complete for the identified defects. Physical operational acceptance is partial; Host reboot persistence, Windows certificate trust, Stage 3 lifecycle, and the full Stage 8 physical sync sequence remain open. Formal stage acceptance remains 60%. Resume when Host management access returns, verify service startup and Host Overview, resolve the supported trust workflow, complete Stage 10 and Stage 3, then run Stage 8 before the Stage 9 audit.

## Resumed checkpoint — Wave1fix12 (2026-11-09)

The previous blocker has changed: SSH access to Host has returned and its post-reboot operational state is now verified. Formal accepted progress remains **60%**; no previously accepted stage was reopened or reweighted.

- Host SSH using the existing key exited 0: `ABEDKILANY`, `abedkilany\AbedKilany`, High Integrity SID `S-1-16-12288`, UUID `4C4C4544-0051-5A10-8042-C4C04F343032`.
- `sshd`, `VentioHost`, and `VentioPostgres` are Running/Automatic under `LocalSystem`, `NT SERVICE\VentioHost`, and `NT SERVICE\VentioPostgres`, respectively. Host TCP 8443 is listening, and pinned HTTPS `/healthz` returns `{"apiVersion":1,"status":"alive"}`.
- Restart event and process-start timestamps show expected downtime during the controlled reboot. OpenSSH and Ventio services started automatically after boot. The earlier SSH timeout probes occurred in that reboot interval; no persistent SSH authentication/configuration defect was found in sampled logs.
- Host/Client registry product version is `0.1.18`. The Flutter build package source is `0.1.18+19`. Host Overview readiness and its displayed version are **not visually verified**.
- Client queue DB and WAL/SHM were inspected in read-only SQLite mode while its app was not running. `SYNC-TEST-001` is absent; no Client database files were modified.
- The original Windows PowerShell certificate trust flow still failed with live Host HTTPS. Its corrected `curl.exe --cacert` flow passed seven disposable certificate checks and returned `TRUSTED_AND_VALIDATED` on the physical Client using the confirmed Host fingerprint.
- A same-version Client repeat install exited 0, Inno reported installation success/no reboot, and all three local SQLite DB/WAL/SHM SHA-256 hashes remained unchanged.
- Computer Use could not activate the current desktop target. Following the single refreshed selection retry, the helper returned `GetCursorPos failed: Access is denied. (0x80070005)`; Host Overview UI verification remains blocked.

### Current stage disposition

| Stage | Status |
|---|---|
| 10 — Windows Installer & Host Provisioning | **OPEN — partial pass.** The installed Host is running after reboot with live pinned HTTPS health. A repeated Client install passed with local SQLite data unchanged. Fresh Host install, Host repair/recovery, data-preserving Host upgrade assertions, uninstall retention, permission/failure matrix, and remaining offline integration scenarios are not all closed. |
| 3 — Unified First-Run Setup | **OPEN — NOT ACCEPTED.** Installed first-admin, resume/interruption/idempotency, setup-failure export, and first-run UI readiness lifecycle remain unverified. |
| 8 — End-to-End Validation | **OPEN — partial pass.** Physical Client trust and Host HTTPS pass; the specified historical record is absent. Application pin update, physical enrollment, extension approval, offline creation/sync, Host receipt, and independent readback remain unverified. |
| 9 — Final Engineering Audit & Acceptance | **OPEN — NOT ACCEPTED.** Required earlier gates remain incomplete and the final audit has not been accepted. |

Detailed evidence: [Wave1fix12 resumed checkpoint](evidence-closure-2026-11-08/wave1fix12-resumed-checkpoint-2026-11-09.md), [Host live read-only check](evidence-closure-2026-11-08/host-wave1fix12-current-check.log), [pinned TLS regression log](evidence-closure-2026-11-08/pinned-tls-regression-wave1fix12.log), [Client trust helper result](evidence-closure-2026-11-08/client-host-trust-helper-wave1fix12.log), [Client repeat-install log](evidence-closure-2026-11-08/client-repeat-install-installer-wave1fix12.log), and [Client post-install data check](evidence-closure-2026-11-08/client-repeat-install-postcheck-wave1fix12.log).

The Wave1fix11 installer remains the latest verified Windows build: SHA-256 `89D36270CE0D595286D09EED5FE030182E3A3E2C9B1750A52ABE3410790BB568`. The trust helper change is a separate support-script correction and does not alter that installer binary. Wave 1 remains open at 60%; do not declare final closure.

## Additional access verification

A fresh SSH check to Client 192.168.1.105 succeeded: `hostname` → `AbedKilany`; `whoami` → `abedkilany\abedkilany`; `whoami /groups` included `Mandatory Label\High Mandatory Level` / `S-1-16-12288`; UUID `9EB7F117-F40D-11DE-81D0-B9F76E398C6C`. The Host UUID remains distinct at `4C4C4544-0051-5A10-8042-C4C04F343032`. A fresh Host SSH attempt via Client still timed out during SSH banner exchange, so current Host state could not be re-read.

## Current Host operational recheck — 2026-11-09

A fresh SSH connection to Host `192.168.1.102` with the existing key exited 0 and verified `ABEDKILANY`, `abedkilany\abedkilany`, and High Integrity `S-1-16-12288`. `sshd`, `VentioHost`, and `VentioPostgres` are Running/Automatic; the Host listener on 8443 is active; pinned HTTPS `/healthz` returned HTTP 200 with `{"apiVersion":1,"status":"alive"}`. Product registry version is 0.1.18. Read-only ACL inspection verified protected ProgramData, Host, and PostgreSQL data roots with expected SYSTEM, Administrators, and service access. This confirms the prior connection gap was temporary and that service startup persisted through the controlled reboot. It does **not** establish authenticated readiness or the visual Host Overview. The full output is preserved in [Host current check](evidence-closure-2026-11-08/host-wave1fix12-current-check.log). The accepted ledger is still 60%; Stages 10, 3, 8, and 9 remain open.

### Fresh Computer Use check — 2026-11-09 09:28 UTC

A fresh Computer Use inventory showed no Remote Desktop Connection window. The only Explorer window was minimized; binding it returned “window is minimized”, and launching the Explorer inventory app returned the same window without creating a fresh desktop window. The Host shortcut could not be opened through the available graphical control, so Host Overview readiness and GUI-displayed version remain **BLOCKED — ENVIRONMENT / NOT VISUALLY VERIFIED**. Host CLI and pinned HTTPS evidence above is reported separately and is not substituted for the UI requirement.

## Wave1fix13 Host UI checkpoint — 2026-11-09

RDP to `192.168.1.102` succeeded. The remote Command Prompt visibly returned `AbedKilany`; Ventio opened with title `ventio native client`. Home showed `Host profile selected · AB`, `Selected scope: CD / EF`, and `Host access requires a verified session`. Host Setup showed PostgreSQL and Ventio Host Running, but all six setup progress indicators were empty; tenant/company/branch inputs were blank and **Set up Host** was disabled. Host Settings displayed `https://ABEDKILANY:8443`, `https://192.168.1.102:8443`, and the known certificate fingerprint. No application version was visible in the inspected UI.

The Host Overview route is gated on a persistent identity with `host.status.read` for the exact scope. No such verified session was present, so Overview readiness/version remain **BLOCKED — ENVIRONMENT / NOT VISUALLY VERIFIED**. No credential was entered and setup was not initiated. These observations are preserved in [Host UI evidence](evidence-closure-2026-11-08/host-wave1fix13-ui-evidence-2026-11-09.md).


## Wave1fix15 physical follow-up — 2026-11-09

Host and Client share the text name `AbedKilany`, but fresh read-only checks confirm distinct UUIDs and MachineGuids. The Host was healthy before a controlled Stage 10 reboot: its two Ventio services were Running/Automatic under their virtual service accounts, and loopback HTTPS health returned HTTP 200. After the accepted reboot request, ICMP, SSH, RDP, and HTTPS remained unreachable through the bounded recovery poll. Post-boot service state is unknown; Stage 10 reboot persistence is `BLOCKED — ENVIRONMENT`, not a verified service failure. Exact output: [Host reboot probe log](evidence-closure-2026-11-08/host-wave1fix15-reboot-probes.log).

The Client's preserved queue database contains one `PENDING` `extension.record.create` command, attempt count 0, whose envelope contains historical identifier `SYNC-TEST-001`. Its payload was omitted and the command was not modified. Queue database and WAL/SHM copies are preserved in [Client queue evidence](evidence-closure-2026-11-08/client-queue-preservation-20261109.json). The Wave1fix15 same-version 0.1.18 repeat installer exited 0 on the physical Client; its installer log is retained and SHA-256 hashes for the SQLite/WAL/SHM files and opaque secure-storage file were unchanged before/after. This closes only the repeated Client install/local-data-retention procedure, not Host upgrade data preservation or physical synchronization.

Host RDP remained at the Windows secure lock screen. Computer Use could not activate the Client RDP dialog (`failed to activate captured window`). No GUI state was altered. The installed Host Setup retry, Host Overview readiness/version, and physical Host–Client enrollment/extension/offline-sync/receipt/readback sequence therefore remain unverified. Stages 10, 3, 8, and 9 remain open; accepted Wave 1 progress remains 60%.


## Stage 9 targeted review — 2026-11-09

The final closure changes in this checkpoint were reviewed in source. The existing-profile setup path now forwards only the validated Host transport error code into the sanitized setup diagnostic; the focused Host Setup suite had passed 26/26 with targeted analysis clean. The installer now calls the supported Host-stop helper after Recovery Authority migration and before the LAN helper's stopped-service precondition. The path-contract regression asserts that ordering.

Recheck output:

```text
UNIFIED_INSTALLER_HOST_PROGRAM_FILES_PATH_CONTRACT_PASS
UNIFIED_INSTALLER_SHARED_FLUTTER_FIRST_RUN_HOST_CLIENT_CHOICES_PASS
UNIFIED_INSTALLER_HOST_PROVISIONING_DEFERRED_TO_FLUTTER_PASS
git diff --check: exit 0; only existing LF/CRLF normalization warnings
```

This review found no new security or data-integrity regression in these scoped changes. It is not a final release audit: Host post-reboot state is unavailable, the physical setup and synchronization lifecycle is incomplete, and the unsigned internal installer has not had its commercial signing/toolchain status resolved. Stage 9 remains OPEN.


## Client silent uninstall/reinstall retention check — 2026-11-09

Preflight on Client confirmed `VentioHost` and `VentioPostgres` were absent, `C:\ProgramData\Ventio` did not exist, no Ventio UI process was running, and the installed application was 0.1.18. The existing user data directory and pending queue snapshot had already been preserved.

The installed `C:\Program Files\Ventio\unins000.exe` was run with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` and without `-RemoveData`. Observed output:

```text
UNINSTALL_EXIT=0
UNINSTALL_LOG_SUCCESS=True
VENTIO_REGISTRY_AFTER_UNINSTALL=False
PROGRAM_DIR_AFTER_UNINSTALL=False
PROGRAMDATA_AFTER_UNINSTALL=False
```

The app-support file hashes were unchanged after uninstall, including the pending queue and opaque secure-storage file. The checksum-matched Wave1fix15 installer was then run again:

```text
REINSTALL_EXIT=0
REINSTALL_LOG_SUCCESS=True
POST_VERSION=0.1.18
PROGRAM_DIR=True
HOST_SERVICES_ABSENT=True
```

The same Client app-support hashes remained unchanged after reinstall. The uninstaller and reinstall logs are preserved under `client-preserved-2026-11-09/`. **`PASS — VERIFIED` for this physical Client silent uninstall/reinstall-retention procedure.** This did not exercise the graphical Host-data deletion checkbox because no Host data/services existed on Client; Host uninstall/retention UI and Host database retention remain untested.


## Installer removal regression checks — 2026-11-09

On Development, the temporary-fixture removal diagnostics suite passed partial-install state validation, protected diagnostics archiving, and rejection of an unrecognized partial installation. The product-data-root ACL suite passed administrator ownership, protected inheritance, service-only traversal, duplicate SID handling, interactive-writer rejection, and fixed production boundary checks. Both scripts exited 0; output is preserved in `host-removal-diagnostic-archive-regression-20261109.log`.

These are automated fixture checks for the removal and data-root boundaries. They do not exercise Host service/data removal on the physical Host or the uninstall data-deletion checkbox; those operational criteria remain open.


## Host access recovery and reboot-network investigation — 2026-11-09

A fresh SSH connection from Development to `192.168.1.102` using the existing `ventio_lab` key exited 0. It returned `ABEDKILANY`, `ABEDKILANY\AbedKilany`, and High Mandatory Level SID `S-1-16-12288`. The installed Ventio version is `0.1.18`; `sshd`, `VentioHost`, and `VentioPostgres` are Running/Automatic and listening ports 22, 3389, and 8443 were verified. From Development, certificate-pinned HTTPS `/healthz` returned `{"apiVersion":1,"status":"alive"}`, HTTP 200, TLS verify result 0. This verifies Host service startup and HTTPS liveness, not authenticated Host readiness.

Windows event chronology establishes the post-reboot connectivity loss: sshd listened at 12:47:34 and accepted Development's key at 12:47:54; WLAN associated at 12:47:44, then disconnected at 12:48:13. Kernel-Power logged sleep at 12:48:13 with reason `Button or Lid`; Power-Troubleshooter reports wake by `Power Button` at 13:19:06. Seven seconds later the system entered sleep again with the same reason and woke at 13:20:38 from `Power Button`. WLAN/NDIS low-power events align with both transitions, and DHCP was acquired at 13:20:42. This identifies Windows sleep transitions as the cause class; the combined event reason does not distinguish which physical control caused each sleep.

Computer Use opened Remote Desktop using the saved Host connection; read-only `quser` over SSH reports `abedkilany`, `rdp-tcp#0`, ID 2, `Active`. After the corrected reboot, Computer Use screenshot capture failed twice with `IGraphicsCaptureItemInterop.CreateForMonitor failed: Could not capture the given monitor. (0x80070057)`. Thus the Host Overview and visible version/readiness remain unverified. Source inspection confirms authenticated `/api/v1/management/readiness` requires a bearer token from a persistent identity with exact-scope `host.status.read`; a pinned live request without a bearer credential returned HTTP 401 `UNAUTHENTICATED`, correlation `cor_5155fe4fc4906d4d22f06c7019b3ecd6`. No readiness result is claimed. Full findings are in [Host reboot connectivity investigation](evidence-closure-2026-11-08/host-reboot-connectivity-investigation-2026-11-09.md).

A pinned-TLS POST to the live management-readiness route without an Authorization header returned HTTP 401 `UNAUTHENTICATED`, correlation ID `cor_5155fe4fc4906d4d22f06c7019b3ecd6`. This verifies the expected missing-credential denial only; it is not a readiness check and earns no stage weight.

To prevent another sleep while the dedicated Host is AC-powered for acceptance, the Balanced plan's AC `Lid close action` and `Power button action` were changed from index 1 (`Sleep`) to index 0 (`Do nothing`). DC values remained at 1 (`Sleep`); the idle timeout remains Never. A controlled reboot then passed bounded recovery on the first SSH attempt, all services were Running/Automatic, pinned HTTPS returned HTTP 200/TLS 0, and after waiting beyond the previous 53-second sleep point there was no post-boot Kernel-Power sleep event. AC/DC settings persisted after reboot. This verifies the correction and reboot regression, not authenticated readiness. The former Host-unreachable checkpoint is superseded for SSH, service startup, and pinned HTTPS liveness. Authenticated readiness and required GUI verification remain open, and Stages 10, 3, 8, and 9 remain open. Accepted progress remains **60%**; no whole-stage weight was added.

## Owner-assisted access checkpoint — 2026-11-09

After the owner confirmed desktop access, one Computer Use attempt found the RDP window `192.168.1.102 - Remote Desktop Connection` and captured the Host Ventio landing screen. Visible text included `Host profile selected · AB`, `Selected scope: CD / EF`, and `Host access requires a verified session`. Host Overview, readiness, and application version were not visible. The first interaction action failed with `GetCursorPos failed: Access is denied. (0x80070005)`; no further UI action was attempted. The visible landing page indicates no verified Host session in that app context, but does not establish server readiness.

Fresh read-only authenticated SSH checks verified Host `AbedKilany`, user `abedkilany\abedkilany`, High Integrity SID `S-1-16-12288`, all three services Running/Automatic, and HTTPS `/healthz` HTTP 200. SSH to the physical Client verified its source address `192.168.1.105`; `Test-NetConnection` to Host `192.168.1.102:8443` succeeded. That is TCP reachability only. Source inspection confirms live management readiness additionally requires an authenticated Bearer session with `host.status.read` at the exact company/branch scope; the native client reads it through `HostCredentialVault`, and no separate supported readiness CLI was found. No stored token was read or exposed.

The installer process-creation policy rejection remains a separate Stage 10 blocker. It occurred before the planned file move or installer launch and was not bypassed. The dashboard and execution history record both blockers independently. Exact owner-assisted UI evidence still required: Host Overview/readiness/version; installed Host Setup first-admin, interruption/resume/idempotency and real failure-export results; Host uninstall retention choice; and the physical Host–Client enrollment, `sync.test / 0.1.0` approval, offline record, sync acceptance/receipt, and independent Client readback. Preserve the historical pending `SYNC-TEST-001` before any reset. No accepted stage weight changed.

## Process-policy attribution and physical Client recovery checks — 2026-11-09

The installer denial is attributed to the Codex command-launch policy: the preserved `exec_command` event records `CreateProcess ... Rejected ... blocked by policy` before the planned Host file move and installer launch. Development's enabled AppLocker, Code Integrity, and Defender Operational channels had zero records during the 13:00–13:20 UTC window; Security event 4688 also had no records. No Windows process was observed. The literal command text was not preserved; the recorded operation was to move `C:\Program Files\Ventio\ventio_native_client.exe` aside and run the verified same-version installer silently. The approval-capable flow is unavailable in the current `approval_policy=never` session, and the owner reports approval is not available yet. No alternate shell or launcher was used.

From the physical Client, the Host LAN certificate fingerprint matched the preserved public PEM; `curl.exe --cacert` to `https://192.168.1.102:8443/healthz` returned HTTP 200, `TLS_VERIFY=0`, and `{"apiVersion":1,"status":"alive"}`. The Client's database, WAL, and SHM hashes also still match the preserved `SYNC-TEST-001` snapshot. These revalidate TLS transport and queue preservation; they do not establish authenticated Host readiness, enrollment, synchronization, or receipt acceptance. No grouped test count or 60% accepted ledger change was made. Details, safe installer steps, and the exact approval limitation are in [the process-policy and Client revalidation evidence](evidence-closure-2026-11-08/installer-process-policy-source-and-client-queue-2026-11-09.md).

A read-only cross-check of the Development acceptance artifact and Host-staged installer copy returned the same SHA-256 8e921367a6a7139a232fdf0a9f5fd3d1d61703bbf53d25c3ca705991d446b284 and size 104200244 bytes; the Development artifact is unsigned. Installer execution remains blocked by the unavailable Codex approval route. No stage weight changed.

A read-only Host backup inventory located the pre-upgrade PostgreSQL copy at C:\ProgramData\Ventio\Backups\ventio-postgresql-before-upgrade-20261108T193506653Z-16dabf5cda154b8fbec9ee8bbd00cf77. Its data directory has 1,379 files and 51,093,333 bytes, matching backup-manifest.json. This verifies file-count and byte-total consistency only; logical row preservation and per-file cryptographic integrity remain unverified. No Host data or service state changed; accepted progress remains 60%. Details: [Host backup identity and manifest evidence](evidence-closure-2026-11-08/host-post-upgrade-backup-identity-2026-11-09.md).

## Host administrator credential recovery investigation — 2026-11-09

The Host owner reports application 401 UNAUTHENTICATED while liveness and services work. The installed first-administrator broker issues a 24-hour token; completed setup handoffs and protected receipt metadata are dated November 7, so expiration is the strongest explanation on November 9. The API maps missing, expired, revoked and disabled credentials to the same 401; no credential/authentication row or protected token was read, so the exact current vault state is unproven. Installed Windows credential reissue needs an active operator credential; the audited trusted-local provision flow requires the Recovery Authority writer and ventio_identity_admin connection, not available in this session. No reset or mutation was performed. Stages remain open and accepted progress remains 60%. See [credential recovery investigation](evidence-closure-2026-11-08/host-administrator-credential-recovery-investigation-2026-11-09.md).

## SSH-only engineering and owner handoff

The latest checkpoint reused successful physical upgrade, reboot and Client retention evidence. It independently verified installed payload and application identity, scoped review and coordinated migration data preservation. Existing-owner recovery, the policy-gated repair, clean installed setup/retention and physical enrollment-through-readback remain open. Accepted progress is **60%**. See the [engineering evidence and stage matrix](wave1-ssh-engineering-completion-2026-11-09.md) and [consolidated owner UI acceptance](WAVE1-OWNER-UI-ACCEPTANCE.md).

## Formal stage acceptance — 2026-11-11

Stages 3, 10 and 8 are accepted at their whole weights of 11, 20 and 6 points. Installed safe-repeat evidence completed Stage 3. The service, setup, failure, upgrade/repair/recovery, retention and explicit deletion evidence completes Stage 10 for the verified internal candidate. Host/PostgreSQL executable hashes are identical to the earlier installed reboot-tested payload, so that successful reboot is reused. The already-passed physical business flow then closes Stage 8's dependencies. Accepted progress is **97%**. Stage 9 remains open for the scoped final audit, W1-UI-001 and signing/distribution disposition.

UAC cancellation was covered by automated tests. The fixture's existing administrator elevation policy suppressed the physical consent prompt. No claim is made that a physical cancellation occurred. The candidate remains unsigned and the Inno commercial-use license remains unverified. The saved original Host archive and staged recovery remain protected outside the current fixture.
