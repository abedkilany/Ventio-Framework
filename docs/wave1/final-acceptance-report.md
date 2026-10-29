# Wave 1 Host/Client Final Acceptance Report

**Audit snapshot:** 2026-10-30 01:05 Asia/Beirut
**Branch:** `codex/extension-platform`
**Release decision:** **BLOCKED — Wave 1 remains open.** This is the current requirement-by-requirement acceptance record, not a release approval. No completion is credited for an unexecuted integration gate.

## Stage gates

| Stage | Status | Evidence and remaining acceptance work |
|---|---|---|
| 0 — Baseline audit and plan (4%) | PASS | Repository, architecture, permissions, recovery, persistence, tests and risks are recorded in `implementation-plan.md`. The standalone progress dashboard is validated and weighs stages to exactly 100%. Commit `ce5ac6e`. |
| 1 — Foundational management contracts (8%) | BLOCKED | Versioned readiness/error contracts and correlation/redaction checks are implemented; Host API tests pass 66/66. PostgreSQL readiness, database roles, Recovery Authority admission and migration compatibility have not been run against PostgreSQL. |
| 2 — User identity, roles and permissions (12%) | BLOCKED | Scoped API/UI work and role separation are present; source review and API contract coverage pass. Live PostgreSQL privilege, forced RLS, branch isolation, audit and escalation tests have not run. |
| 3 — Unified first-run setup (11%) | FAIL | A complete Host setup workflow, headless Host provisioning, and setup resume/rollback are absent. Client pairing UI exists, but a real Host-backed first-run integration has not passed. |
| 4 — Secure pairing and device management (9%) | BLOCKED | Pairing and device management API/UI contracts are implemented and local tests pass (Host API 66/66, device API 8/8, focused device UI 7/7). PostgreSQL digest, expiry, replay, RLS, revocation and cross-device tests are NOT RUN. Credential rotation and authenticated activity history remain incomplete. |
| 5 — Integrated Host administration UI (10%) | BLOCKED | Host overview, user/permission, device/pairing, diagnostics and synchronization areas are integrated in the shared Flutter app with permission gating. Full Host Settings and real Host authorization evidence remain incomplete. |
| 6 — Diagnostics Center (10%) | BLOCKED | Local auth-independent diagnostics and sanitized export have local tests. Remote Host diagnostic-event retrieval, the required failure-class coverage and complete failure-injection/security-redaction evidence remain incomplete. |
| 7 — Offline-first synchronization (7%) | BLOCKED | Durable SQLite queue behavior and UI states have local test coverage. Real Host acceptance, reconnect/rejection/conflict and cross-device propagation evidence has not passed. |
| 8 — End-to-end validation (6%) | BLOCKED | The mandatory real Host/PostgreSQL and installed Host/Client scenarios have not run. Android and two-physical-device validation are not demonstrated. |
| 9 — Final engineering audit (3%) | BLOCKED | This snapshot records current gates; the final audit cannot pass while mandatory earlier gates are open. |
| 10 — Windows installer/provisioning (20%) | FAIL | The built artifact is Client-only. Host/Client role selection, isolated Host PostgreSQL provisioning, background Host service, bootstrap, reboot recovery, upgrade and retention-choice uninstall are absent. The artifact does not satisfy the unified installer requirement. |

## Stage 10 acceptance tests

