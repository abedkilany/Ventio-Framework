# Wave 2 B defect register

Latest tested package: `17b014125b695e3242e2d9b50b3eb9732a8c5fcb`
Current disposition: **WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**
Last updated: 2026-11-15 20:29 UTC
Earlier physical installation evidence is tied to `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`. The newer package at `17b014125b695e3242e2d9b50b3eb9732a8c5fcb`, including correction `f11bf27e83dd6b206fc63289bbf325471a1ee026`, was installed on TEST-02; its Host executable is now quarantined by Defender. TEST-01's installed manifest has no source commit field.
Branch: `feature/wave-2-a`; Draft PR #6 remains open and unmerged.
This register separates a confirmed package defect from environment and
acceptance blockers.

## Confirmed product/package defect

| ID | Severity | Status | Summary | Reproduction, cause and correction |
|---|---|---|---|---|
| WB-PKG-01 | High | **CLOSED — correction passed candidate regression** | The Windows package gate rejected the Visual C++ runtime fetched through Microsoft's moving latest-version URL because its size or SHA-256 differed from the pinned repository metadata. | Reproduced in run `43603493035`, job `132473048657`. The integrity check was retained. Commit `fb341a7` pins the Microsoft 14.51.36247 endpoint and logs actual runtime metadata. Candidate package run `43605015043` completed successfully, including the unchanged runtime integrity and installer verification steps. No application source changed. |
| WB-PKG-02 | Medium | **SOURCE FIXED — LATEST PACKAGE INSTALLED; DIAGNOSTIC RETEST PENDING** | Bootstrap session failures discarded the safe Host transport error and were reported only as `HOST_SESSION_AUTHENTICATION_FAILED`. | Reproduced in `LocalHostSetupCredentialStore.saveCredentialAndProfile` with a safe `HOST_CREDENTIAL_EXPIRED`/401 response. Commit `f11bf27` preserves the validated Host code; focused regression confirms the error is retained and the failed credential is rolled back. The fix is included in package commit `17b0141`, installed on TEST-02. Host setup completed there, but the Client/session diagnostic path has not been exercised. |

## Open environment and acceptance blockers

