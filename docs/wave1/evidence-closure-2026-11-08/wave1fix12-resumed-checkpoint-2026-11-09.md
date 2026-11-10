# Wave1fix12 Resumed Closure Checkpoint — 2026-11-09

## Current disposition

Formal Wave 1 acceptance remains **60%**. Accepted stages remain 0, 1, 2, 4, 5, 6, and 7. Stages 10, 3, 8, and 9 remain open. This checkpoint adds post-reboot Host evidence, a read-only preservation check of the Client command queue, and a corrected certificate-trust helper test on the physical Client.

## Host SSH identity and token

Command: OpenSSH to `abedkilany@192.168.1.102` using the existing `%USERPROFILE%\.ssh\ventio_lab` identity; remote PowerShell queried the machine name, account, token group, and product UUID.

Observed output:

```text
ABEDKILANY
abedkilany\AbedKilany
Mandatory Label\High Mandatory Level   S-1-16-12288
4C4C4544-0051-5A10-8042-C4C04F343032
```

SSH connected with exit code 0. The administrative High Integrity SID was present.

## Host service and HTTPS readiness

Observed `Win32_Service` state after the reboot:

```text
Name            State    StartMode  StartName                    ExitCode
sshd            Running  Auto       LocalSystem                   0
VentioHost      Running  Auto       NT SERVICE\VentioHost         0
VentioPostgres  Running  Auto       NT SERVICE\VentioPostgres     0
```

The Host listener was `0.0.0.0:8443`. Host LAN metadata reported `listenerEnabled=true`, endpoint `https://ABEDKILANY:8443`, alternative endpoint `https://192.168.1.102:8443`, and certificate SHA-256 `703297d631e194a071d107cc56c762f86a1bb6df4177252cdf06f61ce87e18f6`.

Development ran `curl.exe --cacert host-lan-certificate.pem https://192.168.1.102:8443/healthz` with the preserved public Host certificate. Observed body: `{"apiVersion":1,"status":"alive"}`; `CURL_EXIT=0`.

The installed product registry entry reports `DisplayVersion=0.1.18`, `InstallLocation=C:\Program Files\Ventio`. The Flutter Client source package version is `0.1.18+19`; the Host Overview’s displayed version was not visually observed, so the build suffix is not claimed as visible Host UI evidence.

## Reboot persistence and previous SSH gap

Read-only event and process evidence establishes this reboot timeline on Host local time:

```text
02:57:12  System event 1074: restart initiated for “Ventio Wave 1 automatic service startup verification”
02:57:30  OpenSSH Operational: sshd received termination signal during shutdown
02:57:40  Win32_OperatingSystem LastBootUpTime
02:57:53  OpenSSH logged listeners on 0.0.0.0:22 and :: port 22
02:57:53  sshd and VentioPostgres service processes started
02:57:55  VentioHost service process started
```

System event 7040 records OpenSSH’s start type changing from demand-start to Automatic at `2026-11-08 22:29:59`; current service state is Automatic/Running. The earlier failed SSH probes occurred during the controlled restart interval; current logs show service termination at shutdown and listener restoration after boot, with no failed key authentication in the sampled events. This supports **transient reboot downtime**, not a persistent SSH configuration or authentication failure. Host services and HTTPS were subsequently verified live.

## Client queue preservation check

The physical Client’s application support database and its `-wal`/`-shm` sidecars were copied to a Development temporary directory while `ventio_native_client.exe` was not running. The copied snapshot was queried in SQLite `mode=ro`, with `PRAGMA query_only=ON`; only table names and metadata for the named historical ID were selected. No envelope, payload, credential, or receipt contents were read or exported.

Observed:

```text
SQLITE_OPEN_MODE=READ_ONLY
SQLITE_TABLES=local_commands
HISTORICAL_COMMAND=NOT_PRESENT
```

The Client DB files were 4,096 bytes (`.sqlite3`), 28,872 bytes (`-wal`), and 32,768 bytes (`-shm`) at the inspected snapshot. `SYNC-TEST-001` was not present in `local_commands`. No Client database or queue state was modified. The absent record must not be represented as a preserved pending operation.

## Certificate-trust defect and correction

With Host HTTPS healthy and the same fingerprint-confirmed certificate, the original PowerShell `Invoke-WebRequest` flow still failed with the Windows TLS trust-relationship error, while `curl.exe --cacert` succeeded. The cause was the helper’s reliance on the Windows chain builder treating a self-signed server leaf in `CurrentUser\TrustedPeople` as a chain trust anchor. It does not do so in this Client environment.

The helper now validates the supplied certificate’s exact SHA-256 pin, exact endpoint SAN, validity period, and Server Authentication EKU before adding the public leaf to `CurrentUser\TrustedPeople`. It probes `/healthz` with `curl.exe --cacert` using that exact certificate, requires HTTP 200 and the Host liveness contract, does not follow redirects, and removes a newly-added store entry on failure. No insecure switch or permissive callback is used.

