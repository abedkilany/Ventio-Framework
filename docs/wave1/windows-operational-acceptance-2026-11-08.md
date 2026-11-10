# Windows Operational Acceptance and Performance Remediation — 2026-11-08

## Decision

**Release recommendation: BLOCKED.** The current source contains verified fixes for coordinated database upgrades, setup progress, automatic LAN HTTPS configuration, pairing idempotency, durable synchronization, and sanitized diagnostics. Disposable integration and Windows source-level checks pass. The specified Host at `192.168.1.102:8443` accepts TCP connections from this workstation, but an HTTPS request using normal Windows certificate validation fails with `UntrustedRoot`. I did not bypass certificate validation. The workstation is `bahaa`, not `ABEDKILANY`; its Ventio services are active, so installed-service or installer tests against it would risk existing state. The separate `192.168.1.105` Client and its SQLite queue are not accessible here. No physical two-device acceptance is claimed.

The pending `SYNC-TEST-001` operation was not read, retried, acknowledged, deleted, or otherwise changed. No live Host or Client database was opened by the tests in this report.

## Root cause analysis

| Observation | Finding and evidence | Status |
|---|---|---|
| `RECOVERY_FINGERPRINT_MISMATCH` after migrations 031 and 032 | The upgrade regression constructs a persisted migration-030 Host, applies 031/032 outside the coordinated upgrade while leaving the independent witness unchanged, and reproduces the mismatch. The trusted helper rejects it before DDL and preserves the database, identity rows, and witness. The safe path applies migrations through 035 through the Recovery Authority protocol and commits witness and database state with durable receipts. The distinct installer defect was confirmed: installer 0.1.8 skipped the database-upgrade script; the 0.1.9 source ordering fix now runs verified backup and upgrade before restarting Host. | `PASS — VERIFIED` in isolated fixture; physical installer upgrade remains unverified |
| `HOST_SETUP_INTERRUPTED_REQUIRES_RECOVERY` | The exact historical operation cannot be attributed to memory pressure from available evidence. A separate confirmed setup failure was the hard-coded expectation of 29 migration rows when the payload contained 30. That defect was fixed by deriving the ledger count from the package. Current broker writes a running heartbeat every five seconds while provisioning is active; the client allows up to 45 minutes and treats a missing/stale heartbeat separately from a valid running operation. | `PASS — VERIFIED` for current source and focused tests; original incident attribution remains uncertain |
| TLS files existed but `listenerEnabled = false` | The current normal Host provisioning path calls `enable-host-lan-listener.ps1 -RestartServices`, verifies certificate-pinned HTTPS readiness, and only then marks the listener enabled. The isolated Windows LAN configuration tests pass for DPAPI configuration, scoped firewall profiles, public-profile refusal, upgrade config preservation, and Recovery Authority preservation. The target Host TCP port is reachable, while Windows default trust rejects the certificate as `UntrustedRoot`; the exact older deployed artifact’s failure point remains unconfirmed. | `PASS — VERIFIED` for source path and isolated Windows tests; target certificate identity and installed readiness not verified |
| “Host denied record access” lacked useful evidence | The Host denial code was already stored safely in SQLite, but the record page discarded it and rendered only generic text. The Client now reads the persisted safe code and displays it with the existing denial guidance; cached records continue to be hidden until an authorized Host query succeeds. | `PASS — VERIFIED` by regression test |
| Extension candidate submission and approval | Added durable scoped Host candidate listing and review routes, a Host Administration review screen, separate approve/reject actions, durable rejection reasons, exact package digest checks, self-review denial, and Recovery Authority admitted mutations. The first rejection integration reproduced HTTP 503/SQLSTATE 23514: migration 034 had dropped the wrong PostgreSQL table constraint, leaving the old lifecycle check in place. Corrected 034 to replace the actual lifecycle constraint while preserving manifest identity integrity. The disposable PostgreSQL run now verifies candidate submission, idempotency, direct-validator denial, scoped listing, self-review denial, approval and exact-digest distribution, rejection reason persistence, and rejection from the approved registry. The physical `sync.test` candidate’s registration remains uninspected. | `PASS — VERIFIED` for disposable Host lifecycle and operator UI regressions; physical candidate and operator review remain untested |
| Windows HTTPS reports `UntrustedRoot` | Added a Windows CurrentUser `TrustedPeople` provisioning script that requires an independently confirmed SHA-256 fingerprint, checks certificate validity and Server Authentication EKU, imports only a public certificate, and validates `/healthz` using ordinary Windows TLS hostname and validity checks. The Client now reconnects with the exact pinned leaf as its sole trust anchor and keeps standard TLS validation active; the catch-all bad-certificate callback was removed from enrollment and later API requests. The specified Host certificate was not trusted or changed here. | `PASS — VERIFIED` for implementation, Client regression suite, and PowerShell parsing; physical trust remains unverified |
| Offline record acceptance | Existing disposable Windows Host/SQLite integration verifies offline queue persistence, same-ID retries, Host receipts, conflict handling and SQLite reopen. Those are useful integration results, but they do not inspect or alter the owner’s pending operation and do not constitute this two-machine run. | `PASS — VERIFIED` for isolated integration only; physical operation remains untested |

