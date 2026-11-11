# Wave1fix15 Client repeat-install and Host reboot checkpoint

**Captured:** 2026-11-09 12:58 Asia/Beirut
**Accepted Wave 1 progress:** 60% (unchanged)
**Open gates:** Stages 10, 3, 8, and 9

The Stage 3 and Stage 8 evidence pages retain their earlier 2026-11-02 snapshot of 50%, before Stage 6 was accepted. The later authoritative stage ledger in `final-audit-preparation-20261102.md` records Stage 6 closed and 60% accepted. This checkpoint preserves the later 60% ledger and does not recalculate or reopen accepted stages.

## Physical machine identity

Read-only PowerShell over the existing `ventio_lab` SSH key returned:

```text
Host address: 192.168.1.102
Computer name: AbedKilany
UUID: 4C4C4544-0051-5A10-8042-C4C04F343032
MachineGuid: 84344ef3-d1ec-477e-9539-ae1a5702266c

Client address: 192.168.1.105
Computer name: AbedKilany
UUID: 9EB7F117-F40D-11DE-81D0-B9F76E398C6C
MachineGuid: e1bd301b-05eb-4b3f-9b40-2c899ae39ae8
Installed Ventio: 0.1.18
VentioHost service: not installed
VentioPostgres service: not installed
```

The duplicate computer-name text is confirmed, but the hardware UUIDs and Windows MachineGuids differ. The Host and Client are distinct physical systems; no rename was needed.

## Client queue preservation before lifecycle testing

No Ventio Client process was running. Before installation testing, the Client's `ventio_native_client.sqlite3` database and existing WAL/SHM sidecars were copied read-only to `client-preserved-2026-11-09/`. The SQLite copy was opened in read-only mode. The only queue row was:

```text
command_id: 986963e9-1695-458a-85cc-aa5f4267aad8
type: extension.record.create
host_status: PENDING
attempt_count: 0
created_at_utc: 2026-11-07T22:29:32.597183Z
updated_at_utc: 2026-11-07T22:29:32.597183Z
last_attempt_at_utc: null
```

The payload and credential store contents were not emitted. The historical identifier `SYNC-TEST-001` is present inside this pending command's envelope; its test record was therefore preserved. The command was not retried, acknowledged, deleted, or changed. The preserved database, WAL, and SHM hashes are recorded in `client-queue-preservation-20261109.json`.

## Client physical repeat-install and local-data retention

The unsigned internal Wave1fix15 0.1.18 installer was transferred to Client `192.168.1.105`. Its SHA-256 matched the Development artifact:

```text
8e921367a6a7139a232fdf0a9f5fd3d1d61703bbf53d25c3ca705991d446b284
```

