# Wave 2 B defect register

Candidate: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
Current disposition: **WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**
Last updated: 2026-11-14 20:41 UTC
Tested product remains `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`; report updates are documentation-only.
Branch: `feature/wave-2-a`; Draft PR #6 remains open and unmerged.
This register separates a confirmed package defect from environment and
acceptance blockers.

## Confirmed product/package defect

| ID | Severity | Status | Summary | Reproduction, cause and correction |
|---|---|---|---|---|
| WB-PKG-01 | High | **CLOSED — correction passed candidate regression** | The Windows package gate rejected the Visual C++ runtime fetched through Microsoft's moving latest-version URL because its size or SHA-256 differed from the pinned repository metadata. | Reproduced in run `43603493035`, job `132473048657`. The integrity check was retained. Commit `fb341a7` pins the Microsoft 14.51.36247 endpoint and logs actual runtime metadata. Candidate package run `43605015043` completed successfully, including the unchanged runtime integrity and installer verification steps. No application source changed. |

## Open environment and acceptance blockers

| ID | Severity | Status | Summary | Evidence / next action |
|---|---|---|---|---|
| WB-ENV-01 | High | **CLOSED** | Designated interactive RDP sessions were initially unavailable. | Current SSH connections identify VENTIO-TEST-01/Codex-1 and VENTIO-TEST-02/Codex-3; `quser` confirms both RDP sessions Active. |
| WB-ENV-02 | Medium | **MITIGATED** | Downloading a local Flutter SDK on TEST-01 was impractical at the observed transfer rate. | GitHub-hosted CI produced the candidate package; no local SDK was needed on the test computers. |
| WB-ENV-03 | High | **CLOSED — KEY-BY-KEY INPUT WORKED** | Long-text automation through the RDP clipboard path was unreliable. | With the correct Flutter fields focused, key-by-key input populated and visually verified the exact disposable Tenant/Company/Branch values on TEST-01. No owner intervention was needed; this was a test-control limitation, not an application defect. |
| WB-ENV-04 | Critical | **CLOSED** | The candidate package was initially absent and direct download/relay paths failed. | Owner-staged ZIP verified on both test computers: 103,796,488 bytes and SHA-256 `0c83cd20dab447e6d024fe3d62dd5e9588499deb417a986820bf10d6a13114ae`. The exact installer was extracted and installed on each machine. Earlier partial transfers were hashed and removed; no local relay copy was saved. |
| WB-ACC-01 | Critical | Open | Real two-computer synchronization, offline changes and reconciliation have not run. | TEST-01 Host/PostgreSQL are installed, but Host API waits for local first-admin bootstrap. Complete the plan's two-device/two-identity cases after that gate. |
| WB-ACC-02 | Critical | Open | Physical backup, scheduling, corruption and full restore/reconciliation have not run. | PostgreSQL now exists on TEST-01 but no product backup/scheduler/restore scenarios were executed. Continue only against the isolated Ventio installation and preserve Recovery Authority boundaries. |
| WB-ACC-03 | High | Open | The full fixed-scope capability matrix and B6 audit are incomplete. | CI provides subsets, not complete capability closure. Record each required positive, negative, recovery and platform scenario against the exact candidate. |
| WB-ACC-04 | High | **RESOLVED FOR TEST-01 LAB RUN; DISTRIBUTION LIMITATION OPEN** | The unsigned Host Setup Broker was blocked while Smart App Control was enforcing. The owner later disabled Smart App Control on TEST-01 for this authorized test. | The earlier 3033/3077 events and exact broker hash remain valid historical evidence. Before retry, registry showed `VerifiedAndReputablePolicyState=0`; after documented `CiTool.exe -r`, `CiTool -lp -json` showed the `VerifiedAndReputableDesktop` policy not enforced on TEST-01. Other Code Integrity policies and Defender remained enabled. The supported broker then completed PostgreSQL/Host provisioning through LAN configuration. Do not generalize this result to machines where SAC is enforced: unsigned distribution compatibility remains a deployment limitation. |
| WB-ACC-05 | High | **OPEN — NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED** | A silent uninstall from SSH returned exit code 0 but left the Client process and six application files while removing the uninstall registration/helper files. | TEST-02 had no Host/PostgreSQL services or ProgramData\Ventio. The Client was still running in RDP session 4 while uninstaller ran from SSH; the session boundary may explain the result. The verified installer was rerun from SSH and returned 0. Under the current SSH-only rule, same-session interactive uninstall and cleanup verification were not executed and require manual owner validation. Latest SSH checks show the Ventio install directory and uninstall key remain; `unins000.exe` is not running. No test database or Host data was present or removed. |
| WB-ACC-06 | Critical | **BLOCKED — NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED** | First-administrator Bootstrap cannot complete from SSH because the supported named-pipe endpoint intentionally rejects remote/network Windows identities. | Broker operation `72bf64daac9a47408d37efe80e882cdc` completed payload validation, PostgreSQL provisioning, database initialization, Host registration and LAN configuration, then failed `HOST_FIRST_ADMIN_PIPE_CONNECT_FAILED` (exit 7). SSH `Codex-1` token includes `NT AUTHORITY\NETWORK` (`S-1-5-2`); source inspection confirms this SID is denied by the first-admin pipe ACL and caller locality is required. Remote resume reproduced the same denial. Completing first admin through the supported local Ventio UI is **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**. This is an acceptance blocker/security boundary, not a confirmed product defect. Do not bypass the ACL, UAC or policy. |

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

## SSH-only continuation disposition

No application-source defect was confirmed or corrected in the resumed
SSH-only verification. Fresh physical migrations 001–040 and selected RLS and
least-privilege checks passed on TEST-01. First-admin Bootstrap is blocked by
the designed local-only named-pipe authorization (WB-ACC-06), which also blocks
Host API, real synchronization, and dependent physical gates. GUI-only tests
must be recorded as **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**. Do not
interpret WB-ACC-06 as authorization to relax the security boundary.