## Implemented corrections in the current source

The repository already includes these corrections from prior engineering work, independently reviewed during this run:

- Recovery Authority-coordinated Host schema upgrade with a restricted verified backup, atomic migration batch, durable operation receipts, stale-witness rejection, and interruption reconciliation.
- Installer ordering that invokes the database upgrade before the Host restart path.
- Five-second setup progress heartbeats, bounded operation duration, safe retry semantics, and accurate setup phase reporting.
- Automatic LAN certificate provisioning, firewall/configuration setup, HTTPS readiness verification, and listener activation from the supported setup workflow.
- Pairing v2 request IDs, durable Client-side retry identity, safe unknown-outcome reporting, and a dedicated 120-second request deadline. The timeout correction follows a controlled reproduction that showed the earlier 15-second `Future.timeout` did not cancel a Host mutation.

This run also changed [extension_store.dart](../../packages/ventio_native_client/lib/src/extension_store.dart), [extension_studio_page.dart](../../packages/ventio_native_client/lib/src/extension_studio_page.dart), and [extension_studio_test.dart](../../packages/ventio_native_client/test/extension_studio_test.dart) so an authorized administrator or user can see the persisted safe reason code for a Host record-read denial. It does not expose credentials, request bodies, or raw server exception text.

The Host review workflow is available to operators with the exact `extension.package.review` branch grant. Candidate listing and decisions execute through the restricted Identity API database role; PostgreSQL rechecks current scope and submitter identity. A candidate's submitter is rejected by the database, and approval/rejection is committed through the existing administrative audit and Recovery Authority path. Clients can request review, but cannot approve or distribute their own package.

## Regression and integration verification

| Check | Result |
|---|---|
| `dart test/all_tests.dart` in `ventio_core` | 81 passed, 0 failed |
| Targeted Flutter suites: Host setup, extension package transfer, Host-backed extension flow, synchronization UI, Extension Studio | 80 passed, 0 failed; one real-Host-only case skipped outside its integration runner |
| `flutter test --no-pub test/extension_studio_test.dart` after denial-code change | 39 passed, 0 failed |
| `flutter analyze --no-pub` in `ventio_native_client` | No issues found |
| `dart analyze lib test` in `ventio_host_api` | No issues found |
| `flutter test --no-pub` in `ventio_native_client` after the review UI, HTTPS pinning, timing probe, and isolated-data support | 229 passed, 0 failed, 2 real-Host integration cases skipped |
| `flutter analyze --no-pub` in `ventio_native_client` after startup timing changes | No issues found |
| `scripts/windows/trust-host-certificate.ps1` PowerShell parser | Passed |
| Setup Broker .NET validation executable | Passed request allowlist, caller SID, operation ID, ACL and arbitrary-argument checks |
| Host Service .NET validation executable | Passed readiness, bootstrap, config, TLS certificate, broker and DPAPI receipt checks; elevated actual service-SID ACL case skipped |
| `test-host-lan-listener-config.ps1` | Passed six isolated DPAPI, firewall, network-profile and Recovery Authority preservation checks |
| `test-unified-installer-path-contract.ps1` | Passed Host path, first-run choice and deferred-provisioning contracts |
| Disposable PostgreSQL 16.15 migration-030 upgrade fixture | **21 checks passed**, including 031–035 success with preserved identity, stale 031/032 fingerprint reproduction and fail-closed preservation, pre-commit interruption, retry, lost commit acknowledgement, prepared-transaction recovery and receipt reconciliation |
| Disposable PostgreSQL 16.15 extension lifecycle integration | **145 passed, 0 failed**, including correct rejection constraint migration, preserved manifest identity check, authorized approval/rejection, rejection reason persistence, self-review denial, restricted database access, RLS, Host receipts and recovery-admission checks |
| Windows Release Client full suite | **231 passed, 0 failed, 2 real-Host-only skipped** |
| Targeted Host API analyzer after migration and diagnostic changes | No issues found |
| Targeted Client analyzer after review UI and trust changes | No issues found |
| `git diff --check` | Passed |

