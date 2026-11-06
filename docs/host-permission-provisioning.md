# Host Permission Provisioning and Credential Ceilings

## Confirmed cause

The first Host administrator is intentionally provisioned with six direct management grants at the exact initial tenant, company, and branch. Bootstrap writes those same six grants into the initial credential's `allowed_scopes` ceiling. The list is:

- `host.status.read`
- `host.diagnostics.read`
- `identity.users.manage`
- `identity.devices.manage`
- `identity.pairing.manage`
- `identity.roles.manage`

Business permissions such as `extension.package.read` and `extension.package.submit` are absent by design. Bootstrap creates a bounded identity manager, not a business superuser.

Current user permissions and credential ceilings are separate controls. Direct grants and role-derived grants can change after credential issuance, but authentication only projects the intersection of current authority and the credential's exact scope and permission ceiling. Granting `extension.package.read` to a user therefore does not change an already-issued credential. Ordinary rotation carries forward the prior ceiling.

Ordinary pairing also cannot be used to expand the issuer's authority. It snapshots a target's effective direct and role permissions and rejects any requested permission outside the caller's live credential authority. The field Client's `POST /api/v1/extensions/approved` received HTTP 403 because its credential did not contain `extension.package.read`; that is expected Host authorization behavior.

## Supported provisioning flow

The correction adds an explicitly reviewed local trusted-operator workflow. It does not widen ordinary Client APIs, ordinary pairing, or rotation.

1. A Ventio operator signs into the Host application using an active credential whose exact branch ceiling includes `identity.pairing.manage`.
2. An authorized identity manager grants a selected business permission directly to the target user or through a role at the exact company and branch. The target permission must exist before credential provisioning.
3. On the Windows Host, the operator selects that target user and scope in **Host devices & pairing**, chooses only the permissions for the new Client, and confirms the exact permission list in the UI.
4. Windows asks a local administrator for UAC approval. The service authenticates the administrator through its protected local named pipe. The trusted helper then uses the separately held Identity API database role and Recovery Authority admission to check the operator credential, the current target grants, the exact scope, and the approved permission list.
5. PostgreSQL creates a five-minute one-time pairing digest and an audit event. The code is returned through a short-lived machine-DPAPI protected file whose ACL grants read access only to the requesting Windows user, local administrators, and SYSTEM. The broker resolves the requester's profile by SID, so a different administrator account may approve the UAC prompt. The code is not placed in command-line arguments, application logs, or database rows.
6. The intended Client redeems the code over the existing Host enrollment flow. The Host creates a device-specific credential with only that exact scope and permission list. The new device is separate from prior registrations. Existing devices remain valid unless an operator explicitly revokes them.

The database function is executable by the Identity API role only. The regular runtime role cannot call it. Its SQL checks require a live operator credential with `identity.pairing.manage`; the local Windows administrator approval does not replace the Host identity check. Requested permissions must already be granted to the target directly or through a role. Management, Host, system, security, recovery, and authorization namespaces cannot be requested.

If a trusted pairing result is lost after PostgreSQL commits, the one-time code cannot be recovered. The database suppresses another trusted pairing for that same user and branch for the five-minute pairing lifetime, preventing repeated minting while the ambiguous code could still be redeemed. After the code expires, an operator may review state and issue a new request. No automatic credential revocation occurs.

## Safe denial diagnostics

When an approved-registry request fails a current-session permission check, the Host may return one fixed safe reason code:

- `USER_PERMISSION_DENIED`: there is no current direct or role-derived grant at that exact scope.
- `CREDENTIAL_CEILING_DENIED`: a current grant exists, but this credential was issued without it.
- `CREDENTIAL_SCOPE_DENIED`: the credential does not admit the requested company and branch.
- `AUTHORIZATION_STATE_UNAVAILABLE`: the Host could not safely classify the denial.

The diagnostic function is available only to the Identity API role, verifies the Recovery Authority, reads no token plaintext, and returns no credential digest, grant list, or secret. The Client uses the result to give an actionable message rather than showing an authorization failure as Host unavailability.

## Database and upgrade impact

Ventio Setup 0.1.10 added the scoped-pairing contracts described above. Ventio Setup 0.1.11 adds the versioned reissue state migrations, narrow security-definer functions, forced RLS policy, and Recovery Authority mutation triggers. See [Host same-device credential reissue](host-same-device-credential-reissue.md) for the complete transition and migration behavior.

The Windows upgrade path stops the Host service, creates and verifies a restricted PostgreSQL data backup, applies schema migrations, installs and verifies the security contract, and only then permits Host restart. A failed backup, migration, or contract check leaves `VentioHost` stopped. Neither installer nor workflow resets existing devices, credential rows, certificates, Client SQLite, or Recovery Authority state.

Existing devices and their current credential ceilings are preserved by the upgrade. A selected device receives a replacement credential only after the same device has securely staged the token and acknowledged possession. The source credential is revoked atomically when the replacement becomes active.

### Already-enrolled Client identity preservation

Ventio Setup 0.1.10 did not support a same-device ceiling update. Ventio Setup 0.1.11 adds trusted credential reissue for an existing registered device. It preserves the device ID, exact Host profile scope, SQLite database, durable queue, records, and Host receipts. Ordinary credential rotation still inherits the existing ceiling, and new-device pairing still creates a separate device ID.

Do not redeem a new-device pairing on an already-enrolled Client when its device identity and local SQLite state must be preserved. Use **Reissue credential ceiling** for the existing device, then **Check for update** on that same Client. The complete operator and Client recovery protocol is in [Host same-device credential reissue](host-same-device-credential-reissue.md).

