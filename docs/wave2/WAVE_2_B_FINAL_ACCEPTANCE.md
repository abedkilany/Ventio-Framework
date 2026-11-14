# Wave 2 B final acceptance

## Disposition

**WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**
Last updated: 2026-11-14 16:42 UTC

This candidate is not submitted as verified or production-ready. All nine
candidate CI workflows have passed, and the exact artifact was verified,
installed and launched on both dedicated Windows test computers. Host
provisioning, mandatory database/operations scenarios, real two-computer
synchronization and physical backup/restore gates remain incomplete.

## Candidate and environment

- Repository: `abedkilany/Ventio-Framework`
- Branch: `feature/wave-2-a`
- Draft PR: [#6](https://github.com/abedkilany/Ventio-Framework/pull/6), open,
  unmerged and still Draft
- Starting source commit: `9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61`
- Product/package verification commit: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
- Test machines: VENTIO-TEST-01 (`192.168.1.106`) and VENTIO-TEST-02
  (`192.168.1.107`), Windows 11 Pro build 26300, PowerShell 5.1.26100.9711
- Current access: SSH identifies Codex-1 on TEST-01 and Codex-3 on TEST-02;
  `quser` confirms both designated RDP sessions Active. All four accounts were
  previously verified as local Administrators at High Integrity. No reboot has
  been run, so post-restart continuity is unverified.
- Candidate build evidence: workflow-installed Dart 3.13.7 and .NET SDK 8.0.428
  were used for Host compilation; Flutter 3.44.1, PostgreSQL 16.15, Inno Setup
  6.7.4 and VC++ runtime 14.51.36247.0 are recorded. The packaged evidence
  reports Dart 3.12.1 (Flutter-bundled Dart) and .NET 10.0.403 after the
  Flutter/build steps; these are not the Host compile SDK versions.

## Verification gates

| Gate | Status | Acceptance evidence |
|---|---|---|
| B0 | Partial | Machine identities, versions, SSH and active designated RDP sessions, isolated roots, and exact artifact hashes/size are recorded. Package is installed on both machines. Restart continuity and some optional tooling probes remain open. |
| B1 | **PASS in candidate CI** | All nine candidate workflows passed, including Host API run `43605015106` and package workflow run `43605015043`. This does not substitute for physical acceptance. |
| B2 | Partial | PostgreSQL 16 CI covers migrations/bootstrap, RLS, identity, least privilege and logical recovery. No physical migration, representative Wave 1 upgrade, recovery authority reconciliation or isolation matrix has run; Host provisioning is still pending. |
| B3 | Partial | CI covers portions of API, persistence, durable jobs, identity, package approval and recovery. Complete scenario-by-scenario operations/data processing acceptance is open. |
| B4 | Partial | Windows Client installation and launch passed on both machines (TEST-01 Host setup screen; TEST-02 reached Welcome). TEST-02 now needs package repair after the inconclusive silent-uninstall probe. No Host connection, real two-computer sync, offline edit, conflict/receipt recovery, Android UI or permissions/scaling evidence. |
| B5 | Not executed physically | No physical service lifecycle, Task Scheduler/local approval, backup/tamper/retention, interrupted backup or disposable restore/reconciliation. |
| B6 | Not complete | Physical gates, capability audit and final acceptance audit are open. |

## Defects and security

- WB-PKG-01 reproduced when Microsoft's moving VC++ runtime URL returned a
  binary outside the pinned size/hash. Commit `fb341a7` pins the
  14.51.36247 endpoint and adds diagnostics without weakening the gate.
  Candidate package workflow run `43605015043` passed, so this defect is
  closed.
- No application-source defect was confirmed or changed during Wave 2 B.
- CI's completed security suites cover direct SQL, least privilege, forced RLS,
  identity/revocation, scoped roles, credential reissue and recovery cases.
- No credentials or production data were used. No password was entered into
  chat, source, scripts or reports.
- Defender and Code Integrity remained enabled. Installer and application
  binaries are unsigned. Installation and Client launch succeeded on both
  machines without an observed application-control block; `WinDefend` is
  RUNNING and the Code Integrity Operational log is enabled on both. Uninstall
  and Host service lifecycle remain untested. A silent SSH uninstall on TEST-02
  returned 0 but left the RDP Client process and six application files after
  removing its uninstall registration; the separate-session invocation is
  inconclusive and must be repeated interactively. The Code Integrity log also
  contains earlier 3033/3077 events mentioning `unins000.exe`; those predate
  this probe and cannot be tied to its file hash. The known Wave 1 unsigned
  uninstaller limitation remains a deployment risk.
- Wave 1 acceptance also restricts production distribution pending release
  signing, packaging-license closure and resolution of sole-owner Recovery
  Authority limits. Wave 2 B evidence does not remove those restrictions.
- No physical Host provisioning, migrations, test database, service backup or
  restore has been completed. Wave 1's historical activity coverage boundary
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
on TEST-01 and Welcome on TEST-02. Both `VentioHost` and `VentioPostgres`
services remain absent until Host setup completes. TEST-02 is now in a partial
uninstall state: a silent SSH invocation removed its uninstall registration but
left the active Client process and six application files. Its RDP capture shows
the lock screen. Restore the verified package and repeat the uninstall from the
interactive session before treating that lifecycle gate as passed.

Initial direct artifact downloads on the lab computers returned HTTP 403.
Identified incomplete candidate files were hashed and removed. Automatic
approval review rejected the local workstation relay attempt as
`blocked by policy`; it was stopped without retaining a local package copy.
The owner then staged the artifact through an approved channel, and both full
copies passed the size/hash check.

## Required before Wave_2_B can be submitted for owner acceptance

1. Complete the Host setup on TEST-01 through Ventio's supported setup flow and
   verify service identities, ACLs, migrations 001–040 and readiness. RDP
   screenshots and clicks work, but automated long-text entry into the Flutter
   scope fields is unreliable; the owner was asked to enter the disposable IDs
   and start the previously authorized setup.
2. Execute the physical migration/upgrade, identity/authorization, Host
   operations, client UI, two-computer offline/reconciliation, scheduling,
   backup integrity/retention and full disposable restore/recovery cases.
3. Map all 22 fixed-scope capability IDs
   to positive/negative evidence, document every unexecuted case and rerun
   affected regressions on the exact final product commit.

**Readiness recommendation:** Do not begin Wave_2_C. Keep PR #6 Draft and
unmerged. Reassess only after every mandatory gate passes and owner acceptance
is separately recorded. This report does not claim production readiness.