The first attempt at the upgrade fixture stopped before Recovery Authority tests because the supplied PostgreSQL tool path did not include the trusted Host upgrade executable. That disposable server was stopped; the correctly packaged rerun above passed. The failed attempt left only copied `.sql` fixtures under `%LOCALAPPDATA%\VentioFramework\postgres-test-runs\20261108121639930-1`. A cleanup command was rejected by the execution policy, so those temporary copies remain; they contain no database, credentials, or user records.

## Performance evidence

The Windows Release Client was measured on this workstation, `bahaa`, with a fresh isolated SQLite profile for each cold run and the same profile reopened for its warm run. Five paired cold/warm runs were captured before and after parallelizing the independent command-queue and extension-store opens. Existing app data and credentials were not used. The table reports medians from instrumented release builds; elapsed values are internal workflow spans, not deployment targets.

| Workflow | Before | After | Result |
|---|---:|---:|---|
| Cold: Flutter binding to both local databases ready | 34.0 ms | 30.2 ms | 3.9 ms faster |
| Warm: Flutter binding to both local databases ready | 27.0 ms | 25.1 ms | 1.9 ms faster |
| Cold: Flutter binding to first screen ready | 65.5 ms | 59.6 ms | 5.9 ms faster |
| Warm: Flutter binding to first screen ready | 59.1 ms | 58.1 ms | 1.0 ms faster |
| Cold command queue open | 16.8 ms | 25.2 ms | Individual span increased under concurrent initialization |
| Cold extension store open | 13.5 ms | 29.4 ms | Individual span increased under concurrent initialization |

The total database-ready and first-screen spans improved modestly; warm first-screen change is within measurement noise. Parallel work raises each individual SQLite span due to contention, while allowing their wall-clock work to overlap. The change is retained because the measured combined startup path shortened without skipping either initialization. These numbers describe one Windows workstation, not the target Host or Client hardware. No arbitrary performance threshold is asserted.

The earlier isolated pairing investigation remains the only Host API stage baseline: about **2.98 s total**, **2.35 s Host processing**, including Recovery Authority lock/ACL setup 832 ms, witness read 429 ms, pending witness write 471 ms, database transaction 21 ms, and witness finalization 480 ms. It confirms that ACL-checked Windows helper launches and durable witness operations dominate that sample. They were not weakened or bypassed. A release-build pairing request, Pairing Code page initialization/generation, representative non-startup page navigation, and initial Host Setup were not measured in this run; the target Host and Client were unavailable for those operations. CPU, RAM, and disk counters were also not collected. No before/after improvement is claimed for the unmeasured workflows.

The Host integration suite also measured the current Recovery Authority and database paths on its isolated PostgreSQL 16.15 fixture with 1,000 users and 20,000 audit rows: fingerprint snapshot median **0.528 ms**, 20-row RLS query median **4.508 ms** with the transaction authorization cache and **10.66 ms** on the uncached comparison path, RLS transaction median **451.41 ms**, and authenticated Host query median **1,172.26 ms** (five samples). These are a local integration profile, not release-service or target-hardware measurements, and have no comparable before value. The pairing breakdown shows the larger cost in Recovery Authority Windows lock/ACL helper launch and durable witness I/O; those security checks remain intact.

## Operational acceptance scenarios