The existing 0.1.18 installation was run again in silent mode with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`. Observed result:

```text
PRE_VERSION=0.1.18
INSTALL_EXIT=0
POST_VERSION=0.1.18
INSTALL_LOG_SUCCESS=True
HOST_SERVICE=
POSTGRES_SERVICE=
```

SHA-256 hashes for the local Client SQLite databases, WAL/SHM sidecars, and opaque `flutter_secure_storage.dat` were identical before and after installation. No credential contents were read. The unrelated pending queue row remained intact in the captured read-only database. This verifies the physical Client repeat-install procedure and local-data retention for this same-version install; it does not verify a Host upgrade's PostgreSQL business-data preservation or Client enrollment/synchronization. Installer log: `client-wave1fix15-installer.log` on Client at `C:\Users\abedkilany\AppData\Local\Temp`.

**Classification: `PASS — VERIFIED`** for the repeated Client installation and local-data retention procedure.

## Host pre-reboot checkpoint and reboot-persistence attempt

Immediately before the controlled reboot, SSH to Host succeeded and returned:

```text
Host=AbedKilany
UUID=4C4C4544-0051-5A10-8042-C4C04F343032
SERVICE=VentioHost|Running|Auto|NT SERVICE\VentioHost
SERVICE=VentioPostgres|Running|Auto|NT SERVICE\VentioPostgres
LoopbackHealth={"apiVersion":1,"status":"alive"}HTTP_STATUS=200
```

The planned reboot was requested remotely with `shutdown.exe /r /t 15 /d p:4:1`; PowerShell returned `REBOOT_SCHEDULED`. The subsequent recovery poll did not regain SSH, RDP, or HTTPS:

```text
ICMP=False
TCP_22=False
TCP_3389=False
TCP_8443=False
POLL=1 22=False 8443=False
POLL=2 22=False 8443=False
POLL=3 22=False 8443=False
POLL=4 22=False 8443=False
POLL=5 22=False 8443=False
POLL=6 22=False 8443=False
POLL=7 22=False 8443=False
POLL=8 22=False 8443=False
POLL=9 22=False 8443=False
POLL=10 22=False 8443=False
RECOVERY_WINDOW_EXPIRED
```

This run cannot determine the post-boot Windows service state because the Host is unreachable. The pre-reboot state passed; reboot persistence is **`BLOCKED — ENVIRONMENT`**, not a verified service failure. No Host database or configuration was changed by the probe. The recovery request and bounded port polls are included in the append-only execution history.

## Graphical acceptance limitation

Host RDP displayed the Windows secure lock screen. For the Client, Computer Use could not activate the Remote Desktop Connection dialog (`failed to activate captured window`); no credential was entered and no lock screen was operated. Host Overview readiness/version and the installed setup retry therefore remain visually unverified. The physical Client synchronization flow was not started because the Host became unreachable during the controlled reboot.

## Updated gate disposition

- **Stage 10 — OPEN.** The physical Host in-place upgrade and physical Client repeat-install/local-data-retention procedures passed. The Host reboot-persistence attempt is blocked by Host network unavailability. Fresh install, repair/recovery matrix, Host PostgreSQL data-preservation assertion, uninstall/retention options, representative failure cases, and offline-sync integration remain open.
- **Stage 3 — OPEN.** The earlier installed setup retry failed to authenticate its saved administrator session. Safe transport-code propagation is deployed and its focused suite passed 26/26, but the retry after that correction, installed first-administrator lifecycle, interruption/resume, idempotency, failure export, authenticated readiness and reboot evidence are incomplete.
- **Stage 8 — OPEN.** Client local data was preserved, but physical enrollment, exact-scope authorization, extension approval, offline record creation, Host acceptance/receipt, retry, restart synchronization, and independent readback were not run.
- **Stage 9 — OPEN.** The targeted change review and focused regression results remain valid; final engineering acceptance cannot pass while Stages 10, 3, and 8 are open and Host post-reboot state is unavailable.

No accepted stage was reopened, no accepted percentage was changed, and no business database was reset.


## Stage 9 targeted review — 2026-11-09

The final closure changes in this checkpoint were reviewed in source. The existing-profile setup path now forwards only the validated Host transport error code into the sanitized setup diagnostic; the focused Host Setup suite had passed 26/26 with targeted analysis clean. The installer now calls the supported Host-stop helper after Recovery Authority migration and before the LAN helper's stopped-service precondition. The path-contract regression asserts that ordering.

Recheck output:

```text
UNIFIED_INSTALLER_HOST_PROGRAM_FILES_PATH_CONTRACT_PASS
UNIFIED_INSTALLER_SHARED_FLUTTER_FIRST_RUN_HOST_CLIENT_CHOICES_PASS
UNIFIED_INSTALLER_HOST_PROVISIONING_DEFERRED_TO_FLUTTER_PASS
git diff --check: exit 0; only existing LF/CRLF normalization warnings
```

This review found no new security or data-integrity regression in these scoped changes. It is not a final release audit: Host post-reboot state is unavailable, the physical setup and synchronization lifecycle is incomplete, and the unsigned internal installer has not had its commercial signing/toolchain status resolved. Stage 9 remains OPEN.


## Client silent uninstall/reinstall retention check — 2026-11-09

Preflight on Client confirmed `VentioHost` and `VentioPostgres` were absent, `C:\ProgramData\Ventio` did not exist, no Ventio UI process was running, and the installed application was 0.1.18. The existing user data directory and pending queue snapshot had already been preserved.

The installed `C:\Program Files\Ventio\unins000.exe` was run with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` and without `-RemoveData`. Observed output:

```text
UNINSTALL_EXIT=0
UNINSTALL_LOG_SUCCESS=True
VENTIO_REGISTRY_AFTER_UNINSTALL=False
PROGRAM_DIR_AFTER_UNINSTALL=False
PROGRAMDATA_AFTER_UNINSTALL=False
```

The app-support file hashes were unchanged after uninstall, including the pending queue and opaque secure-storage file. The checksum-matched Wave1fix15 installer was then run again:

```text
REINSTALL_EXIT=0
REINSTALL_LOG_SUCCESS=True
POST_VERSION=0.1.18
PROGRAM_DIR=True
HOST_SERVICES_ABSENT=True
```

The same Client app-support hashes remained unchanged after reinstall. The uninstaller and reinstall logs are preserved under `client-preserved-2026-11-09/`. **`PASS — VERIFIED` for this physical Client silent uninstall/reinstall-retention procedure.** This did not exercise the graphical Host-data deletion checkbox because no Host data/services existed on Client; Host uninstall/retention UI and Host database retention remain untested.


## Installer removal regression checks — 2026-11-09

On Development, the temporary-fixture removal diagnostics suite passed partial-install state validation, protected diagnostics archiving, and rejection of an unrecognized partial installation. The product-data-root ACL suite passed administrator ownership, protected inheritance, service-only traversal, duplicate SID handling, interactive-writer rejection, and fixed production boundary checks. Both scripts exited 0; output is preserved in `host-removal-diagnostic-archive-regression-20261109.log`.

These are automated fixture checks for the removal and data-root boundaries. They do not exercise Host service/data removal on the physical Host or the uninstall data-deletion checkbox; those operational criteria remain open.


## Final Windows acceptance artifact integrity

The Wave1fix15 0.1.18 installer hash was rechecked against its adjacent manifest: `8e921367a6a7139a232fdf0a9f5fd3d1d61703bbf53d25c3ca705991d446b284` on both; Authenticode is `NotSigned`. Output is preserved in `wave1fix15-final-installer-check-20261109.txt`.

A fresh local-neighbor check for Host found no ARP entry and a zero link-layer address on Development's `Wi-Fi 3` interface. This adds network-layer evidence that the Host is not currently responding on the local link; it does not establish whether the Host is powered off or explain the cause.
