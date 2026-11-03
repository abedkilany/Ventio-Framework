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