| Scenario | Result | Evidence boundary |
|---|---|---|
| A — Clean Host installation | `BLOCKED — ENVIRONMENT` | Isolated Host provisioning and installer contract tests pass. Target TCP 8443 is reachable, but default Windows HTTPS validation reports `UntrustedRoot`; the Host’s trusted fingerprint and an authorized installed-service session are unavailable. Current workstation has running Ventio services and existing installation state, so clean installation cannot be safely performed here. |
| B — Physical Client enrollment | `NOT TESTED` | Earlier same-workstation process integrations cover pinned HTTPS enrollment. No access to the specified separate physical Client in this run. |
| C — Extension approval | `NOT TESTED` | The disposable PostgreSQL lifecycle verified submission, authorized approval, rejection, exact digest distribution, audit and authorization boundaries; the Windows review UI has two widget regressions. Physical candidate registration for `sync.test`, operator approval on the target Host and distribution to the target Client remain unverified. |
| D — Physical offline record synchronization | `NOT TESTED` | Isolated Host/SQLite integrations pass, but the preserved operation on the specified Client was not touched and no physical receipt was observed. |
| E — Cross-Client physical visibility | `NOT TESTED` | Prior logical-client readback tests do not count as a second physical Client. |
| F — Installed prior-version upgrade | `BLOCKED — ENVIRONMENT` | The disposable migration-030 PostgreSQL/Recovery Authority fixture was rerun against the corrected payload and passed all 21 checks through migration 035. This proves the controlled fixture path only. The original installed Host’s upgrade from 0.1.9, its preserved data, installer/service restart and Client connectivity remain unverified; no in-place physical Host upgrade was performed. |
| G — Performance and responsiveness | `BLOCKED — ENVIRONMENT` | Cold/warm startup was measured in Windows Release with isolated data, and parallel startup database opening produced a small measured improvement. Pairing Code page/generation, representative navigation, and initial Host Setup still require authorized Host workflows and comparable target-device measurements. |

## Remaining risks and minimal physical acceptance

1. Provide access to the target Host (`ABEDKILANY`, `192.168.1.102`) and separate Client (`192.168.1.105`) for a scheduled acceptance session, or run the procedure below on those machines. The current workstation is a different Windows host.
2. On the physical Host, verify the new operator workflow using a separate account with the exact `extension.package.review` grant. Confirm that the existing `sync.test` candidate is present before taking any action. Do not approve or reject the owner’s existing candidate as part of acceptance without explicit operational direction.
3. On an isolated Windows VM, install a prior-version Host fixture with preserved database rows, valid service identities and witness state; run the signed/reviewed target installer in place; verify 031–035, Recovery Authority state, services, Client connectivity and receipts. Do not use clean-install success as upgrade evidence.
4. On the actual Host, verify services, four readiness components, exact HTTPS certificate fingerprint, listener status, and TCP/TLS reachability from the separate Client before enrolling.
5. On the Client, confirm the existing pending operation remains unchanged, restart the app, restore network, and retry that same operation reference. Verify Host validation, PostgreSQL transaction, receipt verification, durable SQLite confirmation, and readback from a separately enrolled Client.
6. Capture release-build timings for cold and warm startup, representative navigation, Pairing Code page initialization and generation, and initial Host Setup. Record workflow stages using comparable device state and report medians plus per-stage distributions; do not set targets until this baseline exists.

### Physical HTTPS trust workflow

On the Host, obtain `host-lan-certificate.pem` and the SHA-256 fingerprint from `host-lan-info.json` through an authenticated channel. Independently compare the fingerprint with the Host administrator. On the Client, use the endpoint name or IP that appears in the certificate SAN, then run:

```powershell
.\scripts\windows\trust-host-certificate.ps1 `
  -Endpoint 'https://ABEDKILANY:8443' `
  -CertificatePath '.\host-lan-certificate.pem' `
  -ExpectedSha256 '<independently-confirmed-64-character-SHA-256>'
```

The script imports the public leaf into the current Windows user's `TrustedPeople` store and checks `https://ABEDKILANY:8443/healthz` with normal Windows certificate validation. It removes a newly added trust entry if validation fails. The Client's own enrollment and later API calls use the exact pinned certificate and standard TLS hostname and expiry checks. Do not continue enrollment if fingerprint comparison, hostname validation, or `/healthz` fails.

The development installer in the available packaging reports is unsigned. Release signing and a physical installed lifecycle are separate gates. Until the extension approval workflow and machine-level scenarios are closed, **the Windows Host–Client workflow is not release-ready**.

## Follow-up: final engineering preparation

Follow-up work produced an unsigned internal Windows candidate, `0.1.18+19`, and the consolidated package under `artifacts/ventio-windows-acceptance-0.1.18-20261108`. The existing enrolled Client now has an operator-controlled certificate pin renewal screen that requires an independently confirmed fingerprint and verifies exact pin, SAN, validity, and standard TLS before changing only the pin. A failed validation leaves the previous pin and enrollment intact. The physical target certificate remains unverified.

