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

No table or data migration is added. The versioned Host payload adds two idempotent security-definer functions to `security/postgres/pairing.sql`, installs their narrow grants, and verifies their definitions and ACLs during upgrade. The existing pairing function is re-applied idempotently as part of the same contract.

The existing Windows upgrade path stops the Host service, creates and verifies a restricted PostgreSQL data backup, applies schema migrations, installs the security contract, validates the migration ledger and function ACLs, and only then restarts the Host. A failed backup, migration, or contract verification leaves `VentioHost` stopped. PostgreSQL remains available for recovery. Neither the installer nor this workflow resets the database, devices, credentials, certificates, or Recovery Authority state.

Existing credentials and devices are preserved. Their permission ceilings are not changed by upgrade or a later grant. New Client credentials use the selected exact permission set. Operators should keep earlier devices until the replacement Client has been verified, then revoke a superseded or unused device through the existing device administration workflow when policy calls for it.

## Owner deployment and acceptance procedure

1. Copy `dist/windows/permission-provisioning-0.1.10-release/Ventio-Setup-0.1.10.exe` to the physical Host. Its SHA-256 is `3a4c7dac0a119ad26c5fc8dd9b4f5401227969f61af1411f34de44166cf81bfb`; verify it before running Setup.
2. Run Setup on the Host and accept the existing-installation upgrade. Keep the Host powered and allow Setup to finish its backup, database contract update, validation, and service restart. Do not select uninstall or data removal. If Setup reports an upgrade failure, leave `VentioHost` stopped and preserve the generated backup for recovery; do not edit PostgreSQL security tables by hand.
3. Verify the Host services and Host Readiness. Confirm Database, Schema, and Recovery Authority are READY and that the existing tenant, company, branch, certificates, registered devices, and Recovery Authority remain present.
4. In the Host application, sign in as the authorized administrator and select tenant `a`, company `b`, branch `c`. In **Users & permissions**, grant only `extension.package.read` to the intended target user, directly or through a narrowly scoped role. The UI should explain that the existing credential remains ceiling-limited.
5. In **Host devices & pairing**, select that exact user and scope, choose **Create trusted scoped pairing**, and leave only `extension.package.read` in the requested permission list. Confirm the displayed ceiling. Approve the Windows UAC prompt with a local administrator. If the operator credential lacks `identity.pairing.manage` in this exact branch or the target lacks the permission, the Host must reject the request.
6. On the intended physical Client, enroll using the one-time code before it expires. Verify the enrolled user's tenant, company, branch, and permission ceiling. The request above must produce a credential containing only `extension.package.read` for tenant `a`, company `b`, branch `c`.
7. From that Client, call `POST /api/v1/extensions/approved`. It should succeed without HTTP 403 when an approved package exists and is visible to that exact scope. A Client with no grant, a different scope, or a credential without the permission must still be denied.
8. Continue the separate physical acceptance: install an approved declarative extension, create an offline SQLite record, restart the Client and verify durable Pending state, synchronize through the real Host PostgreSQL path, confirm Host acceptance, and verify that record from another authorized Client. Keep the Crash Recovery verification gate separate until it passes.

These steps provision permission for the intended new Client only; they do not give every Client the administrator's full authority. Physical acceptance remains pending until the owner completes and records these checks on the real Host.

## Verification record

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
