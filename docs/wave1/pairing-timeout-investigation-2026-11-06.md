# Pairing Timeout Investigation — 2026-11-06

## Status

The client and Host changes below are implemented and covered by local automated tests. The defect is **not deployment-closed**: the corrected build still requires the owner's physical Windows Host/Client acceptance, including Host-authoritative business-record synchronization. Wave 1 acceptance remains **60/100**.

## Field evidence and limits

The installed Host was reported READY at all four readiness components while the Client displayed `HOST_REQUEST_TIMEOUT`. Three pairing rows were observed in `public.ventio_identity_pairings` around 2026-11-05 19:46, 19:52, and 19:53 UTC. Each row establishes that a pairing mutation committed. The schema deliberately stores only the code digest, not the one-time code, and the rows have no Client request reference. Consequently, the rows cannot be mapped to individual clicks or timeout responses, and they do not establish that every timed-out attempt committed.

The installed build did not record per-stage operation timings. Therefore, the specific field delay location—connection/pool acquisition, Recovery Authority admission or file work, transaction execution, witness finalization, or response transmission—cannot be established retrospectively. The field root cause is not attributed to any one of those stages.

The source-confirmed defect was that pairing used the general 15-second Client request deadline, whose `Future.timeout` did not cancel Host-side mutation. After the deadline, the UI treated the response as a failure and a subsequent button press could create a new logical issuance. A controlled integration test reproduces the consequential ambiguity: a pairing row can commit while the response is held beyond the old 15-second deadline. This proves the failure mode, not that the three historical records followed that exact timing sequence.

## Request lifecycle review

| Stage | Finding |
|---|---|
| Flutter Generate Pairing Code | Called `HostDeviceManagementClient.createPairing`; the page had no durable logical request reference to reuse after an ambiguous result. |
| Client HTTP request | Used the 15-second general management timeout. Timing out did not cancel work already admitted by the Host. |
| Host route | Authenticated the caller and enforced exact tenant/company/branch scope and pairing permission before mutation. |
| PostgreSQL connection | Pool acquisition and connection setup are separately measured by the Host. The pool's connection timeout is bounded at five seconds. |
| Recovery Authority | Admission serializes witness updates and remains fail-closed. Admission is bounded at 30 seconds; statement and row/advisory lock timeouts remain bounded. |
| Database operation | Pairing is inserted under a PostgreSQL transaction and existing authorization, scope, digest-only storage, issuance limits, and audit rules. |
| Commit and witness finalization | A committed row can exist before the HTTP response is received. The Host finalizes the independent witness before returning success; an ambiguous transport result cannot prove whether commit occurred. |
| Response and UI | A response lost or delayed after submission was previously represented as a generic timeout, giving the operator no safe retry identity or unknown-outcome guidance. |

No locks, witness checks, fingerprint verification, or fail-closed behavior were bypassed. Recovery fingerprint calculation was measured locally and was not a material part of the measured operation.

## Controlled timing evidence

The disposable PostgreSQL pairing integration run recorded a successful local request at approximately **2.98 seconds total**, with approximately **2.35 seconds** in Host processing. A single instrumented run measured approximately:

| Segment | Duration |
|---|---:|
| PostgreSQL pool acquisition | 78 ms |
| Database connection setup | 23 ms |
| Recovery Authority lock acquisition / lock-file ACL setup | 832 ms |
| Recovery Authority queue wait | 0 ms |
| OS lock wait | 0 ms |
| Recovery witness read | 429 ms |
| Pending witness write | 471 ms |
| PostgreSQL advisory lock acquisition | 1 ms |
| Before-mutation database fingerprint | 5 ms |
| Pairing transaction/mutation | 21 ms |
| After-mutation fingerprint | 0 ms |
| Remaining transaction work | 7 ms |
| Witness finalization | 480 ms |

Separate controlled contention measured a pool wait of about **235 ms**; four distinct concurrent pairing requests completed in about **9.93 seconds** total. The delayed-response scenario deliberately held a post-commit response beyond 15 seconds and confirmed the old deadline could expire while the Host later returned HTTP 201. These are local disposable-environment measurements, not measurements of the owner's installed computer. The previous field build has no comparable stage timings, so there is no valid before/after field latency comparison.

## Engineering correction

### Idempotent pairing request contract

The Client now calls `/api/v2/management/pairing/create` with a cryptographically random `cor_<32 hex>` request ID in both the body and `X-Correlation-ID`. The Host rejects malformed or mismatched identifiers before mutation. Version 1 remains available for older clients; the new Client does not silently fall back to the unsafe legacy mutation route.

The request identifier deterministically selects the existing pairing primary key. Under the existing PostgreSQL serialization and primary-key constraint, a repeated request for the same authenticated creator, tenant, company, and branch cannot create another pairing. A replay after acceptance returns HTTP 409 `PAIRING_CODE_UNAVAILABLE`: the Host stores no plaintext code and cannot recover the one-time value. The Client retains the same identifier and target for a retry, then presents controlled replacement guidance if the code cannot be recovered and its five-minute validity window expires. A new logical request remains subject to the existing rate limit (ten issuances per creator/exact branch in fifteen minutes); an already accepted replay is reconciled before that rate check.

No pairing secret, raw code, credential, digest, request body, database password, or Recovery Authority fingerprint is added to logs or diagnostics. The operation ID and initiating actor are stored in the Client's existing SQLite local state store, scoped by a non-reversible identity binding and excluded from diagnostic export.

### Bounded timeouts and outcomes

