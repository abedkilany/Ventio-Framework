# Wave 2 B final acceptance

## Disposition

**WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**

This candidate is not submitted as verified or production-ready. All nine
candidate CI workflows have passed. Mandatory physical Windows, two-computer
synchronization and backup/restore gates have not run. The package is not yet
verified on the test machines.

## Candidate and environment

- Repository: `abedkilany/Ventio-Framework`
- Branch: `feature/wave-2-a`
- Draft PR: [#6](https://github.com/abedkilany/Ventio-Framework/pull/6), open,
  unmerged and still Draft
- Starting source commit: `9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61`
- Product/package verification commit: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
- Test machines: VENTIO-TEST-01 (`192.168.1.106`) and VENTIO-TEST-02
  (`192.168.1.107`), Windows 11 Pro build 26300, PowerShell 5.1.26100.9711
- Accounts: Codex-1/2 and Codex-3/4 verified as local Administrators at High
  Integrity through SSH. RDP endpoints are reachable; designated RDP session
  identities and UI control remain outstanding.

## Verification gates

| Gate | Status | Acceptance evidence |
|---|---|---|
| B0 | Partial | Machine identity, versions, SSH access, admin integrity, clean Ventio baseline and isolated roots recorded. Package staging, designated RDP sessions and restart continuity remain open. |
| B1 | **PASS in candidate CI** | All nine candidate workflows passed, including Host API run `43605015106` and package workflow run `43605015043`. This does not substitute for physical acceptance. |
| B2 | Partial | PostgreSQL 16 CI covers migrations/bootstrap, RLS, identity, least privilege and logical recovery. No physical fresh install, physical representative Wave 1 upgrade or physical isolation matrix. |
| B3 | Partial | CI covers portions of API, persistence, durable jobs, identity, package approval and recovery. Complete scenario-by-scenario operations/data processing acceptance is open. |
| B4 | Blocked | No physical Windows install/launch, Android UI, real two-computer sync, offline edit, conflict/receipt recovery or UI permissions/scaling evidence. |
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
- Defender and Code Integrity remained enabled. The candidate's physical
  application-control behavior is unknown because the installer was not run.
- No physical migrations, database, service, backup or restore have been
  performed. Wave 1's historical activity coverage boundary remains explicit;
  no events are inferred.
- The Wave 2 A handoff's Windows development-Host shutdown-timeout risk has not
  been reproduced or assessed in this physical run.

## Windows artifact and installation

Candidate artifact from GitHub Actions run `43605015043`:

- Artifact ID: `14117789094`
- Name: `ventio-wave2-windows-acceptance-fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
- Size: 103,796,488 bytes
- Digest: `sha256:0c83cd20dab447e6d024fe3d62dd5e9588499deb417a986820bf10d6a13114ae`

The workflow built the Windows Host payload and Flutter Client Release,
verified its pinned PostgreSQL and Microsoft VC++ prerequisites and the Inno
Setup bootstrapper, tested the unified installer package and uploaded the
artifact. This is build evidence only. The artifact was not installed, launched
or tested under Windows application control on either physical computer.

Direct artifact downloads on the lab computers returned HTTP 403. Identified
incomplete candidate files were hashed and removed. Automatic approval review
rejected the local workstation relay attempt as `blocked by policy`; it was
stopped without retaining a local package copy. The owner is staging the
verified artifact through an approved channel.

## Required before Wave_2_B can be submitted for owner acceptance

1. Verify artifact size and digest on both test computers.
2. Install the exact candidate with Defender and Code Integrity enabled; record
   installer signature/application-control behavior, Host/Client launch and
   service lifecycle.
3. Execute the plan's physical migration, identity/authorization, Host
   operations, client UI, two-computer offline/reconciliation, scheduling,
   backup integrity/retention and full disposable restore/recovery cases.
4. Map all 22 fixed-scope capability IDs
   to positive/negative evidence, document every unexecuted case and rerun
   affected regressions on the exact final product commit.

**Readiness recommendation:** Do not begin Wave_2_C. Keep PR #6 Draft and
unmerged. Reassess only after every mandatory gate passes and owner acceptance
is separately recorded. This report does not claim production readiness.
