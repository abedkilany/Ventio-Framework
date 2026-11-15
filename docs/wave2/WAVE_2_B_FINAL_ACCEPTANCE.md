# Wave 2 B final acceptance

## Disposition

**WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**
Last updated: 2026-11-15 12:42 UTC

This candidate is not submitted as verified or production-ready. The package
installed on TEST-02 is commit `17b014125b695e3242e2d9b50b3eb9732a8c5fcb`; all
nine GitHub Actions workflows passed on that package. Report head
`7f08d43692980d8605aa6a9cd4eb8e48b11d3754` also passed all nine workflows.
Windows Acceptance Package run `43653937272` produced the artifact installed
on TEST-02. The owner confirms
the initial first-administrator attempt failed and retrying **Set up Host**
succeeded; the initial TEST-02 failure code and cause are unknown.
SSH verified setup operation `8e5eace6076314dc95c1389f95c707d2` complete at
`HOST_READINESS`, both services Running, PostgreSQL accepting local connections
and Host `/healthz` returning 200. During a later controlled process-crash
test, Defender quarantined TEST-02's `ventio_host.exe`; its Host service is
currently Stopped while PostgreSQL remains Running. TEST-01 SSH has returned;
its Host is healthy and its fresh migration/schema/RLS checks passed, but the
payload manifest has no source commit field. TCP 8443 from TEST-02 to TEST-01
is reachable, while default TLS validation fails. No authenticated Client/API
session or real synchronization was verified. Backup scheduling, physical
backup/restore, runtime-role SQL, full authorization, Wave 1 upgrade, GUI
acceptance and the capability audit remain open. Final status remains
**WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**.

## Candidate and environment

