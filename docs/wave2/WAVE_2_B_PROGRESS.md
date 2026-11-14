# Wave 2 B verification progress

**Current status: WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**
Current blocker: local first-administrator bootstrap and remaining mandatory acceptance gates.
Branch: `feature/wave-2-a`
Draft PR: [#6](https://github.com/abedkilany/Ventio-Framework/pull/6), open and unmerged
Starting source commit: `9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61`
Product/package verification commit: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
Last updated: 2026-11-14 20:41 UTC

Wave_2_C and merge into `main` are out of scope. The current product candidate
has no application-source changes after the package correction in
`fb341a7`; the acceptance-package workflow and reports are the Wave_2_B
verification additions. Report documents are committed separately; they do not
change the tested product/package commit `fb341a78` or its recorded CI results.

## Gate ledger

| Gate | Status | Evidence / remaining work |
|---|---|---|
| B0 — Environment and tooling | **PARTIAL** | SSH-only access reverified Codex-1/TEST-01 and Codex-3/TEST-02. Both are Windows 11 Pro 26H2, build 26300.9974, PowerShell 5.1.26100.9818. Artifact hashes remain verified. No computer reboot was performed. |
| B1 — Static, core and contract verification | **PASS in candidate CI** | All nine workflows passed on product commit `fb341a78…` and report-only PR head `96c6573c…` (all nine run IDs recorded in test results). CI is not physical acceptance evidence. |
| B2 — PostgreSQL, identity and security | **PARTIAL — physical DB/security profile passed** | TEST-01 physical PostgreSQL 16.15 initialized fresh migrations 001–040 (40 files, no checksum mismatch). Forced RLS and least-privilege smoke checks passed. Wave 1 upgrade, cross-scope authorization matrix, identity API and Recovery Authority tests remain blocked or unexecuted until first-admin bootstrap. |
| B3 — Host operations and data processing | **PARTIAL** | Host/PostgreSQL services were installed and an orderly service restart passed. First-admin bootstrap failed through SSH by design because the remote Windows token is denied by the local-only named-pipe ACL. Host API and remaining processing/operations scenarios did not run. |
| B4 — Native Flutter and offline synchronization | **PARTIAL / BLOCKED** | Client packages remain installed on both computers. No GUI was used in this resumed run. Real Host connection, two-computer synchronization, offline edits, conflicts, receipts and Android/UI cases remain unexecuted; GUI cases are **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**. |
| B5 — Backup, restore and Windows operations | **PARTIAL** | Physical VentioPostgres/VentioHost services run on TEST-01 and orderly restart persistence passed. Scheduling, approval, product backup integrity/retention, interruption, disposable restore and reconciliation remain unexecuted. |
| B6 — Full regression and final acceptance audit | **NOT COMPLETE** | Physical gates, capability audit and final rerun on a delivered package remain open. |

## Lab state and boundary

- Work was performed from the clean `feature/wave-2-a` worktree and through
  SSH to VENTIO-TEST-01 (`192.168.1.106`) and VENTIO-TEST-02
  (`192.168.1.107`). The original checkout was not used for builds or tests.
- Both machines were verified as Windows 11 Pro 26H2 build 26300.9974,
  PowerShell 5.1.26100.9818. Initial free space was 63.5 GB and 147.3 GB
  respectively. The latest OS registry `ProductName` string says Windows 10 Pro,
  but `DisplayVersion=26H2` and build 26300 identify the Windows 11 release.
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

## SSH-only continuation — 2026-11-14 20:31 UTC

This section supersedes earlier statements that TEST-01 had no Host or
PostgreSQL installation; those described the initial pre-resume checkpoint.
The resumed work used SSH and command-line automation only. No Computer Use,
RDP interaction, screenshots, mouse automation or GUI control was used.

- TEST-01 identifies as `VENTIO-TEST-01`; TEST-02 identifies as
  `VENTIO-TEST-02`. `Codex-1` and `Codex-3` SSH sessions are elevated
  Administrators. Both machines report Windows 11 Pro 26H2 build 26300.9974
  and PowerShell 5.1.26100.9818.
- After the owner disabled Smart App Control on TEST-01, the registry reported
  `VerifiedAndReputablePolicyState=0`. `CiTool.exe -r` completed successfully;
  `CiTool -lp -json` then reported the matching
  `VerifiedAndReputableDesktop` policy as not enforced. Other Code Integrity
  policies remain active. Microsoft Defender reported antivirus, real-time
  protection and antimalware service enabled. No Defender or UAC setting was
  changed.
- A preflight verified TEST-01 hostname, elevated identity, policy state,
  Defender state, broker path and hash against the package manifest, and the
  absence of prior Ventio services/data before provisioning.
- Ran the packaged Setup Broker's supported `--setup-new-host` operation using
  the previously owner-approved scope: Tenant `wave2b-20261114-ventio01`,
  Company `company-test01`, Branch `branch-test01`. It validated the payload,
  provisioned PostgreSQL, initialized the database, registered Host, and
  configured LAN settings. It stopped at `FIRST_ADMINISTRATOR_BOOTSTRAP` with
  `HOST_FIRST_ADMIN_PIPE_CONNECT_FAILED` (exit 7). The SSH token carries
  `NT AUTHORITY\NETWORK` (`S-1-5-2`); source inspection confirms the initial
  administrator pipe denies that SID and requires a local caller. A remote
  resume attempt failed for the same reason. This is an intentional security
  boundary; no alternate token, scheduled task or policy bypass was attempted.
- TEST-01 now has `VentioPostgres` and `VentioHost` registered as Automatic and
  Running, under `NT SERVICE\VentioPostgres` and `NT SERVICE\VentioHost`.
  PostgreSQL 16.15 on `127.0.0.1:54329` accepts connections. Host waits for the
  first administrator before binding its API, so `http://127.0.0.1:8080/healthz`
  was unavailable as expected.
- On fresh `ventio_host`, migrations 001–040 were verified against the
  installed package: 40/40 filenames and normalized SHA-256 checksums matched,
  with zero mismatches. Checked application and identity tables are owned by
  `ventio_owner` and have both RLS and FORCE RLS enabled. The
  `ventio_runtime_app` role passed `ventio_security.assert_runtime()`; direct
  migration-ledger reads, owner role elevation, and unauthorized delete plans
  were denied. Runtime and identity API roles are not superusers, do not bypass
  RLS, and cannot create roles/databases. The identity API role has no direct
  SELECT on identity secrets, records or migration ledger. These are physical
  fresh-install/profile checks, not the full tenant/branch or identity API
  acceptance matrix.
- `HostMigrationCredential.psm1` could not be loaded because Windows PowerShell
  policy rejected the unsigned module. No execution-policy bypass was used;
  equivalent checks were performed in memory using machine DPAPI and ACLs.
- An orderly service restart was exercised: stop Host and PostgreSQL, start
  PostgreSQL and wait for readiness, then start Host. Both services returned to
  Running and `pg_isready` accepted connections. This is not a forced-crash or
  computer reboot test. No reboot was performed.
- TEST-02 was not altered in this SSH-only continuation. Its independent client
  remains installed, but no real Host connection or two-device synchronization
  can proceed until first-admin bootstrap is completed locally.

### Current gate disposition

- **Passed physically:** TEST-01 Host/PostgreSQL provisioning through database
  initialization; fresh migrations 001–040/checksums; checked RLS and
  least-privilege profile; normal service restart persistence; SSH identity and
  security-state checks.
- **Blocked:** first administrator, Host API readiness and dependent physical
  identity/authorization and real synchronization tests. Local UI completion is
  required under the product's current local-only first-admin security design.
- **Not executed — manual owner validation required:** Ventio UI first-admin
  completion, interactive Windows Client flows, Android device UI, uninstall
  cleanup, and any test requiring GUI-only local approval. Use the exact status
  `NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED` in the detailed results.
- **Not executed:** representative Wave 1 upgrade fixture; full cross-tenant,
  company and branch authorization matrix; Host operations/data processing;
  Task Scheduler; product backup verification/corruption/retention; interrupted
  backup; disposable product restore and Recovery Authority reconciliation;
  crash/reboot recovery; complete 22-capability matrix and B6 audit.

No application-source defect was confirmed or fixed in this continuation. The
recorded database and service checks do not close Wave_2_B. The required final
disposition remains **WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**.

## Next steps

1. Complete first-administrator bootstrap through Ventio's local supported
   interface on TEST-01. Keep Defender and Code Integrity protections enabled;
   no remote bypass is acceptable. After the local step, SSH can continue with
   API and non-GUI verification.
2. Repeat the uninstall from TEST-02's Codex-3 interactive session and verify
   cleanup; under the SSH-only rule classify it as
   `NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED`.
3. After first-admin bootstrap, verify API readiness and run identity,
   authorization, two-device offline synchronization, Host operations,
   scheduling, backup and disposable restore/reconciliation against the
   isolated test installation.
4. Close the capability matrix only with scenario evidence and update the final
   acceptance report. Any unexecuted mandatory gate keeps
   the disposition **WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**.
