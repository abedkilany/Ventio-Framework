# Wave 2 B verification progress

**Current status: PARTIAL VERIFICATION / BLOCKED ON PHYSICAL PACKAGE DELIVERY AND UI ACCESS**
Branch: `feature/wave-2-a`
Draft PR: [#6](https://github.com/abedkilany/Ventio-Framework/pull/6), open and unmerged
Starting source commit: `9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61`
Product/package verification commit: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
Last updated: 2026-11-14 15:14 UTC

Wave_2_C and merge into `main` are out of scope. The current product candidate
has no application-source changes after the package correction in
`fb341a7`; the acceptance-package workflow and reports are the Wave_2_B
verification additions.

## Gate ledger

| Gate | Status | Evidence / remaining work |
|---|---|---|
| B0 — Environment and tooling | **PARTIAL / CURRENTLY UNREACHABLE** | SSH as all four named local administrators was verified earlier on the two dedicated Windows 11 Pro 26300 machines. PowerShell is 5.1.26100.9711. Initial RDP TCP/3389 checks passed, but the latest checks found both TCP/22 and TCP/3389 unreachable on both machines while the owner stages the candidate package. TEST-02 previously showed an existing `AbedKilany` session rather than Codex-3/4. No reboot/SSH-continuity check has been run. |
| B1 — Static, core and contract verification | **PASS in candidate CI** | All nine candidate workflows completed successfully, including Host API run `43605015106` and the Windows acceptance-package workflow. All eight pre-existing workflows also passed on starting commit `9bd0e9e…`. This automated evidence does not close physical gates. |
| B2 — PostgreSQL, identity and security | **PARTIAL** | Candidate CI exercised PostgreSQL 16, the checked-in migrations, bootstrap/security profile, direct SQL, least privilege, RLS, identity/revocation, scoped roles, pairing and recovery. Fresh migration and compatibility tests were not run on either physical test machine; there is no physical upgrade fixture. |
| B3 — Host operations and data processing | **PARTIAL** | Candidate CI covered Host API, persistence, durable commands, credential lifecycle, extension package approval and crash/restore test suites. Full scenario-by-scenario Wave 2 capability acceptance and physical Host operations remain open. The Wave 2 A handoff's Windows Host shutdown-timeout risk has not been reproduced or assessed. |
| B4 — Native Flutter and offline synchronization | **BLOCKED ON PHYSICAL ACCESS** | Windows and Android tests/builds passed in GitHub-hosted CI. No candidate was installed or launched on a test computer; no Android device UI test or real two-computer synchronization/offline/conflict scenario ran. CUA and Sky could not activate the RDP window (`failed to activate captured window`). |
| B5 — Backup, restore and Windows operations | **NOT EXECUTED PHYSICALLY** | No Host service or PostgreSQL deployment was installed on either test computer. No physical scheduler, local approval, backup, corruption, retention, restore or Recovery Authority reconciliation test ran. CI logical database recovery tests are separate evidence. |
| B6 — Full regression and final acceptance audit | **NOT COMPLETE** | Physical gates, capability audit and final rerun on a delivered package remain open. |

## Lab state and boundary

- Work was performed from the clean `feature/wave-2-a` worktree and through
  SSH to VENTIO-TEST-01 (`192.168.1.106`) and VENTIO-TEST-02
  (`192.168.1.107`). The original checkout was not used for builds or tests.
- Both machines were verified as Windows 11 Pro build 26300, PowerShell
  5.1.26100.9711. Initial free space was 63.5 GB and 147.3 GB respectively.
- All four SSH identities (`Codex-1` through `Codex-4`) were verified as
  local Administrators at High Integrity. RDP endpoints accepted TCP
  connections during initial preflight; a later check found TCP/22 and TCP/3389
  unreachable on both machines. The active session identity was not verified as
  the designated test identity.
- TEST-01 contains only the isolated starting-source archive in
  `C:\VentioTest\downloads`; TEST-02's downloads directory is empty.
  The source archive is for `9bd0e9e…`, not the built candidate.
- No Ventio services, product processes, PostgreSQL cluster, test database,
  installed product, or candidate installer is present on either test machine.
- Candidate artifact download attempts from the lab returned HTTP 403 or left
  incomplete files. Those exact partial files were hashed, their Codex-owned
  transfer processes were stopped, and only the incomplete files were removed.
  No installer was run. A local relay attempt was rejected by automatic
  approval review with `blocked by policy`; it was stopped without saving the
  package locally. The owner is now staging the artifact through an approved
  channel. The exact artifact path was last confirmed absent before both
  machines became unreachable, so staging remains unverified.
- Defender and Code Integrity remained enabled. No system accounts, policies,
  network configuration, non-Ventio services or preserved data were changed.

## Completed work

1. Confirmed the source commit and read the Wave 2 B plan, scope/acceptance,
   Wave 2 A handoff/progress, platform contracts, Wave 1 final acceptance,
   PostgreSQL security acceptance and Windows physical acceptance guide.
2. Verified the clean physical baseline, SSH identities, machine versions,
   permissions and isolated test roots.
3. Added a GitHub-hosted Windows acceptance-package workflow. Its first run
   reproduced WB-PKG-01. The version-specific Microsoft runtime URL and
   diagnostics were corrected on `fb341a7`; the candidate package workflow
   then passed on the exact PR head.
4. Re-ran the existing CI matrix against `fb341a78…`; all nine candidate
   workflows completed successfully.
5. Recorded the artifact metadata and cleaned the incomplete transfer files
   after confirming their exact machine, path, owner and hashes.

## Next steps

1. Verify the owner-staged package's exact length and SHA-256 on both test
   machines; inspect its contents and installer signature before running it.
2. If the exact artifact passes verification, execute the authorized
   installation and Windows service/migration gates, then revisit whether the
   UI controller can operate the designated RDP sessions.
3. Continue B2/B3 on the physical Host; run real two-machine client scenarios
   and the physical backup/scheduler/restore cases only against the isolated
   test installation.
4. Close the capability matrix only with scenario evidence and update the final
   acceptance report. Any unexecuted mandatory gate keeps
   the disposition **PARTIAL VERIFICATION / BLOCKED**.