The full Client suite was rerun: **233 passed, 0 failed, 2 real-Host-only cases skipped**; Client and Host API analyzers report no issues. The Windows ACL-backed private-file suite passed. The PostgreSQL extension lifecycle suite was freshly rerun on a disposable PostgreSQL 16.15 cluster: **145 passed, 0 failed**. The migration-030-through-035 Recovery Authority upgrade fixture was also freshly rerun: **21 checks passed**, including the 031/032 stale-fingerprint reproduction, preservation, interruption recovery, and lost-ack reconciliation. The Host review UI and its authorization flow are regression-covered, but the physical `sync.test` candidate was not inspected or decided.

Five paired Windows Release process-launch captures, recaptured after correcting the Windows process-I/O counter source, report fresh isolated-profile median 383.5 ms (range 346.3–1,674.7 ms) and warm same-profile median 394.8 ms (range 331.1–517.6 ms). The validated Windows `Win32_Process` transfer counters show about 10.21 MB read per fresh-profile launch and 10.23 MB warm. Earlier first-pass I/O values were zero because `Get-Process` did not expose the properties on Windows PowerShell; those raw traces are retained but excluded from published full-process measurements. Detailed method and limitations are in `performance-report-2026-11-08.md`. Navigation, Pairing Code page/generation, and initial Host Setup still lack comparable release measurements. Recovery Authority instrumentation shows Windows PowerShell ACL helper launches, cross-process locking, independent durable witness writes, and finalization dominate the isolated 2.98 s pairing request sample. The package includes a read-only Host/PostgreSQL resource sampler for the physical run. No security optimization was made without parity evidence.

The candidate packages the unified Client/optional Host installer (SHA-256 `5c299604a5696d25fcad4cccba624df56e25bfe617a66028635e277dde30cb51`), payload manifest, trust helper, performance collector, physical guide, evidence template, and checksum file. Installer is **NotSigned** and is intended only for controlled internal acceptance. The package includes a `source-state.json` because its base Git revision was dirty.

The original installed 0.1.9 Host upgrade remains unverified. The 21 checks are a disposable database/recovery fixture, not a realistic installed-service upgrade. No physical Host/Client action was performed, and the existing `SYNC-TEST-001` pending operation was left untouched. Therefore A–H physical acceptance remains incomplete and the release remains **BLOCKED**; Level 1 engineering preparation is complete, Level 2 is pending.


## 2026-11-09 Wave1fix15 physical follow-up

- Host 0.1.18 in-place upgrade: `PASS — VERIFIED` (installer exit 0, recovery-policy cleanup, Running/Automatic services and HTTPS health before reboot; see Wave1fix15 installer log and previous closure evidence).
- Client 0.1.18 repeated installation and local SQLite/WAL/SHM plus secure-storage hash retention: `PASS — VERIFIED`; installer exit 0 and local state hashes unchanged. This was not a fresh-install test.
- Host reboot persistence: `BLOCKED — ENVIRONMENT`; the planned reboot was accepted, but SSH/RDP/HTTPS stayed unreachable across ten recovery polls and a later spot check. No post-boot service state can be asserted.
- Host database business-data preservation, fresh installation, repair/recovery, uninstall/data-retention options, representative installer failures, and physical offline synchronization remain `NOT TESTED` in this follow-up.

Evidence and exact outputs: [Wave1fix15 physical follow-up](evidence-closure-2026-11-08/wave1fix15-client-repeat-install-and-host-reboot-2026-11-09.md), [reboot probe log](evidence-closure-2026-11-08/host-wave1fix15-reboot-probes.log), and [installer log](evidence-closure-2026-11-08/client-preserved-2026-11-09/client-wave1fix15-installer.log). Stage 10 remains OPEN.


### Client uninstall/reinstall retention — 2026-11-09

Client's no-Host-data path passed a silent uninstall and reinstall. The uninstaller exited 0, removed the Ventio registry entry and Program Files directory, and left user app-support data unchanged; the Wave1fix15 reinstall exited 0 and restored version 0.1.18 with the same app-support hashes. No Host services or ProgramData\Ventio data existed. This is not evidence for the Host-data deletion checkbox, Host service removal, or Host database retention UI; those remain open. Logs and full disposition: [Wave1fix15 follow-up](evidence-closure-2026-11-08/wave1fix15-client-repeat-install-and-host-reboot-2026-11-09.md).


