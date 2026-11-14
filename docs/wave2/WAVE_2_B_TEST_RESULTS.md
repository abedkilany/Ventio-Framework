# Wave 2 B test results

**Status: PARTIAL VERIFICATION / BLOCKED**
Starting source: `9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61`
Product/package verification commit: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
Branch: `feature/wave-2-a`; Draft PR: [#6](https://github.com/abedkilany/Ventio-Framework/pull/6)
Report date: 2026-11-14
Last updated: 2026-11-14 16:42 UTC

The exact candidate product commit was used by GitHub-hosted CI and the
acceptance-package workflow. All nine candidate workflows completed
successfully by 2026-11-14 15:14 UTC. The candidate package was later verified
and installed on both physical test computers; the full physical acceptance
run remains incomplete. No product code was changed during this verification.

## Environment and fixtures

| Machine | Verified identity | OS / build | PowerShell | Initial free C: | Recorded state |
|---|---|---|---|---:|---|
| VENTIO-TEST-01 (`192.168.1.106`) | `Codex-1`, `Codex-2`; Administrators, High Integrity | Windows 11 Pro 10.0.26300 | 5.1.26100.9711 | 63.5 GB initial | `Codex-1` SSH identity and active RDP session verified. Unified package installed; Ventio is open at Host setup. Both Host/PostgreSQL services are still absent. |
| VENTIO-TEST-02 (`192.168.1.107`) | `Codex-3`, `Codex-4`; Administrators, High Integrity | Windows 11 Pro 10.0.26300 | 5.1.26100.9711 | 147.3 GB initial | `Codex-3` SSH identity and active RDP session verified. Installer exit code 0 and first launch reached Welcome. After the inconclusive silent-uninstall probe, the installation is partial and RDP shows the lock screen; restore and interactive retest are pending. Both Host/PostgreSQL services and ProgramData\Ventio are absent. |

SSH succeeded for all four named accounts during initial preflight. At the
current checkpoint, SSH identifies the intended machine/account pair on each
host and `quser` shows active RDP sessions `codex-1` and `codex-3`. No restart
was performed, so post-reboot SSH/RDP continuity is not established. The RDP
screens can be captured and clicked; long text entry through the CUA controller
has not populated the Host scope field reliably.

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

## Physical gate results

| Gate | Result | Executed evidence / outstanding scenarios |
|---|---|---|
| B0 environment | **PARTIAL** | Machine identity, OS/PowerShell versions, SSH access, designated active RDP sessions, isolated roots and artifact hashes/size are verified. Candidate installed on both machines. Restart continuity and several optional tooling/version probes remain outstanding. |
| B1 static/core/contracts | **PASS in candidate CI** | All nine candidate workflows PASS. |
| B2 PostgreSQL/identity/security | **PARTIAL** | Candidate CI covers migration/bootstrap, RLS, least privilege, direct SQL, identity, scoped roles, pairing and logical recovery. No physical 001–040 run, representative 001–036 physical upgrade, or test-machine cross-tenant/company/branch matrix has been executed. |
| B3 Host/data | **PARTIAL** | Candidate CI covers portions of Host API, persistence, durable jobs, credential lifecycle, package review and recovery. Physical customization rebasing, full CSV source-row correlation, durable Windows job recovery, organization/settings UI, history pagination/redaction and Host restart scenarios remain unrun. |
| B4 native/offline | **PARTIAL** | Windows Client installed and launched on both machines; TEST-01 shows Host setup and TEST-02 reached Welcome before the uninstaller probe. TEST-02 now needs package repair and an unlocked RDP desktop. No Host connection, real two-computer sync, offline edit, conflict/receipt recovery, Android UI test, protected-field, workspace/view/report or UI permissions/scaling scenario has run. |
| B5 backup/restore/operations | **NOT RUN PHYSICALLY** | No installed Host, Task Scheduler, local approval, physical backup, tamper/corruption, retention, interrupted backup, disposable restore or Recovery Authority reconciliation. CI logical database restore tests passed on the recovery workflow. |
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
  databases. No migration, restore or credential was applied to a physical
  test computer.
- No account password or production credential was requested, recorded, or
  placed in source, scripts, reports or CI. No live product data was accessed.
- Defender and Code Integrity remained enabled: `WinDefend` is RUNNING and the
  Code Integrity Operational log is enabled on both machines. The installer,
  Client, Host broker and service binaries are unsigned. Installation and
  launch succeeded without an observed application-control block; this does
  not resolve the inherited unsigned deployment limitation or prior
  uninstaller block.
- Wave 1 history did not capture old cross-record target events or prior field
  values. No historical events are inferred.
- The Wave 2 A handoff records Windows development-Host shutdown timeouts in
  automated CI without a confirmed source cause. This B investigation item was
  not reproduced because no candidate Host was installed on a test computer.

## Not executed

No completed interactive uninstall/cleanup test, Host service provisioning,
physical PostgreSQL migration,
representative Wave 1 physical upgrade, real two-computer synchronization,
Android device UI, Windows permissions/scaling/navigation matrix, scheduled
operation, physical backup or physical restore was executed. No reboot was
performed. No local product build or test was run on the owner's workstation.
