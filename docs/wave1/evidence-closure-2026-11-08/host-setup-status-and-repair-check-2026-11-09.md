# Installed Host SetupStatus and repair-check disposition — 2026-11-09

## Installed first-administrator handoff evidence

Using authenticated SSH as the High Integrity administrator, read only the small JSON records under `C:\Program Files\Ventio\SetupStatus`. Four records reported `state=complete`, `phase=HOST_READINESS`, and an empty `failureCode`:

| Operation record | Updated UTC | Observed state |
|---|---|---|
| `3385b2fc37f4687939b69d48ae57daab.json` | 2026-11-07 21:43:44Z | complete / HOST_READINESS / no failure code |
| `4ce28ac6f25d6dc93194e2301dc74326.json` | 2026-11-07 20:50:12Z | complete / HOST_READINESS / no failure code |
| `e642f3d9bda87f206f3edd2bb59c885a.json` | 2026-11-07 20:35:47Z | complete / HOST_READINESS / no failure code |
| `1fad4487039dc586db467efb077fbace.json` | 2026-11-05 19:31:01Z | complete / HOST_READINESS / no failure code |

The installed Setup Broker source implements `CompleteFirstAdministrator` by writing `complete / HOST_READINESS` only after the first-administrator service response has been acknowledged and the protected bootstrap result has been matched. This verifies the installed first-administrator broker/Recovery Authority handoff path completed. It does **not** prove that the Host's management-readiness endpoint currently returns READY; that route still requires a bearer identity with exact-scope `host.status.read`, and the Overview is not visually readable in the current Computer Use session. The phase name is a workflow phase, not a live readiness result.

The three older maintenance result paths checked (`maintenance-bound-completion-20261031.json`, `maintenance-first-admin-diagnostic-20261031.json`, and `maintenance-status-update-20261031.json`) were absent. No credential or `.dpapi` file contents were read.

**Disposition:** `PASS — VERIFIED` for the installed first-administrator broker handoff subcriterion; Stage 3 remains open for authenticated live readiness, UI/session verification, interruption/resume and idempotency, failure export, and complete installed lifecycle evidence.

## Verified repair package and attempted procedure

The Development Wave1fix15 installer matched its SHA-256 manifest: `8e921367a6a7139a232fdf0a9f5fd3d1d61703bbf53d25c3ca705991d446b284`. Authenticode reports `NotSigned`. It was copied to the Host evidence directory and its Host-side SHA-256 independently matched. Before the intended repair procedure, the installed `ventio_native_client.exe` was verified not running; its SHA-256 `7D6EE8CD6769F9B52C852867D3DE5A12381732229233FE11D69EBAFF6AA7DA76` was copied to the same evidence directory. Read-only `pg_controldata` reported PostgreSQL system identifier `7705548262546041680`, cluster state `in production`; all three services were Automatic/Running.

The planned test would move the preserved Client executable aside, silently run the checksum-verified same-version installer, then verify that the packaged file was restored with the original hash, services recovered, and HTTPS liveness returned. The local execution tool rejected the command at process creation with `CreateProcess ... Rejected ... blocked by policy`. The file move and installer launch did not occur. The pre-test executable copy, manifest, and verified installer remain in `C:\ProgramData\Ventio\RecoveryEvidence\wave1-repair-restore-20261109T130558Z`. The installed executable, services, database, and configuration were not changed by this rejected procedure.

**Disposition:** `BLOCKED — ENVIRONMENT` for this repair-style installation procedure. This does not pass repair/recovery or close Stage 10. No test-machine permission is missing; the local execution policy rejected process creation.

## Post-rejection state check — 2026-11-09 13:17 UTC

After the rejected process-creation request, a separate read-only SSH check confirmed the installed file and Host state remained intact:

```text
APP_PRESENT=True
APP_SHA256=7D6EE8CD6769F9B52C852867D3DE5A12381732229233FE11D69EBAFF6AA7DA76
HELD_FILE_PRESENT=False
BACKUP_PRESENT=True
INSTALLER_PRESENT=True
INSTALLER_SHA256=8E921367A6A7139A232FDF0A9F5FD3D1D61703BBF53D25C3CA705991D446B284
SERVICE=sshd STATUS=Running START=Automatic
SERVICE=VentioHost STATUS=Running START=Automatic
SERVICE=VentioPostgres STATUS=Running START=Automatic
Database system identifier: 7705548262546041680
Database cluster state: in production
{"apiVersion":1,"status":"alive"} HTTP=200
```

This confirms the staged pre-test copy and installer are present, the app file was not moved, the PostgreSQL cluster identifier is unchanged, and services/HTTPS liveness remain available. It does not convert the blocked repair procedure into a pass.

## Current Computer Use window inventory — 2026-11-09 13:21 UTC

A fresh Computer Use window inventory returned no Host RDP window and no Ventio application window. The only matching browser window was Edge displaying ChatGPT, not Ventio. No RDP capture was retried and no UI input was sent. The Host Overview remains visually unverified because there is no current targetable Host UI window; the earlier RDP capture failure remains documented separately.