- Pairing HTTP processing timeout is 120 seconds; other management requests retain the 15-second timeout.
- Connection acquisition remains separately bounded; a failure before request submission is reported as connection timeout/Host unreachable.
- A timeout or transport/protocol failure after submission becomes `PAIRING_OUTCOME_UNKNOWN`, not a definitive database failure.
- Safe, known Host rejections retain distinct categories, including authorization, database unavailable, Recovery Authority unavailable, and Recovery Authority busy.
- Unexpected Host processing failures return a correlated safe unknown-outcome response and structured Host diagnostic; private failure detail is protected.
- The UI preserves the request reference and target on ambiguous outcomes. The Host still enforces admission, transaction serialization, database fingerprint checks, witness durability, anti-rollback behavior, scope authorization, and rate limits.

Recovery Authority witness read failures now map to a correlated, sanitized Recovery Authority error. Pending witness state still fails closed. The shared `security/postgres/pairing_create.sql` contract is applied during initial setup and by the existing-installation upgrade script after its restricted backup step; no data reset or schema migration is required. The upgrade preserves the database, services, credentials, certificates, DPAPI configuration, and Recovery Authority files.

## Changed files

- `packages/ventio_core/lib/src/management_contracts.dart`
- `packages/ventio_host_api/lib/src/host_api.dart`
- `packages/ventio_host_api/lib/src/pairing_administration.dart`
- `packages/ventio_host_api/lib/src/recovery_authority.dart`
- `packages/ventio_host_api/test/api_tests.dart`
- `packages/ventio_host_api/test/pairing_integration.dart`
- `packages/ventio_host_api/test/test_support.dart`
- `packages/ventio_native_client/lib/src/device_management_page.dart`
- `packages/ventio_native_client/lib/src/extension_studio_page.dart`
- `packages/ventio_native_client/lib/src/host_device_management.dart`
- `packages/ventio_native_client/lib/src/local_diagnostics.dart`
- `packages/ventio_native_client/lib/src/native_english_messages.dart`
- `packages/ventio_native_client/test/host_device_management_test.dart`
- `packages/ventio_native_client/test/local_diagnostics_test.dart`
- `scripts/ci/run-local-postgres-integration.ps1`
- `scripts/windows/test-unified-installer-path-contract.ps1`
- `scripts/windows/upgrade-host-database.ps1`
- `scripts/windows/validate-unified-installer.ps1`
- `security/postgres/pairing.sql`
- `security/postgres/pairing_create.sql`
- `docs/wave1/pairing-api-v1.md`
- `docs/wave1/pairing-timeout-investigation-2026-11-06.md`

## Verification results

| Verification | Result |
|---|---|
| Flutter pairing and diagnostics focused tests | **PASS — 23 passed, 0 failed** |
| Host API contract tests | **PASS — 75 passed, 0 failed** |
| Dart analysis for `ventio_host_api` and `ventio_core` | **PASS — no issues found** |
| Flutter analysis | **PASS — no issues found** |
| Disposable PostgreSQL pairing integration | **PASS — 38 passed, 0 failed** |
| Restricted database-upgrade pairing-contract application and verification | **PASS** within the disposable PostgreSQL run |
| Unified installer path contract | **PASS** |
| PowerShell syntax parse for changed upgrade, validation, contract, and integration-runner scripts | **PASS** |
| Recovery Authority crash-recovery integration | **PARTIAL / FAIL**: the suite passed its SIGKILL/restart checks through `after_commit`, then timed out waiting for a second Host mutation while the shared witness was intentionally pending. Pairing's direct pending-witness test confirms fail-closed rejection with no database mutation. The duplicate-operation test's expectation to reach PostgreSQL while a global Recovery Authority witness is pending is incompatible with that admission boundary. This suite is not reported as passed. |

The PostgreSQL tests use disposable local databases and test-specific witness state. No installed Host database, service, Recovery Authority, credential, or pairing record was touched.

## Remaining acceptance and deployment procedure

The source correction is testable and buildable locally, but deployment closure requires the owner to run the new development installer on the actual Host and separate Client. Do not uninstall, delete data, reset PostgreSQL, replace certificates, or manually change Recovery Authority state.

1. Verify the installer signature status and SHA-256 against the handoff before running it. The development installer is unsigned and is not a production-signed release.
2. Run the installer elevated as an in-place update over the existing Host. Keep the existing installation and data directories; choose no removal/reset option.
3. Verify `VentioHost` and `VentioPostgres` are running under their existing service identities; check all four Host readiness components are READY and that HTTPS certificate validation succeeds from the separate Client.
4. From the Host administration UI, issue one pairing code. Record only the correlation ID and outcome; do not copy the code into logs or diagnostics. Confirm the Client shows the code or a truthful `outcome unknown` state with the same request ID on retry.
5. Enroll the separate physical Client over certificate-validated HTTPS. Verify the Host records the authorized device and that both devices remain within the expected tenant/company/branch scope.
6. Create one non-sensitive test business record on a Client, verify durable local pending state, Host acceptance receipt, and propagation to the other Client after reconnection. Repeat after restarting the Client and Host services to verify persistence.
7. Capture sanitized diagnostics and timing evidence, redacting pairing code and credentials. If any step fails, retain logs/diagnostics and do not retry with a new pairing request ID until the existing operation is reconciled or the five-minute code window expires.

Until those physical tests pass, successful code, test, and build results do not establish real Windows deployment or end-to-end synchronization acceptance. Stages 3, 8, and 10 remain open; the formal Wave 1 score stays at 60/100.
