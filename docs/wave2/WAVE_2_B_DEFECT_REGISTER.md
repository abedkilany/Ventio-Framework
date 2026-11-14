# Wave 2 B defect register

Candidate: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
Current disposition: **WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**
Last updated: 2026-11-14 23:32 UTC
Physical installation evidence remains tied to `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`; correction `f11bf27e83dd6b206fc63289bbf325471a1ee026` is included in package candidate `b3a5f585b8c641321fa3fc33503eb10ca00837f0` and has not been physically installed.
Branch: `feature/wave-2-a`; Draft PR #6 remains open and unmerged.
This register separates a confirmed package defect from environment and
acceptance blockers.

## Confirmed product/package defect

| ID | Severity | Status | Summary | Reproduction, cause and correction |
|---|---|---|---|---|
| WB-PKG-01 | High | **CLOSED — correction passed candidate regression** | The Windows package gate rejected the Visual C++ runtime fetched through Microsoft's moving latest-version URL because its size or SHA-256 differed from the pinned repository metadata. | Reproduced in run `43603493035`, job `132473048657`. The integrity check was retained. Commit `fb341a7` pins the Microsoft 14.51.36247 endpoint and logs actual runtime metadata. Candidate package run `43605015043` completed successfully, including the unchanged runtime integrity and installer verification steps. No application source changed. |
| WB-PKG-02 | Medium | **SOURCE FIXED — PACKAGE BUILT; PHYSICAL RETEST PENDING** | Bootstrap session failures discarded the safe Host transport error and were reported only as `HOST_SESSION_AUTHENTICATION_FAILED`. | Reproduced in `LocalHostSetupCredentialStore.saveCredentialAndProfile` with a safe `HOST_CREDENTIAL_EXPIRED`/401 response. Unlike `verifyAndBindExistingProfile`, the bootstrap path replaced `HostPackageTransportException.code` with a generic code. Commit `f11bf27` preserves the validated Host code; focused regression confirms the error is retained and the failed credential is rolled back. Windows Acceptance Package run `43650771423` succeeded on `b3a5f585`; artifact SHA-256 is `aea0a03f95589eec58bf70df6a1685ff66a4ba59ce464bda7f683472e2a89173`. Physical installation and observation of the Host response remain pending. |

## Open environment and acceptance blockers

| ID | Severity | Status | Summary | Evidence / next action |
|---|---|---|---|---|
| WB-ENV-01 | High | **CLOSED** | Designated interactive RDP sessions were initially unavailable. | Current SSH connections identify VENTIO-TEST-01/Codex-1 and VENTIO-TEST-02/Codex-3; `quser` confirms both RDP sessions Active. |
| WB-ENV-02 | Medium | **MITIGATED** | Downloading a local Flutter SDK on TEST-01 was impractical at the observed transfer rate. | GitHub-hosted CI produced the candidate package; no local SDK was needed on the test computers. |
| WB-ENV-03 | High | **CLOSED — KEY-BY-KEY INPUT WORKED** | Long-text automation through the RDP clipboard path was unreliable. | With the correct Flutter fields focused, key-by-key input populated and visually verified the exact disposable Tenant/Company/Branch values on TEST-01. No owner intervention was needed; this was a test-control limitation, not an application defect. |
| WB-ENV-04 | Critical | **CLOSED** | The candidate package was initially absent and direct download/relay paths failed. | Owner-staged ZIP verified on both test computers: 103,796,488 bytes and SHA-256 `0c83cd20dab447e6d024fe3d62dd5e9588499deb417a986820bf10d6a13114ae`. The exact installer was extracted and installed on each machine. Earlier partial transfers were hashed and removed; no local relay copy was saved. |
| WB-ACC-01 | Critical | Open | Real two-computer synchronization, offline changes and reconciliation have not run. | TEST-01 services and unauthenticated health are ready, but the local Client has not established an authenticated first-administrator session. Complete the plan's two-device/two-identity cases after that gate. |
| WB-ACC-02 | Critical | Open | Physical backup, scheduling, corruption and full restore/reconciliation have not run. | PostgreSQL now exists on TEST-01 but no product backup/scheduler/restore scenarios were executed. Continue only against the isolated Ventio installation and preserve Recovery Authority boundaries. |
| WB-ACC-03 | High | Open | The full fixed-scope capability matrix and B6 audit are incomplete. | CI provides subsets, not complete capability closure. Record each required positive, negative, recovery and platform scenario against the exact candidate. |
| WB-ACC-04 | High | **RESOLVED FOR TEST-01 LAB RUN; DISTRIBUTION LIMITATION OPEN** | The unsigned Host Setup Broker was blocked while Smart App Control was enforcing. The owner later disabled Smart App Control on TEST-01 for this authorized test. | The earlier 3033/3077 events and exact broker hash remain valid historical evidence. Before retry, registry showed `VerifiedAndReputablePolicyState=0`; after documented `CiTool.exe -r`, `CiTool -lp -json` showed the `VerifiedAndReputableDesktop` policy not enforced on TEST-01. Other Code Integrity policies and Defender remained enabled. The supported broker then completed PostgreSQL/Host provisioning through LAN configuration. Do not generalize this result to machines where SAC is enforced: unsigned distribution compatibility remains a deployment limitation. |
| WB-ACC-05 | High | **OPEN — NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED** | A silent uninstall from SSH returned exit code 0 but left the Client process and six application files while removing the uninstall registration/helper files. | TEST-02 had no Host/PostgreSQL services or ProgramData\Ventio. The Client was still running in RDP session 4 while uninstaller ran from SSH; the session boundary may explain the result. The verified installer was rerun from SSH and returned 0. Under the current SSH-only rule, same-session interactive uninstall and cleanup verification were not executed and require manual owner validation. Latest SSH checks show the Ventio install directory and uninstall key remain; `unins000.exe` is not running. No test database or Host data was present or removed. |
| WB-ACC-06 | Critical | **BLOCKED — AUTHENTICATED SESSION NOT VERIFIED** | The named-pipe boundary was respected; owner-run local setup completed the first-admin broker handoff, but the Client could not establish the resulting Host session. | After the owner cleared Ventio data and reran setup locally, broker operation `0793a94d97f202699fbbff49b5db5cc8` reached `complete` at `HOST_READINESS`; the protected result remained present, both services were Running and `/healthz` returned 200. The UI reported `HOST_SESSION_AUTHENTICATION_FAILED` at 2026-11-14 22:35:55 UTC. The generic code hides the Host response; WB-PKG-02 preserves it in the next package. No authorization boundary was bypassed. |

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
PostgreSQL service restart passed, but crash recovery remains untested. The
interactive uninstall remains untested. A silent uninstall from SSH left a
partial install while the Client was running in a separate RDP session; see
WB-ACC-05. Wave 1 records an unsigned uninstaller blocked by Code Integrity,
and TEST-02 has earlier 3033/3077 events mentioning `unins000.exe` whose file
hash is unavailable. Keep the deployment compatibility risk open and do not
disable Code Integrity or Defender.

During this follow-up, the owner unlocked TEST-02's Codex-3 desktop. The RDP
window was visible, but Computer Use could not operate its Start/Settings UI.
The latest SSH inspection still found the application directory and uninstall
registration; no uninstaller process was running.

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
on the current database. The source diagnostic fix is packaged in candidate
`b3a5f585` but is not installed. Do not clear Host data or relax the
pipe/UAC/security boundaries to retry this session.
