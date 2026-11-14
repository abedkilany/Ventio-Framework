# Wave 2 B verification progress

**Current status: PARTIAL VERIFICATION / BLOCKED ON SIGNING PATH AND REMAINING ACCEPTANCE GATES**
Branch: `feature/wave-2-a`
Draft PR: [#6](https://github.com/abedkilany/Ventio-Framework/pull/6), open and unmerged
Starting source commit: `9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61`
Product/package verification commit: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
Last updated: 2026-11-14 18:43 UTC

Wave_2_C and merge into `main` are out of scope. The current product candidate
has no application-source changes after the package correction in
`fb341a7`; the acceptance-package workflow and reports are the Wave_2_B
verification additions. Report documents are committed separately; they do not
change the tested product/package commit `fb341a78` or its recorded CI results.

## Gate ledger

| Gate | Status | Evidence / remaining work |
|---|---|---|
| B0 — Environment and tooling | **PARTIAL** | SSH is currently working as Codex-1 on VENTIO-TEST-01 and Codex-3 on VENTIO-TEST-02; both designated RDP sessions are Active. Both Windows 11 Pro 26300 / PowerShell 5.1.26100.9711 identities and candidate ZIPs were checked. The ZIP is 103,796,488 bytes with SHA-256 `0c83cd20…13114ae` on each machine. No reboot/SSH-continuity check has been run. |
| B1 — Static, core and contract verification | **PASS in candidate CI** | All nine workflows passed on product commit `fb341a78…` (Host API `43605015106`; package `43605015043`) and on latest observed report-only PR head `1d78ca5…` (Host API `43623933317`; package `43623933314`; Native `43623933340`). Report commits contain no product-source changes. All eight pre-existing workflows passed on starting commit `9bd0e9e…`. This automated evidence does not close physical gates. |
| B2 — PostgreSQL, identity and security | **PARTIAL** | Candidate CI exercised PostgreSQL 16, the checked-in migrations, bootstrap/security profile, direct SQL, least privilege, RLS, identity/revocation, scoped roles, pairing and recovery. Fresh migration and compatibility tests were not run on either physical test machine; there is no physical upgrade fixture. |
| B3 — Host operations and data processing | **PARTIAL** | Candidate CI covered Host API, persistence, durable commands, credential lifecycle, extension package approval and crash/restore test suites. Full scenario-by-scenario Wave 2 capability acceptance and physical Host operations remain open. The Wave 2 A handoff's Windows Host shutdown-timeout risk has not been reproduced or assessed. |
| B4 — Native Flutter and offline synchronization | **PARTIAL / BLOCKED** | The candidate Windows Client was installed and launched on both computers. TEST-01's scope was entered and setup invoked through Ventio; after UAC approval, Code Integrity blocked the unsigned Setup Broker. The owner unlocked TEST-02's Codex-3 RDP session, but Computer Use could not control its desktop; the interactive uninstall retest remains pending and SSH still sees the install. No Host connection, two-computer synchronization, offline/conflict scenario or Android device UI test has run. |
| B5 — Backup, restore and Windows operations | **NOT EXECUTED PHYSICALLY** | No Host service or PostgreSQL deployment was installed on either test computer. No physical scheduler, local approval, backup, corruption, retention, restore or Recovery Authority reconciliation test ran. CI logical database recovery tests are separate evidence. |
| B6 — Full regression and final acceptance audit | **NOT COMPLETE** | Physical gates, capability audit and final rerun on a delivered package remain open. |

## Lab state and boundary

- Work was performed from the clean `feature/wave-2-a` worktree and through
  SSH to VENTIO-TEST-01 (`192.168.1.106`) and VENTIO-TEST-02
  (`192.168.1.107`). The original checkout was not used for builds or tests.
- Both machines were verified as Windows 11 Pro build 26300, PowerShell
  5.1.26100.9711. Initial free space was 63.5 GB and 147.3 GB respectively.
- All four SSH identities (`Codex-1` through `Codex-4`) were previously
  verified as local Administrators at High Integrity. The current SSH
  connections identify VENTIO-TEST-01/Codex-1 and VENTIO-TEST-02/Codex-3;
  `quser` shows both designated RDP sessions Active.
- The candidate artifact is present on both machines at
  `C:\VentioTest\downloads\ventio-wave2-windows-acceptance-fb341a78eca1bb897e2ce09f1271dae39bbd7d11-verified.zip`.
  Both copies are 103,796,488 bytes and SHA-256
  `0c83cd20dab447e6d024fe3d62dd5e9588499deb417a986820bf10d6a13114ae`.
  The installer inside the package hashes to
  `5413f65d86235633d40e1912767dd576303ecb0a7216d4a5e846c977f955977b` and
  Authenticode reports `NotSigned`.
- The unified installer was run on both machines. TEST-01 is machine-wide under
  `C:\Program Files\Ventio`; TEST-02's first launch reached Welcome. The
  TEST-02 package was restored through the verified installer after the
  inconclusive silent-uninstall probe (exit code 0). The owner later unlocked
  its RDP desktop, but Computer Use could not operate Start/Settings. Latest
  SSH confirms the install directory and uninstall registration remain, so no
  interactive uninstall retest was completed. `VentioPostgres` and
  `VentioHost` are absent on both machines.
- On TEST-01 the exact disposable scope was entered and visually checked:
  Tenant `wave2b-20261114-ventio01`, Company `company-test01`, Branch
  `branch-test01`. Ventio launched `VentioSetupBroker.exe` and the authorized
  UAC approval was accepted. Windows Code Integrity then blocked the broker:
  events 3033 and 3077 at 2026-11-14 16:54:52–16:54:53 UTC identify the exact
  path under `C:\Program Files\Ventio\host-payload` and say it did not meet
  Enterprise signing-level requirements (policy
  `{0283ac0f-fff1-49ae-ada1-8a933130cad6}`). The 67,592,883-byte broker is
  `NotSigned`, SHA-256
  `bfb4d9bc9f06b11d537a10215ec4dfcf65d9ce78b11150eb53df6a348bd083f4`.
  Read-only `CiTool.exe -lp` inspection on both machines identifies this as
  `VerifiedAndReputableDesktop`, signed, authorized and currently enforced.
  The owner confirmed no organizational signing path is currently available.
  No Host/PostgreSQL service or `C:\ProgramData\Ventio` was created. This is a
  confirmed deployment-policy incompatibility; no protection was changed.
- Defender and Code Integrity remain enabled. Installer and application
  binaries are unsigned; `WinDefend` is RUNNING and the Code Integrity
  Operational log is enabled on both machines. The installer and Client launch
  succeeded, but TEST-01's Setup Broker was blocked as described above. No
  security setting, account, network configuration, non-Ventio service or
  preserved data was changed.
- Latest read-only SSH check reconfirmed both machine hostnames and that
  `Codex-1`/`Codex-3` RDP sessions report Active. Both machines still have no
  `VentioHost` or `VentioPostgres` service and no `C:\ProgramData\Ventio`.
  The owner unlocked TEST-02's RDP desktop, which was visible during the check;
  Computer Use could not activate Start/Settings and the window later minimized.
  TEST-02's Ventio install directory and uninstall registration remain present;
  `unins000.exe` was not running. No interactive uninstall was performed.

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
5. Recorded the artifact metadata and cleaned the identified incomplete
   transfer files after confirming their exact machine, path, owner and hashes.
6. Verified the approved artifact ZIP hash and size on both machines, installed
   the unified package, and launched the Client on both RDP sessions.
7. Ran a TEST-02 silent-uninstaller probe from SSH. It returned 0 but left the
   Client process and six app files while removing uninstall registration; this
   is inconclusive across the SSH/RDP session boundary and needs an interactive
   rerun after repair.
8. Entered and verified the TEST-01 disposable Host scope, approved the expected
   Ventio Setup Broker UAC request, and correlated its failure to new Code
   Integrity 3033/3077 events for the exact installed broker path and hash.
   Confirmed both services and `C:\ProgramData\Ventio` remain absent.
9. Restored TEST-02 from the verified installer (exit code 0); registry version
   and application files were restored. Its locked RDP session prevents visual
   confirmation and the required interactive uninstall retest.
10. Verified the active Code Integrity policy metadata on both computers. The
    policy is signed, authorized and enforced; the owner confirmed that no
    institutional code-signing route is available at this time.
11. Confirmed all nine pull-request workflows also passed on report-only head
    `50832447b8445849692787977f31865883868b6d`, including Host API run
    `43619047598`. Product verification remains tied to
    `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`.
12. Rechecked machine identities, active RDP session state and absence of Host
    services/data over SSH. The owner unlocked TEST-02's RDP desktop. Computer
    Use could display it but could not control Start/Settings; a latest SSH
    check confirms the Ventio directory and uninstall key remain, with no
    uninstaller process. The interactive uninstall retest remains unexecuted.
13. Verified all nine GitHub Actions workflows completed successfully on the
    latest observed report-only PR head `1d78ca5e80284e8040320544701589063756fd48`.
    Product verification remains tied to `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`.

## Next steps

1. Establish an organization-approved signing path and supply a release
   candidate whose Setup Broker satisfies the existing Enterprise signing
   policy; the owner reports no such path is currently available. Then repeat
   the exact supported Host setup on TEST-01 with Code Integrity enabled. Do not
   retry by weakening policy.
2. Repeat the uninstall from TEST-02's Codex-3 interactive session when the UI
   can be controlled, then verify complete cleanup. The desktop was unlocked,
   but this run's Computer Use could not operate it.
3. After Host provisioning succeeds, verify service identities, ACLs, fresh
   migrations and readiness; continue B2/B3 on that isolated Host and run real two-machine client scenarios
   and the physical backup/scheduler/restore cases only against this test
   installation.
4. Close the capability matrix only with scenario evidence and update the final
   acceptance report. Any unexecuted mandatory gate keeps
   the disposition **PARTIAL VERIFICATION / BLOCKED**.
