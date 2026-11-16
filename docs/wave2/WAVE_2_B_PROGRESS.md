# Wave 2 B verification progress

**Current status: WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**
Current checkpoint (2026-11-16 08:15 UTC): SSH identifies both test machines; Host and PostgreSQL are Running on both, local health is HTTP 200, and the exact Host SHA-256 is present on both. Mutual pinned TLS 1.2 probes between the machines passed certificate fingerprint, validity and SAN checks; unauthenticated `/api/v1/session` returned 401 from each direction. Defender remains enabled, but read-only threat history now confirms the Bearfoos event on both hosts (including `DidThreatExecute=true`); its root cause remains unconfirmed. No Client process is running, no Ventio backup task/set is present, and real synchronization/backup remain unexecuted. See the latest checkpoint below.
Branch: `feature/wave-2-a`
Draft PR: [#6](https://github.com/abedkilany/Ventio-Framework/pull/6), open and unmerged
Starting source commit: `9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61`
Product/package verification commit: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
Diagnostic correction commit: `f11bf27e83dd6b206fc63289bbf325471a1ee026` (unit-tested)
Latest installer package installed on TEST-02: `17b014125b695e3242e2d9b50b3eb9732a8c5fcb`
Host API test-harness correction commit: `e3efc25075388d2ac92543238c99473313d85d79` (verified in CI)
Latest physically tested Host artifact source commit: `a7c85ef5617bca9345804106aa17457b2eaf858c` (exact Host SHA-256 `5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`)
Latest CI-verified PR head: `a7c85ef5617bca9345804106aa17457b2eaf858c` (11/11 checks passed)
Last updated: 2026-11-16 08:15 UTC

Wave_2_C and merge into `main` are out of scope. Prior physical installation
evidence remains tied to `fb341a78`. The diagnostic correction is included in
candidate `b3a5f585`; the Windows Acceptance Package workflow succeeded and
created artifact `ventio-wave2-windows-acceptance-b3a5f585b8c641321fa3fc33503eb10ca00837f0`
(103,810,454 bytes; SHA-256 `aea0a03f95589eec58bf70df6a1685ff66a4ba59ce464bda7f683472e2a89173`).
That `b3a5f585` status is historical. The newer package from commit
`17b014125b695e3242e2d9b50b3eb9732a8c5fcb` passed all nine GitHub Actions
workflows; Windows Acceptance Package run `43653937272` produced the artifact
installed on TEST-02. Its ZIP SHA-256 is
`1c5a1076ab427cd132afc5efd1d7c2610e61376647441c00a628fb04b5f650eb`; the
installer SHA-256 is
`E117F4E762ECBDBBF2E0A3B6649FC6887101F5CF08907B293A1CBC929013B020`.
Owner-reported Host setup then succeeded on TEST-02. SSH confirmed operation
`8e5eace6076314dc95c1389f95c707d2` complete at `HOST_READINESS`, both services
Running, PostgreSQL accepting local connections, and `/healthz` returning 200.
After TEST-01 SSH returned, read-only checks confirmed its Host and PostgreSQL
services, local health endpoint and fresh database schema. TEST-01's installed
payload manifest contains no source commit field, so its files cannot be tied
to the package commit with available evidence. TEST-02's tested package remains
`17b0141`; its Host executable was later quarantined by Defender during the
controlled crash test recorded below.

## Gate ledger

| Gate | Status | Evidence / remaining work |
|---|---|---|
| B0 — Environment and tooling | **PARTIAL** | SSH identifies TEST-01/Codex-1 and TEST-02/Codex-3. Both Host/PostgreSQL services are Running and Defender/real-time protection are enabled; current signature is 1.463.324.0. TEST-01 is back on the network. Historical Defender detections on both Hosts remain unresolved. |
| B1 — Static, core and contract verification | **PASS in candidate CI** | All 11 PR checks passed on exact source head `a7c85ef5617bca9345804106aa17457b2eaf858c`; workflow run 43767153016 produced the exact-hash Host artifact used on TEST-02. CI is not physical acceptance evidence. |
| B2 — PostgreSQL, identity and security | **PARTIAL — selected fresh checks PASS** | TEST-02's fresh 40-migration/ledger checksum, `assert_schema()`, 30-table owner/RLS/FORCE RLS, least-privilege, runtime assertion, Recovery Authority admission and empty-queue claim checks passed before reboot; Host/PostgreSQL then persisted through reboot. Full cross-scope authorization, Wave 1 upgrade and recovery reconciliation remain open. |
| B3 — Host operations and data processing | **PARTIAL** | Both Hosts return `/healthz` HTTP 200 and unauthenticated `/api/v1/session` HTTP 401 over mutually pinned TLS. No authenticated operations or populated durable-job/data-processing scenarios passed. Historical TEST-01 worker errors remain unresolved. |
| B4 — Native Flutter and offline synchronization | **PARTIAL / BLOCKED** | No Client process is running on either device; authenticated pairing/enrollment, two-computer synchronization, offline edit, conflict recovery and receipt reconciliation were not executed. Local `flutter devices` listed only Windows, Chrome and Edge; no Android target was available and `adb` was not on PATH. GUI-dependent and Android UI cases are **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**. |
| B5 — Backup, restore and Windows operations | **PARTIAL** | Earlier TEST-02 Host-process crash recovery passed in 108 seconds and Host/PostgreSQL survived a controlled reboot. Current read-only inspection found no Ventio scheduled task or backup directory/set on either host. Local approval, product backup execution, integrity/retention, interruption and disposable restore remain unexecuted. Defender event history is recorded separately and remains unresolved. |
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
  verified as local Administrators at High Integrity. On 2026-11-15 07:35 UTC,
  SSH identified VENTIO-TEST-02/Codex-3; Codex-1 on TEST-01 timed out. Earlier
  `quser` checks showed both designated RDP sessions Active.
- At the earlier 2026-11-14 checkpoint, the candidate artifact was present on both machines at
  `C:\VentioTest\downloads\ventio-wave2-windows-acceptance-fb341a78eca1bb897e2ce09f1271dae39bbd7d11-verified.zip`.
  Both copies are 103,796,488 bytes and SHA-256
  `0c83cd20dab447e6d024fe3d62dd5e9588499deb417a986820bf10d6a13114ae`.
  The installer inside the package hashes to
  `5413f65d86235633d40e1912767dd576303ecb0a7216d4a5e846c977f955977b` and
  Authenticode reports `NotSigned`.
- At the earlier 2026-11-14 checkpoint, the unified installer was run on both machines. TEST-01 is machine-wide under
  `C:\Program Files\Ventio`; TEST-02's first launch reached Welcome. The
  TEST-02 package was restored through the verified installer after the
  inconclusive silent-uninstall probe (exit code 0). The owner later unlocked
  its RDP desktop, but Computer Use could not operate Start/Settings. The
  2026-11-14 SSH check confirmed the install directory and uninstall registration remained, so no
  interactive uninstall retest was completed. `VentioPostgres` and
  `VentioHost` were absent on both machines. This pre-provision state was
  superseded on 2026-11-15 when the owner completed Host setup on TEST-02.
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
- The 2026-11-14 read-only SSH check reconfirmed both machine hostnames and that
  `Codex-1`/`Codex-3` RDP sessions report Active. At that checkpoint both
  machines still had no `VentioHost` or `VentioPostgres` service and no
  `C:\ProgramData\Ventio`.
  The owner unlocked TEST-02's RDP desktop, which was visible during the check;
  Computer Use could not activate Start/Settings and the window later minimized.
  TEST-02's Ventio install directory and uninstall registration remain present;
  `unins000.exe` was not running. No interactive uninstall was performed.
  TEST-02's later Host provisioning and current TEST-01 SSH timeout are recorded
  in the 2026-11-15 update below.

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

- **Passed physically on the earlier install:** TEST-01 Host/PostgreSQL
  provisioning through database initialization; fresh migrations
  001–040/checksums; checked RLS and least-privilege profile; normal service
  restart persistence; SSH identity and security-state checks. The owner later
  cleared that database. The latest TEST-02 database has the selected fresh
  migration/schema/RLS checks recorded below; remaining security and recovery
  scenarios are still open.
- **At the 2026-11-14 checkpoint, blocked:** authenticated first-administrator
  session and dependent physical identity/authorization and real synchronization
  tests. TEST-01 Client session validation failed. TEST-02 setup later completed,
  but its authenticated Client session is still unverified.
- **Not executed — manual owner validation required:** remaining interactive
  Windows Client flows, Android device UI, uninstall
  cleanup, and any test requiring GUI-only local approval. Use the exact status
  `NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED` in the detailed results.
- **Not executed:** representative Wave 1 upgrade fixture; full cross-tenant,
  company and branch authorization matrix; Host operations/data processing;
  Task Scheduler; product backup verification/corruption/retention; interrupted
  backup; disposable product restore and Recovery Authority reconciliation;
  crash/reboot recovery; complete 22-capability matrix and B6 audit.

At the 2026-11-14 23:32 UTC checkpoint, the owner-managed clean reinstall had
completed provisioning but reproduced a Client session failure. A confirmed
diagnostic defect was corrected in
`f11bf27`: bootstrap session transport failures now retain their validated
Host error code. Focused unit tests and analysis pass, and the candidate
package built successfully. SSH inspection then found a Host job-worker
diagnostic immediately before the Client session failure; this is a plausible
shared PostgreSQL/Recovery Authority readiness issue, not a proven cause. At
that checkpoint the new candidate had not been installed or retried physically;
it was subsequently installed on TEST-02 and Host setup succeeded after retry,
as recorded below. Final disposition remains
**WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**.

### 2026-11-14 23:32 UTC — SSH-only diagnostic correlation

On TEST-01, the latest SSH check confirmed operation
`0793a94d97f202699fbbff49b5db5cc8` still `complete` at 22:31:08.425 UTC and
both `VentioHost` and `VentioPostgres` were Running. The Host diagnostic file
contained `HOST_JOB_WORKER_UNAVAILABLE` (`host.jobs`) at 22:34:38.505 UTC,
about 77 seconds before the Client's `HOST_SESSION_AUTHENTICATION_FAILED` at
22:35:55.809 UTC. The worker emits this generic event when its database/
Recovery Authority tick throws; the event does not expose the underlying cause.
Persistent token authentication also resolves the token from PostgreSQL on
each request, so the timing suggests (but does not prove) a shared backend
readiness fault. `/healthz` is process liveness only, not database readiness.
At 23:17 UTC, the configured PostgreSQL port was confirmed as 54329 and
`pg_isready -h 127.0.0.1 -p 54329` returned `accepting connections`. This is a
current unauthenticated readiness probe; it does not verify database login,
migrations, or Recovery Authority admission at the earlier failure time.
No evidence implicates Smart App Control or DPAPI, and no Host data or service
was modified during this read-only check.

## 2026-11-15 07:35 UTC — TEST-02 Host setup and SSH verification

The owner reported that the first Host setup attempt failed while creating the
first Host administrator, then retried with **Set up Host** and succeeded. No
GUI interaction was performed by the agent. SSH to `Codex-3@192.168.1.107`
identified `VENTIO-TEST-02` and confirmed the latest operation file
`8e5eace6076314dc95c1389f95c707d2.json`: state `complete`, phase
`HOST_READINESS`, updated `2026-11-15T07:21:08.5243312Z`.

The installed acceptance package is built from exact commit
`17b014125b695e3242e2d9b50b3eb9732a8c5fcb`, which passed all nine GitHub
Actions workflows. Windows Acceptance Package run `43653937272` produced the
artifact. The package ZIP SHA-256 is
`1c5a1076ab427cd132afc5efd1d7c2610e61376647441c00a628fb04b5f650eb`; the
installer in the owner-provided TEST-02 Desktop folder has SHA-256
`E117F4E762ECBDBBF2E0A3B6649FC6887101F5CF08907B293A1CBC929013B020` and is
unsigned. The installed manifest reports 1,724 payload files, 310,613,952
bytes and PostgreSQL 16.15. Installed `VentioSetupBroker.exe`,
`VentioHostService.exe` and `postgres.exe` hashes match that manifest.

On TEST-02, `VentioHost` and `VentioPostgres` are Running with Automatic start
and separate virtual service identities (`NT SERVICE\VentioHost` and
`NT SERVICE\VentioPostgres`). PostgreSQL is bound to `127.0.0.1:54329` and
the bundled `pg_isready` returned `accepting connections`. Host `/healthz` at
`http://127.0.0.1:8080/healthz` returned HTTP 200 with
`{"apiVersion":1,"status":"alive"}`. Host listens on port 8443; requests
to its HTTPS `/healthz` endpoint failed Windows default certificate
validation for the IP, machine name and localhost. This probe does not test
the Client's certificate-pinning path, so no bypass was attempted and the
result remains an open compatibility/security finding. Both services are
configured to restart after failures at 5, 30 and 60 seconds; no failure was
injected. Defender, real-time protection and Tamper Protection are enabled;
`VerifiedAndReputablePolicyState=0`. No policy was changed during these
checks.

At the initial 07:35 checkpoint, fresh migration/security checks had not yet
been run. The subsequent 08:04 read-only B2 checks and orderly restart are
recorded below. Authenticated API, backup/restore and forced crash/reboot tests
remain open.
At 07:35 UTC SSH to TEST-01/Codex-1 timed out, so TEST-01 cannot serve as an
independent synchronization peer. Two-computer synchronization remains
blocked; GUI-only Client acceptance is **NOT EXECUTED — MANUAL OWNER
VALIDATION REQUIRED**.

## 2026-11-15 08:04 UTC — TEST-02 fresh migration and schema checks

The protected migration credential file was present at the supported
ProgramData path, machine-DPAPI protected, and its file/directory ACLs were
protected with only BUILTIN\Administrators and SYSTEM Full Control. The
secret was decrypted in memory and passed to `psql` through the child process
environment; it was not displayed, added to an argument, or written to disk.
All checks below were read-only except session-scoped `SET ROLE`.

The installed package contained migrations `001_records.sql` through
`040_wave2_job_archival.sql`. Comparing canonical-LF SHA-256 values of all 40
installed migration files with `public.ventio_schema_migrations` returned 40
entries, zero missing, zero extra and zero checksum mismatches. As
`ventio_owner`, `ventio_security.assert_schema()` returned successfully.
All 30 public `ventio_*` tables returned by the catalog check were owned by
`ventio_owner` and had both RLS and FORCE RLS enabled. The runtime and identity
API roles were neither superuser, database/role creators nor BYPASSRLS. Direct
SELECT checks for identity secrets, records and the migration ledger were false
for the identity API role; runtime direct migration-ledger SELECT was also
false. The migration login cannot `SET ROLE ventio_runtime_app`, so
`assert_runtime()` and real runtime SQL execution were not run. No table data
was modified.

## Next steps

TEST-01 access has returned. The mandatory remaining work is to resolve the
Defender detection through an approved signed build or vendor/security review,
verify Client trust and authentication through the supported Client path, then
run the two-device and authorized backup/restore scenarios. GUI-dependent
checks remain `NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED`. Keep PR #6 Draft
and unmerged; the disposition remains **WAVE_2_B — PARTIAL VERIFICATION /
BLOCKED**.

## 2026-11-15 10:15 UTC — TEST-01 reconnection, physical B2 and crash recovery

SSH to `Codex-1@192.168.1.106` again identified `VENTIO-TEST-01`. Both
`VentioHost` and `VentioPostgres` were Running/Automatic under their dedicated
virtual service identities. PostgreSQL 16.15 accepted local connections on
`127.0.0.1:54329`; Host `/healthz` returned HTTP 200 and unauthenticated
`/api/v1/session` returned HTTP 401. The protected migration credential's
LocalMachine-DPAPI value was used only in process memory and the `psql`
environment; it was not printed, placed in arguments or saved. The installed
40 migration files matched all 40 ledger hashes, `ventio_security.assert_schema()`
passed, and all 30 checked public `ventio_*` tables were owned by
`ventio_owner` with RLS and FORCE RLS. The aggregate RLS violation count was
zero. Runtime, identity API and migrator roles had no superuser/create-db/
create-role/BYPASSRLS flags; identity API and runtime direct reads of the
migration ledger were false, and the migrator could not assume the runtime
login. No table data was changed.

Using the protected identity-API connection settings and the existing Recovery
Authority witness in memory, `ventio_security.admit_recovery` succeeded. The
same identity-API transaction invoked `wave2_claim_job()` with an empty queue
and was rolled back. This proves current witness admission and the empty-queue
claim path only; it does not explain earlier `HOST_JOB_WORKER_UNAVAILABLE`
events on TEST-01 (latest recorded event: `2026-11-15T09:38:14.516937Z`) or
test execution of an actual queued command. The prior diagnostic emits no raw
exception. Latest checks also confirmed Defender antivirus, real-time
protection and antimalware service remain enabled; `VerifiedAndReputablePolicyState=0`.

From TEST-02, TCP `192.168.1.106:8443` succeeded, while standard
`Invoke-WebRequest https://192.168.1.106:8443/healthz` failed with a TLS trust
relationship error. No trust bypass was used. TEST-01's manifest has no source
commit field; current `ventio_host.exe` SHA-256 is
`5A18C389C5CCE563CAA8A5A5BA9222108B785680AEBED6878996385C3EA1E5F2` and
`VentioHostService.exe` SHA-256 is
`AF64049CC55C08A92209E8EC581DF69229D9551F9046418AFEDB1A5EE8F1F3C4`.

On TEST-02, a controlled crash test killed only the verified child
`ventio_host.exe` (PID 3208) at `2026-11-15T09:59:14Z`; preflight found no
established Host TCP clients. PostgreSQL stayed on PID 4424 and remained
accepting connections. Within seconds, Microsoft Defender event 1116/1117
classified `C:\Program Files\Ventio\host-payload\ventio_host.exe` as
`Trojan:Win32/Bearfoos.A!ml` (threat 2147731250, Severe) and quarantined it
while real-time protection was enabled. After 100 seconds the Host service
remained Stopped with exit code 2; SCM had attempted its 5/30/60-second restart
actions. The sanitized service diagnostic reports
`HOST_ENGINE_PROCESS_START` / `InvalidOperationException`, consistent with the
quarantined executable being absent. A manual `Start-Service` attempt also
failed. No file was restored, Defender exception added, or security control
weakened. TEST-02's Host is currently unavailable; its PostgreSQL data remains
intact and running.

Read-only Task Scheduler inspection on TEST-01 found no tasks under `\Ventio\`.
The product backup scheduler, approval workflow, backup integrity/retention,
and disposable restore were not executed. The owner-installed TEST-02 package
is tied to commit `17b014125b695e3242e2d9b50b3eb9732a8c5fcb`; TEST-01's current
Host payload commit is unverified, and both test machines have Defender enabled.

## SSH-only continuation — 2026-11-15 10:56 UTC

A fresh SSH probe again identified VENTIO-TEST-01. Its VentioHost and
VentioPostgres services were Running/Automatic under their dedicated service
identities. Defender antivirus, real-time protection and antimalware service
were enabled. Win32_DeviceGuard.CodeIntegrityPolicyEnforcementStatus returned
2; no Host provisioning retry was performed.

A controlled VentioHost service restart passed after confirming the service
path/identity and no established connections to Host ports 8080 or 8443.
Local http://127.0.0.1:8080/healthz returned 200 before and after; the
service returned to Running and the Host process/listeners recovered in 18.4
seconds. PostgreSQL was not restarted or modified and remained Running;
pg_isready reported 127.0.0.1:54329 - accepting connections. The engine
remained present with the previously recorded SHA-256
5A18C389C5CCE563CAA8A5A5BA9222108B785680AEBED6878996385C3EA1E5F2.

At 10:51 UTC, TEST-02 SSH still found VentioHost Stopped and
ventio_host.exe absent. Defender still recorded threat 2147731250 for that
path and emitted events 1116/1117 while Defender and real-time protection
were enabled. The owner reports that retrying first-administrator setup
succeeded; this does not change the current stopped-service/quarantined-file
state. No restore, exclusion or security-policy change was attempted.

Standard HTTPS validation to TEST-01 localhost:8443 still fails certificate
trust; no bypass was used. Real Client authentication/synchronization remains
blocked. On report head 1e2c5f8e06e15c8643e8202b0753212a2ae70c81, all nine PR workflows completed successfully. Host API run 43704184519 passed, including extension approval/scope/recovery integration and trusted credential reissue. This CI result does not replace physical acceptance evidence.

## Windows API integration timeout — 2026-11-15 12:01 UTC

On report head 8929a966d9429cc0f74c075d9de74b06e2e97bd5, Host API attempt 1
(run 43707135745) failed in test/api_integration.dart at line 329 while waiting
up to 20 seconds for a child Host process to exit after the shutdown command.
The previous Host API run 43704184519 had passed the same 34-assertion test.
The focused rerun of run 43707135745, attempt 2, completed successfully,
including extension approval/scope/recovery. All nine PR workflows for 8929a96
are now completed successfully; this is pre-correction CI evidence.

Cause: the Windows test fixture wrote the shutdown command but kept the child's
stdin pipe open. The child listens on stdin and cancels that subscription after
Host shutdown; the sibling identity fixture documents that EOF is needed for
reliable cancellation on Windows. The test helper now closes stdin after
writing the command. Correction commit: e3efc25075388d2ac92543238c99473313d85d79.
The existing process-restart integration test is the focused regression and
passed on post-correction head 676c9896d3340a04d2dabb4157a9d96c837e3f61.
This is a test-harness reliability fix, not a confirmed production Host defect.

Local Dart formatting passed. A local analyzer attempt could not resolve the
package imports because dependencies were not present in this worktree;
GitHub Actions passed formatting/analyzer on the pre-correction report head.
All nine GitHub Actions workflows passed on post-correction head
676c9896d3340a04d2dabb4157a9d96c837e3f61. Host API run 43712289370 passed
formatting, analysis, HTTP/PostgreSQL, identity, RLS/least-privilege, scoped
roles, pairing, extension approval/recovery and trusted credential reissue.
Native Flutter/Windows/Android run 43712289247 and Windows package run
43712289246 also passed. No workflow was canceled.

## TEST-01 TLS and diagnostics follow-up — 2026-11-15 14:09 UTC

Read-only SSH inspection confirmed TEST-01 `VentioHost` and `VentioPostgres`
are Running and `/healthz` returns 200. The Host publishes
`https://VENTIO-TEST-01:8443` (alternate `https://192.168.1.106:8443`) and
reports its LAN certificate as self-signed, requiring explicit client trust.
The public certificate's Subject and Issuer are both `CN=VENTIO-TEST-01`, its
SAN contains `VENTIO-TEST-01` and `192.168.1.106`, and its SHA-256
`2c63e4ffaa97dd4ba06be9d55360ef7fc907d7b3a8db6a889de6356e6d4f6368` matches
the published fingerprint. The Client pairing page requires that fingerprint
and directs the user to enter it before enrollment; it forbids certificate
bypass. No trust store or certificate was changed. B4 remains blocked pending
authenticated pairing and real two-device sync; this TLS result explains the
default trust failure and is not itself a confirmed product defect.

TEST-01's sanitized diagnostic file contains six `HOST_JOB_WORKER_UNAVAILABLE`
events, most recently at 2026-11-15 13:09:53 UTC. At 14:09 UTC no newer event
was present. The Host worker deliberately omits the underlying exception, so
the historical B3 cause remains unresolved; no authenticated operations were
executed. TEST-02 still has `VentioHost` Stopped and its engine file absent,
while Defender antivirus, real-time protection and antimalware service remain
enabled. No file was restored or excluded.

All nine workflows passed on report-only successor head
0bd9ea9bd439dfd9e87a1ab2c7bd84681bfa4a82: Host API 43715371756, Windows
Acceptance Package 43715371820, Native Flutter 43715371758, Core 43715371761,
Credential Lifecycle 43715371766, Durable Commands 43715371754, Host Crash
Recovery 43715371763, Host Engineering 43715371819 and Host Persistence
43715371745. PR #6 remains open and Draft.

## SSH-only continuation — 2026-11-15 14:48 UTC

Latest read-only SSH checks confirm TEST-01 VentioHost and VentioPostgres are
Running and /healthz returns 200. The only setup status file is complete at
HOST_READINESS, updated 2026-11-14T22:31:08Z; this does not prove administrator
login or Client authentication. The latest HOST_JOB_WORKER_UNAVAILABLE remains
2026-11-15T13:09:53Z; its cause is unresolved.

Both test machines are now security-blocked: VentioHost is Stopped, PostgreSQL
is Running, and `ventio_host.exe` is absent. Defender Antivirus, real-time
protection and AM service are enabled on both. No file was restored or
excluded.

All nine GitHub Actions workflows passed on exact PR head
ee167d6d219bdb655edae129441b7a12e15d9420: Host API 43723289645, Host Crash
Recovery 43723289479, Native Flutter 43723289568, Credential Lifecycle
43723289469, Host Persistence 43723289505, Windows Acceptance Package
43723289499, Host Engineering 43723289481, Core Foundation 43723289578, and
Durable Commands 43723289470. This CI pass does not replace physical
acceptance. PR #6 is still open, Draft and unmerged.

## Dual-machine Defender quarantine checkpoint — 2026-11-15 20:29 UTC

SSH verified both hosts as `VENTIO-TEST-01` and `VENTIO-TEST-02`. At the
checkpoint, both `VentioHost` services were Stopped with exit code 2, both
`VentioPostgres` services were Running, and Host health at
`http://127.0.0.1:8080/healthz` could not connect. TEST-01's service-startup
record identifies `HOST_ENGINE_PROCESS_START`; its SCM events report system
error 2. The bundled payload manifest lists 92 verified files and the only
missing file is `ventio_host.exe` (8,806,400 bytes; expected SHA-256
`5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`).

Microsoft Defender recorded threat 2147731250 (`Trojan:Win32/Bearfoos.A!ml`,
Severe) and a successful remediation for that exact path on TEST-01 at
2026-11-15T20:10:00Z. TEST-02 has the same threat/path and successful action
at 2026-11-15T09:59:21Z. Defender Antivirus, real-time protection and AM
service remain enabled on both. Current Code Integrity state on TEST-01 is
enforced; no Code Integrity event for `VentioHostService.exe` or
`ventio_host.exe` was found. Earlier CI events for the Setup Broker remain
historical and separate. The evidence confirms quarantine as the immediate
deployment blocker; it does not establish whether Defender's classification
is a false positive or a real threat. No file was restored, no exclusion was
added, and no security control was weakened.

TEST-02's native Client remains installed, but neither machine can currently
provide a Host pairing code. No enrollment, Host setup retry, data restore or
physical B4 synchronization was attempted after confirming the quarantine.
Continue only after a trusted signed candidate or formal Defender disposition
is available. PR #6 was open, Draft and unmerged at exact head
`02b8ecc3901527f0b635fd66e5c68c1734d7dff8`; all ten checks passed there. This
checkpoint does not change the partial/blocked acceptance disposition.

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

SSH to Codex-1/`192.168.1.106` again identifies `VENTIO-TEST-01`; Codex-3/
`192.168.1.107` identifies `VENTIO-TEST-02`. On both, `VentioHost` and
`VentioPostgres` are Running with Automatic start, `ventio_host.exe` exists at
`C:\Program Files\Ventio\host-payload\ventio_host.exe` with SHA-256
`5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`, and local
`/healthz` returns HTTP 200. Microsoft Defender Antivirus and real-time
protection are enabled; intelligence is `1.463.324.0`.

Read-only Defender history reports `Trojan:Win32/Bearfoos.A!ml` / Threat ID
`2147731250` on both machines. TEST-01's event began `2026-11-15T20:10:00.859Z`,
status last changed at `20:11:32.332Z`, and includes the Host file plus a
process; TEST-02's event began `2026-11-15T09:59:21.939Z`, status last changed
at `09:59:45.177Z`, and includes the Host file. Both report
`ActionSuccess=true`; `Get-MpThreat` reports `IsActive=false` and
`DidThreatExecute=true`. These records do not establish the classifier's root
cause or prove a false positive. No quarantine item was restored, no exclusion
was added, and no protection setting was changed. The binary's historical
security disposition remains **ROOT CAUSE NOT CONFIRMED**.

From each physical machine to the other, TLS 1.2 and `/healthz` returned HTTP
200 after exact certificate SHA-256 pin, certificate time, DNS SAN and IP SAN
checks. Pins: TEST-01 `2c63e4ffaa97dd4ba06be9d55360ef7fc907d7b3a8db6a889de6356e6d4f6368`;
TEST-02 `b34d2c33650fb658a40266e6c474289d165938ff90bccadcdb4f9c4b1a99433f`.
Both uncredentialed `/api/v1/session` probes returned HTTP 401, as expected.
The TLS library reported chain errors for the self-signed certificates; the
probe accepted them only when the expected exact pin, validity interval and
both SAN identities matched.

No `ventio_native_client` process was running on either computer. No task under
`\\Ventio\\` or `VentioHostBackups` was found. The documented backup paths
`C:\ProgramData\Ventio\Backups` and
`C:\ProgramData\Ventio\Installer\Operations` do not exist on either host.
Therefore these checks prove
cross-machine Host reachability and certificate identity only; they are not
Client enrollment, authenticated synchronization or backup evidence. Real
two-device/offline synchronization and product-authorized backup/restore
remain **NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED**. The attempt to
re-run protected TEST-01 database credential checks was not executed because
the installed PowerShell module was rejected by the existing script policy; no
execution-policy bypass was applied. Earlier recorded migration/security
checks remain historical evidence, not a fresh re-run in this checkpoint.

No product code changed. PR #6 remains Draft and unmerged; no Wave_2_C work or
merge to `main` was started.
