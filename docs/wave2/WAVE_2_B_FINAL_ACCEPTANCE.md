# Wave 2 B final acceptance

## Disposition

**WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**
Last updated: 2026-11-16 17:43 UTC

Current security investigation: **ROOT CAUSE NOT CONFIRMED**. Defender's current signature `1.463.329.0` cleanly scanned the exact Host executable on both machines using a non-remediating custom scan, but detection history still records Threat ID `2147731250` (`Trojan:Win32/Bearfoos.A!ml`) and `DidThreatExecute=true` on both. Neither the classifier cause nor false-positive status is established. Defender and real-time protection remain enabled. No quarantine item was restored or exclusion added. Further Host execution is blocked pending a Microsoft disposition for the exact hash or explicit owner risk acceptance for isolated testing with Defender enabled.

This candidate is not submitted as verified or production-ready. The current
physical Host artifact on TEST-02 was built from exact PR head
`a7c85ef5617bca9345804106aa17457b2eaf858c`, matching the historically reported
Host SHA-256. Host/PostgreSQL are Running on both machines; their Host
executables match the exact hash. TEST-01 SSH and cross-host pinned TLS are
restored. Both machines return health HTTP 200; uncredentialed session requests
return 401. Defender protections remain enabled, and the event history is
recorded below. GitHub Actions completed with 11/11 PR checks successful on
report head `e6d30b218128d2551f44a9d325e8e1a5363fc93f`; PR #6 remains open,
Draft and unmerged.
Real Client authentication/enrollment, two-device/offline synchronization,
product backup/scheduling/restore, and remaining database/security and GUI
acceptance gates are incomplete. Final status remains
**WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**.

The latest complete product CI candidate is source commit
`e756dcbb3cb58d8feca7e022e337f13ed398d5a5`; its ten associated workflows
passed. Windows acceptance artifact ID `14246616073` has ZIP SHA-256
`0f085fdae0fc9ea05484524c9640a294fa01f467e475d85aab707f5b81aa3d64`. The
physical Host hash on both machines is `5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`, but this checkpoint did not install that artifact or extract its embedded hash file. The two installed Client executable hashes differ: TEST-01 `CD9DFA98CD03A76C2CFC7F8CAD4C570FB963E141B91FD5D19124A4C3206D6BD4`; TEST-02 `FED4BBAE863E9A6DC150D6DEFCAEE3460938C5103E188CD6A663A78194DE8208`. Therefore there is not yet one common verified physical Client candidate.

## Candidate and environment