Automated regression `scripts/windows/test-ventio-pinned-tls.ps1` passed seven checks: valid DNS endpoint, valid IP endpoint, rejection of wrong leaf, wrong SAN, wrong EKU, expired certificate, and wrong fingerprint. `scripts/windows/test-unified-installer-path-contract.ps1` passed its unified-installer boundary checks, including the new trust-helper contract assertion.

The updated helper and module were executed on physical Client `192.168.1.105` against live Host `192.168.1.102:8443`. Observed output:

```text
Endpoint:   https://192.168.1.102:8443
Fingerprint: 703297d631e194a071d107cc56c762f86a1bb6df4177252cdf06f61ce87e18f6
State:       TRUSTED_AND_VALIDATED
Exit code:   0
```

The successful result adds the confirmed public Host certificate to the Client user’s `TrustedPeople` store as intended. This does not update Ventio Client’s separate application-level Host pin and does not prove enrollment or synchronization.

## Remaining acceptance work

| Stage | Current disposition |
|---|---|
| 10 — Windows Installer & Host Provisioning | **OPEN — partial physical pass.** Current installed upgrade version `0.1.18`, dedicated service identities, automatic reboot startup, and pinned Host health are verified. Fresh/clean installation, repair/recovery, upgrade data-preservation assertions, uninstall retention choices, permission/failure cases, sanitized diagnostics, and offline integration are not all closed. |
| 3 — Unified First-Run Setup | **OPEN — NOT ACCEPTED.** This checkpoint does not include first-admin creation, installed UI resume/idempotency, interruption, setup failure export, or the complete first-run readiness UI lifecycle. |
| 8 — End-to-End Validation | **OPEN — partial physical pass.** Physical Host↔Client pinned HTTPS and Client trust helper pass. `SYNC-TEST-001` was absent. App-level Host pin, enrollment, extension approval, offline record creation, Host acceptance, receipt, and independent Client readback remain unverified. |
| 9 — Final Engineering Audit & Acceptance | **OPEN — NOT ACCEPTED.** Cannot accept while mandatory Stage 10, 3, and 8 criteria remain open. |

Computer Use could not visually verify Host Overview. After the RDP app was absent from the current Computer Use window inventory, activating a freshly launched File Explorer target failed; the single fresh-selection recovery attempt returned `GetCursorPos failed: Access is denied. (0x80070005)`. No SSH or health result is substituted for Host Overview UI evidence.

## Client repeat-install follow-up — 2026-11-09

The Wave1fix11 installer was copied to Client `%TEMP%` only after SHA-256 was compared with Development. Both sides reported `89d36270ce0d595286d09eed5fe030182e3a3e2c9b1750a52abe3410790bb568`.

The same 0.1.18 installer was silently re-run on Client to exercise Stage 10 repeat-install behavior. It exited 0; the Inno log records `Installation process succeeded.` and `Need to restart Windows? No`. Registry `DisplayVersion` remained `0.1.18`; the Client had no `VentioHost` or `VentioPostgres` services, and no Ventio process was running after setup.

The local command queue database and WAL/SHM sidecar hashes matched the pre-install snapshot exactly:

```text
ventio_native_client.sqlite3       4096  97e8d54f8a7255106f66cf1b213c4a4d7b558d21310b1c2bfedc3d0d526dddda
ventio_native_client.sqlite3-shm  32768  c35020473aed1b4642cd726cad727b63fff2824ad68cedd7ffb73c7cbd890479
ventio_native_client.sqlite3-wal  28872  ddbd8192448225df9bbd5ea53076ff48434d736c3d88561b11c35aad37f41406
```

Installer log: [Client repeat-install log](client-repeat-install-installer-wave1fix12.log). Post-install checks: [Client repeat-install state](client-repeat-install-postcheck-wave1fix12.log). No queue record or SQLite file was modified by the repeat install.

## Resumed live Host verification — 2026-11-09 09:20 UTC

A new SSH session using the existing `ventio_lab` key exited 0. Observed `hostname=ABEDKILANY`, `whoami=abedkilany\abedkilany`, and High Mandatory Level `S-1-16-12288`. `sshd`, `VentioHost`, and `VentioPostgres` are Running/Automatic; Host TCP 8443 is listening. Product registry reports 0.1.18. A pinned request from Development returned HTTP 200 and `{"apiVersion":1,"status":"alive"}`. This endpoint is process liveness only; no authenticated exact-scope readiness request was made.

Read-only `Get-CimInstance Win32_Service` and `Get-Acl` checks verified VentioHost runs as `NT SERVICE\VentioHost`, VentioPostgres runs as `NT SERVICE\VentioPostgres`, and both report exit code 0. Protected ACLs on `C:\ProgramData\Ventio`, `C:\ProgramData\Ventio\Host`, and `C:\ProgramData\Ventio\PostgreSQL\data` grant only the expected SYSTEM, Administrators, and service identities. No service, ACL, database, or application setting was modified. Full sanitized command output is in [Host current check](host-wave1fix12-current-check.log).
