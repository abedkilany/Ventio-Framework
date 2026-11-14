# Wave 2 B defect register

Candidate: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
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
| WB-ENV-01 | High | Open | Designated interactive RDP sessions have not been established for the Codex test accounts. | SSH administrator access and RDP TCP/3389 are verified. TEST-02's active session belongs to `AbedKilany`, not Codex-3/4. The owner was asked to leave RDP sessions open as Codex-1 and Codex-3. |
| WB-ENV-02 | Medium | Mitigated for CI; physical setup pending | Downloading a local Flutter SDK on TEST-01 was impractical at the observed transfer rate. | The GitHub-hosted Windows package workflow built the candidate. The package must still be staged and verified on both machines before physical installation. No incomplete SDK remains. |
| WB-ENV-03 | Critical | Open | Available UI automation cannot activate the selected RDP desktop. | CUA and Sky both returned `failed to activate captured window` after refreshing/reselecting. Native physical UI scenarios cannot run until a usable designated session/controller is available. |
| WB-ENV-04 | Critical | Open | The candidate package has not reached the test machines through an approved route. | Direct lab downloads returned HTTP 403 and produced incomplete files, which were hashed and removed after stopping only the identified transfer processes. Automatic approval review rejected the local relay attempt with `blocked by policy`; it was stopped without saving the package locally. The owner is staging the verified artifact through an approved channel. |
| WB-ACC-01 | Critical | Open | Real two-computer synchronization, offline changes and reconciliation have not run. | No Client or Host candidate was installed. Run the plan's two-device/two-identity cases only after the verified artifact is present and the Host is ready. |
| WB-ACC-02 | Critical | Open | Physical backup, scheduling, corruption and full restore/reconciliation have not run. | No physical Host/database exists yet. Execute only against the isolated Ventio test installation, with local approval and independent Recovery Authority intact. |
| WB-ACC-03 | High | Open | The full fixed-scope capability matrix and B6 audit are incomplete. | CI provides subsets, not complete capability closure. Record each required positive, negative, recovery and platform scenario against the exact candidate. |
| WB-ACC-04 | High | Open | Windows installer application-control and service lifecycle compatibility are unknown for this candidate. | The package was built and CI-verified but not installed. Defender and Code Integrity remain enabled. Record any rejection as a deployment limitation; do not weaken protections. |

## Inherited Wave 1 risk

Wave 1 acceptance records that installer 0.1.18 is unsigned and that an old
uninstaller was blocked by Windows Code Integrity. This was not reproduced for
the Wave 2 B candidate because the candidate was not installed. Do not disable
Code Integrity or Defender to work around it.

Wave 1 did not retain historical cross-record target events or prior values.
Wave 2 history checks must respect this coverage boundary and must not infer
missing events.

The Wave 2 A handoff also records Windows development-Host shutdown timeouts
observed in automated CI without a confirmed source cause. This B investigation
remains open; it could not be reproduced on the dedicated machines because no
candidate Host was installed.
