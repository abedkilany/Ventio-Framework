# Host SSH, services, and HTTPS revalidation — 2026-11-09

**Result:** `PASS — VERIFIED` for authenticated administrative SSH, service startup, listeners, and HTTPS liveness. This does not establish authenticated application readiness or a visually inspected Host Overview.

## Procedure

From Development (`192.168.1.104`), connected to Host (`192.168.1.102`) as `abedkilany` with the existing `%USERPROFILE%\.ssh\ventio_lab` key and ran a read-only PowerShell payload. It reported the computer name and account, checked the High Integrity group, read the three Windows service states/start types, listed listeners on 22/3389/8443, and requested `https://localhost:8443/healthz`.

## Observed output

```text
HOST=ABEDKILANY
IDENTITY=abedkilany\abedkilany
HIGH_INTEGRITY=Mandatory Label\High Mandatory Level  Label  S-1-16-12288
SERVICE=sshd STATUS=Running START=Automatic
SERVICE=VentioHost STATUS=Running START=Automatic
SERVICE=VentioPostgres STATUS=Running START=Automatic
LISTENER=:::22 Listen
LISTENER=0.0.0.0:22 Listen
LISTENER=:::3389 Listen
LISTENER=0.0.0.0:3389 Listen
LISTENER=0.0.0.0:8443 Listen
{"apiVersion":1,"status":"alive"} HTTP=200
```

The loopback `curl.exe -k` request skips certificate validation and is recorded only as an HTTPS liveness check. The prior Development-to-Host pinned-TLS check returned HTTP 200 with TLS verify result 0 after the controlled reboot; see [the reboot investigation](host-reboot-connectivity-investigation-2026-11-09.md).

## Readiness and graphical acceptance

No valid bearer credential with `host.status.read` was available to this run. The previously recorded pinned-TLS request to the management readiness route without a bearer token returned HTTP 401 `UNAUTHENTICATED`; this is an authentication-boundary result, not a readiness snapshot. The attempt to call the readiness endpoint locally from Windows PowerShell failed certificate trust and did not bypass the Host's trust policy.

The RDP session remained connected, but Computer Use screenshot capture failed with `IGraphicsCaptureItemInterop.CreateForMonitor failed: Could not capture the given monitor. (0x80070057)`. The installed Development Ventio launcher also failed with `GetCursorPos failed: Access is denied. (0x80070005)`. Host Overview readiness/version therefore remain visually unverified. These UI limitations do not negate the successful SSH, service, and liveness checks.

## Acceptance disposition

This revalidation adds no stage weight. Stage 10, Stage 3, Stage 8, and Stage 9 remain open for the already-recorded lifecycle, authenticated readiness, physical Host–Client sequence, and final audit criteria. The Client's preserved `SYNC-TEST-001` queue evidence remains untouched.
