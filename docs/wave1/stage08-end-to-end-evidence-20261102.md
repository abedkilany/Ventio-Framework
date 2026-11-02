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