## Owner deployment and acceptance procedure

1. Copy the new versioned Ventio Setup 0.1.11 installer to the physical Host and verify its SHA-256 against the release report before running it.
2. Run Setup on the Host and accept the existing-installation upgrade. Allow the restricted backup, schema migrations, Recovery Authority contract update, verification, and service restart to finish. Do not uninstall or select data removal. If upgrade fails, leave `VentioHost` stopped and preserve the verified backup; do not edit security tables manually.
3. Update the existing Client application in place with Setup 0.1.11. Preserve its Windows profile, Host profile, and app data. Do not clear Client data or re-enroll.
4. Verify Host readiness and the existing registrations for tenant `a`, company `b`, branch `c`, certificate, and device ID.
5. In **Users & permissions**, grant only `extension.package.read` to the intended user directly or through a narrowly scoped role at tenant `a`, company `b`, branch `c`.
6. In **Host devices & pairing**, select the existing device and choose **Reissue credential ceiling**. Review the complete replacement permission list, retain existing authorized permissions, and approve the Host-local UAC prompt.
7. On that already-enrolled Client, select **Check for update**. Confirm the original device ID, exact scope, local records, and pending command IDs remain unchanged. Retry using the same operation reference if status is retryable or unknown; do not enroll again.
8. Verify `POST /api/v1/extensions/approved` succeeds for the intended Client while unrelated permissions and cross-scope access remain denied. Continue physical acceptance with an approved declarative extension, a real offline SQLite record, restart-persistent Pending state, Host PostgreSQL acceptance and receipt, and readback from another authorized Client. Keep Crash Recovery as a separate open gate.

These steps update only the selected existing device ceiling; they do not give every Client the administrator's authority. Physical acceptance remains pending until the owner completes and records these checks on the real Host.

## Prior 0.1.10 verification record (historical)

The implementation-specific 0.1.11 checks and current release identity are documented in [Host same-device credential reissue](host-same-device-credential-reissue.md).

Verified results:

- PostgreSQL Host security suites passed: database security 118/0, user administration 40/0, role administration 20/0, pairing 45/0, and extension package integration 138/0.
- Fresh first-administrator and legacy-style security-contract upgrade integration passed 14/14 assertions. Existing credential ceiling and device identity were preserved.
- Host API tests passed: API contract 75/0 and user management HTTP API 16/0.
- Dart analysis passed for Host API and Windows Client. Focused Flutter device and extension tests passed 66/66.
- Windows Host service and Setup Broker tests passed. One service-owner ACL integration check was skipped because the test process was not elevated.
- Windows Host payload, Flutter Windows release build, Setup Broker build, and Inno Setup installer compilation passed. Installer privilege-boundary contract checks passed.
- A later redundant Host security rerun was blocked during disposable-cluster startup after PostgreSQL became ready but before the test runner created its database. That isolated cluster was stopped and removed. The completed PostgreSQL suite results above came from the earlier successful disposable-cluster run.
- Full installer install/upgrade lifecycle validation is blocked because its script requires a clean elevated Windows machine. It was not run against the owner's Host.

The release is on `codex/extension-platform`, based on `c435894353b6035486e9e25ca19d64006ca7df20`. The versioned installer is `dist/windows/permission-provisioning-0.1.10-release/Ventio-Setup-0.1.10.exe`, SHA-256 `3a4c7dac0a119ad26c5fc8dd9b4f5401227969f61af1411f34de44166cf81bfb`.

No production Host was modified during implementation. The separate Crash Recovery verification gate and the owner-run physical acceptance checks remain open.

## Exact implementation files

- `docs/host-permission-provisioning.md`
- `installer/windows/host-service/FirstAdminBootstrapBroker.cs`
- `installer/windows/host-service/Program.cs`
- `installer/windows/setup-broker/Program.cs`
- `installer/windows/setup-broker.tests/Program.cs`
- `packages/ventio_host_api/bin/local_host.dart`
- `packages/ventio_host_api/bin/trusted_windows_pairing.dart`
- `packages/ventio_host_api/lib/src/extension_packages.dart`
- `packages/ventio_host_api/lib/src/host_api.dart`
- `packages/ventio_host_api/lib/src/postgres_extension_packages.dart`
- `packages/ventio_host_api/lib/src/role_administration.dart`
- `packages/ventio_host_api/lib/src/trusted_windows_pairing.dart`
- `packages/ventio_host_api/lib/ventio_host_api.dart`
- `packages/ventio_host_api/test/extension_package_integration.dart`
- `packages/ventio_host_api/test/first_admin_bootstrap_integration.dart`
- `packages/ventio_host_api/test/pairing_integration.dart`
- `packages/ventio_native_client/lib/src/device_management_page.dart`
- `packages/ventio_native_client/lib/src/extension_studio_page.dart`
- `packages/ventio_native_client/lib/src/host_setup_windows.dart`
- `packages/ventio_native_client/lib/src/native_english_messages.dart`
- `packages/ventio_native_client/pubspec.yaml`
- `scripts/ci/run-local-postgres-integration.ps1`
- `scripts/windows/build-host-payload.ps1`
- `scripts/windows/build-windows-installer.ps1`
- `scripts/windows/provision-host-installation.ps1`
- `scripts/windows/register-host-service.ps1`
- `scripts/windows/test-unified-installer-path-contract.ps1`
- `scripts/windows/upgrade-host-database.ps1`
- `scripts/windows/validate-unified-installer.ps1`
- `security/postgres/bootstrap.sql`
- `security/postgres/pairing.sql`
