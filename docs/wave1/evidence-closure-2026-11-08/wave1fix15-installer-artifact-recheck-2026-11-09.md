# Wave1fix15 Acceptance Installer Artifact Recheck — 2026-11-09

## Procedure

Read the existing SHA-256 manifest for the recorded Wave1fix15 Windows acceptance installer, recalculated the executable hash, and queried its Authenticode status. No build or installer execution was performed.

## Observed result

- File: `artifacts/ventio-windows-acceptance-0.1.18-wave1fix15-20261109/installers/unified/Ventio-Setup-0.1.18.exe`
- Size: `104,200,244` bytes
- Manifest SHA-256: `8e921367a6a7139a232fdf0a9f5fd3d1d61703bbf53d25c3ca705991d446b284`
- Recalculated SHA-256: `8e921367a6a7139a232fdf0a9f5fd3d1d61703bbf53d25c3ca705991d446b284`
- Authenticode status: `NotSigned`

**PASS — VERIFIED** for artifact presence and manifest/hash match. The installer remains an unsigned acceptance artifact; this check does not establish release-signing or commercial toolchain readiness and does not close Stage 10 or Stage 9.
