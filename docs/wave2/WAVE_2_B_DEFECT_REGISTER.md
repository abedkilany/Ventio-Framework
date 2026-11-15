# Wave 2 B defect register

Latest tested package: `17b014125b695e3242e2d9b50b3eb9732a8c5fcb`
Current disposition: **WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**
Last updated: 2026-11-15 08:12 UTC
Earlier physical installation evidence is tied to `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`. The newer package at `17b014125b695e3242e2d9b50b3eb9732a8c5fcb`, including correction `f11bf27e83dd6b206fc63289bbf325471a1ee026`, is installed on TEST-02.
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
| WB-ENV-01 | High | **PARTIAL — TEST-01 SSH UNREACHABLE** | TEST-01 was available earlier, but its SSH endpoint stopped responding during the latest physical verification window. | TEST-01/Codex-1 SSH timed out at 2026-11-15 07:35 UTC. TEST-02/Codex-3 remains reachable and its Host is provisioned. Restore TEST-01 access before physical two-device synchronization. |
| WB-ENV-02 | Medium | **MITIGATED** | Downloading a local Flutter SDK on TEST-01 was impractical at the observed transfer rate. | GitHub-hosted CI produced the candidate package; no local SDK was needed on the test computers. |
| WB-ENV-03 | High | **CLOSED — KEY-BY-KEY INPUT WORKED** | Long-text automation through the RDP clipboard path was unreliable. | With the correct Flutter fields focused, key-by-key input populated and visually verified the exact disposable Tenant/Company/Branch values on TEST-01. No owner intervention was needed; this was a test-control limitation, not an application defect. |
| WB-ENV-04 | Critical | **CLOSED** | The candidate package was initially absent and direct download/relay paths failed. | Owner-staged ZIP verified on both test computers: 103,796,488 bytes and SHA-256 `0c83cd20dab447e6d024fe3d62dd5e9588499deb417a986820bf10d6a13114ae`. The exact installer was extracted and installed on each machine. Earlier partial transfers were hashed and removed; no local relay copy was saved. |
| WB-ACC-01 | Critical | **BLOCKED — TEST-01 UNREACHABLE** | Real two-computer synchronization, offline changes and reconciliation have not run. | SSH to TEST-01/Codex-1 timed out at 2026-11-15 07:35 UTC. TEST-02 is now provisioned as Host, but no independent reachable client peer is available. |
| WB-ACC-02 | Critical | Open | Physical backup, scheduling, corruption and full restore/reconciliation have not run. | PostgreSQL now exists on TEST-02; no product backup/scheduler/restore scenarios were executed. Continue only against the isolated Ventio installation and preserve Recovery Authority boundaries. |
| WB-ACC-03 | High | Open | The full fixed-scope capability matrix and B6 audit are incomplete. | CI provides subsets, not complete capability closure. Record each required positive, negative, recovery and platform scenario against the exact candidate. |
| WB-ACC-04 | High | **RESOLVED FOR TEST-01 LAB RUN; DISTRIBUTION LIMITATION OPEN** | The unsigned Host Setup Broker was blocked while Smart App Control was enforcing. The owner later disabled Smart App Control on TEST-01 for this authorized test. | The earlier 3033/3077 events and exact broker hash remain valid historical evidence. Before retry, registry showed `VerifiedAndReputablePolicyState=0`; after documented `CiTool.exe -r`, `CiTool -lp -json` showed the `VerifiedAndReputableDesktop` policy not enforced on TEST-01. Other Code Integrity policies and Defender remained enabled. The supported broker then completed PostgreSQL/Host provisioning through LAN configuration. Do not generalize this result to machines where SAC is enforced: unsigned distribution compatibility remains a deployment limitation. |
| WB-ACC-05 | High | **OPEN — NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED** | A silent uninstall from SSH returned exit code 0 but left the Client process and six application files while removing the uninstall registration/helper files. | This was observed before the 2026-11-15 TEST-02 Host setup. The latest install now has Host/PostgreSQL data; do not repeat destructive uninstall without preserving required evidence and following the dedicated uninstall plan. Same-session interactive cleanup remains unverified. |
| WB-ACC-06 | Critical | **OPEN — AUTHENTICATED SESSION NOT VERIFIED** | TEST-01 previously failed to establish its first-admin session; TEST-02 Host provisioning succeeded after retry, but no authenticated Client/API session has been verified on either current installation. | On TEST-01, the UI reported `HOST_SESSION_AUTHENTICATION_FAILED` after broker operation `0793a94d97f202699fbbff49b5db5cc8` reached `HOST_READINESS`; the installed diagnostic fix has not been exercised in that session. On TEST-02, the owner reports the first administrator creation failed on the first attempt and a **Set up Host** retry succeeded; SSH confirms operation `8e5eace6076314dc95c1389f95c707d2` complete at `HOST_READINESS`, with both services Running and `/healthz` 200. No diagnostic code for the initial TEST-02 attempt was supplied, so its cause is unknown. Provisioning completion does not prove authenticated Client/API use. TEST-01 is now SSH-unreachable. |
| WB-ACC-07 | High | **OPEN — TLS TRUST VALIDATION FAILED** | Windows default TLS validation rejected the TEST-02 Host HTTPS endpoint on port 8443. | Read-only `Invoke-WebRequest` to `/healthz` using `127.0.0.1`, `VENTIO-TEST-02` and `localhost` failed with `Could not establish trust relationship for the SSL/TLS secure channel`. The Client-specific pinning path was not exercised; no certificate bypass or policy change was made. Verify supported certificate enrollment/trust before claiming client network compatibility. |

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

`WB-ACC-07` records a failed system-default TLS validation probe on HTTPS port
8443 for the IP, machine hostname and localhost. This is not yet confirmed as
a Client defect because the Client-specific certificate pinning path was not
tested. Authenticated Client/API use, runtime-role execution, full scope
isolation, Wave 1 upgrade, Recovery Authority checks, backup/restore and actual
crash recovery remain open. TEST-01 SSH timed out at 07:35 UTC, leaving real
two-device synchronization blocked.
