# Wave 2 B test results

**Status: WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**
Starting source: `9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61`
Product/package verification commit: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
Host API test-harness correction commit: `e3efc25075388d2ac92543238c99473313d85d79`
Latest physically tested Host artifact source commit: `a7c85ef5617bca9345804106aa17457b2eaf858c`; installed Host SHA-256 `5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`
Latest CI-verified PR head: `a7c85ef5617bca9345804106aa17457b2eaf858c` (11/11 checks passed)
Branch: `feature/wave-2-a`; Draft PR: [#6](https://github.com/abedkilany/Ventio-Framework/pull/6)
Report date: 2026-11-16
Last updated: 2026-11-16 08:15 UTC

The previously reported `b3a5f585` workflow snapshot is historical and was
superseded by package commit `17b014125b695e3242e2d9b50b3eb9732a8c5fcb`.
All nine workflows passed on that exact commit. Windows Acceptance Package
run `43653937272` produced the artifact installed on TEST-02; Host setup
subsequently completed there.
The artifact ZIP SHA-256 is
`1c5a1076ab427cd132afc5efd1d7c2610e61376647441c00a628fb04b5f650eb`. The
installer SHA-256 is
`E117F4E762ECBDBBF2E0A3B6649FC6887101F5CF08907B293A1CBC929013B020` and
Authenticode reports `NotSigned`. Installer package
`17b014125b695e3242e2d9b50b3eb9732a8c5fcb` remains installed on TEST-02; for
the current lab continuation, its Host engine was replaced with the exact-hash
binary rebuilt from the GitHub artifact at `a7c85ef`. No quarantined file was
restored. This does not mean the physical acceptance gates passed. TEST-01's
installed payload manifest has no source commit field, so physical results
from that Host cannot be attributed to a repository commit with available
evidence.

All nine GitHub Actions workflows completed successfully on report head
`7f08d43692980d8605aa6a9cd4eb8e48b11d3754`: Core Foundation
`43693434672`, Host Engineering `43693434611`, Host Persistence
`43693434571`, Windows Acceptance Package `43693434492`, Durable Commands
`43693434656`, Credential Lifecycle `43693434549`, Host API `43693434504`,
Host Crash Recovery `43693434577`, and Native Flutter/Extension Builder
`43693434521`. This commit changed documentation only; these CI results do
not replace physical acceptance.

The report-only PR head `50832447b8445849692787977f31865883868b6d` also
completed all nine GitHub Actions workflows successfully: Core Foundation
`43619047607`, Host Engineering `43619047608`, Host Persistence `43619047677`,
Durable Commands `43619047612`, Crash Recovery `43619047596`, Credential
Lifecycle `43619047822`, Windows Acceptance Package `43619047645`, Native
Flutter/Extension Builder `43619047614`, and Host API `43619047598`. No product
code changed on that report-only commit; the tested product candidate remains
`fb341a78eca1bb897e2ce09f1271dae39bbd7d11`.

All nine workflows completed successfully on the latest observed report-only
PR head `1d78ca5e80284e8040320544701589063756fd48`: Host Persistence
`43623933401`, Durable Commands `43623933305`, Windows Acceptance Package
`43623933314`, Core Foundation `43623933304`, Host Engineering `43623933279`,
Host Crash Recovery `43623933428`, Credential Lifecycle `43623933267`, Native
Flutter/Extension Builder `43623933340`, and Host API `43623933317`. This head
also changed documentation only; product verification remains tied to
`fb341a78eca1bb897e2ce09f1271dae39bbd7d11`.

After resuming physical verification, all nine workflows also completed
successfully on report-only head `96c6573c55e497611ace2874569d3eaddac80c1d`:
Host API `43628704098`, Host Persistence `43628704064`, Windows Acceptance
Package `43628704029`, Durable Commands `43628704015`, Host Engineering
`43628704020`, Core Foundation `43628704280`, Credential Lifecycle
`43628704077`, Host Crash Recovery `43628704026`, and Native Flutter /
Extension Builder `43628704030`. This was documentation-only; product/package
testing remains tied to `fb341a78…`. The documentation update now being prepared
will create a newer PR head and may start CI; no workflow was stopped.

## Environment and fixtures

| Machine | Verified identity | OS / build | PowerShell | Initial free C: | Recorded state |
|---|---|---|---|---:|---|
| VENTIO-TEST-01 (`192.168.1.106`) | `Codex-1`, `Codex-2`; Administrators, High Integrity (previously verified) | Windows 11 Pro 26H2, 10.0.26300.9974 (previously verified) | 5.1.26100.9818 | 63.5 GB initial | Currently unreachable from the runner and TEST-02 on SSH/RDP/Host ports 22/3389/8080/8443; cause unknown. Its prior Host/B2 evidence remains historical and its installed payload cannot be tied to a source commit. |
| VENTIO-TEST-02 (`192.168.1.107`) | `Codex-3`, `Codex-4`; Administrators, High Integrity (previously verified) | Windows 11 Pro 26H2, build 26300 | 5.1.26100.9818 | 147.3 GB initial | Host/PostgreSQL Running after controlled process-crash recovery and Windows reboot. Exact Host hash matches `5a18…e5f2`; Defender and real-time protection enabled, signature `1.463.319.0`. |

SSH succeeded for all four named accounts during initial preflight. At the
2026-11-15 07:35 UTC checkpoint, SSH identified TEST-02/Codex-3 but timed out
for TEST-01/Codex-1. `quser` had previously shown active RDP sessions
`codex-1` and `codex-3`.
After the first session error, the owner reported a power interruption. SSH
later recorded boot time `2026-11-14T22:02:07.500Z`; Host/PostgreSQL services
and health were subsequently observed ready on that earlier install. This was
an unplanned reboot, not a controlled crash-recovery test. The later clean
install occurred after that reboot.
On the 2026-11-14 check, SSH returned VENTIO-TEST-01 for Codex-1 and
VENTIO-TEST-02 for Codex-3; `query user` reported RDP session ID 4 as Active on
both. The owner unlocked the TEST-02 desktop; its RDP window showed the Windows
desktop, but Computer Use could not open Start/Settings and the window later
minimized. No uninstaller process was found and the install directory and
uninstall key remained. No interactive uninstall was performed.
Earlier in this run, RDP screens could be captured and clicked. Long
`type_text` calls were unreliable, but focused key-by-key input populated and
visibly verified all three TEST-01 scope IDs; no owner intervention was
required for that entry.

The exact starting-source archive on TEST-01 is
`C:\VentioTest\downloads\Ventio-Framework-9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61.zip`,
2,028,317 bytes, SHA-256
`2cd275a26055734c4847bcc923310209b11127d48b0de334ae3c1df27360186c`.
This is source evidence only and not the built candidate.

The initial Flutter SDK download attempt on TEST-01 was stopped because its
observed transfer rate was impractical; its exact partial files were removed.
The candidate's workflow build evidence records Windows Server 2025
10.0.26100, Flutter 3.44.1, PostgreSQL 16.15, Inno Setup 6.7.4 and VC++
14.51.36247.0. The evidence file reports Dart 3.12.1 and .NET 10.0.403 after
the Flutter/build steps; the workflow separately installs Dart 3.13.7 and the
.NET 8 SDK for Host compilation. Neither lab machine was used for local product
builds.

## Candidate CI

All nine candidate workflows completed successfully. The Host API job passed
its trusted same-device credential-reissue integration test and disposed its
private PostgreSQL fixture.

| Workflow | Run ID | Candidate status | Coverage / notes |
|---|---:|---|---|
| Ventio Core Foundation | `43605015119` | **PASS** | Core Dart and architecture/contract gates |
| Ventio Host Engineering Gate | `43605015112` | **PASS** | Dart format/analyzer; PostgreSQL 16; migration/security bootstrap; OS separation, migration compatibility, recovery boundary and bounded-performance audit |
| Ventio Durable Commands | `43605015199` | **PASS** | Durable command and disposable PostgreSQL integration suite |
| Ventio Host Persistence | `43605015100` | **PASS** | PostgreSQL persistence integration suite |
| Ventio Host Crash Recovery | `43605015133` | **PASS** | Process interruption, retry, fresh-cluster logical restore and cleanup |
| Ventio Credential Lifecycle | `43605015144` | **PASS** | Credential lifecycle and revocation integration |
| Native Flutter Client and Extension Builder | `43605015035` | **PASS** | Contract examples, localization gate, format/analyzer, Flutter tests, Windows Extension Builder integration, Windows Debug/Release and Android Debug/Release builds |
| Wave 2 B Windows Acceptance Package | `43605015043` | **PASS** | Windows Host payload, pinned PostgreSQL runtime tools, Flutter Windows Release, Inno Setup tooling signature check, Microsoft VC++ prerequisite validation, unified installer validation and artifact upload |
| Ventio Host API | `43605015106` | **PASS** | Windows ACL/private-file tests and PostgreSQL 16 API, identity/revocation, direct SQL/RLS, role, pairing, extension approval/recovery and credential-reissue suites |

The starting commit `9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61` also had all
eight pre-existing PR workflows pass:

| Workflow | Run ID | Result |
|---|---:|---|
| Ventio Core Foundation | `43585471124` | PASS |
| Ventio Host Engineering Gate | `43585471096` | PASS |
| Ventio Durable Commands | `43585471163` | PASS |
| Ventio Host Persistence | `43585471148` | PASS |
| Ventio Host Crash Recovery | `43585471192` | PASS |
| Ventio Credential Lifecycle | `43585471100` | PASS |
| Native Flutter Client and Extension Builder | `43585471093` | PASS |
| Ventio Host API | `43585471120` | PASS |

These are GitHub-hosted CI results, not physical Windows installation or
two-computer synchronization evidence. The PostgreSQL workflows create
disposable PostgreSQL 16 instances, run the repository migration/bootstrap
commands and security/identity/recovery suites. The repository currently
contains migrations 001–040. CI migration compatibility and logical restore
coverage does not replace a physical Wave 1 upgrade or Windows restore.

## Windows acceptance-package defect and artifact

The first package workflow, run `43603493035` (job
`132473048657`), built the Host payload and Flutter Windows Release and
verified the Inno Setup signature, then failed the existing pinned Visual C++
runtime size/hash check. The Microsoft latest-version URL had returned a binary
that did not match the pinned metadata. The check was not weakened.

Commit `fb341a7` changed the runtime URL to the explicit Microsoft
14.51.36247 release, records actual version/length/SHA-256/signature metadata,
and checks out the exact PR head. The unchanged integrity gate and complete
package workflow passed on candidate commit `fb341a78…`.

Successful candidate artifact:

- Workflow run: `43605015043`
- Artifact ID: `14117789094`
- Name: `ventio-wave2-windows-acceptance-fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
- Size: 103,796,488 bytes
- GitHub artifact digest: `sha256:0c83cd20dab447e6d024fe3d62dd5e9588499deb417a986820bf10d6a13114ae`
- GitHub-hosted build inputs recorded by the workflow: Dart 3.13.7, .NET 8,
  Flutter 3.44.1, PostgreSQL 16 runtime tools, Inno Setup 6.7.4 and the
  version-pinned Microsoft VC++ runtime.

Initial direct lab-machine requests returned HTTP 403. Incomplete files on TEST-01
(24,689,709 bytes, SHA-256
`3da78603bdab686a482fa5fd73969cfdded7c61bfdb435982a41fb54f57c5067`) and
TEST-02 (25,959,700 bytes, SHA-256
`e46e8f530026f89662a4c0da7c1435d61ebfa8cc0e0f4b9c0b0baab6e382fd39`) were
created by the failed transfer attempts, after which only the identified
Codex-owned transfer processes and these exact incomplete files were stopped
and removed. The owner then staged the complete verified artifact on both
machines. Each copy is 103,796,488 bytes with SHA-256
`0c83cd20dab447e6d024fe3d62dd5e9588499deb417a986820bf10d6a13114ae`.

A local relay attempt to stream the artifact into TEST-01 was rejected by
automatic approval review as `blocked by policy`. It was stopped; no package
was saved on the local workstation. The owner later delivered the package
through the approved channel. Its internal installer is 104,319,695 bytes,
SHA-256 `5413f65d86235633d40e1912767dd576303ecb0a7216d4a5e846c977f955977b`,
and Authenticode status is `NotSigned`. The unified installer was run on both
machines. The TEST-02 silent installation returned exit code 0. Both native
clients were launched in the interactive Codex RDP sessions. No Host service
or PostgreSQL service was installed automatically.

### TEST-02 uninstaller probe — inconclusive

Before the probe, TEST-02 had no `VentioHost` or `VentioPostgres` service and
no `C:\ProgramData\Ventio` directory. The installed `unins000.exe` was
4,452,610 bytes, SHA-256
`95e345709a8a502906ea46ee5a6b9222599bc942f4761f70ef73fcb4f10a3564`, and
Authenticode `NotSigned`. A silent uninstaller invocation from the Codex-3 SSH
session returned exit code 0 while the Client was still open in RDP session 4.
Afterward, the uninstall registry entry and uninstaller helpers were gone, but
the Client process remained and six application files remained in
`C:\Program Files\Ventio`; `C:\ProgramData\Ventio` remained absent. This is
not accepted as a successful uninstall. Because the uninstaller was started
from SSH while the UI was in a separate RDP session, repeat the check from the
interactive session after restoring the package. No Host data or service was
present or removed.

The Code Integrity log contains earlier events 3033/3077 mentioning an
`unins000.exe` at 15:11:44 local time, before this probe. A read of the last ten
minutes after the probe found no new 3033/3077 event. The earlier events cannot
be tied to the probed file hash from the available event text.

### TEST-01 Host setup — Code Integrity block

The TEST-01 Host setup screen showed PostgreSQL and Ventio Host as Not
installed. The following disposable scope was entered and visually verified:
Tenant `wave2b-20261114-ventio01`, Company `company-test01`, Branch
`branch-test01`. Pressing **Set up Host** launched the expected UAC request for
`VentioSetupBroker.exe` (Publisher: Unknown); the explicitly authorized UAC
approval was accepted. The app then reported that its protected local setup
component was unavailable.

The installed broker exists at
`C:\Program Files\Ventio\host-payload\VentioSetupBroker.exe` (67,592,883
bytes; its computed SHA-256 matches the installed payload manifest:
`bfb4d9bc9f06b11d537a10215ec4dfcf65d9ce78b11150eb53df6a348bd083f4`;
Authenticode `NotSigned`). New Code Integrity Operational events 3033 at
`2026-11-14 16:54:52.120 UTC` and 3077 at `2026-11-14 16:54:53.202 UTC` identify
`svchost.exe` attempting to load that exact installed path and report that the
broker does not meet Enterprise signing-level requirements, policy ID
`{0283ac0f-fff1-49ae-ada1-8a933130cad6}`. This correlates the UI failure to
the actual Code Integrity block; it is not inferred from the generic UI error.
Read-only `CiTool.exe -lp` checks on TEST-01 and TEST-02 confirmed the same
policy ID `{0283ac0f-fff1-49ae-ada1-8a933130cad6}`, Friendly Name
`VerifiedAndReputableDesktop`, and `Policy is Signed: true`, `Authorized: true`,
`Is Currently Enforced: true` on both computers. The owner confirmed there is
no organizational signing path available at present. `VentioHost` and
`VentioPostgres` remain unregistered, and
`C:\ProgramData\Ventio` is absent. No cluster, database or Host data was
created. Defender and Code Integrity stayed enabled.

## Earlier SSH-only physical tests before owner clean reinstall — 2026-11-14 20:31 UTC

This section is authoritative for the resumed run and supersedes earlier
statements that TEST-01 had no Host/PostgreSQL installation. Execution used
SSH and command-line automation only. No Computer Use, RDP interaction,
screenshots, mouse automation or GUI control was used.

### Security preflight and effective policy state

- TEST-01 hostname, elevated `Codex-1` Administrator token, Ventio install
  path, broker hash/manifest, prior service state and absence of
  `C:\ProgramData\Ventio` were confirmed before provisioning.
- Owner disabled Smart App Control for TEST-01 testing. Registry state was
  `VerifiedAndReputablePolicyState=0`. Microsoft documents value `0` as Off;
  `CiTool.exe -r` completed successfully and `CiTool -lp -json` then showed
  the associated `VerifiedAndReputableDesktop` policy as not enforced. Other
  Code Integrity policies remained active.
- Microsoft Defender remained enabled: `AntivirusEnabled=True`,
  `RealTimeProtectionEnabled=True`, and `AMServiceEnabled=True`. No Defender,
  UAC, or other policy setting was changed during this run.

### Host setup and local first-admin boundary

- Ran Setup Broker operation `72bf64daac9a47408d37efe80e882cdc` with the
  supported `--setup-new-host` operation and previously approved scope
  `wave2b-20261114-ventio01` / `company-test01` / `branch-test01`.
- Payload validation, PostgreSQL service provisioning, database initialization,
  Host service registration and LAN configuration completed. The operation
  stopped at `FIRST_ADMINISTRATOR_BOOTSTRAP` with
  `HOST_FIRST_ADMIN_PIPE_CONNECT_FAILED` (exit code 7). A remote resume attempt
  produced the same failure.
- `whoami /groups` showed the SSH token includes `NT AUTHORITY\NETWORK`
  (`S-1-5-2`). Source inspection confirmed that the first-admin named-pipe DACL
  denies that network SID and also checks the caller is local. This is an
  intentional security boundary, not a test defect. No alternate identity,
  scheduled task, UAC bypass, policy bypass or GUI automation was attempted.
- `VentioPostgres` and `VentioHost` are Automatic and Running as
  `NT SERVICE\VentioPostgres` and `NT SERVICE\VentioHost`. PostgreSQL 16.15
  is ready on `127.0.0.1:54329`. Host does not bind its API until first admin
  exists; `127.0.0.1:8080/healthz` was therefore unavailable.

### Physical migrations, RLS and permissions

- On fresh database `ventio_host`, migration filenames 001–040 matched the
  packaged migrations and all 40 normalized SHA-256 checksums matched; zero
  checksum mismatches. The range was `001_records.sql` through
  `040_wave2_job_archival.sql`.
- Queried business, command, audit, outbox, document-number and identity tables:
  checked relations are owned by `ventio_owner` with both RLS and FORCE RLS
  enabled.
- `ventio_runtime_app`: `ventio_security.assert_runtime()` passed. Direct
  migration-ledger read, `SET ROLE ventio_owner`, and unauthorized delete-plan
  checks were denied. Role flags confirmed no superuser, BYPASSRLS, database
  creation or role creation; no direct migration-ledger access.
- `ventio_identity_api_app`: membership in `ventio_identity_api` passed; role
  has no superuser/create-db/create-role/BYPASSRLS attributes and no direct
  SELECT on identity users, credentials, records or migration ledger.
- This proves fresh migration/checksum and selected RLS/least-privilege profile
  behavior only. It does not prove cross-tenant/company/branch behavior,
  identity API flows, credential lifecycle, Wave 1 upgrade, or Recovery
  Authority reconciliation on a physical host.
- Windows PowerShell execution policy denied loading unsigned
  `HostMigrationCredential.psm1`. No `-ExecutionPolicy Bypass` was used;
  equivalent DPAPI/ACL checks were done in memory.

### Service persistence

Confirmed TEST-01 service names, identities and PostgreSQL data path, then
performed an orderly stop of Host and PostgreSQL, start of PostgreSQL with
readiness wait, and start of Host. Both returned to Running and `pg_isready`
accepted connections. **PASS: orderly service restart persistence.** This did
not simulate a process crash, power failure or Windows reboot; none was run.
TEST-02 was not modified during this continuation.

## Physical gate results

| Gate | Result | Executed evidence / outstanding scenarios |
|---|---|---|
| B0 environment | **PARTIAL** | SSH identifies both machines; both Host/PostgreSQL services are Running and Defender/real-time protection are enabled with signature `1.463.324.0`. TEST-01 network access has returned. No GUI was used. |
| B1 static/core/contracts | **PASS in candidate CI** | All 11 checks passed on exact PR head `a7c85ef5617bca9345804106aa17457b2eaf858c`, including Dart Core, architecture contracts, Host API/engineering/recovery, PostgreSQL adapter, durable commands, credential lifecycle, Windows/Android native build, acceptance package and reproducibility. This does not replace physical platform acceptance. |
| B2 PostgreSQL/identity/security | **PARTIAL — selected fresh checks PASS** | On TEST-02, all 40 packaged migration checksums match all 40 ledger entries; `assert_schema()` passes; 30 public tables have `ventio_owner`, RLS/FORCE RLS and zero violations. Selected least-privilege checks, `assert_runtime()`, Recovery Authority admission and a rolled-back empty-queue job-claim probe pass. Cross-scope authorization, Wave 1 upgrade and recovery reconciliation remain open. |
| B3 Host/data | **PARTIAL** | Both Hosts return health 200 and unauthenticated `/api/v1/session` returns 401 over mutually pinned TLS. No authenticated operations or populated durable-job/data-processing scenarios were exercised. Historical TEST-01 `HOST_JOB_WORKER_UNAVAILABLE` cause remains unresolved. |
| B4 native/offline | **PARTIAL / BLOCKED** | No Client process is running on either device. Authenticated pairing/enrollment, real two-computer synchronization, offline edit, conflict/receipt recovery, or Windows/Android UI scenarios were not executed. Local `flutter devices` listed only Windows, Chrome and Edge; no Android target was available and `adb` was not on PATH. GUI acceptance cases are **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**. |
| B5 backup/restore/operations | **PARTIAL** | Earlier TEST-02 Host crash recovery passed in 108 seconds and the Host/PostgreSQL services returned after controlled reboot. Current inspection found no Ventio task or product backup directory/set on either host. Locally approved backup, task scheduling, physical integrity/corruption/retention, interruption and disposable restore were not executed. Current Defender history is reported separately. |
| B6 final audit | **NOT COMPLETE** | Physical gates, capability matrix, defect regression adjacency and exact-candidate final rerun remain open. |

The fixed-scope capability IDs are
`A12, A11, K09, D08, J01, J03, K08, M01, M02, M05, M09, B09, C08, C09,
C12, F05, H04, B02, K10, L01, D09, J04`. CI exercises subsets through the
core, Host, PostgreSQL, recovery and Flutter suites; none of the 22 capabilities
has complete Wave 2 B positive-and-negative physical acceptance evidence yet.
The full matrix remains open.

| Capability | Candidate CI evidence bucket | Remaining plan acceptance; B status stays open |
|---|---|---|
| A12 | Core/native tests and Host API/package suites | Same-effective-schema custom-field create/update/detail; permission, type/removal, required-field, name and count denials |
| A11 | Core contract and native test suites | Full list/form/detail/page merge behavior; invalid layout, key, digest, icon, ordering and repeated-session label cases |
| K09 | Host extension-package approval/recovery and native tests | Two-client publication, stale-revision rebase, lost response, restart and concurrent-owner preservation across releases |
| D08 | Host API, scoped-role and query suites | Complete import/export operation and field grants, role/device/token revocation, scope spoofing and safe denial matrix |
| J01 | Host API and native suites | CSV quoting/BOM/newline/types/defaults plus malformed encoding, bounds, overflow, rounding and child-field negatives |
| J03 | Durable-command, persistence and Host API suites | Original logical preview rows across batches, retry, restart, lost response, cancellation and archival |
| K08 | Host API query and native suites | Authorized filter/sort/projection, cross-scope cursor replay, permission changes, response bounds and formula escaping |
| M01 | Host administration/user/role suites | Two-tenant hierarchy CRUD, immutable parents, archive/reactivate, no implicit grants, CAS races and credential ceilings |
| M02 | Host API, contract and operations suites | Persisted scoped settings and actual UI/header effects; maintenance, claim pause, limit, type and unauthorized-edit cases |
| M05 | Host recovery CI provides logical recovery evidence only | Windows local approval, exact policy/revision, schedule/retry, protected backup integrity, retention pins, ACL/reparse and interruption cases |
| M09 | Host crash-recovery CI provides logical restore evidence only | Physical staged restore compatibility, local confirmation/elevation, preserved cluster, independent Recovery Authority and rollback cases |
| B09 | Native Flutter/local-data suites | Saved-search filters/columns/sort, revision sync across restart/devices, permission changes and stale/deleted definitions |
| C08 | Native Flutter/local-data suites | Current-permission workspace links, module ordering and role/scope/endpoint changes |
| C09 | Native Flutter/local-data suites | Per-user/Host/scope preference persistence, offline edits, concurrent conflict and retry |
| C12 | Core contract and native suites | Declarative report-card permissions, aggregates/groups, loading/empty states, unknown versions and bounds |
| F05 | Host API extension package approval suite | Supersession/revocation, digest/dependency mismatch, unauthorized report and invalid-filter negatives |
| H04 | Host API/native history suites | Event capture, deleted-ID lookup, keyset pagination, field redaction, legacy seed and declared historical boundary |
| B02 | Contract examples, Core and API suites | Exact v1/legacy wire compatibility and rejection of unsupported versions/properties/job envelopes |
| K10 | Durable-command and Host API suites | Approved lifecycle effects, invalid operation/version/input denials and no executable/SQL shortcut |
| L01 | Durable-command, persistence and crash-recovery suites | Two-worker fencing, stale lease/finish, five-attempt boundary, current claim authority and cancellation ambiguity |
| D09 | Credential lifecycle, pairing and API suites | Scope/ceiling/revocation/TLS/redirect negative matrix; no third-party authentication bypass |
| J04 | Contract validation and Host API suites | Route/method/content-type/auth/body limits, tenant spoofing and refusal of arbitrary outbound endpoints/handlers/scripts |

The CI bucket column identifies related automated suites; it does not claim
that every listed scenario passed. Each row remains **OPEN** until the plan's
specific positive and negative cases are recorded against the exact candidate.

## Security, migration and recovery notes

- Candidate CI's completed database suites exercised the PostgreSQL security
  profile, forced RLS, least privilege, scoped authorization,
  identity/revocation, credential reissue and Recovery Authority boundaries.
- The Host Engineering and recovery CI workflows exercised migration
  compatibility and logical backup/restore scenarios on disposable runner
  databases. Separately, the SSH-only continuation applied fresh migrations
  001–040 on TEST-01; no Wave 1 upgrade or product backup restore was performed
  physically.
- No account password or production credential was requested, recorded, or
  placed in source, scripts, reports or CI. No live product data was accessed.
- Defender remains enabled: `WinDefend` is RUNNING and its antivirus,
  real-time protection and antimalware services are enabled. The owner disabled
  Smart App Control on TEST-01 for this test; registry state was 0 and, after
  `CiTool.exe -r`, `CiTool -lp -json` reported the related policy not enforced
  on TEST-01. Other Code Integrity policies remained active. Initial 3033/3077
  events for the unsigned broker are historical evidence from before this
  policy change. Provisioning then succeeded through LAN configuration and
  stopped at the local-only first-admin pipe. See the SSH-only section above.
  The unsigned installer/broker remains a distribution limitation where code
  signing is enforced. TEST-02's earlier silent uninstaller probe remains
  inconclusive; under the current SSH-only rule its interactive retest is not
  executed and requires manual owner validation.
- Wave 1 history did not capture old cross-record target events or prior field
  values. No historical events are inferred.
- The Wave 2 A handoff records Windows development-Host shutdown timeouts in
  automated CI without a confirmed source cause. The orderly service restart
  passed; forced-crash/shutdown behavior was not reproduced.

## Not executed

**Executed but failed:** the owner completed the local broker setup flow on
TEST-01, but the Client failed to establish the authenticated first-admin
session (`HOST_SESSION_AUTHENTICATION_FAILED`). The newer `17b0141` package,
which includes the safe diagnostic correction, was installed on TEST-02; its
bootstrap Client/session error path has not been exercised there.

**NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED:** remaining Windows UI
navigation, permissions/scaling and interactive uninstall/cleanup; Android
device UI; and other GUI-only local approval workflows.

Other unexecuted mandatory scenarios: representative Wave 1 physical upgrade;
complete cross-tenant/company/branch and identity authorization; completion of
authenticated Host API/session verification; Host operations/data processing;
real two-computer synchronization, offline changes
and conflict/receipt recovery; Task Scheduler; product backup integrity,
corruption, retention and interruption; disposable product restore and
Recovery Authority reconciliation; forced process crash or computer reboot;
and the full B6 capability/regression audit. Physical fresh migrations 001–040
and selected RLS/least-privilege checks did execute and pass as recorded above.
The focused Dart test and analyzer ran in the repository worktree on the
execution workstation, not on TEST-01 or TEST-02. No Windows package was built
or physically installed from that workstation.

## Owner clean-install follow-up — 2026-11-14

After the owner removed the previous TEST-01 Ventio data and installed the
verified package again, local scope `Test-01` / `Codex-01` / `Codex` was used.
The UI exported `HOST_SETUP_STATUS_UNAVAILABLE` at 22:29:33 UTC. SSH later
observed operation `0793a94d97f202699fbbff49b5db5cc8` in `complete` state at
22:31:08 UTC, with the protected result file present, both Windows services
Running, and `/healthz` returning 200. The owner then exported
`HOST_SESSION_AUTHENTICATION_FAILED` at 22:35:55 UTC while the UI was at
“store the administrator credential securely.”

After this second error, SSH still showed the same completed operation and
protected result (metadata only), running services, and `/healthz` 200. No
Ventio Event Log provider or recent Ventio Application event was found. Source
inspection places the failure after the client stores the bootstrap token and
calls `GET /api/v1/session`; a Host transport failure was being collapsed to a
generic authentication code. `f11bf27` fixes this loss of safe diagnostics.
The actual Host response remains unknown pending installation and execution of
the package built from the fix.

The owner reported the power interruption followed the earlier 21:59:20 UTC
session error; SSH later recorded boot time `2026-11-14T22:02:07.500Z`. The
clean-install error at 22:35:55 UTC occurred after that reboot, so the prior
interruption is not considered its cause. The owner cleared this clean
installation after prior physical migration/RLS tests, so those earlier
database results do not certify the current database; rerun them on the current
fresh installation.

Source-level regression evidence on `f11bf27`:

- `flutter test test/host_setup_test.dart`: **28 passed**.
- `dart analyze lib/src/host_setup.dart test/host_setup_test.dart`: **No issues found**.
- `dart format` completed; it reported that `flutter_lints` was not resolved by
  the formatter's lint include, but the focused analyzer ran clean after
  dependency resolution.
- Windows Acceptance Package CI succeeded on `b3a5f585`; artifact metadata and
  SHA-256 are recorded above. The diagnostic candidate is not physically
  installed, so physical evidence remains tied to `fb341a78…`.

## 2026-11-14 23:32 UTC — SSH-only diagnostic correlation

Read-only SSH inspection of TEST-01 confirmed operation
`0793a94d97f202699fbbff49b5db5cc8` remained `complete` at 22:31:08.425 UTC;
`VentioHost` and `VentioPostgres` were Running. The Host's sanitized
`host-diagnostics.jsonl` recorded `HOST_JOB_WORKER_UNAVAILABLE` in component
`host.jobs` at 22:34:38.505 UTC, 77 seconds before the Client event
`HOST_SESSION_AUTHENTICATION_FAILED` at 22:35:55.809 UTC.

Source inspection shows that the worker emits the generic event when its
administration-pool tick fails, including identity-connection verification,
Recovery Authority admission, or the durable-job claim. The diagnostic omits
the underlying exception. Persistent token authentication also resolves the
token from PostgreSQL and applies Recovery Authority admission for each
request. This makes a shared backend-readiness issue plausible, but the time
correlation does not prove causality. `/healthz` confirms process liveness only
and does not certify database readiness. The client build installed during
this failure discarded all safe Host transport codes in the post-storage
`GET /api/v1/session` check; the new `b3a5f585` package preserves the code, but
must be installed and exercised to identify the actual response. No evidence
from this check implicates Smart App Control or DPAPI.

At 23:17 UTC, the configured PostgreSQL listener was confirmed on `127.0.0.1`
port `54329`; the Ventio-bundled `pg_isready` returned `accepting connections`
(exit 0). This read-only check confirms current listener readiness only. It
does not establish authenticated SQL access, migration state, or Recovery
Authority admission at the earlier error time.

## 2026-11-15 07:35 UTC — TEST-02 successful Host provisioning

The owner confirms that the first attempt failed during first Host
administrator creation and a retry via **Set up Host** succeeded. No
diagnostic code for the initial TEST-02 attempt was supplied, so its cause is
unknown. The agent used SSH and read-only commands only.
`Codex-3@192.168.1.107` identified
`VENTIO-TEST-02`. Latest setup status file
`8e5eace6076314dc95c1389f95c707d2.json` reports `state=complete`,
`phase=HOST_READINESS`, updated `2026-11-15T07:21:08.5243312Z`.

Installed candidate: `17b014125b695e3242e2d9b50b3eb9732a8c5fcb`; all nine
GitHub Actions workflows passed on that commit. Windows Acceptance Package
run `43653937272` produced the artifact. Acceptance ZIP SHA-256:
`1c5a1076ab427cd132afc5efd1d7c2610e61376647441c00a628fb04b5f650eb`.
Installer SHA-256:
`E117F4E762ECBDBBF2E0A3B6649FC6887101F5CF08907B293A1CBC929013B020`;
Authenticode is `NotSigned`. Its installed manifest records 1,724 files,
310,613,952 bytes and PostgreSQL 16.15. SHA-256 values for the installed
Setup Broker, Host service and PostgreSQL executable match that manifest.

`VentioHost` and `VentioPostgres` are Running, Automatic, and use separate
virtual service accounts. PostgreSQL binds to `127.0.0.1:54329`; bundled
`pg_isready` returned `accepting connections`. Host `/healthz` on
`127.0.0.1:8080` returned HTTP 200 and `{"apiVersion":1,"status":"alive"}`.
Host listens on 8443; default Windows TLS validation failed for requests to
`https://127.0.0.1:8443/healthz`,
`https://VENTIO-TEST-02:8443/healthz` and
`https://localhost:8443/healthz`. This does not determine whether Ventio's
Client-specific certificate validation succeeds. No validation bypass was
used. Services have restart-on-failure actions after 5, 30 and 60 seconds;
no crash was injected. Defender antivirus, real-time protection and Tamper
Protection were enabled; `VerifiedAndReputablePolicyState=0`.

No direct migration-ledger/checksum, RLS, role/field authorization, API session,
backup, restore or forced crash/reboot test was run on this fresh database. At
07:35 UTC, SSH to TEST-01/Codex-1 timed out. Two-computer synchronization
therefore remains **BLOCKED**. Remaining GUI-only acceptance is
**NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**.

## 2026-11-15 07:50 UTC — orderly TEST-02 service restart

Before changing service state, SSH confirmed the machine name, both service
identities, Automatic start configuration, current Running state and the
Ventio PostgreSQL data directory at
`C:\ProgramData\Ventio\PostgreSQL\data`. The sequence stopped `VentioHost`,
stopped `VentioPostgres`, started PostgreSQL and waited for
`pg_isready -h 127.0.0.1 -p 54329`, then started Host and waited for
`http://127.0.0.1:8080/healthz`. Every step passed; both services ended in
Running state and health returned HTTP 200. **PASS: orderly service restart
persistence on the TEST-02 installation.** No database contents were deleted
or rewritten by the check. This is not a process crash, power-loss or Windows
reboot recovery test; backup scheduling, backup integrity/retention and
disposable restore remain unexecuted.

## 2026-11-15 08:04 UTC — fresh TEST-02 migration and schema security checks

Read-only SSH verified the protected migration credential's file and directory
ACLs: inheritance disabled, owner BUILTIN\Administrators, only Administrators
and SYSTEM have Full Control. The LocalMachine-DPAPI secret was decrypted only
in memory and supplied to the bundled `psql` process through its environment;
it was not printed, placed in command-line arguments or saved. Database checks
used `SET ROLE ventio_owner` only for the connection and issued no data changes.

The installed migration directory contained 40 SQL files from
`001_records.sql` through `040_wave2_job_archival.sql`. Canonical-LF SHA-256
comparison against `public.ventio_schema_migrations` found 40 ledger entries,
zero missing, zero extra and zero mismatches. `ventio_security.assert_schema()`
passed. All 30 public `ventio_*` tables returned by the catalog query were
owned by `ventio_owner` with RLS and FORCE RLS enabled. `ventio_runtime_app`
and `ventio_identity_api_app` were not superusers, could not create databases
or roles, and did not bypass RLS. Direct SELECT checks for identity credentials,
records and the schema migration ledger were false for the identity API role;
runtime direct migration-ledger SELECT was false. The migration login cannot
`SET ROLE ventio_runtime_app`, so `assert_runtime()` and runtime SQL execution
were **NOT EXECUTED**. These results do not cover cross-tenant/company/branch
isolation, identity API flows, Wave 1 upgrade or Recovery Authority admission.

## 2026-11-15 10:15 UTC — TEST-01 reconnection and TEST-02 crash recovery

SSH to `Codex-1@192.168.1.106` again identified `VENTIO-TEST-01`. Its Host and
PostgreSQL services were Running/Automatic under `NT SERVICE\VentioHost` and
`NT SERVICE\VentioPostgres`. Bundled `pg_isready` accepted connections on
`127.0.0.1:54329`; Host `/healthz` returned HTTP 200 and unauthenticated
`/api/v1/session` returned HTTP 401. These results prove local liveness and
unauthenticated rejection only, not successful Client authentication.

The protected migration credential was decrypted only in process memory. The
40 installed SQL files matched all 40 ledger checksums. As `ventio_owner`,
`ventio_security.assert_schema()` passed; all 30 checked public `ventio_*`
tables were owned by `ventio_owner` with RLS and FORCE RLS enabled, and the
RLS violation count was zero. Runtime, identity API and migrator roles had no
superuser/create-db/create-role/BYPASSRLS flags. Identity API and runtime
direct migration-ledger SELECT were false; the migrator could not assume the
runtime login. No table data was changed. `assert_runtime()`, runtime SQL,
cross-scope isolation and Wave 1 upgrade remain untested.

Using the protected identity-API settings and Recovery Authority witness only
in memory, the identity API login profile was verified, `admit_recovery`
passed, and `wave2_claim_job()` returned an empty queue inside a transaction
that was rolled back. This verifies current admission and the empty-queue path,
not execution of an actual queued job. TEST-01's safe diagnostics record
`HOST_JOB_WORKER_UNAVAILABLE` at 22:34:38.505 UTC, 09:28:20.464 UTC,
09:31:47.609 UTC, 09:32:59.473 UTC and 09:38:14.516 UTC. The current probe
did not reproduce those historical errors; the diagnostic omits the cause.

From TEST-02, TCP `192.168.1.106:8443` succeeded, but ordinary HTTPS
validation failed with `Could not establish trust relationship for the
SSL/TLS secure channel`. No TLS bypass was used. TEST-01's payload manifest
has no source commit field; its current `ventio_host.exe` SHA-256 is
`5A18C389C5CCE563CAA8A5A5BA9222108B785680AEBED6878996385C3EA1E5F2`, and
`VentioHostService.exe` SHA-256 is
`AF64049CC55C08A92209E8EC581DF69229D9551F9046418AFEDB1A5EE8F1F3C4`.

The controlled TEST-02 crash test killed only `ventio_host.exe` PID 3208 at
`2026-11-15T09:59:14Z`; preflight found no established Host TCP clients.
Within seconds, Defender event IDs 1116/1117 detected
`Trojan:Win32/Bearfoos.A!ml` (threat 2147731250, Severe) in
`C:\Program Files\Ventio\host-payload\ventio_host.exe` and quarantined it.
Defender and real-time protection remained enabled. SCM applied its 5/30/60
second restart actions but could not recover Host; the sanitized startup file
reports `HOST_ENGINE_PROCESS_START` / `InvalidOperationException`. A manual
`Start-Service` attempt also failed. No file was restored, Defender exception
added or security policy changed. At the last check, TEST-02 `VentioHost` was
Stopped while `VentioPostgres` remained Running on PID 4424 and accepted local
connections. The earlier orderly restart is not crash-recovery acceptance.

Read-only Task Scheduler inspection found no tasks under `\Ventio\` on
TEST-01. Product backup approval, scheduling, integrity/retention and
disposable restoration remain **NOT EXECUTED**. GUI-dependent approval and
interactive acceptance remain **NOT EXECUTED — MANUAL OWNER VALIDATION
REQUIRED**.

## Additional SSH-only results — 2026-11-15 10:56 UTC

| Scenario | Result | Evidence |
|---|---|---|
| TEST-01 Host service restart | PASS | Preflight verified VENTIO-TEST-01, the VentioHost service identity/path and no established Host-port connections. Restart-Service VentioHost returned the service to Running in 18.4 seconds. Local http://127.0.0.1:8080/healthz returned HTTP 200 before and after. |
| TEST-01 PostgreSQL continuity | PASS | PostgreSQL was not restarted or modified; service remained Running and bundled pg_isready returned accepting connections on 127.0.0.1:54329. |
| TEST-01 engine continuity | PASS | ventio_host.exe remained present with SHA-256 5A18C389C5CCE563CAA8A5A5BA9222108B785680AEBED6878996385C3EA1E5F2. |
| TEST-02 post-setup service availability | BLOCKED — SECURITY | At 10:51 UTC the service was Stopped and the engine file absent; Defender still recorded threat 2147731250 and events 1116/1117. Owner reports the setup retry succeeded, but the Host is not currently running. |
| TEST-01 ordinary TLS trust | FAIL | Standard HTTPS validation to https://localhost:8443/healthz failed with a certificate trust error. No certificate-validation bypass was used. |
| GitHub Actions on report head 1e2c5f8 | PASS | All nine workflows completed successfully, including Host API run 43704184519. Extension approval/scope/recovery and trusted credential reissue integration passed. |

This continuation adds no confirmed product-code defect or source correction.
Authenticated Client use, two-device sync, product backup scheduling,
integrity/retention, disposable restore, remaining B2/B3 cases and GUI-dependent
acceptance remain incomplete. Interactive scenarios are NOT EXECUTED —
MANUAL OWNER VALIDATION REQUIRED.

## Host API process-shutdown timeout and correction — 2026-11-15 12:01 UTC

| Run / check | Result | Evidence |
|---|---|---|
| Host API run 43707135745, attempt 1 | FAIL | test/api_integration.dart timed out after 20 seconds at line 329 awaiting the first child Host process to exit after graceful shutdown. |
| Host API run 43704184519 | PASS | The same 34-assertion isolated HTTP/PostgreSQL process-restart test completed, including graceful process shutdown. |
| Host API run 43707135745, attempt 2 | PASS | On the same pre-fix source head, the retry completed extension approval/scope/recovery integration. All nine workflows on 8929a96 are now successful; attempt 1's intermittent timeout remains recorded. |
| Correction commit e3efc25; CI head 676c989 | PASS | The Windows test helper closes child stdin after sending the shutdown command, delivering EOF to the child's stdin listener. Host API run 43712289370 passed the full job, including isolated HTTP/PostgreSQL process restart and all downstream identity/security integration tests. All nine workflows on 676c989 succeeded. |

Diagnosis: the test parent left stdin open while the child awaited stdin-subscription cancellation during shutdown. The sibling identity fixture explicitly closes stdin to deliver EOF on Windows. The same test's success before and on the second attempt shows the timeout was intermittent. No production Host defect was confirmed.

Local dart format passed. A local dart analyzer invocation could not resolve package imports because dependencies were absent. Post-correction GitHub Actions on 676c989 passed formatting and analyzer plus all required jobs. Run IDs: Core 43712289305; Host Engineering 43712289253; Host API 43712289370; Credential Lifecycle 43712289323; Host Crash Recovery 43712289357; Host Persistence 43712289257; Durable Commands 43712289259; Native Flutter Client and Extension Builder 43712289247; Windows Acceptance Package 43712289246.

## TLS trust and latest SSH diagnostic check — 2026-11-15 14:09 UTC

| Check | Result | Evidence |
|---|---|---|
| TEST-01 service/liveness | PASS | `VentioHost` and `VentioPostgres` Running over SSH; `http://127.0.0.1:8080/healthz` returned 200. |
| TEST-01 LAN certificate identity | PASS — published fingerprint matches | Host info reports self-signed certificate and requires explicit trust. Certificate Subject/Issuer `CN=VENTIO-TEST-01`, SAN `VENTIO-TEST-01` and `192.168.1.106`, valid through 2029-11-14; computed SHA-256 `2c63e4ffaa97dd4ba06be9d55360ef7fc907d7b3a8db6a889de6356e6d4f6368` matches the published value. No trust bypass or trust-store change. |
| Client pairing / real synchronization | NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED | Pairing UI requires entering the Host SHA-256 fingerprint. No authenticated Client enrollment, second-device sync, offline edit or conflict/receipt recovery was performed. |
| TEST-01 job worker diagnostics | BLOCKED — cause unresolved | Six safe `HOST_JOB_WORKER_UNAVAILABLE` events remain recorded; latest at 2026-11-15 13:09:53 UTC. At 14:09 UTC there was no newer diagnostic event. The log intentionally omits the underlying exception. |
| TEST-02 current Host state | BLOCKED — SECURITY | SSH finds `VentioHost` Stopped and `ventio_host.exe` absent. Defender antivirus, real-time protection and antimalware service remain enabled. |
| Latest post-correction CI | PASS — 9/9 | All workflows passed on report-only head `0bd9ea9bd439dfd9e87a1ab2c7bd84681bfa4a82`; Host API `43715371756` passed. |

The nine latest CI runs on `0bd9ea9bd439dfd9e87a1ab2c7bd84681bfa4a82` were:
Native Flutter `43715371758`, Core `43715371761`, Credential Lifecycle
`43715371766`, Durable Commands `43715371754`, Host API `43715371756`, Host
Crash Recovery `43715371763`, Host Engineering `43715371819`, Host Persistence
`43715371745`, and Windows Acceptance Package `43715371820`; all concluded
success.

## SSH-only continuation and final CI checkpoint — 2026-11-15 14:48 UTC

Exact PR head checked: ee167d6d219bdb655edae129441b7a12e15d9420. All nine
workflows concluded success:

| Workflow | Run | Result |
|---|---:|---|
| Host API | 43723289645 | PASS |
| Host Crash Recovery | 43723289479 | PASS |
| Native Flutter Client and Extension Builder | 43723289568 | PASS |
| Credential Lifecycle | 43723289469 | PASS |
| Host Persistence | 43723289505 | PASS |
| Windows Acceptance Package | 43723289499 | PASS |
| Host Engineering Gate | 43723289481 | PASS |
| Core Foundation | 43723289578 | PASS |
| Durable Commands | 43723289470 | PASS |

Final read-only SSH check: TEST-01 Host and PostgreSQL services Running and
/healthz HTTP 200. The recorded setup operation is complete at HOST_READINESS;
it does not establish authenticated administrator login. The latest safe
worker diagnostic is still HOST_JOB_WORKER_UNAVAILABLE at
2026-11-15T13:09:53Z, with cause unresolved. TEST-02 Host is Stopped,
PostgreSQL is Running, its Host engine is absent, and Defender protections
remain enabled. No new product defect was confirmed and no source code changed
during this continuation.

All physical and GUI-dependent scenarios remain classified individually in
the gate ledger. In particular, actual two-device sync, offline/conflict
recovery, product backup scheduling and disposable restore were not executed.
Disposition remains WAVE_2_B — PARTIAL VERIFICATION / BLOCKED.

## Dual-machine Host availability and Defender quarantine — 2026-11-15 20:29 UTC

This read-only SSH checkpoint followed the previously successful Host setup on
TEST-02 and the prior healthy TEST-01 check. It executed no new setup, service
start, restore, exclusion or database mutation.

| Check | TEST-01 | TEST-02 |
|---|---|---|
| Identity / Windows | `VENTIO-TEST-01`; Windows 11 lab machine | `VENTIO-TEST-02`; Windows 11 build 26300 |
| `VentioHost` | Stopped; `ExitCode=2`; service executable exists | Stopped; `ExitCode=2` |
| `VentioPostgres` | Running; `ExitCode=0` | Running; `ExitCode=0` |
| Host engine | Missing from payload; manifest requires 8,806,400 bytes and SHA-256 `5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2` | Missing from payload |
| Local Host `/healthz` | Connection refused | Connection refused |
| Defender | Antivirus, real-time and AM service enabled | Antivirus, real-time and AM service enabled |

On TEST-01, the payload manifest lists 92 verified files; exactly one file is
missing: `ventio_host.exe`. Defender event IDs 1116/1117 record
`Trojan:Win32/Bearfoos.A!ml` (threat 2147731250, Severe), successful
remediation and the exact engine path at 2026-11-15T20:10:00Z. TEST-02 has the
same detection and successful remediation at 2026-11-15T09:59:21Z. TEST-01's
sanitized service startup record names stage `HOST_ENGINE_PROCESS_START`; SCM
event 7023 reports system error 2, with recovery attempts. This ties the
current Host outage to the Defender quarantine. It does not independently
determine whether the detection is false positive or malicious. The engine is
unsigned; no file was restored, no Defender exclusion was created, and no
security setting was changed. TEST-01's effective Code Integrity policy
reports enforced; no Code Integrity events for the Host engine or Host service
executable were found in the inspected period. Historical Setup Broker CI
blocks are distinct.

TEST-02's native Client executable remains installed, and its enrollment UI
was previously confirmed to require a temporary Host-issued pairing code.
Neither Host is currently available to generate it. No Client enrollment,
real two-device synchronization, offline/reconnect, conflict recovery, backup
scheduling or disposable restore was executed in this checkpoint.

The PR head `02b8ecc3901527f0b635fd66e5c68c1734d7dff8` was checked after all ten
GitHub Actions workflows completed successfully: `dart-core` (run
43726724853), `host-recovery` (43726724893), `architecture-contracts`
(43726724853), `host-api` (43726724902), `postgres-adapter` (43726724894),
`host-engineering-gate` (43726724889), `credential-lifecycle` (43726724877),
`durable-commands` (43726724846), `native-client-windows-android`
(43726724870), and `windows-acceptance-package` (43726724861). This CI status
does not clear the physical security blocker. PR #6 was open, Draft and
unmerged at that head.

Disposition remains **WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**. The
immediate prerequisite to retrying Host is a trusted signed candidate or
formal Defender disposition for the exact engine hash. Do not restore the
quarantined artifact or weaken Defender/Code Integrity.

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
restore were not executed. On TEST-02 there was no `\Ventio\VentioHostBackups`
task, no `\Ventio\` task at all, no product backup directory and no backup set.
Backup local approval was not bypassed. No application
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

## SSH-only physical checkpoint — 2026-11-16 08:15 UTC

| Test | Result | Evidence |
|---|---|---|
| Host identity and SSH | PASS | `Codex-1@192.168.1.106` identifies `VENTIO-TEST-01`; `Codex-3@192.168.1.107` identifies `VENTIO-TEST-02`. |
| Host/PostgreSQL service presence | PASS | Both `VentioHost` and `VentioPostgres` are Running with Automatic start on both computers. |
| Installed Host hash | MATCH | Both installed `ventio_host.exe` files hash to `5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`. |
| Local Host health | PASS | `http://127.0.0.1:8080/healthz` returned 200 on both. |
| Mutual TLS Host reachability | PASS | Each device reached the other over TLS 1.2; exact SHA-256 pin, validity interval, DNS SAN and IP SAN matched. `/healthz` returned 200 in both directions. TEST-01 pin: `2c63e4ffaa97dd4ba06be9d55360ef7fc907d7b3a8db6a889de6356e6d4f6368`; TEST-02 pin: `b34d2c33650fb658a40266e6c474289d165938ff90bccadcdb4f9c4b1a99433f`. The TLS library reported chain errors because the certificates are self-signed; acceptance was based only on the exact expected pin plus time and SAN checks. |
| Unauthenticated session endpoint | PASS | Pinned `/api/v1/session` returned 401 from both Hosts, as expected without credentials. |
| Product backup task/data presence | NOT PRESENT | No `\\Ventio\\` or `VentioHostBackups` scheduled task was found. The documented paths `C:\ProgramData\Ventio\Backups` and `C:\ProgramData\Ventio\Installer\Operations` do not exist on either computer. No backup was initiated. |
| Real Client-to-Host sync | NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED | No `ventio_native_client` process was running on either device. No authenticated pairing, edits, offline queue, conflict or receipt recovery occurred. The execution environment had no Android device/emulator (`flutter devices` showed Windows, Chrome and Edge; `adb` was not on PATH). A pinned health probe is not a Client synchronization test. |
| TEST-01 fresh DB credential check | NOT EXECUTED | The installed protected credential PowerShell module was rejected by the existing script policy. No execution-policy bypass was applied; previous successful B2 evidence remains historical. |

### Defender event state observed during the checkpoint

Defender Antivirus and real-time protection were enabled on both computers;
security intelligence was `1.463.324.0`. Read-only `Get-MpThreatDetection` /
`Get-MpThreat` queries found Threat ID `2147731250`,
`Trojan:Win32/Bearfoos.A!ml`, on both machines. TEST-01 initial detection was
`2026-11-15T20:10:00.859Z` (last status change `20:11:32.332Z`, status ID 3);
TEST-02 initial detection was `2026-11-15T09:59:21.939Z` (last status change
`09:59:45.177Z`, status ID 3). Both entries report `ActionSuccess=true`,
`IsActive=false`, and `DidThreatExecute=true`; TEST-01's event also records a
process resource. These fields are reported without inferring what action
success means for quarantine state. No quarantine item was restored, no
exclusion was added, and no protection setting was changed. The cause remains
**ROOT CAUSE NOT CONFIRMED**. This checkpoint did not run a new on-demand scan.

The network outage reported at 2026-11-15 23:31 UTC has recovered for SSH and
Host TCP/TLS reachability. This does not change the acceptance status: client
authentication/synchronization, offline recovery, cross-scope authorization,
Wave 1 upgrade, backup scheduling/integrity/retention/restore and final B6 audit
remain outstanding. No product defect was reproduced or corrected here.
