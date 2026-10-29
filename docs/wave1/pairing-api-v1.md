# Secure Device Pairing API v1

**Status:** backend contract and integrated Flutter pairing/device-management screen are implemented; deterministic API/UI tests pass. PostgreSQL integration tests are present but NOT RUN. Docker remains stopped by user direction; the CI harness can use native PostgreSQL binaries without Docker, but the local pinned archive transfer was too slow to finish.

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

Enrollment rejects device IDs that resemble bearer tokens, including clients that bypass the Flutter UI. Authorized `identity.devices.manage` users can list device/credential lifecycle metadata and revoke a device through the separate management API. Device listing currently returns `lastAuthenticatedAtUtc: null`; connected state and authenticated-activity history are not yet available. Revocation stops every credential on that device, but a branch-scoped caller cannot revoke a device with an active credential ceiling outside that branch.

## Verification status

- `dart run test/api_tests.dart`: 65 passed, 0 failed; covers authentication, exact-scope permission, versioning, correlation, no-secret diagnostics, unauthenticated redemption contract, and source rate limiting.
- `dart run test/management_devices_api_test.dart`: 8 passed, 0 failed; covers exact-scope authorization, safe inventory projection, and revocation dispatch.
- Flutter `test/host_device_management_test.dart`: 7 passed, 0 failed; covers inventory, one-time pairing code handling, permission denial, redaction, error correlation, and UI user selection.
- Full Flutter package suite: 162 passed, 2 environment-gated skips; Flutter package analysis clean.
- `dart analyze` for `ventio_host_api`: passed.
- `test/pairing_integration.dart`: added for digest-only storage, target privilege ceiling, cross-branch non-disclosure, one-time redemption/replay/expiry, 30-day credential scope, device role, and audit/diagnostic redaction. It is intentionally NOT RUN while Docker remains stopped.
- Host administrators can create a code for an active scoped user, select that user from the Host user list when separately authorized, view registered devices and credential state, and revoke a device. The UI displays no connection state when Host activity telemetry is absent.
- Stage 4 is not accepted based on these local checks; restricted database grants, Recovery Authority, and PostgreSQL integration behavior remain unverified until the database suite runs. Credential rotation and authenticated activity history are still outstanding.