| Required scenario | Status | Evidence |
|---|---|---|
| Fresh Host installation on supported Windows | FAIL | No Host installation workflow or Host installer exists. |
| Host service starts automatically, survives UI exit, and starts after reboot | FAIL | Host launcher is a foreground process; no Windows Host service is installed. |
| PostgreSQL and API operational readiness | BLOCKED | A native isolated PostgreSQL CI harness exists, but local PostgreSQL tests were not run. `psql`/`pg_ctl` are absent; Docker remains stopped per user direction. The pinned 373 MB archive transfer was cancelled after a 1 MiB range took 20 seconds. No database was initialized or started. |
| Initial administrator bootstrap | FAIL | No graphical production Host bootstrap workflow exists. |
| Client-only installation without PostgreSQL | PASS | Current Client-only Inno Setup artifact installs the Flutter application without PostgreSQL; fresh per-user install and required-file checks passed. |
| Client pairing with a temporary Host-generated token and authenticated connection | BLOCKED | The shared Flutter enrollment flow and pairing API contracts are locally tested; PostgreSQL-backed redemption and live Host authentication were not run. |
| Admin on Client and ordinary user on Host receive correct permissions | BLOCKED | UI/API permission-gating checks exist, but live server authorization, RLS and scope integration were not run. |
| Offline SQLite operation and subsequent Host synchronization | BLOCKED | Queue/retry/receipt mechanics have local tests; integrated real Host acceptance and propagation were not run. |
| Representative installer and connection failures have clear UI reporting | BLOCKED | Several local connection/diagnostic states exist; installer-stage reporting and full failure-category injection are incomplete. |
| Safe upgrade without data loss | BLOCKED | Client package replacement from 0.1.0 to 0.1.1 preserved the installed files and external-data marker. The test uses the same Flutter payload under a test package version and does not verify SQLite migrations or Host PostgreSQL backup/upgrade. |
| Uninstall retention choices | FAIL | The Client uninstaller preserves data outside the app folder, but no explicit Host/client data-retention choice flow exists. |
| Sanitized diagnostics export has no secret leakage | PASS | Local sanitized export and redaction tests pass; installer/Host provisioning logs have not yet been validated end to end. |

## Latest verification evidence

- Full Flutter suite: **162 passed, 2 environment-gated skips**; Flutter analysis clean.
- Core suite: **81 passed**.
- Host API contracts: **66 passed**; device API contracts: **8 passed**; focused device UI/client tests: **7 passed**.
- Windows Flutter release build and Inno Setup 6.7.3 compilation passed.
- Current Client-only installer: 14,562,917 bytes; SHA-256 `47cc471db0651a229c51a125909c4b46978a12491e2727bbbf3ceddf3b1dac59`.
- Client package smoke checks passed for fresh per-user installation, same-version repeat installation, uninstallation and preservation of data outside the install directory. A separate package-version upgrade check passed, but neither check tests Host provisioning, service lifecycle or database migration.
- Client package upgrade smoke test passed: the validator compiled the same current Flutter payload as package 0.1.1, installed 0.1.0, upgraded in place, confirmed the registered 0.1.1 version, retained the application and external-data marker, then uninstalled while retaining that marker. This is not Host database or SQLite schema-upgrade evidence.
- Host API launcher change is committed as `e110126`; device management slice as `8baa866`; the native CI PostgreSQL process scripts are `scripts/ci/install-postgres-tools.ps1` and `scripts/ci/start-postgres-test-instance.ps1`.
- No PostgreSQL process was started locally. Docker remains stopped. Docker is not a product prerequisite and is not required by the repository's Windows CI PostgreSQL harness.

## Security review snapshot

- **PASS — source-reviewed/local evidence:** Host permissions derive from authenticated scoped grants rather than device role; remote device administration uses dedicated scopes; Client enrollment requires HTTPS and normal certificate validation; local credential storage uses the platform vault; diagnostic projections omit credentials; the Host launcher refuses a non-authoritative device gateway on external TLS listeners.
- **BLOCKED — live database evidence:** PostgreSQL grants, forced RLS, tenant/branch isolation, Recovery Authority admission, pairing digest storage, expiry/replay defense, revocation, credential ceilings and API/local role separation require integration execution.
- **FAIL — deployment controls absent:** No production Windows Host service identity/configuration, isolated PostgreSQL installer, elevated fixed-operation broker, upgrade migration/backup path or explicit uninstall retention workflow is implemented and verified.

## Release gate

**Wave 1 is not complete.** Do not describe the current Client installer as the unified Host/Client installer. The next engineering work is to define and implement the Windows Host provisioning boundary using a dedicated service identity, isolated PostgreSQL data directory, protected configuration and the existing independent Recovery Authority. Run database integrations through the native isolated CI harness when available; keep Docker stopped unless the user changes that instruction.