| ID | Severity | Status | Summary | Evidence / next action |
|---|---|---|---|---|
| WB-ENV-01 | High | **RESOLVED — SSH RESTORED** | TEST-01 SSH was temporarily unreachable. | SSH to Codex-1 now identifies `VENTIO-TEST-01`; read-only service, API liveness and PostgreSQL checks completed. `quser` showed the RDP session disconnected, and no GUI interaction was used. |
| WB-ENV-02 | Medium | **MITIGATED** | Downloading a local Flutter SDK on TEST-01 was impractical at the observed transfer rate. | GitHub-hosted CI produced the candidate package; no local SDK was needed on the test computers. |
| WB-ENV-03 | High | **CLOSED — KEY-BY-KEY INPUT WORKED** | Long-text automation through the RDP clipboard path was unreliable. | With the correct Flutter fields focused, key-by-key input populated and visually verified the exact disposable Tenant/Company/Branch values on TEST-01. No owner intervention was needed; this was a test-control limitation, not an application defect. |
| WB-ENV-04 | Critical | **CLOSED** | The candidate package was initially absent and direct download/relay paths failed. | Owner-staged ZIP verified on both test computers: 103,796,488 bytes and SHA-256 `0c83cd20dab447e6d024fe3d62dd5e9588499deb417a986820bf10d6a13114ae`. The exact installer was extracted and installed on each machine. Earlier partial transfers were hashed and removed; no local relay copy was saved. |
| WB-ACC-01 | Critical | **BLOCKED — BOTH HOSTS UNAVAILABLE; CLIENT TLS/AUTHENTICATION UNVERIFIED** | Real two-computer synchronization, offline changes and reconciliation have not run. | At the 2026-11-15 20:29 UTC SSH check, both Host services were Stopped and both required `ventio_host.exe` files were absent after successful Defender remediation. TEST-01 had previously served Host traffic and its self-signed TLS certificate was verified, but it is no longer available. No authenticated Client session was established; TEST-02's Client certificate validation and enrollment remain untested. |
| WB-ACC-02 | Critical | **OPEN — NOT EXECUTED** | Physical backup, scheduling, corruption and full restore/reconciliation have not run. | Read-only inspection found no tasks under `\Ventio\` on TEST-01. Product approval/scheduling needs its supported Host operation path; no task was created by bypassing that authorization. No physical backup integrity/retention or disposable restore evidence exists. |
| WB-ACC-03 | High | Open | The full fixed-scope capability matrix and B6 audit are incomplete. | CI provides subsets, not complete capability closure. Record each required positive, negative, recovery and platform scenario against the exact candidate. |
| WB-ACC-04 | High | **RESOLVED FOR TEST-01 LAB RUN; DISTRIBUTION LIMITATION OPEN** | The unsigned Host Setup Broker was blocked while Smart App Control was enforcing. The owner later disabled Smart App Control on TEST-01 for this authorized test. | The earlier 3033/3077 events and exact broker hash remain valid historical evidence. Before retry, registry showed `VerifiedAndReputablePolicyState=0`; after documented `CiTool.exe -r`, `CiTool -lp -json` showed the `VerifiedAndReputableDesktop` policy not enforced on TEST-01. Other Code Integrity policies and Defender remained enabled. The supported broker then completed PostgreSQL/Host provisioning through LAN configuration. Do not generalize this result to machines where SAC is enforced: unsigned distribution compatibility remains a deployment limitation. |
| WB-ACC-05 | High | **OPEN — NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED** | A silent uninstall from SSH returned exit code 0 but left the Client process and six application files while removing the uninstall registration/helper files. | This was observed before the 2026-11-15 TEST-02 Host setup. The latest install now has Host/PostgreSQL data; do not repeat destructive uninstall without preserving required evidence and following the dedicated uninstall plan. Same-session interactive cleanup remains unverified. |
| WB-ACC-06 | Critical | **OPEN — AUTHENTICATED SESSION NOT VERIFIED** | TEST-01 previously failed to establish its first-admin session; TEST-02 provisioning succeeded after retry, but no authenticated Client/API session has been verified. | TEST-01's earlier UI report was `HOST_SESSION_AUTHENTICATION_FAILED` after operation `0793a94d97f202699fbbff49b5db5cc8` reached `HOST_READINESS`. Current local `/api/v1/session` returns 401 without credentials, as expected; no successful Client token/session was exercised. TEST-02's owner-reported Set up Host retry completed at `HOST_READINESS`, but its Host engine is now quarantined and unavailable. |
| WB-ACC-07 | High | **OPEN — CLIENT PINNING / ENROLLMENT NOT EXECUTED** | TEST-01 uses the intended self-signed LAN certificate, but no Client has explicitly pinned it or completed enrollment. | Read-only inspection confirmed Subject/Issuer `CN=VENTIO-TEST-01`, SAN `VENTIO-TEST-01` and `192.168.1.106`, and SHA-256 `2c63e4ffaa97dd4ba06be9d55360ef7fc907d7b3a8db6a889de6356e6d4f6368` matching Host metadata. The supported Client UI requires explicit fingerprint entry and forbids bypass. The default trust error is expected for this self-signed certificate; no trust store or security policy was modified. Pairing requires manual owner validation under the SSH-only limit. |
| WB-ACC-08 | High | **OPEN — HOST JOB WORKER ERROR, CAUSE UNRESOLVED** | TEST-01 safe Host diagnostics record intermittent `HOST_JOB_WORKER_UNAVAILABLE` events. | Events occurred at `2026-11-14T22:34:38.505Z` and `2026-11-15T09:28:20Z`, `09:31:47Z`, `09:32:59Z`, `09:38:14Z`, and `13:09:53Z`. At 14:09 UTC there was no newer entry. The event deliberately omits the exception. A read-only identity-API probe passed current Recovery Authority admission and invoked the empty-queue claim path in a rolled-back transaction; this did not reproduce or explain the events. No product defect or correction is confirmed. |
| WB-ACC-09 | Critical | **FAILED — BOTH HOST ENGINES QUARANTINED; RESTORE BLOCKED BY SECURITY BOUNDARY** | Defender quarantined the required Host engine on both dedicated machines, leaving both Host services unavailable. | TEST-02's earlier controlled crash was followed by Defender events 1116/1117 identifying `C:\Program Files\Ventio\host-payload\ventio_host.exe` as `Trojan:Win32/Bearfoos.A!ml` (2147731250, Severe); remediation succeeded at `2026-11-15T09:59:21Z`. On TEST-01, Defender recorded the same detection/path and successful remediation at `2026-11-15T20:10:00Z`. Its manifest enumerates 92 verified files and exactly one missing file, `ventio_host.exe`, whose expected size is 8,806,400 bytes and SHA-256 is `5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`. TEST-01's service record identifies `HOST_ENGINE_PROCESS_START`; SCM event 7023 reports system error 2. Both `VentioHost` services are Stopped with exit code 2; both PostgreSQL services remain Running. Defender protections remain enabled. The cause of the Defender classification (false positive versus genuine threat) is not established. No quarantine restore, exclusion, or security-policy weakening was attempted. A trusted signed candidate or formal Defender disposition is required before retrying Host recovery. |

## Inherited Wave 1 risk

The tested package contains `Ventio-Setup-0.1.18.exe` (SHA-256
`5413f65d86235633d40e1912767dd576303ecb0a7216d4a5e846c977f955977b`), and
Authenticode reports `NotSigned`. Its installer, Client, Setup Broker and Host
service executables are unsigned. Installation and Client launch succeeded on
both dedicated machines while Defender and Code Integrity remained enabled.
The first TEST-01 setup attempt was blocked when Code Integrity rejected the
unsigned Setup Broker; the owner later disabled Smart App Control for the
authorized TEST-01 lab run and provisioning then progressed to the
first-administrator boundary; see WB-ACC-04 and WB-ACC-06. An orderly Host and
PostgreSQL service restart passed. A later controlled Host-engine crash on
TEST-02 failed to recover because Defender quarantined the engine; see
WB-ACC-09. The
interactive uninstall remains untested. A silent uninstall from SSH left a
partial install while the Client was running in a separate RDP session; see
WB-ACC-05. Wave 1 records an unsigned uninstaller blocked by Code Integrity,
and TEST-02 has earlier 3033/3077 events mentioning `unins000.exe` whose file
hash is unavailable. Keep the deployment compatibility risk open and do not
disable Code Integrity or Defender.

During this follow-up, the owner unlocked TEST-02's Codex-3 desktop. The RDP
window was visible, but Computer Use could not operate its Start/Settings UI.
The latest SSH inspection still found the application directory and uninstall
registration; no uninstaller process was running. This GUI-control limitation
is historical; the current Wave 2 B pass used SSH only.

No organization signing path is available. WB-ACC-04 remains a distribution
limitation for environments where Smart App Control or Enterprise signing
policy enforces code signing. The owner-authorized TEST-01 policy state was
checked before retry; Defender and the remaining Code Integrity policies
stayed enabled.

Wave 1 did not retain historical cross-record target events or prior values.
Wave 2 history checks must respect this coverage boundary and must not infer
missing events.

The Wave 2 A handoff also records Windows development-Host shutdown timeouts
observed in automated CI without a confirmed source cause. This B investigation
remains open; only an orderly restart, not forced crash/shutdown behavior, was
verified on the physical Host service.

## Owner-managed clean reinstall and diagnostic follow-up

The owner removed the prior TEST-01 Ventio installation/data and installed the
same verified package. The new scope was Tenant `Test-01`, Company `Codex-01`,
Branch `Codex`. UI reported `HOST_SETUP_STATUS_UNAVAILABLE` at 22:29:33 UTC;
SSH later confirmed the same operation completed at 22:31:08 UTC. The current
operation remains `complete`, both services are Running, the protected result
file exists (metadata only inspected), and `/healthz` returns 200. A later UI
attempt reported `HOST_SESSION_AUTHENTICATION_FAILED` at 22:35:55 UTC.

No Ventio Windows Event Log provider or recent Ventio Application event was
present. Source inspection shows credential write failures map to
`HOST_CREDENTIAL_STORAGE_FAILED`; the observed session failure is raised after
the client attempts `GET /api/v1/session`. The installed candidate replaces
all Host transport exceptions in this path with a generic authentication code.
WB-PKG-02 fixes that diagnostic loss. The actual Host response is not yet known.

The owner reported the power interruption followed the earlier 21:59:20 UTC
session error; SSH later recorded boot time `2026-11-14T22:02:07.500Z`. The
clean-install session error at 22:35:55 UTC occurred after that reboot, so the
earlier outage does not explain this later failure. A read-only SSH check found
`HOST_JOB_WORKER_UNAVAILABLE` at 22:34:38.505 UTC, 77 seconds before the
session error. The worker event is emitted for any failed database/Recovery
Authority tick and does not identify the exception. Persistent session auth
also reads PostgreSQL per request, making a shared backend fault plausible but
unconfirmed. `/healthz` is process liveness, not database readiness. At 23:17
UTC, the configured PostgreSQL port 54329 returned `accepting connections` to
the bundled `pg_isready`; this current listener check does not validate
authenticated database access or the earlier Recovery Authority path.

The prior SSH-only migrations/RLS checks belong to the installation that was
subsequently removed; they do not certify the new clean database. Retest them
on the current database. At the 2026-11-14 checkpoint, package `b3a5f585` had
not yet been installed. The newer package `17b0141` is now installed on
TEST-02. Do not clear Host data or relax the pipe/UAC/security boundaries.

## TEST-02 owner setup and SSH verification — 2026-11-15 07:35 UTC

The owner reports that the first administrator creation failed on the first
attempt and that retrying **Set up Host** succeeded. SSH verified operation
`8e5eace6076314dc95c1389f95c707d2` in `complete` / `HOST_READINESS` state,
both services Running and Automatic, PostgreSQL 16.15 accepting local
connections on `127.0.0.1:54329`, and HTTP 200 from local `/healthz`. The Host
and PostgreSQL services use separate virtual service identities and have
restart actions configured for 5/30/60 seconds. These actions were inspected,
not exercised.

The installed payload manifest contains 1,724 files and 310,613,952 bytes;
the installed Setup Broker, Host service and PostgreSQL executable hashes
match it. Defender, real-time protection and Tamper Protection are enabled;
the observed `VerifiedAndReputablePolicyState` is 0. The owner-supplied
installer is unsigned. No policy or TLS validation behavior was weakened.

An orderly Host/PostgreSQL service restart passed on TEST-02; PostgreSQL
accepted connections and Host `/healthz` returned 200 afterward. No crash or
reboot was injected.

`WB-ACC-07` records that Client fingerprint pinning and enrollment remain
untested. TEST-01's default certificate-chain rejection is expected for its
self-signed LAN certificate; its certificate fingerprint and SAN match Host
metadata. Authenticated Client/API use, runtime-role execution, full scope
isolation, Wave 1 upgrade, backup/restore and authenticated two-device sync
remain open. TEST-02 Host is unavailable after the Defender event.

## TEST-01 reconnection and TEST-02 recovery test — 2026-11-15 10:15 UTC

TEST-01 was again reachable as `Codex-1@192.168.1.106`; both Host and
PostgreSQL services were Running, PostgreSQL accepted local connections and
Host `/healthz` returned 200. Anonymous `/api/v1/session` returned 401. The
installed payload manifest has no product commit field; current Host and
service binary hashes are recorded in the test-results report. Therefore this
physical evidence is tied to installed file hashes and live database state,
not a verified source commit.

Read-only B2 checks on TEST-01 confirmed 40/40 installed migration checksums,
`assert_schema()` success, 30/30 checked public tables owned by `ventio_owner`
with RLS/FORCE RLS, zero RLS violations and expected restricted role flags.
Selected direct migration-ledger reads were denied. A machine-DPAPI-backed
identity-API connection passed Recovery Authority admission and the
`wave2_claim_job()` empty-queue path inside a rolled-back transaction. This did
not process a job or reproduce the historical job-worker diagnostics.

TEST-02 to TEST-01 TCP 8443 was reachable, but ordinary HTTPS trust validation
failed. No certificate bypass was used. A real Host process crash on TEST-02
was followed by Defender quarantining `ventio_host.exe` as
`Trojan:Win32/Bearfoos.A!ml` (threat 2147731250, Severe). The Host service
remained Stopped after SCM retries and a manual start attempt; PostgreSQL
remained Running/accepting on PID 4424. Defender and real-time protection
remain enabled. No quarantine restore or exclusion was attempted. There is no
`\Ventio\` scheduled task on TEST-01; product backup approval, scheduling,
retention, integrity and disposable restore remain open.

## Latest SSH-only retest — 2026-11-15 10:56 UTC

No new code defect was confirmed. TEST-01's orderly Host-service restart passed:
the service returned to Running in 18.4 seconds, local /healthz returned 200,
and PostgreSQL remained Running/accepting connections. This does not replace
the failed TEST-02 process-crash recovery result in WB-ACC-09.

At 10:51 UTC, TEST-02 still had VentioHost Stopped and no
ventio_host.exe at the installed path; Defender recorded the prior Severe
threat and 1116/1117 detection/remediation events with protection enabled.
The owner's report that first-administrator setup succeeded on retry describes
setup completion, not current service recovery. WB-ACC-09 remains a security
and deployment blocker. No quarantined file was restored and no Defender
exclusion was added. TEST-01 default HTTPS trust also still fails, so WB-ACC-01
remains blocked.

## WB-CI-01 — Windows integration fixture shutdown timeout

| ID | Severity | Status | Summary | Reproduction, cause and correction |
|---|---|---|---|---|
| WB-CI-01 | Medium | FIX VERIFIED — CLOSED | The isolated Host API integration test intermittently timed out waiting for a child Host process to exit after graceful shutdown. | Host API run 43707135745 attempt 1 failed after 20 seconds at test/api_integration.dart:329. The same test passed on run 43704184519 and on attempt 2 of run 43707135745, confirming intermittency. Root cause was the Windows parent fixture leaving stdin open after sending the shutdown command; the child stdin subscription may not cancel promptly without EOF. The sibling identity fixture already closes stdin for this reason. Commit e3efc25075388d2ac92543238c99473313d85d79 closes stdin after writing the command. The process-restart integration passed on post-correction head 676c9896d3340a04d2dabb4157a9d96c837e3f61 in Host API run 43712289370; all nine workflows on that head passed. This is a CI/test-harness defect, not a confirmed production Host defect. |

At 2026-11-15 14:09 UTC, all nine workflows on post-correction head
0bd9ea9bd439dfd9e87a1ab2c7bd84681bfa4a82 had completed successfully.
Host API run 43715371756 passed the process restart regression and remaining
extension approval/scope/recovery integration. No workflow was canceled.

## TLS trust finding — expected trust model, acceptance still open

Read-only TEST-01 inspection confirmed the LAN certificate is self-signed and
the published SHA-256 fingerprint matches the certificate and SAN entries.
The Host explicitly requires Clients to trust the certificate; the pairing UI
requires manual fingerprint entry and prohibits bypassing certificate checks.
The observed default TLS trust error is therefore expected until the supported
pinning step is completed. No certificate trust was weakened and no Client
enrollment or real synchronization was performed. This is not currently
classified as a product defect; B4 remains blocked pending owner validation.

## Final SSH-only continuation checkpoint — 2026-11-15 14:48 UTC

No new product defect was confirmed and no code correction was made during
this continuation. TEST-01 remains live (VentioHost and VentioPostgres
Running; /healthz 200), but the latest HOST_JOB_WORKER_UNAVAILABLE diagnostic
remains unresolved. Its setup record reached HOST_READINESS; authenticated
administrator login is not evidenced.

The TEST-02 crash-recovery blocker remains open. Defender's recorded action for
threat 2147731250 succeeded, the Host executable remains absent, and the
service is Stopped. Defender protections remain enabled; no restore, exclusion
or policy change was attempted. Product backup/restore, real-client
synchronization and manual-UI acceptance blockers also remain open.

All nine CI workflows passed on
ee167d6d219bdb655edae129441b7a12e15d9420; see the final test-results checkpoint
for run IDs. CI success does not clear the physical Windows security or
integration blockers.

## Dual-machine Defender finding — 2026-11-15 20:29 UTC

WB-ACC-09 now applies to both TEST-01 and TEST-02. TEST-01's independent
Defender event and payload-manifest check confirm the same quarantined engine
hash already absent on TEST-02. The immediate failure is established as
Defender remediation of the required engine; whether the detection is a false
positive remains undetermined. Effective Code Integrity policy on TEST-01
remains enforced, while the inspected CI log contains no event for the Host
engine or Host service executable. Defender and Code Integrity were not
weakened. Current PR head `02b8ecc3901527f0b635fd66e5c68c1734d7dff8` has ten
successful Actions checks. Host recovery and the dependent synchronization,
backup and final physical acceptance gates stay blocked until an approved
signed candidate or formal Defender disposition is available.
