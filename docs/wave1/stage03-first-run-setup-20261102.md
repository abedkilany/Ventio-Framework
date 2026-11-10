# Stage 3 — Unified First-Run Setup Evidence

**Status:** IN PROGRESS — 0% accepted (11% stage weight)<br>
**Evidence date:** 2026-11-02 (Asia/Beirut)<br>
**Source checkpoint:** `codex/extension-platform` at `fb0a1a0` (tested source now committed)<br>
**Formal Wave 1 acceptance:** 50 / 100

## Locally verified

- Flutter first-run and Host setup suites passed **26/26**, covering setup flow, elevation cancellation, refusal to repeat a non-idempotent bootstrap request, interrupted-flow resume controls, completed broker result resume, refusal when an existing service is found, pre-API failure reporting/export, unavailable local diagnostics, and setup status.
- Setup Broker and Host Service .NET test suites passed. The elevated service-owner/SID subtest was skipped because this process is not elevated.
- test-host-new-install-state.ps1 passed safe new-install acceptance and rejected existing services, data, backups and out-of-bound paths.
- test-host-provisioning-failure-record.ps1 passed redaction, protected ACL/path and safe-resume checks.
- The PostgreSQL provisioning test mode used a disposable temporary cluster, passed migrations and least-privilege bootstrap/upgrade checks, then stopped and removed the fixture.
- First-administrator bootstrap and Recovery Authority integration run 20261102012802487-1 passed **11/11**, including empty-database initialization, idempotence, fail-closed recovery after an interrupted post-commit handoff, exact receipt retry, no duplicate credential and no second tenant. The isolated database was removed.
- Pairing API integration run 20261102012847455-1 passed **24/24**, including one-time redemption, exact company/branch scope, replay/expiry/revocation and credential rotation. The isolated database was removed.
- Latest Windows PostgreSQL/Host/Client process integration run `20261102174911885-1` passed **31/31 Host assertions**. It exercised authenticated real Host APIs, exact branch authorization, independent Host process generations, durable Client offline work and Host-confirmed synchronization across separate local Client identities and SQLite stores.
- In that run, the real Host issued a single-scope enrollment code over certificate-validated LAN HTTPS. Native Windows Flutter integration test `host_client_enrollment_ui_test.dart` passed **1/1**: the Client pairing screen enrolled through the live Host, persisted the Client profile/credential locally, and authenticated a new session with the expected user and exact branch. The pairing code remained obscured and was not emitted in test output.
- A separate Flutter Host-backed offline integration test passed **1/1** in the same disposable run. The runner stopped and removed its PostgreSQL fixture.
- Dart analysis of the process integration and Flutter analysis of the new pairing integration reported no issues. The new integration compiled the native Windows application successfully.

## Acceptance gaps

Stage 3 remains open because the local process integrations do not prove the installed, elevated Windows setup lifecycle. The following mandatory evidence is still missing:

- Resume/repeat and interrupted setup through an installed Flutter app, privileged broker and actual Windows SCM services.
- Partial-install detection and repeated setup attempts in a clean isolated Windows installation.
- First-administrator and Recovery Authority setup through that installed service/UI path, including end-to-end operational verification.
- Full pre-API failure export from the installed setup screen against real installation failures.
- Elevated service identity/ACL and post-reboot service startup verification on an isolated installation.

The current development token is not elevated. The workstation has registered Ventio services and product paths, so using the Host installer/service lifecycle here would risk modifying existing state. No registered clean Hyper-V VM, Windows Sandbox runtime or local Windows ISO/VHD was available in the previously completed environment audit. These installed lifecycle cases were not attempted, and no current service or product database was changed.

The owner-provided Windows 11 setup/reboot screenshots remain useful external evidence but do not cover all of the installed resume, interruption, repeat and failure-export criteria above. The separate office computer joined to an Active Directory domain is inaccessible to this session. Its reported HOST_FIRST_ADMIN_RECOVERY_AUTHORITY_FAILED remains unexplained; the supplied pg_isready authentication event is not evidence of that failure. No cause is inferred.

## Decision

No Stage 3 points are awarded. The local UI, broker, PostgreSQL, first-admin, Recovery Authority, pairing and live Client enrollment results are implementation and test evidence, not proof of the complete installed acceptance gate. Formal Wave 1 acceptance remains **50%**.

## 2026-11-04 defect closure addendum

The PostgreSQL setup failure is now traced to the initializer's hard-coded 29-entry ledger check against the packaged 30 migrations. A later retry's protected diagnostic identified `DATABASE_INITIALIZATION` / `HOST_DATABASE_MIGRATION_LEDGER_INVALID`; the original generic event and the later diagnostic have separate correlation IDs. The 30-migration disposable PostgreSQL regression now passes, and the project owner confirms Host installation succeeds with the fix. See [Host Setup Provisioning Defect Closure](host-setup-provisioning-defect-closure-20261104.md) for diagnostic provenance, tests, and the source-linked installer.

This adds evidence for database initialization, safe failure reporting, and the owner-confirmed run. It does not satisfy Stage 3's remaining installed elevated resume/interruption/repeat, first-administrator/Recovery Authority, failure-export, service-identity/ACL, and reboot criteria. Stage 3 remains IN PROGRESS with no points awarded; formal acceptance remains **50%**.


