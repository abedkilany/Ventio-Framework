# Stage 8 — End-to-End Validation Evidence

**Status:** BLOCKED — 0% accepted (6% stage weight)<br>
**Evidence date:** 2026-11-02 (Asia/Beirut)<br>
**Source checkpoint:** `codex/extension-platform` at `fb0a1a0` (tested source now committed)<br>
**Formal Wave 1 acceptance:** 50 / 100

## Local Host/Client process integration

Latest disposable Windows PostgreSQL 16.15 run `20261102174911885-1` applied the current migration set and security bootstrap to a run-scoped temporary cluster. The fixture was protected, started on loopback, and removed after a successful run.

- The persistent Windows Host process passed **31/31 Host assertions** across real authenticated APIs, exact company/branch authorization, rejection of unauthorized and out-of-scope requests, Host-side record creation/update/read, and durable state after a Host process restart.
- Two independent local Client identities used separate credential/profile state and SQLite stores. Host-backed offline integration passed **1/1**, covering durable pending work, reconnection, Host-confirmed receipts, conflict handling and propagation of the accepted record to the second Client.
- A real Host-issued, single-scope Client enrollment code was redeemed through the native Flutter Windows pairing UI. The integration passed **1/1** over certificate-validated HTTPS, persisted the local profile and credential, and authenticated a new Host session at the expected user and exact branch. The code remained obscured and was not emitted in test output.
- The run also verified the Host LAN HTTPS endpoint against its trusted certificate while preserving the separate local administration listener.
- A subsequent independent local Client offline integration run `20261102175443262-1` passed **1/1** using separate Client identity and SQLite state. It confirms the latest offline/reconnect evidence independently of the combined process run; it does not add physical-device or installed-lifecycle coverage.

## Android emulator integration

Earlier isolated PostgreSQL/Host run 20261101232100833-1 passed **29/29**. A disposable Android 17/API 37 emulator used the Windows Host LAN endpoint over pinned TLS, retained an offline command, reconnected, received the Host receipt, and read the accepted record. The Flutter Android Debug APK build passed. The temporary AVD was shut down and removed after the run; existing AVDs were not started or changed.

## Mandatory acceptance gaps

All Host processes, Windows Client processes and the Android emulator ran on the same development workstation. These tests provide local process and emulator evidence, not physical-device acceptance.

- No second physical Windows Client or Android device was available for the required physical propagation checks.
- The installed Host and Client lifecycle has not been validated end to end on a clean elevated Windows installation.
- Reboot, installed service identity, data retention and uninstall behavior remain open under Stage 10.

No physical-device test is inferred from the independent local processes or emulator. No existing Ventio service or product database was modified for these runs.

## Decision

Stage 8 remains BLOCKED at **0% accepted** until its physical-device and installed-lifecycle requirements pass. The local process integration and Android emulator evidence do not earn partial weight. Stage 9 remains open pending all mandatory stage gates and its final security/release review.


## 2026-11-09 physical follow-up

Read-only identity checks confirmed distinct Host and Client physical UUIDs. Before any reset, the Client queue snapshot preserved a `PENDING` `extension.record.create` envelope containing `SYNC-TEST-001`, with zero attempts. The operation was not touched. Host became unreachable after the controlled reboot, so enrollment, extension approval, offline creation, Host acceptance/receipt, idempotent retry, and independent readback were not attempted. Stage 8 remains OPEN. See [Client queue preservation](evidence-closure-2026-11-08/client-queue-preservation-20261109.json), [Host reboot probes](evidence-closure-2026-11-08/host-wave1fix15-reboot-probes.log), and [physical follow-up](evidence-closure-2026-11-08/wave1fix15-client-repeat-install-and-host-reboot-2026-11-09.md).

## 2026-11-09 Host access recovery addendum

The earlier Host-unreachable condition is superseded for current network access: authenticated administrative SSH works, services are Running/Automatic, and pinned HTTPS `/healthz` returns HTTP 200. The live readiness endpoint rejected a request without a persistent bearer credential with HTTP 401 `UNAUTHENTICATED`; this is only a negative authorization check. Host RDP is connected and its interactive user session is Active, but Computer Use cannot capture the Host desktop, so enrollment and extension approval cannot be visually driven or verified here. The historical Client queue evidence still shows `SYNC-TEST-001` pending with zero attempts; no sync request or Client queue mutation was made. Physical enrollment, extension approval, offline creation, Host authoritative acceptance, receipt, idempotent retry, conflict/rejection cases, restart synchronization, and independent Client readback remain NOT TESTED. No Stage 8 weight is earned. See [Host reboot connectivity investigation](evidence-closure-2026-11-08/host-reboot-connectivity-investigation-2026-11-09.md) and [preserved Client queue](evidence-closure-2026-11-08/client-queue-preservation-20261109.json).

## 2026-11-09 post-correction reboot follow-up

Host system sleep was identified as the cause class for the previous network outage and an AC-only power-action correction was verified through a controlled reboot. SSH, services, and pinned HTTPS remained available after the previous sleep-transition window; no post-boot Kernel-Power sleep event appeared. This fixes the temporary transport outage for the current test setup, but does not run any Stage 8 workflow. The live management-readiness request remains unauthenticated, and Computer Use cannot capture the connected RDP desktop (`IGraphicsCaptureItemInterop.CreateForMonitor` error `0x80070057`). `SYNC-TEST-001` remains preserved as documented in the previous Client snapshot; no enrollment, approval, sync, or queue mutation occurred after that snapshot. Stage 8 remains OPEN at 0% accepted.

## Formal stage acceptance — 2026-11-11

Stages 3, 10 and 8 are accepted at their whole weights of 11, 20 and 6 points. Installed safe-repeat evidence completed Stage 3. The service, setup, failure, upgrade/repair/recovery, retention and explicit deletion evidence completes Stage 10 for the verified internal candidate. Host/PostgreSQL executable hashes are identical to the earlier installed reboot-tested payload, so that successful reboot is reused. The already-passed physical business flow then closes Stage 8's dependencies. Accepted progress is **97%**. Stage 9 remains open for the scoped final audit, W1-UI-001 and signing/distribution disposition.

UAC cancellation was covered by automated tests. The fixture's existing administrator elevation policy suppressed the physical consent prompt. No claim is made that a physical cancellation occurred. The candidate remains unsigned and the Inno commercial-use license remains unverified. The saved original Host archive and staged recovery remain protected outside the current fixture.
