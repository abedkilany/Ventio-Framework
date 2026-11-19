# Recovery admission observations — 2026-11-19

Read-only evidence, not a fixture marker, environment authorization, security
clearance or successful P test. Review the
[consolidated implementation plan](../../WAVE_2_B_RECOVERY_LAB_IMPLEMENTATION_PLAN.md).

- `guest-readonly-refresh.json`: original local capture from strict SSH at
  16:13 UTC, identity, OS, installed updates and Defender/full-scan status.
- `guest-network-policy-refresh.json`: original local capture at 16:15 UTC,
  firewall/routes, execution context and pending printer-driver replacements.
- `guest-code-integrity-refresh.json`: original local capture of policy listing
  from Microsoft's signed built-in CiTool. No policy changed and no candidate ran.
- `identity-observation.json`: compact projection of 17:00 UTC local Hyper-V/
  registry and strict SSH guest CIM readings; guest SMBIOS UUID differs from VMId.
  BAHAA was already the local management environment; no BAHAA SSH login is claimed.

The three original JSON files are copied byte-for-byte from
`C:\v2b\20261119-recovery-lab`. `SHA256SUMS.txt` indexes these four observations.
Those hashes preserve evidence identity; they establish neither malware absence
nor trust in the hypervisor. Observations must be refreshed before admission.
No production data, private key, token, password or service credential is included.