- Repository: `abedkilany/Ventio-Framework`
- Branch: `feature/wave-2-a`
- Draft PR: [#6](https://github.com/abedkilany/Ventio-Framework/pull/6), open,
  unmerged and still Draft
- Starting source commit: `9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61`
- Product/package verification commit: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
- Diagnostic correction commit: `f11bf27e83dd6b206fc63289bbf325471a1ee026`
- Diagnostic package candidate: `b3a5f585b8c641321fa3fc33503eb10ca00837f0`
- Latest tested package commit: `17b014125b695e3242e2d9b50b3eb9732a8c5fcb`
- Host API test-harness correction commit: `e3efc25075388d2ac92543238c99473313d85d79` (verified by CI on `676c9896d3340a04d2dabb4157a9d96c837e3f61`)
- Post-correction CI-tested source/report head: `676c9896d3340a04d2dabb4157a9d96c837e3f61`; all nine GitHub Actions workflows passed, including Host API run `43712289370` and Windows Acceptance Package run `43712289246`.
- Latest acceptance artifact ZIP SHA-256:
  `1c5a1076ab427cd132afc5efd1d7c2610e61376647441c00a628fb04b5f650eb`.
  Installed `Ventio-Setup-0.1.18.exe` SHA-256:
  `E117F4E762ECBDBBF2E0A3B6649FC6887101F5CF08907B293A1CBC929013B020`;
  Authenticode status `NotSigned`.
- Windows Acceptance Package run `43650771423`: success; artifact
  `ventio-wave2-windows-acceptance-b3a5f585b8c641321fa3fc33503eb10ca00837f0`,
  SHA-256 `aea0a03f95589eec58bf70df6a1685ff66a4ba59ce464bda7f683472e2a89173`.
- All nine workflows on latest package commit `17b0141` passed. Windows
  Acceptance Package run `43653937272` produced the artifact. The correction
  in `f11bf27` is included and the package is
  installed on TEST-02; its Client diagnostic path has not been exercised.
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
- Current access: SSH to Codex-1 and Codex-3 identifies TEST-01 and TEST-02.
  All four accounts were previously verified as local Administrators at High
  Integrity. TEST-01's RDP session is disconnected; no GUI was used. The
  earlier power interruption was not a controlled reboot-recovery test.
- Earlier SSH-only provisioning installed Host/PostgreSQL on TEST-01; the
  owner later completed Host setup on TEST-02 from the package at `17b0141`.
  The TEST-02 setup and service evidence is recorded below. GUI acceptance and
  interactive uninstall remain unexecuted under the SSH-only instruction.
- Candidate build evidence: workflow-installed Dart 3.13.7 and .NET SDK 8.0.428
  were used for Host compilation; Flutter 3.44.1, PostgreSQL 16.15, Inno Setup
  6.7.4 and VC++ runtime 14.51.36247.0 are recorded. The packaged evidence
  reports Dart 3.12.1 (Flutter-bundled Dart) and .NET 10.0.403 after the
  Flutter/build steps; these are not the Host compile SDK versions.

## Verification gates

| Gate | Status | Acceptance evidence |
|---|---|---|
| B0 | Partial | SSH is available to both machines. Defender antivirus/real-time protection remain enabled on both; TEST-01 `VerifiedAndReputablePolicyState=0`. No controlled Windows reboot test was run. |
| B1 | PASS in candidate CI | All nine workflows passed on exact package commit `17b0141`; Windows Acceptance Package run `43653937272` produced the artifact. No full physical regression on the test computers. |
| B2 | Partial | On TEST-01 all 40 migration checksums match, `assert_schema()` passes, and 30 public `ventio_*` tables have owner/RLS/FORCE RLS with zero violations. Selected least-privilege checks and a rolled-back identity-API Recovery Authority/empty-queue claim probe pass. Runtime SQL, Wave 1 upgrade, full isolation and complete identity matrix remain open. Earlier fresh TEST-02 migration/RLS checks passed before the crash test. |
| B3 | Partial | TEST-01 `/healthz` is 200 and anonymous `/api/v1/session` is 401. Intermittent safe `HOST_JOB_WORKER_UNAVAILABLE` diagnostics remain unexplained; a current rolled-back claim probe did not reproduce them. No authenticated operations or data-processing scenarios passed. |
| B4 | Partial / blocked | TEST-02 reaches TEST-01 TCP 8443, but default TLS validation fails. No authenticated Client use, real two-device synchronization, offline edit or conflict/receipt recovery passed. GUI-dependent Client, Android, permissions/scaling and uninstall tests are **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**. |
| B5 | Failed — crash recovery; other operations not executed | An orderly Host/PostgreSQL stop/start passed earlier on TEST-02. A later controlled Host-engine crash was followed by Defender quarantining its executable; SCM and manual service start failed. PostgreSQL stayed Running. No scheduled task was found on TEST-01; approval, product backup integrity/retention and disposable restore were not run. |
| B6 | Not complete | Physical gates, capability audit and final acceptance audit are open. |

## Earlier SSH-only physical evidence (before owner clean reinstall)

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
- **Why the first remote attempt stopped:** SSH `Codex-1` token included
  `NT AUTHORITY\NETWORK` SID `S-1-5-2`. Source inspection confirms the first
  administrator named pipe denies this network SID and requires a local
  caller. A remote resume reproduced the same failure. No alternate identity,
  scheduled task, UAC bypass, or security policy bypass was tried. This is a
  deliberate authorization boundary. The owner later completed the local
  broker setup flow; authenticated Client session validation remains blocked.
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
  crash, power-loss or reboot recovery. At this historical checkpoint, Host
  API readiness awaited first-admin completion.
- **TEST-02 and synchronization at the earlier checkpoint:** TEST-02 was not
  altered during the 2026-11-14 resumed run. Its Client package was present, but
  no real connection, second identity, offline operation, conflict or receipt
  was tested. Later Host setup is documented below; CI is not physical
  two-device evidence.

### Manual and unexecuted tests

The owner executed the local Host setup UI on TEST-01, but the Client failed to
establish the authenticated first-administrator session
(`HOST_SESSION_AUTHENTICATION_FAILED`). TEST-02 setup later completed, but no
authenticated Client session was verified there. The TEST-01 failure remains
open because TEST-01 is now unreachable over SSH.

The following remain **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**:

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
- WB-PKG-02 was a confirmed diagnostic defect: the first-admin session path
  replaced a safe Host transport code with `HOST_SESSION_AUTHENTICATION_FAILED`.
  Commit `f11bf27` preserves the validated code; its 28-test focused suite and
  scoped analyzer passed. Package `17b0141`, which includes the correction, is
  installed on TEST-02. The relevant Client diagnostic path has not been
  exercised, and the underlying TEST-01 Host response remains unknown.
- Initial Code Integrity events 3033/3077 blocked the unsigned broker while SAC
  was enforced; after the owner disabled SAC on TEST-01 and the effective state
  was verified, the broker completed provisioning and first-admin handoff.
  TEST-01's clean-install broker also completed, but Client session
  authentication failed (WB-ACC-06). TEST-02 Host provisioning later completed
  after an owner retry. This does not establish that SAC caused the TEST-01
  session error.
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
  on the earlier TEST-01 installation, with selected RLS/least-privilege
  checks. Those results do not certify the new TEST-02 database. Product
  backup and restore were not tested. Wave 1's historical activity coverage boundary
  remains explicit; no events are inferred.
- The Wave 2 A handoff's Windows development-Host shutdown-timeout risk has not
  been reproduced or assessed in this physical run.

## Owner clean-install diagnostic — 2026-11-14

The owner deleted the old Ventio data, reinstalled the verified package, and
used scope `Test-01` / `Codex-01` / `Codex`. Operation
`0793a94d97f202699fbbff49b5db5cc8` reached `complete` at 22:31:08 UTC. The
protected first-admin result remained present, both services were Running, and
`/healthz` returned 200. The UI exported `HOST_SESSION_AUTHENTICATION_FAILED`
at 22:35:55 UTC while showing the credential-storage step. SSH inspection found
no Ventio Event Log provider or recent Ventio Application event. The failure is
after broker handoff; its exact Host HTTP response is not available in the
installed build because of WB-PKG-02.

The owner reports that power was lost after the earlier 21:59:20 UTC session
error; SSH later recorded boot time `2026-11-14T22:02:07.500Z`. The clean-install
error at 22:35:55 UTC occurred after that reboot, so the earlier outage is not
attributed as its cause. Previous physical migration/RLS evidence predates the
data clear and does not certify the new database. At this 2026-11-14 checkpoint,
fresh database/security checks remained pending; selected checks on the new
TEST-02 installation are recorded in the dated evidence below.

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

1. Restore TEST-01 SSH availability without deleting the TEST-02 Host data.
2. Investigate TEST-02's HTTPS certificate validation and verify an
   authenticated Client session using the supported certificate/pinning path.
   Preserve the existing pipe authorization and all Windows protections.
3. Complete the TEST-02 interactive Client/uninstall checks. Record GUI cases as
   **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED** until owner validation is
   performed.
4. Execute the physical migration/upgrade, identity/authorization, Host
   operations, client UI, two-computer offline/reconciliation, scheduling,
   backup integrity/retention and full disposable restore/recovery cases.
5. Map all 22 fixed-scope capability IDs
   to positive/negative evidence, document every unexecuted case and rerun
   affected regressions on the exact final product commit.

**Readiness recommendation:** Do not begin Wave_2_C while first-administrator
session authentication and mandatory physical gates remain open. The unsigned installer/broker
also remains a deployment limitation on machines enforcing code-signing
policies. Keep PR #6 Draft and unmerged. Reassess only after every mandatory
gate passes and owner acceptance is separately recorded. This report does not
claim production readiness.

## 2026-11-15 07:35 UTC — TEST-02 Host setup update

The owner reports the first Host administrator attempt failed and a retry
through **Set up Host** succeeded. SSH confirmed the latest TEST-02 setup
operation `8e5eace6076314dc95c1389f95c707d2` complete at `HOST_READINESS`,
services `VentioHost` and `VentioPostgres` Running/Automatic, PostgreSQL 16.15
accepting local connections at `127.0.0.1:54329`, and
`http://127.0.0.1:8080/healthz` returning HTTP 200. The installed payload
manifest's hashes match the Setup Broker, Host service and PostgreSQL
executable. The tested package commit is
`17b014125b695e3242e2d9b50b3eb9732a8c5fcb`; all nine GitHub Actions
workflows passed on that commit. Windows Acceptance Package run `43653937272`
produced the artifact.

Windows default TLS validation rejected the Host HTTPS `/healthz` requests on
port 8443 for the IP address, machine hostname and localhost. This may differ
from the Client's pinned-certificate path, which remains untested. No TLS
validation or Windows protection was bypassed. TEST-01 SSH timed out at
07:35 UTC, so real two-device synchronization is not possible at this
checkpoint. Fresh database/security checks and backup/restore/recovery tests
on TEST-02 remain outstanding. Disposition stays
**WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**.

At 07:50 UTC, the agent performed an orderly Host/PostgreSQL service restart
over SSH after confirming the TEST-02 machine, service identities, automatic
start mode and Ventio PostgreSQL data path. Both services stopped and started
successfully; PostgreSQL accepted connections and Host `/healthz` returned 200.
No database contents were deleted or rewritten. This does not test crash,
power-loss or Windows reboot recovery.

At 08:04 UTC, read-only checks on the fresh TEST-02 database compared all 40
installed migration SQL files to the ledger: zero missing, extra or checksum
mismatches. `ventio_security.assert_schema()` passed. All 30 checked public
`ventio_*` tables are owned by `ventio_owner` and have RLS plus FORCE RLS.
Runtime and identity API role flags and selected direct-SELECT denials matched
the expected profile. The migration credential remained machine-DPAPI protected
with restrictive ACLs and was never displayed; `assert_runtime()` was not run
because the migration login cannot assume the runtime role. Full scope isolation,
identity API behavior, Wave 1 upgrade, Recovery Authority and backup/restore
remain unverified.

## Latest SSH-only continuation — 2026-11-15 10:15 UTC

The prior 07:35 UTC TEST-01 SSH timeout is resolved. SSH to
`Codex-1@192.168.1.106` again identified `VENTIO-TEST-01`. Its `VentioHost`
and `VentioPostgres` services are Running/Automatic. PostgreSQL 16.15 accepts
local connections on `127.0.0.1:54329`; Host `/healthz` returns 200 and an
unauthenticated `/api/v1/session` request returns 401. The latter is expected
negative-auth evidence only. TEST-01's RDP session is disconnected and the
SSH-only continuation used no GUI.

The protected migration credential was decrypted only in memory and supplied
to `psql` via its environment. All 40 installed migration SQL files matched
the 40 ledger hashes; `ventio_security.assert_schema()` passed. All 30 checked
public `ventio_*` tables are owned by `ventio_owner` and have RLS plus FORCE
RLS; zero catalog violations were found. Runtime, identity API and migrator
roles are not superusers and have no create-db/create-role/BYPASSRLS flags.
Identity API and runtime direct migration-ledger reads are false, migrator
membership in the runtime login is false, and identity API membership in its
intended role is true. `assert_runtime()`, runtime SQL, cross-scope isolation,
Wave 1 upgrade and full identity/API workflows were not executed.

The protected identity-API login and current Recovery Authority witness were
used only in memory. `admit_recovery` passed, and the identity-API connection
invoked `wave2_claim_job()` with an empty queue in a transaction that was
rolled back. This validates current witness admission and an empty-queue
claim path; it does not process a queued job. TEST-01's safe diagnostics
contain `HOST_JOB_WORKER_UNAVAILABLE` events through
`2026-11-15T09:38:14.516937Z`. The current probe did not reproduce those prior
events, and the event format omits their underlying cause.

From TEST-02, TCP `192.168.1.106:8443` succeeded, but ordinary
`Invoke-WebRequest` to `https://192.168.1.106:8443/healthz` failed with
`Could not establish trust relationship for the SSL/TLS secure channel`. No
trust bypass was used. TEST-01's payload manifest contains no source commit
field; current file hashes are `ventio_host.exe`
`5A18C389C5CCE563CAA8A5A5BA9222108B785680AEBED6878996385C3EA1E5F2` and
`VentioHostService.exe`
`AF64049CC55C08A92209E8EC581DF69229D9551F9046418AFEDB1A5EE8F1F3C4`.
These checks therefore cannot be tied to a source commit with the available
installation evidence.

### Controlled TEST-02 process-crash recovery result

After confirming the target machine, service identity/path, exact child
executable path, PostgreSQL readiness and no established Host TCP clients, the
test terminated only `ventio_host.exe` PID 3208 at `2026-11-15T09:59:14Z`.
PostgreSQL remained on PID 4424 and continued accepting local connections.
Microsoft Defender event IDs 1116/1117 then classified
`C:\Program Files\Ventio\host-payload\ventio_host.exe` as
`Trojan:Win32/Bearfoos.A!ml`, threat 2147731250, severity Severe, and
quarantined it while real-time protection was enabled. The Host service did
not recover through its configured SCM restart attempts; its sanitized
startup-failure file reports `HOST_ENGINE_PROCESS_START` and
`InvalidOperationException`. A manual `Start-Service` also failed because
the executable was absent. TEST-02 `VentioHost` remains Stopped and
`VentioPostgres` remains Running. No quarantined file was restored, Defender
exception added, or security control weakened. This is a failed physical
crash-recovery gate and a deployment/security blocker; it is not evidence of a
confirmed application-code defect.

Read-only Task Scheduler inspection found no tasks under `\Ventio\` on
TEST-01. The supported local approval path, product backup scheduling,
integrity/corruption detection, retention, interrupted backup and disposable
restore were not executed. GUI-only acceptance remains **NOT EXECUTED — MANUAL
OWNER VALIDATION REQUIRED**. TEST-02's package source is commit
`17b014125b695e3242e2d9b50b3eb9732a8c5fcb`; TEST-01's installed source commit
is unknown. The report head tested by CI was
`7f08d43692980d8605aa6a9cd4eb8e48b11d3754`, on which all nine GitHub Actions
workflows passed. PR #6 remains open, Draft and unmerged. Final disposition is
**WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**.

## Final continuation checkpoint — 2026-11-15 10:56 UTC

TEST-01 is back on SSH and passed a controlled Host-service restart. Its Host
returned to Running in 18.4 seconds; the local Host liveness endpoint returned
200, while PostgreSQL stayed Running and pg_isready continued to accept
connections. The installed engine hash remained unchanged. The ordinary HTTPS
trust check to localhost:8443 still fails.

The owner reports successful first-administrator setup on retry at TEST-02.
Current SSH evidence nevertheless finds its Host service Stopped and its engine
absent after Defender quarantine; Defender protections remain enabled. The
crash-recovery gate remains failed, and no quarantine restore or security
exception was attempted.

On report head 1e2c5f8e06e15c8643e8202b0753212a2ae70c81, all nine PR workflows completed successfully. Host API run 43704184519 passed, including extension approval/scope/recovery integration and trusted credential reissue. This CI result does not replace physical acceptance evidence. The final Wave_2_B disposition remains
WAVE_2_B — PARTIAL VERIFICATION / BLOCKED. Required blockers include
TEST-02 Defender disposition or an approved signed package, Client TLS/auth,
real two-device sync, product backup/scheduling/restore, and remaining
capability gates. Manual GUI cases remain NOT EXECUTED — MANUAL OWNER
VALIDATION REQUIRED. PR #6 remains open, Draft and unmerged; no Wave_2_C
work or merge was started.

## CI timeout investigation and correction — 2026-11-15 12:01 UTC

On report head 8929a966d9429cc0f74c075d9de74b06e2e97bd5, Host API attempt 1
failed at the Windows child-process shutdown wait in
packages/ventio_host_api/test/api_integration.dart:329 (20-second timeout).
The test passed on the previous Host API run 43704184519 and passed again on
attempt 2 of 43707135745. By 12:04 UTC the retry and all nine workflows had
completed successfully on this pre-correction head.

The failure was intermittent and isolated to the test fixture: it sent
shutdown to the child Host but left stdin open, while the child cancels its
stdin subscription during shutdown. A sibling fixture closes stdin to deliver
EOF on Windows. Correction commit e3efc25075388d2ac92543238c99473313d85d79
closes stdin after the shutdown command. The existing process-restart test
covers the regression and passed on head
676c9896d3340a04d2dabb4157a9d96c837e3f61. All nine workflows passed there.
No production Host defect was confirmed.

Wave_2_B remains PARTIAL VERIFICATION / BLOCKED because the physical Windows
service/quarantine, TLS/authentication, two-device synchronization,
backup/restore and other mandatory acceptance gates remain open. TEST-01's
SSH-only Host restart passed. PR #6 remains Draft and unmerged.