## 2026-11-09 installed follow-up

The Wave1fix15 Host Setup transport-code correction is installed, but a post-fix UI retry could not be performed: Host RDP remained at the secure lock screen, then Host became unreachable during the controlled reboot-persistence attempt. No installed first-administrator, interruption/resume, idempotency, authenticated readiness, failure-export, or setup-after-reboot criterion is accepted from this run. Stage 3 remains OPEN. See [Wave1fix15 physical follow-up](evidence-closure-2026-11-08/wave1fix15-client-repeat-install-and-host-reboot-2026-11-09.md).

## 2026-11-09 Host access recovery addendum

The earlier post-reboot “Host unreachable” condition is superseded for current connectivity. SSH with the existing key now verifies an administrative High Integrity token (`S-1-16-12288`); `VentioHost` and `VentioPostgres` are Running/Automatic; pinned HTTPS `/healthz` returns HTTP 200. A live pinned-TLS request to `/api/v1/management/readiness` without a bearer token returned HTTP 401 `UNAUTHENTICATED` (`cor_5155fe4fc4906d4d22f06c7019b3ecd6`), so it provides no readiness result. Computer Use connected to Host RDP and Host `quser` reports `abedkilany` in an Active `rdp-tcp#0` session, but Computer Use screenshot capture fails with `foreground window did not report a process id`; Host Setup/Overview UI is still unverified. These checks did not run first-admin, interruption/resume, idempotency, failure export, or the authenticated readiness flow. No Stage 3 weight is earned. Detailed event and access evidence: [Host reboot connectivity investigation](evidence-closure-2026-11-08/host-reboot-connectivity-investigation-2026-11-09.md).

## 2026-11-09 installed Setup Broker handoff evidence

Read-only inspection of the installed `C:\Program Files\Ventio\SetupStatus` found four records reporting `state=complete`, `phase=HOST_READINESS`, and an empty `failureCode`. Setup Broker source shows that `CompleteFirstAdministrator` writes this state after the first-administrator Recovery Authority response is acknowledged and the protected bootstrap result is matched. This verifies the installed first-administrator handoff subcriterion. The phase is not a live Host readiness result; authenticated `/api/v1/management/readiness`, UI/session verification, interruption/resume, idempotency, and failure export remain open. Detailed records and procedure interpretation: [SetupStatus and repair-check evidence](evidence-closure-2026-11-08/host-setup-status-and-repair-check-2026-11-09.md). Stage 3 remains OPEN.

## 2026-11-09 sleep-policy correction and reboot follow-up

Kernel-Power event 42 and Power-Troubleshooter event 1 showed the earlier reachability loss followed sleep transitions (`Button or Lid`) and Power Button wakes. The dedicated Host's AC lid-close and power-button actions were changed to “Do nothing” (DC actions were left at Sleep). A controlled reboot then recovered SSH on the first bounded check; High Integrity, both Ventio services, and pinned HTTPS liveness were verified. After waiting past the prior 53-second sleep transition point, no new Kernel-Power sleep event appeared and the AC/DC action values persisted. This closes the network sleep cause for this regression run only. The RDP session is active, but Computer Use screenshot capture now fails with `IGraphicsCaptureItemInterop.CreateForMonitor failed: Could not capture the given monitor. (0x80070057)`. Host Overview and authenticated readiness remain unverified; no Stage 3 points are awarded.

## 2026-11-10 installed fresh setup, failure and resume

The authorized native Development fixture passed the installed controlled PostgreSQL failure, sanitized report export, safe retry after port release and interrupted Flutter resume on Wave1fix18. Read-only broker tracing records PostgreSQL and Host provisioning while Flutter was closed, then completion of the same operation and reopening in the original test identity. The owner supplied an authenticated READY overview for all four checks in `wave1fresh / fixture / devhost`. Prior installed reboot evidence remains separately recorded. The final safe-repeat and protected lifecycle checks remain pending. UAC cancellation was covered by automated tests and was not physically exercised under the current Windows policy. Formal accepted progress remains 60%. [Installed evidence](evidence-closure-2026-11-08/development-wave1fix18-installed-20261110.json)

## Formal stage acceptance — 2026-11-11

Stages 3, 10 and 8 are accepted at their whole weights of 11, 20 and 6 points. Installed safe-repeat evidence completed Stage 3. The service, setup, failure, upgrade/repair/recovery, retention and explicit deletion evidence completes Stage 10 for the verified internal candidate. Host/PostgreSQL executable hashes are identical to the earlier installed reboot-tested payload, so that successful reboot is reused. The already-passed physical business flow then closes Stage 8's dependencies. Accepted progress is **97%**. Stage 9 remains open for the scoped final audit, W1-UI-001 and signing/distribution disposition.

UAC cancellation was covered by automated tests. The fixture's existing administrator elevation policy suppressed the physical consent prompt. No claim is made that a physical cancellation occurred. The candidate remains unsigned and the Inno commercial-use license remains unverified. The saved original Host archive and staged recovery remain protected outside the current fixture.
