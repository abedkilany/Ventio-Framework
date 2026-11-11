# Installer Process-Policy Source and Client Queue Revalidation — 2026-11-09

## Denial source

The preserved event at `2026-11-09T13:11:51Z` records the local `exec_command` result as `CreateProcess ... Rejected ... blocked by policy`. The attempted repair-style operation was to move the installed Host file `C:\Program Files\Ventio\ventio_native_client.exe` aside, then start the verified `Ventio-Setup-0.1.18.exe` silently to restore the packaged file. The literal command string and exact process arguments were not retained in the closure evidence, so this report does not claim a verbatim command line.

The tool rejected local process creation before a process started. Therefore the remote file move and installer launch were never sent to Host. A subsequent Host check confirmed the installed executable and its pre-test backup were present, the held-file path was absent, and services, PostgreSQL cluster identifier, and HTTPS liveness were unchanged.

The local execution error is a **Codex command-launch/execution-policy rejection**, not a Windows AppLocker, Code Integrity, or Defender rejection. A read-only query of Development's enabled AppLocker, Code Integrity, and Windows Defender Operational logs for `2026-11-09T13:00:00Z`–`13:20:00Z` found no events; Security event 4688 had no records in that interval either. The zero OS-log result is corroborative only; the decisive evidence is that the Codex execution tool rejected process creation and the operation did not reach Windows or Host. This does not predict whether Windows would allow a later, actually launched process.

## Supported approval path and current availability

The `exec_command` tool supports per-command `sandbox_permissions: "require_escalated"` plus a justification when the active Codex approval profile permits an interactive request. The current session is configured with `approval_policy=never`, and its tool policy prohibits requesting sandbox escalation; no approval prompt can be raised here. The user also reported that policy approval is not available yet.

The supported route is an approval-capable Codex session/profile using interactive `approval_policy="on-request"` (or an allowed granular sandbox-approval policy), followed by submitting the exact reviewed command through the built-in `require_escalated` flow and approving that request in Codex. If a managed command rule is a hard deny, the policy owner must change that rule to prompt/allow the exact approved operation. Do not invoke another shell, launcher, or remote execution route to get around the denial. See [official Codex approvals and security documentation](https://learn.chatgpt.com/docs/agent-approvals-security?translationFallback=pt-BR).

## Verified installer for owner-assisted execution

- Development artifact: `C:\Users\User\Desktop\Ventio Framework\artifacts\ventio-windows-acceptance-0.1.18-wave1fix15-20261109\installers\unified\Ventio-Setup-0.1.18.exe`
- SHA-256: `8e921367a6a7139a232fdf0a9f5fd3d1d61703bbf53d25c3ca705991d446b284`
- Size: `104,200,244` bytes
- Authenticode: `NotSigned` (internal test artifact)
- Previously staged Host copy was independently hash-verified. The Host evidence directory `C:\ProgramData\Ventio\RecoveryEvidence\wave1-repair-restore-20261109T130558Z` contains `pre-repair-manifest.json`, a copy of the installer, and `ventio_native_client.exe.before` (SHA-256 `7D6EE8CD6769F9B52C852867D3DE5A12381732229233FE11D69EBAFF6AA7DA76`).

Safe test sequence after the policy owner makes the built-in approval flow available:

1. Target only Host `192.168.1.102`. Recalculate the installer SHA-256 on Development and on the staged Host copy; stop if either differs from the value above. Preserve the existing pre-repair manifest and executable backup.
2. The current Host RDP screenshot showed Ventio open. Have the owner close Ventio and verify `ventio_native_client.exe` is no longer running before moving it. If it remains in use, stop and retain the original file; do not force termination as part of the file-restore test.
3. Through the approved Codex command-approval route, run only the repair-style file-restore procedure: move the installed executable to a separate uniquely named evidence hold path without overwriting `ventio_native_client.exe.before`, then run the verified same-version installer with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` and a unique Inno `/LOG=` path inside the existing evidence directory.
4. Verify installer exit code and log completion, restored installed-file hash/version, `VentioHost` and `VentioPostgres` Running/Automatic, and pinned HTTPS `/healthz`. If the installer fails, retain both copies and logs, restore the executable through the approved path, and do not reset PostgreSQL or alter configuration.

No such execution has occurred. The current approval is unavailable; the procedure remains **BLOCKED — ENVIRONMENT**. This is separate from the Windows Computer Use input limitation.

## Independent Client queue-preservation check

Using authenticated SSH to physical Client `192.168.1.105`, read-only `Get-FileHash` checks were run against its current app-support files. The SQLite database and both sidecars exactly match the preserved `client-queue-preservation-20261109.json` hashes:

```text
ventio_native_client.sqlite3       97e8d54f8a7255106f66cf1b213c4a4d7b558d21310b1c2bfedc3d0d526dddda
ventio_native_client.sqlite3-wal   ddbd8192448225df9bbd5ea53076ff48434d736c3d88561b11c35aad37f41406
ventio_native_client.sqlite3-shm   c35020473aed1b4642cd726cad727b63fff2824ad68cedd7ffb73c7cbd890479
```

The prior read-only database snapshot records `SYNC-TEST-001` as a pending `extension.record.create` with zero attempts. Matching database and sidecar hashes verify those queue bytes have not changed since that snapshot. No SQLite content or secure-storage content was read; the secure-storage file was not part of this hash comparison. **PASS — VERIFIED** for preservation continuity only. No stage weight or grouped test count is added.

## Physical Client TLS revalidation after Host recovery

Read-only SSH on Host returned `host-lan-info.json` values `certificateSha256=703297d631e194a071d107cc56c762f86a1bb6df4177252cdf06f61ce87e18f6`, endpoint `https://ABEDKILANY:8443`, and `listenerEnabled=True`. The public PEM already preserved on Development independently computed to the same SHA-256 fingerprint. That PEM was copied to Client `%TEMP%` as a public test certificate; no trust store or application setting was changed.

On Client `192.168.1.105`, the copied PEM fingerprint was recalculated and matched the Host's current metadata. `curl.exe --cacert <temp-cert> https://192.168.1.102:8443/healthz` then returned:

```text
CLIENT_CERTIFICATE_SHA256=703297d631e194a071d107cc56c762f86a1bb6df4177252cdf06f61ce87e18f6
{"apiVersion":1,"status":"alive"} HTTP_STATUS=200 TLS_VERIFY=0
SSH exit code: 0
```

**PASS — VERIFIED** for current physical Client-to-Host certificate-validated HTTPS health after Host network recovery. This proves transport and public liveness only; it is not an authenticated management-readiness, enrollment, or synchronization result. No grouped test count or stage weight is added.

## Installer copy checksum cross-check — 2026-11-09

At 2026-11-09T15:54:31Z, read-only checks measured both the Development artifact and the Host-staged copy.

- Development path: C:\Users\User\Desktop\Ventio Framework\artifacts\ventio-windows-acceptance-0.1.18-wave1fix15-20261109\installers\unified\Ventio-Setup-0.1.18.exe
- Host path: C:\ProgramData\Ventio\RecoveryEvidence\wave1-repair-restore-20261109T130558Z\Ventio-Setup-0.1.18.exe
- Both sizes: 104200244 bytes
- Both SHA-256: 8e921367a6a7139a232fdf0a9f5fd3d1d61703bbf53d25c3ca705991d446b284
- Development Authenticode status: NotSigned

PASS — VERIFIED for artifact identity and staged-copy integrity. This does not establish Windows execution approval or installer success. The installer remains unexecuted because the supported Codex process-approval flow is unavailable. No acceptance count or stage weight changed.