### Removal regression fixtures — 2026-11-09

`test-host-removal-diagnostic-archive.ps1` passed the partial-install classification, diagnostics archive, and unknown-failure rejection scenarios. `test-host-product-data-root.ps1` passed the data-root ACL security checks. These use isolated temporary fixtures; they supplement but do not replace physical Host removal/retention acceptance. See [captured outputs](evidence-closure-2026-11-08/host-removal-diagnostic-archive-regression-20261109.log).


### 2026-11-09 Host reboot access recovery

The earlier “Host reboot persistence — BLOCKED because SSH/RDP/HTTPS remained unavailable” observation is superseded. From Development, authenticated SSH now verifies `ABEDKILANY`, `abedkilany\abedkilany`, High Integrity SID `S-1-16-12288`, installed version 0.1.18, and `sshd`, `VentioHost`, and `VentioPostgres` Running/Automatic after the recorded reboot. Host ports 22, 3389, and 8443 listen; certificate-pinned HTTPS `/healthz` returns HTTP 200 and the `alive` response. Event logs show sshd listening at 12:47:34 and accepting the Development key at 12:47:54; the later outage correlates with Wi-Fi disconnects and delayed DHCP, while the specific wireless trigger is unproven.

These observations verify post-reboot service startup and HTTPS liveness, not all Stage 10 readiness criteria. The authenticated management readiness request returned HTTP 401 when sent without a bearer token. Computer Use has a connected Host RDP session, but cannot capture its desktop, leaving the Host Overview and uninstall data-retention UI unverified. Fresh installation, repair/recovery, Host business-data preservation, full Host uninstall/data-retention, representative failure matrix, and physical offline-sync integration remain open. Do not treat this checkpoint as Stage 10 acceptance or add stage weight. See [Host reboot connectivity investigation](evidence-closure-2026-11-08/host-reboot-connectivity-investigation-2026-11-09.md).

The WLAN diagnostic report and Kernel-Power events establish the sleep correlation: at 12:48:13.393 and again at 13:19:13.706, Windows logged `Sleep Reason: Button or Lid`; the respective wake events at 13:19:06 and 13:20:38 report `Power Button`. NDIS requested low device power at each sleep and Wi-Fi disconnected; the wireless report records a driver disconnect. The active AC and DC `Sleep after` indices are both zero (never), so this was not the configured idle timeout. The Host is a portable Dell and was AC-online during the read-only check. The logs do not distinguish lid-sensor input from a power-button input.

As a corrective action on the dedicated Host only, `Lid close action` and `Power button action` were set to “Do nothing” on AC, with both DC values unchanged at “Sleep.” A controlled reboot then passed a bounded SSH/service/TLS recovery on the first attempt; after waiting past the prior sleep point, no Kernel-Power sleep event was logged since boot, the AC/DC values persisted, and pinned HTTPS remained HTTP 200/TLS 0. This verifies the reboot/sleep-policy regression only; authenticated readiness and all other Stage 10 lifecycle criteria remain open. No Ventio, network, service, or database settings changed. Full evidence: [Host reboot connectivity investigation](evidence-closure-2026-11-08/host-reboot-connectivity-investigation-2026-11-09.md).

## 2026-11-09 Host repair-style installer procedure disposition

The Wave1fix15 installer manifest and Host-side copy matched SHA-256 `8e921367a6a7139a232fdf0a9f5fd3d1d61703bbf53d25c3ca705991d446b284` (`NotSigned`). A pre-test copy of the non-running Client executable and PostgreSQL cluster identifier `7705548262546041680` were preserved. The planned repair-style file-restore procedure could not start: local tool process creation rejected the file move and silent installer invocation as `blocked by policy`. The installer was not launched and the installed executable, services, database, and configuration were not changed. The pre-test backup and verified installer remain in the Host evidence directory. Stage 10 repair/recovery remains `BLOCKED — ENVIRONMENT`; this does not pass or close the gate. Full evidence: [SetupStatus and repair-check evidence](evidence-closure-2026-11-08/host-setup-status-and-repair-check-2026-11-09.md).
