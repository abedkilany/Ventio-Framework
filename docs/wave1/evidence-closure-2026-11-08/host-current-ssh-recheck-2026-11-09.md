# Fresh Host SSH and Liveness Recheck — 2026-11-09

## Procedure

From Development, connect to `192.168.1.102` as `abedkilany` using the existing `%USERPROFILE%\.ssh\ventio_lab` identity in BatchMode. Execute identity/group, service, listener, installed-version, and loopback HTTPS liveness queries over the authenticated SSH session. No state-changing command was issued.

## Actual output

```text
---IDENTITY---
AbedKilany
abedkilany\abedkilany
Mandatory Label\High Mandatory Level  Label  S-1-16-12288

---SERVICES---
Name            Status StartType
sshd            Running Automatic
VentioHost      Running Automatic
VentioPostgres  Running Automatic

---LISTENERS---
::       22    Listen
0.0.0.0  22    Listen
0.0.0.0  3389  Listen
::       3389  Listen
0.0.0.0  8443  Listen

---VENTIO VERSION---
DisplayName  DisplayVersion
Ventio       0.1.18

---HEALTH---
{"apiVersion":1,"status":"alive"} HEALTH_HTTP=200
```

SSH and remote PowerShell completed with exit code `0`.

## Classification and limits

**PASS — VERIFIED** for authenticated administrative access, identity, High Integrity, service startup state, listening ports, installed version, and local HTTPS liveness. `/healthz` is not the authenticated Host readiness check; live authenticated readiness and the visual Host Overview remain unverified. No service, database, or configuration was modified.
