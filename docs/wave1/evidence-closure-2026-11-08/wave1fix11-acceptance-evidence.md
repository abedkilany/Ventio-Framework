# Wave1fix11 Closure Evidence — 2026-11-09

## Disposition

This evidence bundle records partial physical acceptance and focused automated checks. It does not close Stages 10, 3, 8, or 9. Accepted Wave 1 progress remains 60%, matching the accepted-stage ledger.

| Procedure | Classification | Observed result |
|---|---|---|
| Diagnose upgraded Host startup | PASS — VERIFIED | PostgreSQL Application event record 2783 identified SQLSTATE 42883 and missing `ventio_security.list_extension_submissions(text,text,text,text,integer)`. XML: [event record](host-wave1fix11-readiness/missing-extension-function-postgres-event.xml). |
| Migration 036 Recovery Authority regression | PASS — VERIFIED | 22 checks passed, including restoration of the missing runtime routine, execute ACL boundaries, identity preservation, stale witness fail-closed, interruption, lost acknowledgement, and prepared transaction reconciliation. [Regression log](host-schema-upgrade-disposable-regression-wave1fix10.log). |
| Dart analyzer | PASS — VERIFIED | `dart analyze bin lib test` reported `No issues found!` for `packages/ventio_host_api`. |
| Installer path contract | PASS — VERIFIED | `scripts/windows/test-unified-installer-path-contract.ps1` exited successfully, including the quoted-signature diagnostic regression contract. |
| Windows acceptance build | PASS — VERIFIED | Unified installer version 0.1.18 built. SHA-256 `89D36270CE0D595286D09EED5FE030182E3A3E2C9B1750A52ABE3410790BB568`; checksum manifest matched. Payload included PostgreSQL 16.15; installer boundary and deferred provisioning checks passed. |
| Host installed upgrade | PASS — VERIFIED (pre-reboot checkpoint only) | Inno log reported installation success; installed version `0.1.18+19`; `VentioPostgres` and `VentioHost` Running/Automatic under dedicated virtual service accounts. Pinned HTTPS `/healthz` returned `{"apiVersion":1,"status":"alive"}`. [Installer log](host-wave1fix11-readiness/installer.log). |
| Host HTTPS listener configuration | PASS — VERIFIED (pre-reboot checkpoint only) | Listener enabled at port 8443; certificate fingerprint `703297d631e194a071d107cc56c762f86a1bb6df4177252cdf06f61ce87e18f6`; Private-profile inbound allow rule enabled. [Listener record](host-wave1fix11-readiness/host-lan-info.json). |
| Host reboot persistence | BLOCKED — ENVIRONMENT | After authorized reboot, Development could not reach Host TCP 22 or 8443; earlier post-reboot probe found TCP 3389 open. Current service state is unknown. [Probe record](host-wave1fix11-readiness/post-reboot-access-check.txt). |
| Client installation | PASS — VERIFIED | Client installer exit code 0; installed version `0.1.18+19`; copied installer hash matched. [Client installer log](host-wave1fix11-readiness/client-installer.log). |
| Client pinned HTTPS request | PASS — VERIFIED (before Host reboot) | Client `curl --cacert` using the copied Host public certificate returned alive over `https://192.168.1.102:8443`. The same request timed out after Host reboot. [Check record](host-wave1fix11-readiness/client-host-https-pinned-health.log). |
| Windows Host certificate trust helper | FAIL — REPRODUCED | Supported helper rejected the Host certificate under normal Windows chain validation. Its TrustedPeople add was rolled back; importing to CurrentUser Root failed as unsupported. No validation bypass was used. [Failure record](host-wave1fix11-readiness/client-trust-helper-failure.log). |
| Computer Use visual Host Overview | BLOCKED — ENVIRONMENT | Host RDP window was enumerated but remained minimized; activation failed and input geometry was unavailable. Host Overview readiness and displayed version were not visually verified. |
| Stage 3 first-run installed lifecycle | NOT TESTED | No complete physical installed setup lifecycle was run. |
| Stage 8 physical Host–Client acceptance sequence | NOT TESTED | Enrollment → extension approval → offline record → sync → host acceptance → receipt → independent readback was not completed. |
| Stage 9 final audit | NOT TESTED | Open mandatory acceptance criteria prevent final acceptance. |

## Artifact identity

- Installer: `artifacts/ventio-windows-acceptance-0.1.18-wave1fix11-20261109/installers/unified/Ventio-Setup-0.1.18.exe`
- Installer SHA-256: `89D36270CE0D595286D09EED5FE030182E3A3E2C9B1750A52ABE3410790BB568`
- Migration 036 SHA-256: `50147943077d691d9ac9685eb34efaf062c2022fe88a652de2cd480211fa5244`
- Host UUID: `4C4C4544-0051-5A10-8042-C4C04F343032`
- Client UUID: `9EB7F117-F40D-11DE-81D0-B9F76E398C6C`

## Recommendation

Keep Wave 1 open at 60%. The confirmed upgrade migration gap is corrected and covered by the isolated regression. Re-establish Host management access and verify post-reboot readiness before continuing Stage 10, then complete the installed Stage 3 lifecycle, the full physical Stage 8 sequence, and Stage 9 audit.
