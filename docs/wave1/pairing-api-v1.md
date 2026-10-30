# Secure Device Pairing API v1

**Status:** pairing, enrollment, device inventory, revocation, Host-authorized credential rotation, and scoped last-authenticated activity are implemented. Focused API/UI tests and native PostgreSQL integration pass. Run `93010324-1` passed 24/24; Docker remains stopped by user direction.

Pairing is a Host-authorized operation. Device role is descriptive metadata and grants no user permission. The Host fixes every authority-bearing value; clients cannot choose a device role, scope, permission, or credential lifetime.

## Create a pairing code

`POST /api/v1/management/pairing/create` requires a persistent bearer credential and the direct `identity.pairing.manage` permission within the exact company and branch. The target must be an active user visible in that branch. Their current effective branch permissions must be a subset of the caller's current branch permissions. The API derives tenant and creator identity from authentication.

Request:

```json
{
  "managementApiVersion": 1,
  "companyId": "company-001",
  "branchId": "branch-001",
  "actorId": "user-001"
}
```

Success is HTTP 201. The random 256-bit pairing code appears only in this response and expires after five minutes:

```json
{
  "apiVersion": 1,
  "managementApiVersion": 1,
  "correlationId": "cor_0123456789abcdef0123456789abcdef",
  "pairing": {
    "pairingId": "pair_0123456789abcdef0123456789abcdef",
    "actorId": "user-001",
    "deviceRole": "CLIENT",
    "code": "one-time-code-returned-once",
    "companyId": "company-001",
    "branchId": "branch-001",
    "expiresAtUtc": "2026-10-30T12:05:00.000Z"
  }
}
```

The PostgreSQL table stores only the SHA-256 digest of the pairing code. Pair issuance is limited to ten codes per creator, company, and branch in a fifteen-minute window. The code and digest are excluded from audit details and diagnostics.

## Redeem a pairing code

`POST /api/v1/pairing/redeem` is unauthenticated by design: possession of the short-lived code is the enrollment proof. Production network listeners require TLS at HostApi binding. The request is bounded, JSON-only, and subject to a ten-attempt per-source one-minute in-memory limit. The code is single-use and is consumed in the same admitted database transaction that creates the device and credential.

Request:

```json
{
  "managementApiVersion": 1,
  "code": "one-time-code-from-the-Host-administrator",
  "deviceId": "client-device-001"
}
```

Success is HTTP 201. The response contains the device-specific bearer credential once; clients must store it in platform-protected storage and must not log or export it:

```json
{
  "apiVersion": 1,
  "managementApiVersion": 1,
  "correlationId": "cor_0123456789abcdef0123456789abcdef",
  "enrollment": {
    "tenantId": "tenant-001",
    "actorId": "user-001",
    "deviceId": "client-device-001",
    "deviceRole": "CLIENT",
    "credentialId": "cred_0123456789abcdef0123456789abcdef",
    "companyId": "company-001",
    "branchId": "branch-001",
    "expiresAtUtc": "2026-11-29T12:00:00.000Z",
    "credential": "one-time-device-credential-returned-once"
  }
}
```

The credential lifetime is fixed at thirty days, matching the existing Host credential issuance ceiling. Its database record contains only a digest and one exact company/branch scope with the target user's permission snapshot at issuance. Pairing does not create grants or roles. Later authorization still comes from current Host identity state, bounded by the credential's stored scope ceiling.

Invalid, expired, or replayed codes all return HTTP 410 with `PAIRING_INVALID_OR_EXPIRED`, without distinguishing which condition occurred. Reused device IDs return `DEVICE_ALREADY_REGISTERED`. Every response contains a correlation ID. Audit records include the pairing/device identifiers and scope but never either bearer secret or its digest.

Enrollment rejects device IDs that resemble bearer tokens, including clients that bypass the Flutter UI. Authorized `identity.devices.manage` users can list device/credential lifecycle metadata, review the last successful authentication timestamp, rotate a single-scope credential, and revoke a device. The Host stores the activity summary in a dedicated owner-only table that grants no authority, has forced RLS, is inaccessible directly to runtime/API logins, and is excluded from Recovery Authority generation triggers. Updates are throttled to at most once per minute. The timestamp is informational and does not claim that a device is currently connected. Revocation stops every credential on that device, but a branch-scoped caller cannot revoke a device with an active credential ceiling outside that branch.

## Rotate a device credential

`POST /api/v1/management/devices/rotate-credential` requires a persistent bearer credential with `identity.devices.manage` permission for the exact company/branch. The Host verifies that the target device is active and that its current credential is restricted to exactly that same single branch. Multi-branch credentials cannot be narrowed or widened through rotation. The Host revokes the prior credential and writes a replacement digest and an audit event in the same database transaction.

Request:

```json
{
  "managementApiVersion": 1,
  "companyId": "company-001",
  "branchId": "branch-001",
  "deviceId": "client-device-001",
  "credentialId": "cred_0123456789abcdef0123456789abcdef"
}
```

Success is HTTP 200. The new 256-bit bearer is returned once with a fixed thirty-day expiry; only its digest is stored by PostgreSQL. The response includes tenant, actor, device, and exact scope metadata plus a correlation ID. The Flutter page holds the secret in memory, presents it once to the authorized operator, and lets them clear it. It is never sent back in a later request or included in logs, inventory, audit detail, or diagnostics. The old credential is rejected immediately after commit.

## Verification status

- `dart run test/api_tests.dart`: 66 passed, 0 failed; covers authentication, exact-scope permission, versioning, correlation, no-secret diagnostics, unauthenticated redemption contract, and source rate limiting.
- `dart run test/management_devices_api_test.dart`: 12 passed, 0 failed; covers exact-scope authorization, safe inventory projection, revocation, and rotation permission/scope checks.
- Flutter `test/host_device_management_test.dart`: 11 passed, 0 failed; covers inventory, one-time pairing code handling, permission denial, redaction, error correlation, authorized rotation request, confirmation, one-time display, and last-authenticated activity display.
- Full Flutter package suite: 162 passed, 2 environment-gated skips; Flutter package analysis clean.
- `dart analyze` for `ventio_host_api`: passed.
- `test/pairing_integration.dart`: native PostgreSQL run `93010324-1` passed 24/24, covering digest-only storage, target privilege ceiling, exact-scope enrollment, authentication/activity recording, unchanged Recovery Authority generation, one-time authorized credential rotation, previous-token rejection, refusal of multi-branch rotation, revocation, expiry/replay, and redaction.
- Host administrators can create a code for an active scoped user, select that user from the Host user list when separately authorized, view registered devices and credential status plus last successful authentication time, revoke devices, and rotate a single-scope credential. Flutter `test/host_device_management_test.dart` passes 11/11 including activity display and one-time secret display.
- Stage 4 passed its focused gate. Broader Wave 1 database authorization, diagnostics, offline propagation and physical-device gates remain open. Docker stays stopped.
