# Wave 2 B verification progress

**Current status: WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**
Current blockers: TEST-01 is unreachable over SSH; TEST-02 Host setup completes after retry, but TLS trust, authenticated API use, remaining database/security scenarios, two-device synchronization and other mandatory gates are not verified.
Branch: `feature/wave-2-a`
Draft PR: [#6](https://github.com/abedkilany/Ventio-Framework/pull/6), open and unmerged
Starting source commit: `9bd0e9e756dc1c6dd414794b1e67f0d8c7db8f61`
Product/package verification commit: `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`
Diagnostic correction commit: `f11bf27e83dd6b206fc63289bbf325471a1ee026` (unit-tested)
Latest tested package commit: `17b014125b695e3242e2d9b50b3eb9732a8c5fcb`
Last updated: 2026-11-15 08:12 UTC

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
The evidence does not establish authenticated API use, migration/RLS state, or
client synchronization. TEST-01 SSH timed out at 2026-11-15 07:35 UTC.

## Gate ledger

| Gate | Status | Evidence / remaining work |
|---|---|---|
| B0 — Environment and tooling | **PARTIAL** | TEST-02/Codex-3 SSH is active on Windows 11 Pro build 26300, PowerShell 5.1.26100.9818, PostgreSQL 16.15. TEST-01/Codex-1 SSH timed out at 07:35 UTC. Defender, real-time protection and Tamper Protection are enabled on TEST-02; `VerifiedAndReputablePolicyState=0`. No controlled reboot-recovery acceptance test was run. |
| B1 — Static, core and contract verification | **PASS in candidate CI** | All nine workflows passed on latest package commit `17b0141`; Windows Acceptance Package run `43653937272` produced the installed artifact. Earlier product/report-only CI results are also recorded in test results. CI is not physical acceptance evidence. |
| B2 — PostgreSQL, identity and security | **PARTIAL — selected fresh checks PASS** | On TEST-02, all 40 migration ledger entries/checksums match the installed package; `assert_schema()` passes and all 30 public `ventio_*` tables checked are owned by `ventio_owner` with RLS and FORCE RLS. Runtime/identity role flags and selected direct-read denials match the least-privilege profile. Full identity API, cross-scope authorization, Wave 1 upgrade and Recovery Authority behavior remain open. |
| B3 — Host operations and data processing | **PARTIAL** | TEST-02 setup operation `8e5eace6076314dc95c1389f95c707d2` is `complete` at `HOST_READINESS`; both services run and `http://127.0.0.1:8080/healthz` returns 200. Windows default TLS validation failed for the 8443 endpoint. Authenticated API operations, authorization and data-processing scenarios remain unverified. |
| B4 — Native Flutter and offline synchronization | **PARTIAL / BLOCKED** | TEST-01 SSH timed out and cannot act as the independent peer. No authenticated Client session, real two-computer synchronization, offline edits, conflict/receipt recovery, Android UI, or remaining interactive UI cases were verified. |
| B5 — Backup, restore and Windows operations | **PARTIAL** | An orderly Host/PostgreSQL stop/start passed on TEST-02: PostgreSQL accepted connections and Host `/healthz` returned 200 afterward. No forced crash/reboot, scheduled backup, integrity/retention test or disposable restore was run on the new installation. |
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

The orderly restart passed on TEST-02, but crash/reboot recovery remains open.

1. Restore SSH availability to TEST-01 before another physical two-computer
   test. Do not delete the verified TEST-02 Host data.
2. Repeat the uninstall from TEST-02's Codex-3 interactive session and verify
   cleanup; under the SSH-only rule classify it as
   `NOT EXECUTED — MANUAL OWNER VALIDATION REQUIRED`.
3. Investigate the TEST-02 HTTPS certificate trust result without weakening
   TLS validation. Verify authenticated Client/API use, then run identity,
   authorization, two-device offline synchronization, Host operations,
   scheduling, backup and disposable restore/reconciliation against the
   isolated test installation.
4. Close the capability matrix only with scenario evidence and update the final
   acceptance report. Any unexecuted mandatory gate keeps
   the disposition **WAVE_2_B — PARTIAL VERIFICATION / BLOCKED**.