- Repository: `abedkilany/Ventio-Framework`
- Branch: `feature/wave-2-a`
- Draft PR: [#6](https://github.com/abedkilany/Ventio-Framework/pull/6), open,
  unmerged and still Draft
- Starting source commit: `9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61`
- Product/package verification commit: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
- Diagnostic correction commit: `f11bf27e83dd6b206fc63289bbf325471a1ee026`
- Diagnostic package candidate: `b3a5f585b8c641321fa3fc33503eb10ca00837f0`
- Latest installer package installed on TEST-02: `17b014125b695e3242e2d9b50b3eb9732a8c5fcb`
- Latest physical Host artifact source commit: `a7c85ef5617bca9345804106aa17457b2eaf858c`; Host SHA-256 `5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`
- Host API test-harness correction commit: `e3efc25075388d2ac92543238c99473313d85d79` (verified by CI on `676c9896d3340a04d2dabb4157a9d96c837e3f61`)
- Post-correction CI-tested report head: `0bd9ea9bd439dfd9e87a1ab2c7bd84681bfa4a82`; all nine GitHub Actions workflows passed, including Host API run `43715371756` and Windows Acceptance Package run `43715371820`.
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
- Current access: SSH to Codex-1 identifies TEST-01 and SSH to Codex-3
  identifies TEST-02. Both Host/PostgreSQL services are Running; pinned TLS
  probes between the hosts succeed. All four
  accounts were previously verified as local Administrators at High Integrity.
  No GUI was used. The controlled reboot in the latest checkpoint is separate
  from the earlier power interruption.
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
| B0 | Partial | SSH identifies both machines; Host/PostgreSQL are Running on both. Defender Antivirus and real-time protection are enabled, signature `1.463.324.0`. Defender event history on both is recorded; root cause remains unresolved. |
| B1 | PASS in candidate CI | All 11 checks passed on exact tested code/Host artifact source head `a7c85ef5617bca9345804106aa17457b2eaf858c`; Reproduce run `43767153016` produced the exact-hash Host binary. CI is not physical acceptance evidence. |
| B2 | Partial | TEST-02 fresh DB: 40/40 migrations and ledger checksums, `assert_schema()`, 30 public `ventio_*` tables owner/RLS/FORCE RLS, selected least-privilege checks, `assert_runtime()`, Recovery Authority admission and empty-queue claim probe passed before reboot. Cross-scope authorization, Wave 1 upgrade and restore reconciliation remain open. |
| B3 | Partial | Both `/healthz` endpoints return 200 and unauthenticated `/api/v1/session` returns 401 over mutually pinned TLS 1.2. No authenticated operations or populated durable-job/data-processing scenarios passed. Historical TEST-01 worker errors remain unresolved. |
| B4 | Partial / blocked | No Client process is running on either device. Authenticated enrollment, real two-device synchronization, offline edit or conflict/receipt recovery did not run. Local `flutter devices` listed only Windows, Chrome and Edge; no Android target was available and `adb` was not on PATH. Client pairing, Android UI, permissions/scaling and uninstall tests are **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**. |
| B5 | Partial | Earlier TEST-02 Host crash recovery (108 seconds) and reboot persistence passed. Current inspection found no Ventio scheduled task or product backup directory/set on either machine. Approval, scheduled backup, integrity/corruption/retention, interruption and disposable restore were not run. Defender event history remains unresolved. |
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

## Final SSH-only verification checkpoint — 2026-11-15 14:48 UTC

**Disposition: WAVE_2_B — PARTIAL VERIFICATION / BLOCKED.**

The exact CI-tested PR head is ee167d6d219bdb655edae129441b7a12e15d9420;
all nine GitHub Actions workflows passed. Run IDs and per-workflow results are
in WAVE_2_B_TEST_RESULTS.md. The branch remains feature/wave-2-a; PR #6 remains
open, Draft and unmerged.

Latest SSH evidence confirms TEST-01 Host and PostgreSQL services are Running
and Host /healthz returns 200. Its only current setup status is complete at
HOST_READINESS; authenticated administrator login and Client access remain
unproven. The latest safe Host diagnostic still reports
HOST_JOB_WORKER_UNAVAILABLE, without enough detail to identify the cause.

TEST-02 remains unavailable for Host operations after Defender quarantined its
engine during controlled crash recovery: the Host service is Stopped, the
engine file is absent, PostgreSQL is Running, and Defender protections are
enabled. No quarantine restore or security exclusion was made.

Mandatory physical acceptance is incomplete: B2 representative Wave 1 upgrade
and full identity/scope matrix; B3 authenticated operations and durable data
processing; B4 actual two-computer synchronization, offline recovery and
manual UI scenarios; B5 local approval, scheduled backup, integrity/retention
and disposable restore; and B6 final capability audit. Interactive scenarios
remain NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED. CI success does not
replace these tests. No Wave_2_C work or merge to main was started. Readiness
recommendation for Wave_2_C: not ready until the listed blockers are resolved
and accepted.

## Dual-machine security checkpoint — 2026-11-15 20:29 UTC

**Disposition: WAVE_2_B — PARTIAL VERIFICATION / BLOCKED.**

Exact physical Host evidence: TEST-01's bundled manifest lists 92 verified
files and is missing the required engine `ventio_host.exe` (expected length
8,806,400; SHA-256
`5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`).
Microsoft Defender event 1116/1117 records the severe
`Trojan:Win32/Bearfoos.A!ml` detection and successful remediation on TEST-01
at `2026-11-15T20:10:00Z`; the same threat/path was remediated on TEST-02 at
`2026-11-15T09:59:21Z`. Both `VentioHost` services are stopped (`ExitCode=2`),
both PostgreSQL services remain running, and local `/healthz` connections fail.
TEST-01's service record names `HOST_ENGINE_PROCESS_START`, and SCM logs report
system error 2. Effective Code Integrity policy remains enforced on TEST-01;
no CI event for the Host engine or Host service executable was present in the
inspected period. The evidence establishes Defender quarantine as the
immediate blocker, but does not prove whether the file is benign or malicious.
No quarantined file was restored, no Defender exclusion was added, and no
security feature was disabled.

The latest pre-report PR head `02b8ecc3901527f0b635fd66e5c68c1734d7dff8`
passed all ten GitHub Actions checks. The report-only checkpoint does not
change the product package; physical evidence still applies to the installed
package `17b014125b695e3242e2d9b50b3eb9732a8c5fcb` on TEST-02 and to the
manifest/hash evidence on TEST-01. Readiness recommendation for Wave_2_C:
**not ready**. Resume Host and dependent B3/B4/B5 verification only after a
trusted signed candidate or formal Defender disposition exists for the exact
engine hash. No Wave_2_C work or merge into `main` was started.

## Host security investigation continuation — 2026-11-15

**ROOT CAUSE NOT CONFIRMED. WAVE_2_B — PARTIAL VERIFICATION / BLOCKED.**

See [the Host security investigation](WAVE_2_B_HOST_SECURITY_INVESTIGATION.md)
for sanitized event/quarantine evidence, artifact provenance, source and pipeline
audit, clean rebuilds and exact-hash Defender scans. The original expected Host
hash was independently reproduced from unchanged source and the original
compiler when the original checkout path was used. A temporary worktree path
produces a different but repeatable hash. This explains the build difference;
it does not explain the historical Bearfoos classifier decision.

A confirmed build-evidence defect (WB-SEC-01) was corrected: Host compiler
version/source commit/dirty state/lockfile hash are now recorded before Flutter
changes PATH, and acceptance packaging checks their consistency. This is a
provenance correction, not a claimed antivirus remediation. Runtime source and
compiler flags were not changed for this investigation.

At the 2026-11-15 security-investigation checkpoint, both original engine files
were quarantined and both Host services were stopped; the later 2026-11-16
physical checkpoint below records the subsequent lab state. At that earlier
checkpoint, no Host provisioning, service recovery, real synchronization,
backup/restore or Wave_2_C acceptance work resumed. No exclusion, allow rule,
security-policy bypass or quarantine restore was used. Microsoft-only sample transmission was
authorized by the owner, but there is no confirmed manual submission ID;
automatic sample policy is not evidence of an upload. No vendor response was
awaited. The investigation report records remaining uncertainty explicitly.

The exact reported SHA-256 5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2
was recreated in clean GitHub run 43764300013 on code head
e2c5fb1a592688bdcaf74e09f7a64e0781d4008a. Its on-demand Defender scan passed
in CI (intelligence 1.463.317.0) and on TEST-01 at 21:39:23 UTC and TEST-02 at
21:41:50 UTC (1.463.319.0). Both physical machines retained Antivirus, AM
service and real-time protection. Reproduction files were scanned as data and
never executed; original quarantine and stopped Host services were preserved.
The current static result does not reproduce the earlier detection, but its
historical signature/cloud/runtime cause remains unconfirmed. No runtime
security correction was justified or made; WB-SEC-01 fixes provenance only.

Final code CI checkpoint: all 11 checks passed on exact head
e2c5fb1a592688bdcaf74e09f7a64e0781d4008a at 2026-11-15 21:59 UTC.
The complete snapshot is security-investigation-20261115/final-code-ci.json.
This includes exact-hash reconstruction/Defender evidence and the acceptance
package's new provenance assertions. A later report-only successor does not
change tested code. CI success does not resolve the historical classifier
cause or authorize resuming the blocked physical acceptance gates.


## Physical verification continuation — 2026-11-15 23:41 UTC

Exact tested product artifact source commit: `a7c85ef5617bca9345804106aa17457b2eaf858c`.
The GitHub Actions Reproduce run `43767153016`, artifact ID `14182523609`, produced
a Host binary whose SHA-256 is
`5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`. The artifact
ZIP digest was `sha256:91ab4704a099f58270e98722f0daedf0010fecdb276403cb379b19b6361aca8c`.
On-demand Defender scan of the candidate
on TEST-02 found no threats with signature `1.463.319.0`; Antivirus, AM service and
real-time protection remained enabled. No recent detection was present. This result
neither explains nor dismisses the historical Defender event (**ROOT CAUSE NOT
CONFIRMED**); no quarantined copy was restored or excluded.

TEST-02/Codex-3 (`192.168.1.107`) ran the exact-hash Host. PostgreSQL and Host were
Running, `/healthz` returned HTTP 200 and unauthenticated `/api/v1/session` returned
401. Before reboot, the fresh database passed: 40 packaged migration hashes matched
all 40 ledger entries; `ventio_security.assert_schema()` succeeded; all 30 public
Ventio tables had expected ownership plus RLS and FORCE RLS with zero violations;
selected role/field least-privilege checks and `ventio_security.assert_runtime()`
passed; Recovery Authority admission and an empty job-claim probe passed inside a
rolled-back transaction.

Controlled Host engine termination recovered the service in 108 seconds, with
PostgreSQL Running and health 200. A controlled OS reboot followed; SSH returned and
reported boot time `2026-11-15T23:27:37.500Z`. Both services were Running, the Host
hash still matched, health returned 200, Defender remained enabled, and no recent
threat was recorded. A second SSH check at `2026-11-15T23:41:06Z` confirmed both
services Running, health 200, matching hash, Defender/real-time protection enabled
and zero recent detections. This is current process-crash and reboot-persistence
evidence for TEST-02, not full Wave_2_B acceptance.

TEST-01 (`192.168.1.106`) was unreachable from both the runner and TEST-02 at
2026-11-15 23:31 UTC: TCP ports 22, 3389, 8080 and 8443 failed; ping reported
Destination host unreachable. Cause is unknown. Real two-device synchronization,
offline edits and conflict recovery therefore remain blocked. Authenticated Client
pairing/session, Windows/Android GUI acceptance, product-authorized backup, Task
Scheduler, integrity/corruption/retention, interrupted backup and disposable
restore were not executed. Backup local approval was not bypassed. No application
defect was reproduced or corrected in this checkpoint.

GitHub Actions current head `a7c85ef5617bca9345804106aa17457b2eaf858c`: 11/11 checks
completed successfully — architecture-contracts, dart-core, durable-commands,
host-api, host-engineering-gate, host-recovery, credential-lifecycle,
postgres-adapter, native-client-windows-android, windows-acceptance-package and
reproduce. PR #6 is open, Draft and unmerged.

Current status remains **WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**. Wave_2_C
readiness is **not recommended** until real synchronization and all mandatory
B2–B6 capability gates are evidenced, the unresolved security finding is
dispositioned, and remaining manual owner validation is complete.

## Physical verification continuation — 2026-11-16 08:15 UTC

Exact physical Host artifact source commit remains
`a7c85ef5617bca9345804106aa17457b2eaf858c`; the installed Host SHA-256 on both
machines is `5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`.
SSH now identifies TEST-01/Codex-1 and TEST-02/Codex-3. Both Host and
PostgreSQL services are Running with Automatic start; local `/healthz` returns
200. Defender Antivirus and real-time protection are enabled on both, with
intelligence `1.463.324.0`.

**Read-only Defender evidence:** both hosts list Threat ID `2147731250`,
`Trojan:Win32/Bearfoos.A!ml`. TEST-01 initial detection:
`2026-11-15T20:10:00.859Z`, last status change `20:11:32.332Z`, status ID 3,
file and process resource. TEST-02 initial detection:
`2026-11-15T09:59:21.939Z`, last status change `09:59:45.177Z`, status ID 3,
file resource. Both entries report
`ActionSuccess=true`; current `Get-MpThreat` output reports `IsActive=false`
and `DidThreatExecute=true`. These data do not establish whether the detection
was correct or explain its cause. No quarantined item was restored, no
allow-list/exclusion was added, and no protection setting was changed. The
root cause remains **NOT CONFIRMED**.

**Mutual network probe:** TEST-01's certificate pin is
`2c63e4ffaa97dd4ba06be9d55360ef7fc907d7b3a8db6a889de6356e6d4f6368`; TEST-02's
is `b34d2c33650fb658a40266e6c474289d165938ff90bccadcdb4f9c4b1a99433f`. From
each machine, a TLS 1.2 probe to the other verified the exact fingerprint,
validity dates, DNS SAN and IP SAN; `/healthz` returned HTTP 200 and
unauthenticated `/api/v1/session` returned HTTP 401. The TLS library reported
chain errors for these self-signed certificates; the probe accepted only the
exact expected fingerprint with valid dates and matching SANs.

No `ventio_native_client` process was running on either host. The execution
environment's `flutter devices` showed Windows, Chrome and Edge only; no
Android target was available and `adb` was not on PATH. No Ventio
scheduled task (`\\Ventio\\` or `VentioHostBackups`) was found. The documented
paths `C:\ProgramData\Ventio\Backups` and
`C:\ProgramData\Ventio\Installer\Operations` do not exist on either. Therefore real Client enrollment,
two-device/offline synchronization, authenticated operations and product
backup/restore remain **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**; the
pinned network probe does not substitute for those gates. A fresh TEST-01 DB
recheck was also not executed because its protected PowerShell credential
module was rejected by the existing script policy. No policy bypass was used;
previous B2 evidence remains historical.

No product code changed in this checkpoint. The report-only change does not
alter the tested artifact. PR #6 remains Draft and unmerged; Wave_2_C and merge
to `main` were not started. Final disposition remains
**WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**.

## Live physical recheck — 2026-11-16 11:53 UTC

Fresh SSH command-line evidence confirms both machines are reachable by their
expected Windows identities. On TEST-01 and TEST-02, `VentioHost` and
`VentioPostgres` are Running, local Host `/healthz` returns 200, and
`ventio_host.exe` matches SHA-256
`5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`.
Unauthenticated operation preparation and a fake bearer session both return
401 on both Hosts. This validates rejection of missing/unknown credentials
only, not successful identity, role, tenant, company, or branch authorization.

Defender Antivirus and real-time protection are enabled on both. Security
intelligence versions were `1.463.326.0` on TEST-01 and `1.463.324.0` on
TEST-02. The historical Bearfoos detection remains unresolved; this report
does not declare it a false positive or evidence of infection. No Defender
setting was weakened.

All 11 PR checks completed successfully for report head
`8738c92c7c9d19ae9e962f7bc1366412a019c32e`. This is a documentation-only
continuation from the Host artifact source commit and does not expand physical
test evidence. CI success does not close the remaining acceptance gates.

Interactive Client attempts reached the Dart `startup.first_screen.ready`
trace, but neither process had a native window handle or title after 12
seconds. TEST-01 RDP capture failed with `0x80070057`; TEST-02 produced a black
frame. This prevents verification of visible Client behavior and leaves the
cause unknown. The temporary scheduled launch tasks and Client processes were
removed. Authenticated Client login/enrollment, real two-device sync, offline
recovery, conflict/receipt handling, and visible UI permission/navigation
checks remain **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**. No Android
device/emulator was available.

No Ventio backup task or backup data was present on either host. Product
approval, scheduled backup execution, verification/corruption detection,
retention, interruption, disposable restore and Recovery Authority
reconciliation remain unexecuted. A fresh protected TEST-01 DB credential
recheck remains blocked by the existing script policy; no bypass was used.
The unresolved Defender root cause and all outstanding mandatory gates keep
the readiness recommendation **NOT READY FOR WAVE_2_C**. PR #6 remains Draft
and unmerged.

## Latest physical continuation — 2026-11-16 14:03 UTC

Both test machines are back on the network. SSH identifies the expected
Windows 11 Pro x64 build 26300 hosts, each bundling PostgreSQL 16.15. Host and
PostgreSQL services run under `NT SERVICE\VentioHost` and
`NT SERVICE\VentioPostgres`; the data directory is
`C:\ProgramData\Ventio\PostgreSQL\data`. Both services are Running/Automatic, the
local Host health endpoint returns 200, and both installed Host binaries match
the exact expected SHA-256. Anonymous operation preparation and a fake bearer
session are rejected with 401 on both. Defender and real-time protection are
enabled with current intelligence `1.463.328.0` on both. Cross-host TCP
connectivity on 8443 and 3389 passes in both directions. Exact-pin TLS was not
retested in this checkpoint; the temporary in-memory probe harness failed
during .NET assembly/delegate setup before network access, so 08:15 UTC remains
the latest pinned TLS evidence.

RDP capture on TEST-01 is black and its activation retry failed. SSH shows the
Client process has no native window; TEST-02 has no Client process, and its
active console session was left connected. No authenticated pairing or sync
occurred. Both machines still have no Ventio backup tasks or backup/installer
operations directories. The current TEST-01 database credential recheck is
blocked by the existing script policy. These gates remain incomplete.

GitHub reports ten successful workflow runs on report head
`b33ccbc2e79211ff6dd0a9894f07ca684e26c441`; PR #6 is confirmed open, Draft,
and unmerged. The physically tested Host remains from source commit
`a7c85ef5617bca9345804106aa17457b2eaf858c`. Final status remains
**WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**, with Wave_2_C not recommended.

## Service lifecycle continuation — 2026-11-16 14:18 UTC

Orderly Host service restarts passed on TEST-01 (6.8 seconds) and TEST-02
(5.8 seconds); both returned to Running with PostgreSQL still Running and
local health 200. The installed Host hash was unchanged. On TEST-02, an orderly
PostgreSQL restart passed in 5.5 seconds; Host remained Running, health was
200, and a fake-bearer session request returned 401 after reconnection. Both
Hosts are configured to restart after service failures at 5, 30, and 60
seconds. This configuration read and orderly service restart do not establish
process-crash recovery; the prior controlled crash result remains recorded as
a failure. Backup/restore and authenticated two-device synchronization remain
unverified, so final status remains **WAVE_2_B — PARTIAL VERIFICATION /
BLOCKED**.

## Recovered network and Client provenance checkpoint — 2026-11-16 14:44 UTC

SSH confirms both expected machines are online, both Host/PostgreSQL services
are Running, local health is 200, and the installed Host hash still matches
source commit `a7c85ef5617bca9345804106aa17457b2eaf858c`. Defender and
real-time protection remain enabled with signature `1.463.328.0`; no
protection control was changed. Mutual TCP 8443 and 3389 connections pass.

Physical Client acceptance is now additionally blocked by an installed-image
discrepancy. TEST-01 and TEST-02 both report Client version `0.1.18+19`, but a
manifest comparison found five differing files among 16, including the app
executable, Flutter AOT bundle and three native/plugin DLLs. The main
executable hashes are TEST-01 `CD9DFA98CD03A76C2CFC7F8CAD4C570FB963E141B91FD5D19124A4C3206D6BD4`
and TEST-02 `FED4BBAE863E9A6DC150D6DEFCAEE3460938C5103E188CD6A663A78194DE8208`.
TEST-01's exact Client build provenance is unknown. Its process remains
responsive with no native window; TEST-02 has no Client process. No binary was
replaced because the unified installation also contains the active Host and
the Client installer has shared AppId/previous-install-directory behavior.

No Ventio scheduled task or documented backup directory is present on either
machine. All 11 PR checks passed on CI head
`e6d30b218128d2551f44a9d325e8e1a5363fc93f`, including pairing/enrollment,
extension package approval and recovery, credential reissue, and cleanup.
Authenticated two-device sync, offline/conflict recovery, and physical backup
approval, scheduling, integrity, corruption, retention and restore are not
verified. The required manual visible Client and authorization flows remain
**NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**. The acceptance candidate
remains **WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**; Wave_2_C is not
recommended.

## Final physical acceptance checkpoint — 2026-11-16 17:43 UTC

### PASSED

- Exact lab identity and service state were confirmed by SSH at 17:24 UTC:
  TEST-01/Codex-1 and TEST-02/Codex-3; Windows 11 Pro x64 build 26300;
  VentioHost and VentioPostgres Running/Automatic under their dedicated
  `NT SERVICE` identities.
- The last complete product candidate at `e756dcbb3cb58d8feca7e022e337f13ed398d5a5`
  passed ten GitHub Actions workflows. The Windows package artifact is
  `14246616073` (103,808,079 bytes; ZIP SHA-256
  `0f085fdae0fc9ea05484524c9640a294fa01f467e475d85aab707f5b81aa3d64`).
- Both installed Host executables had SHA-256
  `5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`.
- A custom Defender scan on each exact Host file under signature `1.463.329.0`
  returned exit 0 / `found no threats`; its non-remediating option left the
  file hash and presence unchanged. This is a current static result only.
- WB-CI-02 passed within the full Host Engineering run: `http=503`,
  `HOST_UNAVAILABLE`, 79 audit assertions passed.
- Selected earlier physical TEST-02 checks remain valid as historical
  evidence: migrations 001–040 and checksums, selected RLS/FORCE RLS and
  least-privilege checks, runtime and Recovery Authority admission checks,
  orderly service restart and controlled reboot persistence. They do not
  satisfy the full B2 matrix or upgrade/restore requirements.

### FAILED

- No new reproducible product defect was confirmed in this checkpoint. WB-CI-02
  remains an intermittent test failure with cause unconfirmed, not a confirmed
  product defect. Previously fixed package/diagnostic defects remain recorded
  in the defect register.

### BLOCKED

- **Security decision:** historical Defender detection remains unexplained.
  The owner must provide a Microsoft disposition for the exact Host hash or
  explicitly accept isolated lab execution of this hash while Defender remains
  enabled. No Host API, migration, backup, restore or synchronization behavior
  test was run after the fresh detection review.
- **Candidate equality:** the Client hashes differ despite equal file version;
  no reinstall or file replacement was performed. The candidate installer
  embeds Host and Client in one installation, so equality must be established
  only after the Defender decision and a verified safe update path.
- Full physical B2 cross-scope/RLS, Wave 1 upgrade and identity tests; B3
  authenticated API/operations/data processing; B4 real offline-first
  synchronization; B5 product backup schedule, integrity, retention,
  interruption and full disposable restore; and B6 final audit remain open.
- The 22-capability matrix and the CI run mapping are in
  [test results](WAVE_2_B_TEST_RESULTS.md). CI suite success is not physical
  capability acceptance.

### MANUAL OWNER VALIDATION REQUIRED

After the security decision and common Client candidate are established, the
owner must visually validate: Client first-run and a visible main window on
both devices; certificate fingerprint pinning and pairing with independent
identities; offline create/edit and reconnect with receipts, conflicts and
duplicate prevention; protected-field masking; workspace, saved-view, report,
history and deleted-record navigation; permissions and display scaling; and
any local backup approval/elevation screen. These GUI scenarios were not
performed in this SSH-only checkpoint.

PR #6 remains Draft and unmerged. No Wave_2_C work or `main` merge occurred.
No full CI cycle was initiated for this report checkpoint. Final status remains
**WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**.
