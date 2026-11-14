# Wave 2 B final acceptance

## Disposition

**WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**
Last updated: 2026-11-14 20:41 UTC

This candidate is not submitted as verified or production-ready. All nine
candidate CI workflows passed on the tested product commit and latest observed
report-only PR head before this documentation update. SSH-only physical testing
provisioned PostgreSQL and Host services on TEST-01; migrations 001–040,
selected RLS/least-privilege checks and orderly service restart passed. Host
first-administrator Bootstrap is intentionally local-only and rejects the
remote SSH network token, so the Host API is not ready. The two-device sync,
complete security/operations matrix, backup/restore and GUI acceptance gates
remain unverified. Final status remains **WAVE_2_B — PARTIAL VERIFICATION /
BLOCKED**.

## Candidate and environment

- Repository: `abedkilany/Ventio-Framework`
- Branch: `feature/wave-2-a`
- Draft PR: [#6](https://github.com/abedkilany/Ventio-Framework/pull/6), open,
  unmerged and still Draft
- Starting source commit: `9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61`
- Product/package verification commit: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
- The report updates are documentation-only. All CI and artifact evidence below
  remains tied to the tested product commit `fb341a78…`.
- All nine PR workflows also passed on documentation-only head
  `50832447b8445849692787977f31865883868b6d`; Host API run `43619047598` and
  Windows acceptance-package run `43619047645` are included. No product source
  changed on that head, and the candidate under test remains `fb341a78…`.
- All nine workflows also passed on the latest observed report-only head
  `1d78ca5e80284e8040320544701589063756fd48`, including Host API
  `43623933317`, Native `43623933340` and package `43623933314`. No product
  source changed; product verification remains tied to `fb341a78…`.
- Test machines: VENTIO-TEST-01 (`192.168.1.106`) and VENTIO-TEST-02
  (`192.168.1.107`), Windows 11 Pro 26H2 build 26300.9974, PowerShell
  5.1.26100.9818. Microsoft identifies build 26300 as Windows 11 26H2 in its
  [release information](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information);
  the lab registry's `ProductName` text was stale.
- Current access: SSH identifies Codex-1 on TEST-01 and Codex-3 on TEST-02;
  `query user` reports both RDP sessions Active. The owner unlocked the TEST-02
  desktop during follow-up; all four accounts were previously verified as
  local Administrators at High Integrity. No reboot has been run, so
  post-restart continuity is unverified.
- The SSH-only continuation installed `VentioPostgres` and `VentioHost` on
  TEST-01; see the detailed result below. TEST-02's client install remains
  available as the independent client. GUI acceptance and interactive
  uninstall remain unexecuted under the current SSH-only instruction.
- Candidate build evidence: workflow-installed Dart 3.13.7 and .NET SDK 8.0.428
  were used for Host compilation; Flutter 3.44.1, PostgreSQL 16.15, Inno Setup
  6.7.4 and VC++ runtime 14.51.36247.0 are recorded. The packaged evidence
  reports Dart 3.12.1 (Flutter-bundled Dart) and .NET 10.0.403 after the
  Flutter/build steps; these are not the Host compile SDK versions.

## Verification gates

| Gate | Status | Acceptance evidence |
|---|---|---|
| B0 | Partial | Machine identities, current OS/PowerShell versions, SSH, isolated roots, artifact hashes, Defender and effective TEST-01 policy state verified. No Windows reboot was performed. |
| B1 | **PASS in candidate CI** | All nine candidate workflows passed on product commit `fb341a78…`; all nine also passed on latest checked report-only PR head `96c6573…` (run IDs listed in the SSH-only evidence). This does not substitute for physical acceptance. |
| B2 | Partial | Physical TEST-01 PostgreSQL 16.15 fresh migrations 001–040 and selected RLS/least-privilege profile passed. Wave 1 upgrade, full isolation/identity matrix and Recovery Authority reconciliation remain open. |
| B3 | Partial | Host/PostgreSQL provisioning and orderly service restart passed. First-admin Bootstrap failed through remote SSH by design; Host API and remaining operations/data scenarios are blocked or unexecuted. |
| B4 | Partial / blocked | No real Host connection or two-computer synchronization. GUI-dependent client, Android, permissions/scaling and uninstall tests are **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**. |
| B5 | Partial | Physical services and orderly restart verified. Scheduler, local approval, product backup integrity/retention, interrupted backup, disposable restore and recovery reconciliation not run. |
| B6 | Not complete | Physical gates, capability audit and final acceptance audit are open. |

## SSH-only resumed physical evidence

The resumed execution followed the mandatory SSH/CLI-only rule: no Computer
Use, RDP interaction, screenshots, mouse automation or GUI control. This
section supersedes earlier claims that TEST-01 still had no Host/PostgreSQL
installation.

- **Exact tested product/package commit:**
  `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`. The package ZIP SHA-256 is
  `0c83cd20dab447e6d024fe3d62dd5e9588499deb417a986820bf10d6a13114ae`.
- **Latest checked PR head before this report change:**
  `96c6573c55e497611ace2874569d3eaddac80c1d`, documentation-only; PR #6 was
  open and Draft. All nine associated GitHub Actions workflows passed:
  Host API `43628704098`, Host Persistence `43628704064`, Windows Acceptance
  Package `43628704029`, Durable Commands `43628704015`, Host Engineering
  `43628704020`, Core Foundation `43628704280`, Credential Lifecycle
  `43628704077`, Host Crash Recovery `43628704026`, and Native Flutter /
  Extension Builder `43628704030`. These results do not replace physical
  acceptance.
- **Smart App Control / Defender:** owner disabled Smart App Control on
  TEST-01 for the test. The registry reported
  `VerifiedAndReputablePolicyState=0`; after `CiTool.exe -r`, `CiTool -lp -json`
  reported the related `VerifiedAndReputableDesktop` policy not enforced.
  Other Code Integrity policies remained active. Defender antivirus,
  real-time protection and antimalware service were all enabled. The agent did
  not change Defender, UAC or another policy. Microsoft documents the state
  value and required policy refresh in [Application Control for Windows](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/appcontrol).
- **Provisioning:** the broker at the manifest-verified installed path was run
  using `--setup-new-host`, operation
  `72bf64daac9a47408d37efe80e882cdc`, and the approved disposable scope
  `wave2b-20261114-ventio01` / `company-test01` / `branch-test01`. Payload
  validation, PostgreSQL provisioning, database initialization, Host service
  registration and LAN configuration completed. It failed only at
  `FIRST_ADMINISTRATOR_BOOTSTRAP`, error `HOST_FIRST_ADMIN_PIPE_CONNECT_FAILED`,
  exit 7.
- **Why first admin is blocked:** SSH `Codex-1` token includes
  `NT AUTHORITY\NETWORK` SID `S-1-5-2`. Source inspection confirms the first
  administrator named pipe denies this network SID and requires a local
  caller. A remote resume reproduced the same failure. No alternate identity,
  scheduled task, UAC bypass, or security policy bypass was tried. This is a
  deliberate authorization boundary; local first-admin completion remains a
  manual owner requirement.
- **Physical PostgreSQL and security checks:** PostgreSQL 16.15 is ready on
  `127.0.0.1:54329`. Fresh migrations `001`–`040` matched the packaged files
  and normalized SHA-256 checksums: 40/40 matched, zero mismatches. Checked
  application and identity relations are owned by `ventio_owner` with RLS and
  FORCE RLS. Runtime `ventio_security.assert_runtime()` passed; migration
  ledger reads, owner-role elevation, unauthorized delete planning and direct
  identity secret reads were denied. Runtime and identity API roles are not
  superusers, do not bypass RLS and cannot create roles or databases. Full
  tenant/company/branch authorization and actual identity API flows were not
  executed.
- **Services:** `VentioPostgres` and `VentioHost` are Automatic and Running
  under `NT SERVICE\VentioPostgres` and `NT SERVICE\VentioHost`. An orderly
  stop/start cycle completed and `pg_isready` passed afterward. This is not
  crash, power-loss or reboot recovery. Host API remains unavailable until the
  first administrator is created.
- **TEST-02 and synchronization:** TEST-02 was not altered during the resumed
  run. Its Client package is present, but no real connection, second identity,
  offline operation, conflict or receipt was tested. Existing CI is not
  physical two-device evidence.

### Manual and unexecuted tests

The following are explicitly **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**:

- Complete first administrator setup using the supported local Ventio UI.
- Windows Client first-run/navigation/permissions/scaling and interactive
  uninstall/cleanup scenarios.
- Android UI or device scenarios and any Windows local approval workflow that
  requires a GUI.

Other unexecuted mandatory scenarios include a representative Wave 1 database
upgrade; complete cross-tenant/company/branch isolation and identity/role
authorization; customization rebasing; CSV source-row correlation; durable
Host job retry/cancellation/lost-response behavior; organization/settings and
document-history acceptance; real two-computer offline synchronization,
conflict recovery and protected fields; Task Scheduler; product backup
integrity/corruption/retention/interruption; disposable product restoration and
Recovery Authority reconciliation; forced crash/reboot recovery; and full B6
capability/regression closure.

## Defects and security

- WB-PKG-01 reproduced when Microsoft's moving VC++ runtime URL returned a
  binary outside the pinned size/hash. Commit `fb341a7` pins the
  14.51.36247 endpoint and adds diagnostics without weakening the gate.
  Candidate package workflow run `43605015043` passed, so this defect is
  closed.
- No application-source defect was confirmed or changed during the SSH-only
  continuation. Initial Code Integrity events 3033/3077 blocked the unsigned
  broker while SAC was enforced; after the owner disabled SAC on TEST-01 and
  the effective state was verified, the broker provisioned services/database
  and stopped at the intentional local-only first-admin boundary (WB-ACC-06).
- CI's completed security suites cover direct SQL, least privilege, forced RLS,
  identity/revocation, scoped roles, credential reissue and recovery cases.
- No credentials or production data were used. No password was entered into
  chat, source, scripts or reports.
- Defender remained enabled. The owner disabled Smart App Control on TEST-01
  for this authorized lab test; other Code Integrity policies remained active.
  Installer and application binaries are unsigned. Installation and Client
  launch succeeded on both machines, and TEST-01 provisioning passed the
  earlier SAC-related block after policy state refresh.
  Events 3033 (`2026-11-14 16:54:52.120 UTC`) and 3077
  (`2026-11-14 16:54:53.202 UTC`) identify
  `C:\Program Files\Ventio\host-payload\VentioSetupBroker.exe`, SHA-256
  `bfb4d9bc9f06b11d537a10215ec4dfcf65d9ce78b11150eb53df6a348bd083f4`, and
  policy `{0283ac0f-fff1-49ae-ada1-8a933130cad6}`. They state that the broker
  did not meet Enterprise signing-level requirements at that earlier
  checkpoint. `WinDefend` is RUNNING. After the owner's SAC change, the
  registry reported state 0 and `CiTool.exe -r` followed by `CiTool -lp -json`
  showed the related policy not enforced on TEST-01. The broker then provisioned
  services and database. No organization signing path is currently available,
  so unsigned distribution remains a limitation where code signing is enforced.
  An orderly Host/PostgreSQL service restart passed; crash recovery is untested.
  A silent SSH uninstall on TEST-02 returned 0 but left the RDP Client process
  and six application files after removing its uninstall registration; the
  verified installer restored the registration/version and files (exit 0), but
  the locked RDP session prevents a same-session interactive retest. The Code
  Integrity log also contains earlier 3033/3077 events mentioning
  `unins000.exe`; those predate this probe and cannot be tied to its file hash.
  The known Wave 1 unsigned uninstaller limitation remains a deployment risk.
- Wave 1 acceptance also restricts production distribution pending release
  signing, packaging-license closure and resolution of sole-owner Recovery
  Authority limits. Wave 2 B evidence does not remove those restrictions.
- Physical Host/PostgreSQL provisioning and fresh migrations 001–040 completed
  on TEST-01, with selected RLS/least-privilege checks. Product backup and
  restore were not tested. Wave 1's historical activity coverage boundary
  remains explicit; no events are inferred.
- The Wave 2 A handoff's Windows development-Host shutdown-timeout risk has not
  been reproduced or assessed in this physical run.

## Windows artifact and installation

Candidate artifact from GitHub Actions run `43605015043`:

- Artifact ID: `14117789094`
- Name: `ventio-wave2-windows-acceptance-fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
- Size: 103,796,488 bytes
- Digest: `sha256:0c83cd20dab447e6d024fe3d62dd5e9588499deb417a986820bf10d6a13114ae`

The workflow built the Windows Host payload and Flutter Client Release,
verified its pinned PostgreSQL and Microsoft VC++ prerequisites and Inno Setup
tooling, tested the unified installer package and uploaded the artifact. The
package was copied to both test computers and verified independently at
103,796,488 bytes with the recorded SHA-256. The contained
`Ventio-Setup-0.1.18.exe` is 104,319,695 bytes, SHA-256
`5413f65d86235633d40e1912767dd576303ecb0a7216d4a5e846c977f955977b`, and
Authenticode status `NotSigned`. The unified package was installed on both
machines; TEST-02 installer exit code was 0. The Client launched to Host setup
on TEST-01 and Welcome on TEST-02. On TEST-01 the scope
`wave2b-20261114-ventio01` / `company-test01` / `branch-test01` was entered and
visually verified in the earlier UI-guided phase. At that earlier checkpoint,
Code Integrity blocked the unsigned Setup Broker, no services or database had
been created, and the app reported its protected component unavailable. During
the later SSH-only continuation, after the owner disabled Smart App Control and
the effective state was verified, the same manifest-verified broker completed
Host/PostgreSQL provisioning through LAN configuration. First-admin Bootstrap
then failed on the intended local-only pipe authorization; see the authoritative
SSH-only evidence above. TEST-02 had a prior silent SSH uninstall probe that
removed registration but left the active Client and six files. The verified
installer restored registration/version and files (exit 0). Interactive
uninstall and cleanup verification remain pending.

Initial direct artifact downloads on the lab computers returned HTTP 403.
Identified incomplete candidate files were hashed and removed. Automatic
approval review rejected the local workstation relay attempt as
`blocked by policy`; it was stopped without retaining a local package copy.
The owner then staged the artifact through an approved channel, and both full
copies passed the size/hash check.

## Required before Wave_2_B can be submitted for owner acceptance

1. Complete first-administrator setup using Ventio's supported local interface
   on TEST-01, preserving the current pipe authorization and all remaining
   Windows protections. Then verify Host API readiness and continue physical
   identity/authorization and operational tests through SSH/CLI where possible.
2. Complete the TEST-02 interactive Client/uninstall checks. Record GUI cases as
   **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED** until owner validation is
   performed.
3. Execute the physical migration/upgrade, identity/authorization, Host
   operations, client UI, two-computer offline/reconciliation, scheduling,
   backup integrity/retention and full disposable restore/recovery cases.
4. Map all 22 fixed-scope capability IDs
   to positive/negative evidence, document every unexecuted case and rerun
   affected regressions on the exact final product commit.

**Readiness recommendation:** Do not begin Wave_2_C while the local first-admin
blocker and mandatory physical gates remain open. The unsigned installer/broker
also remains a deployment limitation on machines enforcing code-signing
policies. Keep PR #6 Draft and unmerged. Reassess only after every mandatory
gate passes and owner acceptance is separately recorded. This report does not
claim production readiness.
