# Host RDP Launch Attempt — Computer Use Limitation — 2026-11-09

## Procedure and observed result

Used the supported Computer Use API to launch the preinstalled Windows Remote Desktop client (`C:\Windows\System32\mstsc.exe`) as an alternate to the unavailable `Host` desktop shortcut window.

- `sky.launch_app` returned `GetCursorPos failed: Access is denied. (0x80070005)`.
- A fresh `sky.list_apps()` inventory returned ChatGPT, the existing Explorer window, and Edge; it returned no Remote Desktop Connection window and no Ventio window.
- No RDP target was entered; no authentication dialog was automated; no remote UI action occurred.

**BLOCKED — ENVIRONMENT.** Host Overview and other installed UI acceptance checks remain unverified through Computer Use. This is the same desktop-control access-denied condition already present in prior attempts.
