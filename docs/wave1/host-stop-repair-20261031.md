# Installed Host service stop repair — 2026-10-31

Latest 13:39 Beirut checkpoint: the original scope bootstrap failed at Recovery Authority because the Ventio ProgramData parent belonged to the interactive user and inherited full user access. Its prior SDDL was retained. Only the Ventio parent ACL was tightened to Administrators/SYSTEM with Host/Postgres traversal; witness ownership and database state were not reset. The existing service-controlled bootstrap then succeeded with a pending durable receipt, and `ventio_host.exe` started. Both services are running/automatic. Credential handoff and local request reconciliation remain incomplete; the receipt was not acknowledged and no token was logged. The attempted completion helper failed at its read-only pipe status step before changing local state. Provisioning-source prevention and regression coverage for the parent ACL are still required. Work stopped at the owner's additional ten-minute limit. Accepted progress remains 20%.

Source checkpoint: `codex/extension-platform`, HEAD `0753457`, with uncommitted changes.

## Observed defect

The legacy Host service awaited first-administrator completion or broker termination without including its stop signal. An SCM stop request changed its state to `STOP_PENDING` but could not release that wait. The installer correctly refused to replace files.

The service now includes the explicit stop task in the bootstrap and running-process waits. Focused Host service tests passed, including pending-bootstrap interruption and successful bootstrap completion.

## Authorized installed repair

The development-only `scripts/windows/repair-known-stuck-bootstrap-service.ps1` pins the legacy executable hash, SCM identity, PID, creation time, image path, and absence of child or Host client processes. It rejects other targets and does not expose arbitrary commands, paths, SQL, or credentials. Twelve rejection cases and the native process identity query passed before application.

An elevated UAC maintenance run preserved protected evidence, ended the identified failed pre-file-copy installer and stalled service, temporarily disabled Host startup, and installed the verified development package. The installer performed its normal PostgreSQL stop/start around payload replacement. The maintenance run restored automatic Host startup and started the updated service. Exit code: `0`.

- Package: `dist/windows/host-stop-wait-fix-20261031/Ventio-Setup-0.1.0.exe`
- Package SHA-256: `c4a9ee52a9167bc5c0d56770c52253f65f681886fe3cdd26693e594568f64e32`
- Installed service SHA-256: `129e4f4ab295fa161c32be35c09f488107206250b9fab6701d930a9f7b3113c3`
- Installed Flutter SHA-256: `45057486d3d04211139734de805ed5fdca779accb927df5a57d1b90dff6f4240`
- Protected evidence: `C:\ProgramData\Ventio\RecoveryEvidence\host-stop-repair-*`
- Sanitized completion status: `C:\Program Files\Ventio\SetupStatus\maintenance-stuck-bootstrap-20261031.json`

No database deletion, initialization, migration, credential rotation, or Recovery Authority reset was invoked by this repair.

## Actual regression result

`scripts/windows/verify-fixed-bootstrap-service-stop.ps1 -Apply` verified the fixed installed hash and pending-bootstrap state before issuing normal SCM stop/start commands. The service reached `Stopped` in **76 ms**, then returned to `Running`. PostgreSQL remained running throughout this regression test. Both services are `Automatic`; `pg_isready` accepts connections on `127.0.0.1:54329`.

The normally launched installed Flutter application displays both services as `Running` in Host setup. No administrator bootstrap request was submitted during this check.

Sanitized result: `C:\Program Files\Ventio\SetupStatus\maintenance-fixed-stop-test-20261031.json` (`VENTIO_STOP_TEST_PASS_76_MS`).

## Remaining gates

### Subsequent first-administrator diagnostic

The Host UI rejected the unmatched local pending operation as designed. An authenticated, read-only `status` operation was added to the existing administrator-only service pipe. It checks the receipt caller SID and returns only state and tenant/company/branch metadata, without token, actor, or request credential. Focused service tests passed for successful inspection, other-caller rejection, extra-field rejection, and credential omission.

A pinned elevated development update installed service SHA-256 `16463268de7bcb48aec4f62a3d0ce850403b4d31e36b5cf1e804070acefa4431` and updated its protected payload manifest. The prior executable and manifest are retained under protected `RecoveryEvidence/first-admin-status-*`. This diagnostic build is newer than the development installer package above.

At 13:27 Beirut, the service-owned receipt was `pending`, bound to `Test-Project / Test-Company / Test-Branch`. The local request `c5e5563e1eade9857513a8046aac4274` instead contains `Test-Business / Test-Company / Test-Office`. No local scope rewrite, receipt acknowledgement, credential export, or database reset was performed. Both services remain running. Safe request reconciliation and first-administrator resumption remain unfinished at the time-limited stop.

The first-administrator failure and the mismatch between historical broker operation and local pending operation remain unresolved. `HOST_DATABASE_RECOVERY_ROLE_ROTATION_FAILED` remains an independent recovery defect. Full Host readiness, interrupted-setup recovery, reboot, deployment lifecycle, and other Wave 1 gates are not accepted by this repair. The unsigned development package is not commercially releasable. Accepted weighted progress remains **20%**.
