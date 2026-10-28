# Windows Offline-First Two-Device Validation Closure

Date: 2026-10-29 (Asia/Beirut)
Branch: `codex/extension-platform`
Reviewed source: `a1ee411` (`docs: finalize Wave 1 engineering audit evidence`)
Status: **CONDITIONAL PASS — engineering checks are green; two-device acceptance and root-cause attribution remain open**

## Scope and assessment

This record closes the work possible in the current repository session. It does not close the required two-independent-Windows-device acceptance. No code defect has been confirmed, no security control was changed, no credentials were touched, and the failed operator request was not replayed.

The current branch is clean with respect to tracked files at the start of this work. Existing untracked user files (`Ventio-Project-Status-Ar.md`, `deliverables/`, and the native client's generated/platform files) were preserved. HEAD was `a1ee411`, equal to `origin/codex/extension-platform`; the recent history includes the recovery admission hardening and Wave 1 engineering audit. No source fix or test change was justified by the evidence available, so this closure adds documentation only.

## Registration failure investigation

The operator message `Credential administration failed. Access may be quarantined; consult the private recovery runbook.` is deliberately generic. `identity_admin.dart` catches every exception, prints that fixed message, sets exit code 2, and emits no stage or exception detail. The source path is:

1. `identity_admin.dart` reads the absolute request path using `PrivateFiles.read`, parses JSON, opens the configured administration URL, and dispatches `register-device`.
2. `PrivateFiles.read` on Windows launches the ACL-backed PowerShell helper. It validates a fixed local drive, rejects reparse points in the path chain, checks the request directory and file owner/ACL, and reads bounded content. The helper intentionally suppresses its underlying diagnostic.
3. `RecoveryAuthority.change` takes the OS lock, reads and validates the witness, marks it pending and durably replaces it, takes PostgreSQL's exclusive advisory lock, compares the database fingerprint, then runs the mutation transaction.
4. `IdentityAdministration.registerDevice` submits the audited `DEVICE_REGISTERED` action through `ventio_security.admin_change(jsonb)`. SQL inserts the device and audit record transactionally. An already-present device identifier is rejected by the database uniqueness constraint.
5. After a known SQL rejection before commit, recovery code restores the prior ready witness only after a locked equality check of the old fingerprint. An uncertain commit, I/O error, or failure after commit leaves the witness pending. The database role is intended to have only EXECUTE on the administrative function, not direct identity-table DML.

Windows ACL integration passed in this session, and the supplied observations report that the request and authority files were readable with the expected ACL, the operator RPC privilege existed, and the witness was ready with a fingerprint. These facts do **not** establish which request was executed, whether it reached the administrative function, whether the device row/audit row already exists, whether the fingerprint matched at execution time, or whether the request path seen by the executable matched the inspected file. The request's database URL was replaced with a placeholder, and its original contents, process trace, database state at failure, and exact executable/source revision are unavailable here. The supplied report of a ready witness is not a contemporaneous database fingerprint comparison.

Therefore the failure mechanism is **unresolved**. Duplicate device registration is a concrete possibility because SQL rejects duplicate IDs and the CLI intentionally hides that SQL error; it is not established. A fingerprint mismatch, private-file validation failure, authority path mismatch, connection/schema mismatch, or source/binary mismatch are also not excluded by the retained evidence. The reported EXECUTE grant alone does not prove the connected login's effective authorization or target database/schema. No direct database state was altered to force a result.

### Safe operator diagnostics before any retry

On `IT-PC`, using an independently verified operator session and a read-only connection to the exact `ventio_host_lab` database:

1. Confirm the target server/database identity and migration/bootstrap version. Do not include the connection URL or credentials in command history, screenshots, or logs.
2. Query only the exact target tuple (`lab_tenant`, `lab_user`, `lab_home_client`) in the device table and its identity audit records. Check whether the device already exists, is revoked, or has a registration event. Do not select token digests, raw credentials, witness fingerprints, or unrelated tenants. Save only a redacted result (counts/status and timestamp).
3. Check `lab_credential_04` by credential ID and target device using metadata only (existence/revocation/expiry); never select or export a token/digest. This determines whether a provisioning attempt also left state.
4. With the protected witness owner, verify only `version`, `pending`, and whether the fingerprint matches the database snapshot; do not print or copy the fingerprint. If `pending` is true or evidence is stale/mismatched, stop. Do not reset or edit the witness as a diagnostic.
5. Confirm the exact source revision and `dart --version` used by the failed CLI invocation. Prefer the branch's current CLI source over an unidentified copied executable. Do not re-run the mutating action until the operator has reviewed the read-only findings and confirmed the intended next step.

If the target device row already exists and witness admission is ready, do not repeat registration; continue only with reviewed, scoped credential provisioning after confirming no credential artifact/row already exists. If there is no row but the witness is pending/mismatched, stop and follow the private recovery runbook. If no row exists, witness matches, and logs identify a validation/connection/version issue, correct that specific condition before a reviewed retry. Do not automatically reset recovery authority, remove lock files, revoke identities, or modify protected rows.

## Validation evidence in this session

| Check | Result | Boundary |
|---|---|---|
| Branch and source history | PASS; `codex/extension-platform` at `a1ee411`, same as origin | Does not identify the version used in the earlier failed invocation |
| Host HTTPS health | PASS; `https://it-pc.tailbca130.ts.net/healthz` returned HTTP 200 | Health only; no authenticated operation, trust-chain inspection, or record sync |
| Host API / PostgreSQL local listeners | NOT AVAILABLE in this session on `127.0.0.1:18080` / `127.0.0.1:55440` | No local Host/database process was found at the requested ports |
| Docker disposable database | BLOCKED; Docker Desktop Linux engine unavailable | No isolated PostgreSQL fixture could be started here |
| Windows private-file ACL test | PASS; `dart run test/private_files_windows.dart` | Exercises temporary test files, not the original operator directory/request |
| Host API analyzer | PASS; `dart analyze .` in `packages/ventio_host_api` | Static analysis only |
| Host API formatter | PASS; `dart format --output=none --set-exit-if-changed lib bin test` | No source changes |
| Host API non-database tests | PASS; `dart run test/api_tests.dart`, 45/45 | No live identity database used |
| Core analysis and harness | PASS; `dart analyze .` and `dart run test/all_tests.dart`, 78/78 | In-memory/reference Core coverage |
| Flutter analysis and formatter | PASS; `flutter analyze` and Dart format check on 38 files | No source changes |
| Contract validation | PASS; 7 schema fixtures | Static validation |
| V1.2 Python tests | PASS; 20/20 | Static contract tests |
| Localization gate | PASS; 28 files scanned | Static text gate |
| Package verifier | BLOCKED by existing untracked `Ventio-Project-Status-Ar.md` containing Arabic script | The file is user data and was preserved; this does not indicate a tracked-source verifier regression |
| Flutter unit/widget suite | PASS; 116 passed, 2 skipped by explicit environment guards | The skips are real Host/PostgreSQL integrations, not ordinary unit/widget coverage |

No PostgreSQL-backed registration/lifecycle test, full Host process integration, two-physical-device run, offline/reconnect acceptance, duplicate delivery through two independent clients, conflict/rejection exchange, or remote revocation check was performed in this session. Existing repository audit records provide prior single-machine, emulator, and disposable-database evidence; those runs do not satisfy this request's two-physical-Windows-device criterion.

## Required two-device acceptance — not yet evidenced

The following remain pending on the actual two Windows devices against the intended Host. Use separate client data directories and independently provisioned device credentials. Capture redacted receipts/status and Host revisions, not tokens or connection strings.

- Resolve registration state with the safe diagnostics above. Register `lab_home_client` only if absent and the recovery witness is ready and matches.
- Provision `lab_credential_04` only after confirming it is absent, with the reviewed exact tenant/company/branch/permission ceiling, and deliver the private file through an authenticated confidential channel.
- From each device, prove the HTTPS endpoint and certificate trust, authenticate as the intended identity, and verify the exact tenant/company/branch scope.
- On Device A, create a command while offline. Verify it remains pending/provisional, close and reopen the app, and show the same command ID is still pending. Reconnect and verify automatic retry with a Host `ACCEPTED` receipt/revision.
- Verify Device B reads the Host-confirmed result. Redeliver the same command ID and prove a single authoritative effect/receipt. Interrupt network during delivery and prove retry is idempotent.
- Make two independent edits from the same Host revision. Verify one stale update conflicts, preserves its local draft, and requires review; exercise a separately invalid/unauthorized command and verify rejection does not appear Host-confirmed.
- Verify alternate tenant, company, and branch scopes are denied without record/audit/outbox effects. Revoke Device B or its credential through the trusted operator flow and verify subsequent authorization fails after reconnect/restart.
- Record both physical device identifiers, app/source build, Host/database migration identity, test timestamps, command IDs, and redacted receipt/revision outcomes. Keep secrets, token digests, full URLs, and witness fingerprints out of the evidence.

## Final engineering assessment and next stage

**Phase status: CONDITIONAL PASS.** Repository-level security and source checks available in this session passed. The health endpoint is reachable. The registration root cause and possible prior side effects are not resolved, and the requested two-independent-Windows-device acceptance is not run. The phase must not be reported as fully closed.

**Next stage recommendation:** perform the read-only operator state reconciliation on `IT-PC`, capture the redacted results, and determine the exact failure stage without repeating the mutation. Once recovery admission is confirmed ready/matching and the intended device/credential state is known, complete the checklist above on both physical Windows devices. Reopen code investigation only if that evidence points to a source defect; preserve the least-privilege, ACL, witness, and transactional controls.
