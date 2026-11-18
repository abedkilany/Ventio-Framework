# Wave 2 B test preparation — not executed

Prepared against `feature/wave-2-a` at
`87f8a5c388233f203920aaaec6acbc7bf544a6bc`. This assignment authorizes test source
and documentation only. **All 161 new cases are PREPARED_NOT_EXECUTED.** Static
analysis is not test execution, product acceptance, malware clearance or owner
acceptance. Wave_2_B remains unaccepted; Wave_2_C remains closed.

The [case-level matrix](WAVE_2_B_PREPARED_COVERAGE.md) covers aspects of all 22
capabilities. Its [JSON companion](WAVE_2_B_PREPARED_CASES.json) records each case's
ID, capability, assertion scope, source line, production contracts, command and
unexecuted status. Requirements come from the existing
[acceptance matrix](WAVE_2_B_VERIFICATION_PLAN.md#capability-acceptance-matrix).
An indexed capability is not a claim that every acceptance scenario is covered.

## Changed source inventory and fixtures

Paths below are repository-relative. No production source, dependency manifest,
lockfile, migration, workflow, installer or application configuration is changed.
The only modified existing test is `engineering_audit.dart`; it delegates its
manifest-regression block to the stronger shared check instead of duplicating it.

| Cases | Prepared source | Required fixture and actual behavior |
|---|---|---|
| C001–C031 | `packages/ventio_core/test/wave2_contracts_test.dart` | Pure Core contracts; deterministic bundle/overlay/CSV/definition inputs, including dates/enums/references/child JSON/defaults/exact calculations. No DB or service. |
| S001–S020 | `packages/ventio_native_client/test/wave2_workspace_store_test.dart` | Real temporary SQLite files, FFI SQLite, historical v1/v2 schemas, reopen/CAS/owner isolation. |
| H001–H029 | `packages/ventio_host_api/test/wave2_gateway_integration.dart` | Fresh PostgreSQL 16, real opaque identities, restricted pools, actual HTTP/SQL/metadata/record/report gateways and approval. |
| J001–J027 | `packages/ventio_host_api/test/wave2_jobs_integration.dart` | Separate fresh cluster; real workers/executor, concurrent claims, fenced leases, cancellation, expiry and a killed test-owned child worker. |
| D001–D011 | `packages/ventio_host_api/test/wave2_database_integration.dart` | Separate fresh cluster; actual migration runner, restricted SQL logins, forced RLS, failed DDL rollback and logical backup/restore. Docker fixture mode exercises the existing logical restore helper. |
| O001–O008 | `packages/ventio_host_api/test/wave2_operations_integration.dart` | Separate fresh cluster; actual SQL operation/policy state. Supplied trusted-operator outcomes are explicit state-transition input vectors; they do not prove a local approval, scheduled task or physical backup. |
| U001–U003 | `packages/ventio_host_api/test/wave2_upgrade_integration.dart` | Separate fresh cluster, Git object `7d74a706ef4bb7f9994d151af486eaa38066e633`, Git/tar and verified PostgreSQL 16 `psql`; prepared transactions enabled. Materializes the real 001–036 baseline, then applies the witness-aware 037–040 bridge in its own newly created database. |
| R001–R002 | `packages/ventio_host_api/test/support/wave2_manifest_regression.dart`; integrated in `test/engineering_audit.dart` | Existing Linux OS-separated audit fixture with a verified audited launcher and restricted privilege helper. Requires an actual 503/HOST_UNAVAILABLE, distinguishes transport failure, checks no side effects/process death and requires same-process recovery. WB-CI-02 remains unverified. |
| E001–E006 | `packages/ventio_native_client/test/wave2_offline_integration.dart` | Separate fresh cluster plus two real SQLite queues and independent identities over actual HTTP. Real socket loss after commit; no manufactured receipt. This is a same-machine integration, not two-device acceptance. |
| G001–G007 | `packages/ventio_native_client/integration_test/wave2_workspace_acceptance_test.dart` | Separate fresh cluster, desktop display and integration-test build permission. Real WorkspacePage and DocumentActivityPage against actual Host. Explicit unique empty app-support directory. |
| W001–W011 | `tests/wave2/windows_integrity_tests.ps1` | Disposable Windows filesystem fixture, NTFS ACL/junction support, existing PowerShell; actual exported backup-integrity/operation-storage modules. No installed Host, scheduler or Pester required. |
| P001–P006 | `tests/wave2/windows_operations_acceptance.ps1` | Separately provisioned disposable installed Windows VM, verified and cleared candidate, actual services/scheduler, normal elevated local operation approval and explicit restore authorization. Never TEST-01/TEST-02. |

Shared support added:

- `packages/ventio_core/test/support/wave2_fixtures.dart` and
  `wave2_cases.dart`: bounded declarative package/definitions, fixed UUID inputs,
  typed contract assertions and case-labelled fail-fast reporting.
- `packages/ventio_host_api/test/support/wave2_fixture.dart`: guarded real
  PostgreSQL/HTTP assembly, explicit grants/ceilings and private witness/credential
  files. Uses the existing `recovery/database_fixture.dart` guard.
- `packages/ventio_host_api/test/support/wave2_worker_process.dart`: test-owned
  source worker for process-death recovery; no compiled Host/application binary.
- `packages/ventio_native_client/test/support/wave2_commit_drop_proxy.dart`:
  forwards to real Host, drops only a real accepted response after commit.
- `tests/wave2/installed-lab.example.json`: non-runnable placeholder manifest;
  contains no credential, approved hash or real witness path.
- `tests/wave2/validate_prepared_sources.py`: static inventory/matrix validator
  and optional temporary source copies for analysis; never imports Dart or
  PowerShell test files. Generated artifacts are the two matrix files above.

## Fixture boundaries and determinism

H/J/D/O/U/E/G each need their **own fresh migrated/bootstrap cluster**. Do not run
these suites sequentially against one database: the fixture refuses nonempty
identity/job/package state and deliberately does not reset someone else's data.
All role URLs must use the same loopback port and `/ventio_host_test`. Fixtures
refuse `VENTIO-TEST-01` and `VENTIO-TEST-02`. No remote DSNs are allowed.

The shared guard requires all of:

- `VENTIO_WAVE2_PREPARED_TESTS=yes`, `VENTIO_ALLOW_DATABASE_TESTS=yes`,
  `VENTIO_ALLOW_POSTGRES_CRASH_TEST=yes`, and numeric `VENTIO_CI_RUN_LABEL=N-N`.
- `VENTIO_TEST_DATABASE_URL` (disposable observer/superuser),
  `VENTIO_TEST_RUNTIME_DATABASE_URL` (`ventio_runtime_test`),
  `VENTIO_TEST_ADMIN_DATABASE_URL` (`ventio_admin_test`), and
  `VENTIO_TEST_API_ADMIN_DATABASE_URL` (`ventio_user_api_test`). These are distinct
  role capabilities; the observer is never substituted for a runtime gateway.
- Docker mode: `VENTIO_TEST_POSTGRES_CONTAINER_ID` must identify the expected
  `postgres:16` fixture, database/user/port and run labels. Prefer Linux Docker
  for all PG suites, especially the logical restore suite.
- Existing Windows process mode is also supported by the shared guard, but needs
  all existing private-runner metadata: `VENTIO_TEST_POSTGRES_MODE=process`,
  `RUNNER_TEMP`, `VENTIO_TEST_POSTGRES_DATA_DIRECTORY`,
  `VENTIO_TEST_POSTGRES_BIN_DIR`, `VENTIO_TEST_POSTGRES_PORT`, and
  `VENTIO_TEST_POSTGRES_LOG_FILE`. The data directory must be exactly
  `$RUNNER_TEMP/ventio-pg-$VENTIO_CI_RUN_LABEL/data`, with private ACLs and a real
  loopback PostgreSQL 16 server. These values are not fabricated by these tests.

UUIDs, packages, input rows and job identities are deterministic. Temporary paths,
ephemeral ports and credentials are isolated runtime resources, not golden values.
Expiry/retry cases advance only exact fixture rows rather than sleeping for lease
durations or changing a system clock. Worker polls have bounded timeouts. A retry
state supplied to `finish` is a transition test; actual socket loss, worker death,
witness unavailability and executor effects have separate real integration cases.

Suites fail on unexpected status/error types; they do not skip unavailable
prerequisites as successful tests. Fail-fast means later cases must be recorded
as NOT_RUN_AFTER_FAILURE if a future run stops early. Fixture teardown closes
pools/services it created and removes its private files/restored test cluster;
the source Docker fixture is explicitly disposed by its authorized runner. No
preserved lab database or previous fixture is overwritten.

E/G use an explicitly ephemeral in-memory **credential storage backend**. Identity,
authentication, authorization, HTTP transport, receipts, SQL and SQLite stay real.
These suites make no claim about OS secure storage; W2-M001 covers that boundary.

## Commands for a later authorized execution phase

**None of the commands in this section were executed during preparation.** They
are instructions for a separately authorized phase, not a CI dispatch request.
Use a dedicated disposable runner, not the owner workstation/test computers.
Record the exact prepared tree/diff hash, verified tool hashes/versions, dependency
lockfiles, OS, fixture image digest and commands. Reconcile the existing Host
Dart 3.13.7 and Client Flutter 3.44.1/Dart 3.12.1 workflow contexts; do not silently
change compiler versions or resolve dependencies during test invocation.

An existing correctly resolved package map and approved cached dependencies are
prerequisites. Commands intentionally use explicit `--packages` or `--no-pub`.
If metadata/native dependencies are missing, stop and arrange that prerequisite
under the later execution authorization. No install/download/`pub get` is part of
this preparation. Dart suites are executable `main` programs, not package:test
files; using `dart test` would not run them correctly.

From `packages/ventio_core` (reuse the existing native package map):

```powershell
dart --packages=../ventio_native_client/.dart_tool/package_config.json test/wave2_contracts_test.dart
```

From `packages/ventio_native_client`:

```powershell
flutter test --no-pub test/wave2_workspace_store_test.dart
# Fresh PG fixture and environment below required for each of the next commands.
flutter test --no-pub test/wave2_offline_integration.dart
# Set an absolute, unique, initially empty VENTIO_APP_SUPPORT_DIRECTORY whose
# basename is ventio-wave2-ui-<run-id>. Requires separately authorized test build.
flutter test --no-pub integration_test/wave2_workspace_acceptance_test.dart -d windows
```

On a separately approved Linux desktop runner the last target can be `-d linux`;
this does not satisfy Windows or Android physical acceptance. `wave2_offline_integration.dart`
does not match default `*_test.dart` discovery: invoke it explicitly so a normal
SQLite/component run does not unexpectedly start database/process tests.

From `packages/ventio_host_api`, run **one** PG suite per fresh fixture:

```powershell
dart --packages=.dart_tool/package_config.json test/wave2_gateway_integration.dart
dart --packages=.dart_tool/package_config.json test/wave2_jobs_integration.dart
dart --packages=.dart_tool/package_config.json test/wave2_database_integration.dart
dart --packages=.dart_tool/package_config.json test/wave2_operations_integration.dart
# Also set VENTIO_TEST_PSQL to an existing verified absolute PostgreSQL 16 psql path.
dart --packages=.dart_tool/package_config.json test/wave2_upgrade_integration.dart
```

For reproducibility, this is the Linux Docker fixture setup for **one selected
suite**. It assumes the approved image is already present as `postgres:16` and
all tools/package maps already exist. It does not pull an image, install a helper
or build an executable. Execute from repository root only in the later phase:

```bash
set -euo pipefail
export VENTIO_WAVE2_PREPARED_TESTS=yes
export VENTIO_ALLOW_DATABASE_TESTS=yes
export VENTIO_ALLOW_POSTGRES_CRASH_TEST=yes
export VENTIO_CI_RUN_LABEL="$(date -u +%s)-$$"
w2Container="$(docker run --pull=never -d \
  --label io.ventio.ci.fixture=postgres-test \
  --label "io.ventio.ci.run=$VENTIO_CI_RUN_LABEL" \
  -e POSTGRES_DB=ventio_host_test -e POSTGRES_USER=ventio \
  -e POSTGRES_PASSWORD=ventio_test_only -p 127.0.0.1::5432 \
  postgres:16 -c max_prepared_transactions=20)"
export VENTIO_TEST_POSTGRES_CONTAINER_ID="$w2Container"
w2Mapping="$(docker port "$w2Container" 5432/tcp)"
[[ "$w2Mapping" =~ ^127\.0\.0\.1:[0-9]+$ ]] || exit 1
w2Port="${w2Mapping##*:}"
for w2Attempt in {1..30}; do
  if docker exec "$w2Container" pg_isready -U ventio -d ventio_host_test; then break; fi
  sleep 1
done
docker exec "$w2Container" pg_isready -U ventio -d ventio_host_test
export VENTIO_TEST_DATABASE_URL="postgresql://ventio:ventio_test_only@127.0.0.1:$w2Port/ventio_host_test?sslmode=disable"
export VENTIO_TEST_RUNTIME_DATABASE_URL="postgresql://ventio_runtime_test:runtime_test_only@127.0.0.1:$w2Port/ventio_host_test?sslmode=disable"
export VENTIO_TEST_ADMIN_DATABASE_URL="postgresql://ventio_admin_test:admin_test_only@127.0.0.1:$w2Port/ventio_host_test?sslmode=disable"
export VENTIO_TEST_API_ADMIN_DATABASE_URL="postgresql://ventio_user_api_test:user_api_test_only@127.0.0.1:$w2Port/ventio_host_test?sslmode=disable"
export VENTIO_DATABASE_URL="$VENTIO_TEST_DATABASE_URL"
export VENTIO_MIGRATIONS_DIR=../../migrations/postgres
docker cp security/postgres "$w2Container:/tmp/ventio-security"
cd packages/ventio_host_api
dart --packages=.dart_tool/package_config.json ../ventio_postgres/bin/migrate.dart
docker exec "$w2Container" psql -X -U ventio -d ventio_host_test \
  -v ON_ERROR_STOP=1 -v expected_database=ventio_host_test \
  -f /tmp/ventio-security/bootstrap.sql
docker exec "$w2Container" psql -X -U ventio -d ventio_host_test \
  -v ON_ERROR_STOP=1 -f /tmp/ventio-security/test_logins.sql
# Invoke exactly one selected H/J/D/O/U suite here, or change to the native
# package for E/G. Do not reuse this cluster for another suite.
```

The passwords above are the repository's deliberately public disposable-fixture
passwords. Never use them on a persistent/network-accessible installation.
Before disposing the source container, verify its exact full ID and both labels:

```bash
[[ "$w2Container" =~ ^[a-f0-9]{64}$ ]]
[[ "$(docker inspect -f '{{index .Config.Labels "io.ventio.ci.fixture"}}' "$w2Container")" == postgres-test ]]
[[ "$(docker inspect -f '{{index .Config.Labels "io.ventio.ci.run"}}' "$w2Container")" == "$VENTIO_CI_RUN_LABEL" ]]
docker rm -f "$w2Container"
```

R001/R002 reuse the existing engineering audit, not a mock localhost response:

```bash
# Host package working directory; own fresh fixture, existing verified audit
# binary/workdir/restricted helper and existing OS-separated fixture setup.
export VENTIO_AUDIT_HOST_BINARY=/absolute/verified/ventio-audit-host
export VENTIO_AUDIT_HOST_WORKDIR=/absolute/verified/audit-assembly/packages/ventio_host_api
export VENTIO_AUDIT_PRIVILEGE_HELPER=/usr/local/libexec/ventio-ci-drop-to-nobody
export VENTIO_AUDIT_RESULTS_FILE=/absolute/private/fixture/host-audit-results.json
dart --packages=.dart_tool/package_config.json test/engineering_audit.dart
```

This also runs the pre-existing engineering-audit cases. The original environment
and OS separation are documented in `.github/workflows/host-engineering-gate.yml`.
Do not dispatch it or run its installer/compile steps during preparation. If no
verified existing audit launcher/helper is available, R is BLOCKED_PREREQUISITE
until a later authorization covers obtaining them. A transport failure remains
a failure, not evidence that the expected HTTP 503 was returned.

Windows filesystem suite, from repository root on a disposable Windows runner:

```powershell
$env:VENTIO_WAVE2_PREPARED_TESTS = 'yes'
$fixtureParent = 'C:\absolute\existing\private-test-parent'
& ./tests/wave2/windows_integrity_tests.ps1 -PrivateFixtureParent $fixtureParent
```

The script modifies ACLs only on its newly created fixture files/directories and
unlinks its test junction before exact-root cleanup. It does not modify OS security
policy, Defender, installed services or a real backup. Provision a private NTFS
parent through the normal disposable-runner setup. Neither W nor P changes an
execution policy or bypasses an operating-system security control.

Installed Windows suite prerequisites must be supplied by the owner/environment
operator in a **separately authorized VM**:

1. Machine name `VENTIO-W2-VM01` (or the same pattern with two digits), a fresh
   installed and running cleared candidate, ordinary PostgreSQL/Host services,
   default loopback Host port 8080 and a fresh backup root. No install or launch
   is performed by this assignment. Candidate verification must include all
   payload hashes and separate security clearance; hashing is not malware clearance.
2. Administrator-owned private
   `%ProgramData%\Ventio-W2-Disposable\fixture.json` containing `fixtureOnly:true`,
   the same `fixtureNonce` and `machineName` as the reviewed external fixture
   manifest. Provision ACLs through normal VM setup. Do not create this marker
   on TEST-01/TEST-02 or the owner workstation.
3. Dedicated tenant `w2-physical-disposable`, explicit user/device/scope and
   existing opaque fixture credential with the required package/record,
   workspace and operations/configuration permissions. Approve the exact package
   produced by `w2BundleJson()` (`com.example.wave2`, Asset, version 1.0.0).
   Leave policy definitions, sentinel record and backup directories initially
   absent. The script uses actual authenticated commands to seed the sentinel.
4. Copy `installed-lab.example.json` to an external private reviewed manifest;
   replace every placeholder with the marker nonce, approved payload-manifest
   SHA-256 and actual independent witness path. Supply the credential as
   `VENTIO_W2_TOKEN` and a dedicated disposable observer URI as
   `VENTIO_W2_OBSERVER_DSN` through the private process environment. Never record
   them in chat, source, command transcripts or the case evidence.
5. Launch a normal elevated PowerShell session. Review that P will change the
   fixture's policy/task, take genuine backups, exercise retention, corrupt only
   a copied test backup and perform a real restore. It deliberately ends with
   Host stopped and the old cluster quarantined. It neither resets/adopts the
   witness nor restarts Host or resurrects an old credential after restore.

```powershell
# Repository root, inside that VM; supply secrets privately before invocation.
$env:VENTIO_WAVE2_PREPARED_TESTS = 'yes'
$fixtureManifest = 'C:\absolute\private\reviewed-installed-fixture.json'
& ./tests/wave2/windows_operations_acceptance.ps1 `
  -FixtureManifest $fixtureManifest -ApproveLocalOperations -AllowDisposableRestore
```

P is automated after fixture provisioning and local authorization. Its elevated
steps, physical recovery and subsequent safe cleanup require an environment
operator. It is not appropriate for unattended execution on either test computer.

## Existing coverage deliberately reused

These files were inspected to avoid recreating established suites. Their current
source presence supplies no new passing evidence, and they are outside the 161
new case count:

| Existing source | Coverage reused / capability relationship |
|---|---|
| `packages/ventio_core/test/all_tests.dart` | B02/K10/J01/F05: declarative operations, governed effects, typed field/table/reference/calculation and report contracts. CSV conversion-specific assertions remain in C. |
| `packages/ventio_host_api/test/extension_package_integration.dart` | A12/D08/K08/F05/K10: actual approved metadata, field ACLs, records, report bounds/grouping and cursors. |
| Host `identity_integration.dart`, `pairing_integration.dart`, `credential_reissue_integration.dart`, `role_administration_integration.dart` | D09/D08/M01: opaque identity, pairing/reissue, ceilings, roles and revocation. |
| Host `database_security_integration.dart`, `recovery_integration.dart`, `host_schema_upgrade_recovery_integration.dart` | B02/D09/M09/L01: baseline role/SQL security, independent witness/crash barriers and schema-upgrade recovery. New D/U cover Wave 2 changes. |
| Host `lifecycle_integration.dart` | K10/H04: governed submit/cancel/amend lifecycle foundations; does not prove every new history boundary. |
| Native `test/local_command_queue_test.dart` | J03/K09: stable original IDs, interrupted send, receipt integrity, duplicate protection and fixture/Host distinction. |
| Native `test/official_inventory_host_sqlite_integration_test.dart` | J03/K10: real governed Host/SQLite integration foundations. |
| Native `test/host_transport_test.dart` | D09/J04: existing TLS/redirect and bounded transport negatives. E adds actual commit/lost-response recovery. |

Use the existing commands/fixtures for those suites when a later authorized run
needs them; do not rerun full CI for each new case or repeat installer packaging
for pure contract/database changes. Record the exact source revision for any old
passing evidence before attributing it to the candidate.

## Remaining scenario and physical gaps

The six W2-M cases in the matrix require real device/owner acceptance: OS secure
storage and bootstrap/pairing/TLS UX; actual two-device offline/reboot/conflict;
Windows and Android focus/keyboard/DPI/rotation; normal UAC and interrupted/disk-full
operation recovery; safe post-restore authority reconciliation/fresh authentication;
and installed first-run/upgrade/uninstall/data retention. G's desktop resize/text
simulation and E's two local queues do not close these gates.

Further automated scenario expansion remains explicit, rather than hidden behind
an all-capabilities claim: exhaustive CSV typed-value/ACL/reference-change
cross-products beyond the focused C/H/J cases; every history backfill/keyset tie and 100+ event bound;
all organization archive/reactivation races; exhaustive release/overlay lock-order
and repeated multi-release stress; every witness/DDL/SQLite interrupted-upgrade
crash barrier; non-Gregorian schedule/time-zone transitions and full disk/power-loss
recovery; old-Client/new-Host and new-Client/old-Host binary compatibility. Existing
foundational tests cover portions, not every new composition. These are coverage
gaps or future experiments, not confirmed production defects or passing cases.

## Static preparation checks and evidence rules

Allowed static commands (no case execution):

```powershell
python tests/wave2/validate_prepared_sources.py
# To regenerate documentation after deliberate source changes:
python tests/wave2/validate_prepared_sources.py --write-matrix
```

Dart formatting/parsing, static analysis and the PowerShell AST parser were used
for preparation. Core/Host have no existing local package metadata; rather than
resolve/install dependencies, analysis copies were placed temporarily under the
existing native package context with relative imports rewritten to absolute file
URIs. The analyzer checked those sources, not their runtime behavior. The optional
`--analysis-snapshots` and `--clean-analysis-snapshots` commands implement this
bounded copy/remove operation without modifying package metadata. The directory
is removed after validation and is not a deliverable. Dependency/toolchain-specific
Host analysis in the intended Dart version remains a later prerequisite.

A later result must record case ID, exact candidate/tree/tool versions, isolated
fixture identity, command, exit code, assertion outcome and relevant sanitized
receipts/row counts/hashes. Never publish raw credential digests, tokens, full DSNs,
payload secrets or witness material. Report prerequisites/failures/skips separately.
All C/S/H/J/D/O/U/R/E/G/W/P cases remain unverified because execution was expressly
prohibited. No prepared source closes WB-CI-02 or grants Wave_2_B acceptance.
