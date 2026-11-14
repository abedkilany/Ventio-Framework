# Wave 2 B defect register

Candidate: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
Last updated: 2026-11-14 17:02 UTC
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
| WB-ACC-01 | Critical | Open | Real two-computer synchronization, offline changes and reconciliation have not run. | Candidate Clients are installed and launched on both machines, but Host provisioning is pending. Complete the plan's two-device/two-identity cases after the isolated Host is ready. |
| WB-ACC-02 | Critical | Open | Physical backup, scheduling, corruption and full restore/reconciliation have not run. | No physical Host/database exists yet. Execute only against the isolated Ventio test installation, with local approval and independent Recovery Authority intact. |
| WB-ACC-03 | High | Open | The full fixed-scope capability matrix and B6 audit are incomplete. | CI provides subsets, not complete capability closure. Record each required positive, negative, recovery and platform scenario against the exact candidate. |
| WB-ACC-04 | High | **OPEN — APPLICATION-CONTROL BLOCK CONFIRMED** | The shipped unsigned Host Setup Broker is incompatible with the test machines' Enterprise signing-level policy. | On TEST-01, after the expected UAC approval, Code Integrity events 3033/3077 at 2026-11-14 16:54:52–53 UTC identify `svchost.exe` blocked from loading `C:\Program Files\Ventio\host-payload\VentioSetupBroker.exe` (67,592,883 bytes; SHA-256 `bfb4d9bc9f06b11d537a10215ec4dfcf65d9ce78b11150eb53df6a348bd083f4`; Authenticode `NotSigned`), policy `{0283ac0f-fff1-49ae-ada1-8a933130cad6}`. The UI then reported the protected component unavailable; neither service was created. Requires a signed candidate compatible with policy and a repeat test. Do not weaken Code Integrity or Defender. |
| WB-ACC-05 | High | **OPEN — INTERACTIVE REPRODUCTION PENDING** | A silent uninstall from SSH returned exit code 0 but left the Client process and six application files while removing the uninstall registration/helper files. | TEST-02 had no Host/PostgreSQL services or ProgramData\Ventio. The Client was still running in RDP session 4 while uninstaller ran from SSH; the session boundary may explain the result. The verified installer was rerun from SSH and returned 0; version/uninstall registration and application files are restored. RDP still shows the lock screen, so post-repair visual confirmation and same-session interactive uninstall retest remain pending. No test database or Host data was present or removed. |

## Inherited Wave 1 risk

The tested package contains `Ventio-Setup-0.1.18.exe` (SHA-256
`5413f65d86235633d40e1912767dd576303ecb0a7216d4a5e846c977f955977b`), and
Authenticode reports `NotSigned`. Its installer, Client, Setup Broker and Host
service executables are unsigned. Installation and Client launch succeeded on
both dedicated machines while Defender and Code Integrity remained enabled.
However, TEST-01's first Host setup attempt was blocked when Code Integrity
rejected the unsigned Setup Broker; see WB-ACC-04. The Host service lifecycle
and interactive uninstall remain untested. A silent uninstall from SSH left a
partial install while the Client was running in a separate RDP session; see
WB-ACC-05. Wave 1 records an unsigned uninstaller blocked by Code Integrity,
and TEST-02 has earlier 3033/3077 events mentioning `unins000.exe` whose file
hash is unavailable. Keep the deployment compatibility risk open and do not
disable Code Integrity or Defender.

Wave 1 did not retain historical cross-record target events or prior values.
Wave 2 history checks must respect this coverage boundary and must not infer
missing events.

The Wave 2 A handoff also records Windows development-Host shutdown timeouts
observed in automated CI without a confirmed source cause. This B investigation
remains open; a candidate Host service has not yet been provisioned on the
dedicated machines.
