# Owner-Assisted UI and Authenticated CLI Status — 2026-11-09

## Current supported checks

Fresh authenticated SSH checks used the existing `ventio_lab` key and issued read-only commands.

Host `192.168.1.102`:

```text
hostname.exe: AbedKilany
whoami.exe: abedkilany\abedkilany
High Integrity: S-1-16-12288
sshd: Running / Automatic
VentioHost: Running / Automatic
VentioPostgres: Running / Automatic
HTTPS /healthz: HTTP 200, {"apiVersion":1,"status":"alive"}
```

Client `192.168.1.105`:

```text
hostname.exe: AbedKilany
whoami.exe: abedkilany\abedkilany
High Integrity: S-1-16-12288
Test-NetConnection 192.168.1.102 -Port 8443:
  SourceAddress: 192.168.1.105
  TcpTestSucceeded: True
```

The two addresses remain distinct physical machines per prior UUID evidence. The Client-to-Host check is TCP reachability only; it is not TLS validation, enrollment, or authenticated API acceptance.

## One owner-confirmed Computer Use attempt

After the owner confirmed the Development desktop and Host RDP were accessible, Computer Use found the window `192.168.1.102 - Remote Desktop Connection` and captured the remote Ventio screen. Visible text included `Host profile selected · AB`, `Selected scope: CD / EF`, and `Host access requires a verified session`, plus navigation for Client enrollment, Host Setup, Local diagnostics, and Synchronization. The visible page was the app landing page; it did not show Host Overview, readiness, or application version.

The first interaction action (maximize) failed with `GetCursorPos failed: Access is denied. (0x80070005)`. Per instruction, no further Computer Use action was attempted. This is a Development desktop-control limitation and does not establish a Ventio defect.

## Supported authenticated readiness path

Source inspection confirms the management readiness endpoint requires exactly one syntactically valid Bearer credential and authenticates it before dispatch. The readiness handler additionally requires `host.status.read` within the selected company and branch. The native `HostReadinessClient` obtains its token via `HostCredentialVault`; no standalone authenticated readiness CLI was found in `scripts/windows` or the package command inventory. No bearer token or stored credential was read or exposed. SSH administrator access and public `/healthz` do not grant application permissions.

## Exact remaining owner-assisted UI evidence

| Gate | Required owner-assisted evidence |
|---|---|
| Stage 10 | Host Overview screen showing remote computer name, installed application version, and readiness state; Host uninstall retention choice and observed retained/deleted Host data; installed repair/recovery outcome. Repair launch is also subject to the separate process-creation policy blocker below. |
| Stage 3 | Installed Host Setup lifecycle: first administrator and Recovery Authority completion; interruption followed by safe resume/retry/idempotency; exported diagnostics from a real setup failure; readiness after Windows restart. Capture the resulting setup status and sanitized correlation IDs. |
| Stage 8 | On the physical Host and Client, perform Client enrollment at the exact tenant/company/branch, approve `sync.test / 0.1.0`, create an offline record, reconnect and sync, verify Host-authoritative acceptance and receipt, then independently read the accepted record from the Client. Preserve `SYNC-TEST-001` before any reset; it remains a pending historical operation. Do not treat a simulated second Client as physical evidence. |
| Stage 9 | After the above gates, capture the final cross-stage security, data-integrity, unresolved severity, and release-signing decisions. |

## Separate process-creation policy blocker

The earlier Wave1fix15 repair-style procedure was rejected by the execution environment before the planned file move or installer process started. The Host executable, services, database, and configuration remained unchanged. This blocker is independent of Computer Use. It requires an approved process-creation path for that exact authorized test operation; do not route around the rejection through another shell or launcher.

## Minimum owner actions

1. Restore Computer Use input access for the Development desktop or operate the connected Host RDP session directly, and capture the Stage 10 Overview/uninstall screens and Stage 3/8 UI results listed above.
2. In Ventio, establish or complete a supported administrator session for the exact test scope and keep its credential in the application vault. Share sanitized readiness output/correlation IDs or screenshots; do not send a password or bearer token in chat.
3. Have the environment/policy owner approve the exact process creation needed for the repair-style installer test, or run that test through its approved process-control route. This remains separate from the RDP/UI limitation.
