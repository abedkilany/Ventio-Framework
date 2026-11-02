# Host Management API Contract v1

**Status:** readiness, pairing, scoped device inventory/revocation/credential rotation, scoped user and role administration (including user enable/disable), safe diagnostic events, and authenticated diagnostic-history retrieval are implemented. Their API and disposable PostgreSQL integration contracts have local Windows evidence. A synchronization-summary management route is not active merely because its shared contract exists; command receipts remain the Host authority for synchronization.
**API paths:** under `/api/v1`; management payloads carry `managementApiVersion: 1`.
**Compatibility:** existing `/healthz`, `/api/v1/session`, command and extension routes retain their existing payloads. Every response now also carries an `X-Correlation-ID` response header.

## Process liveness

`GET /healthz` remains unauthenticated process liveness only. It does not claim PostgreSQL, schema, recovery, identity, pairing, or synchronization readiness. The response body remains compatible with existing probes.

## Authenticated readiness

`POST /api/v1/management/readiness` requires a persistent Host credential and a direct `host.status.read` grant for the exact requested company/branch pair. The body is:

```json
{
  "managementApiVersion": 1,
  "companyId": "company-001",
  "branchId": "branch-001"
}
```

The Host derives tenant, actor, device, credential and current grants from authentication. The caller cannot submit identity or permission claims. The route returns the Host API version plus a timestamped status for the API, database connection, approved schema/runtime profile, and Recovery Authority admission. It returns only stable component names, state values and bounded reason codes. It never returns connection details, table names, SQL errors, witness data, credential identifiers, or secret material.

The persistent launcher uses the restricted runtime pool for a read-only `SELECT 1`, `ventio_security.assert_runtime()` (which verifies the approved schema manifest and least-privilege profile), and a transaction-bound Recovery Authority admission check. The readiness probe does not repair migrations, reset a witness, or mutate identity state. External listeners accept only an `AuthoritativeHostReadinessProvider`.

The route returns HTTP 200 with `overallState` (`READY`, `DEGRADED`, `UNAVAILABLE`, or `UNKNOWN`) when the authenticated readiness operation itself completes. Authentication, authorization, and infrastructure failures retain the API's existing 401/403/503 behavior. Local `/healthz` remains available when authentication cannot be completed; callers should correlate the failure using the response header.

## Correlation and error contract

The Host generates a fresh, unguessable `cor_<32 lowercase hex>` identifier for each HTTP request and returns it in `X-Correlation-ID`. Error JSON now includes that same value at the top level alongside the existing versioned `error` object:

```json
{
  "apiVersion": 1,
  "correlationId": "cor_0123456789abcdef0123456789abcdef",
  "error": {
    "code": "HOST_UNAVAILABLE",
    "messageKey": "host_api.error.host_unavailable",
    "message": "Outcome may be unknown. Retry the identical command.",
    "retryable": true
  }
}
```

Existing clients may ignore the added response header and error field. Error codes, status codes, receipt formats and command IDs remain authoritative as before. The client must reuse a command ID after an ambiguous command outcome.

Unexpected Host API failures are recorded through the configured `ManagementDiagnosticSink` as safe `ManagementDiagnosticEvent` contracts. The default development/test sink is a bounded process-local buffer. The persistent Windows Host launcher uses the protected durable ring log; it stores safe structured fields and protected technical context under Host-owned private-file controls. Raw exception text and request bodies are not retained. The authenticated history route returns only sanitized fields; full Diagnostics Center acceptance remains tracked separately in Stage 6.

## Shared management contracts

`ventio_core/src/management_contracts.dart` defines versioned, Flutter-independent types for readiness snapshots, diagnostic categories/severity, device roles, device registration, credential lifecycle, pairing lifecycle, synchronization summary, and administrative operation state. Credential and pairing inventory projections intentionally contain no bearer token, digest, or one-time pairing code. `HostDeviceRole` is descriptive infrastructure metadata; it grants no user permission.

`POST /api/v1/management/devices/list` and `/revoke` require a persistent Host credential with direct `identity.devices.manage` permission in the exact requested company/branch. Inventory includes registration state, descriptive device role, registration timestamp, credential IDs/status/expiry/revocation timestamps and nullable `lastAuthenticatedAtUtc`. Migration 029 and the authentication hook record throttled last-authentication activity in a separate forced-RLS owner-only table; activity does not imply current connectivity and updates do not mutate Recovery Authority state. Inventory never includes bearer credentials or digests. Revocation is performed by a scoped PostgreSQL function under Recovery Authority admission; it revokes every credential for the selected device and is denied if an active credential scope extends beyond the requested branch.

`POST /api/v1/management/pairing/create`, `POST /api/v1/pairing/redeem`, device management, and the scoped user/role administration routes are active when authoritative gateways are configured. User administration includes create, direct grant/revoke, disable and enable; enabling preserves branch-local grants and only reactivates credentials that have not expired or been revoked. Pairing behavior is documented in [pairing-api-v1.md](pairing-api-v1.md); user contracts are in [user-administration-api-v1.md](user-administration-api-v1.md). Other routes reserved in the shared contract file are not active merely because a route constant exists. Latest disposable Windows PostgreSQL 16.15 run `20261102174121596-1` passed database security 118/118, user administration 40/40, role administration 20/20, and pairing/device lifecycle 24/24 (**202/202 total**). Focused user lifecycle rerun `20261101222210370-1` passed 40/40 after including the re-enable audit projection. Separate isolated runs passed persistent HTTP/PostgreSQL command integration 34/34 and Recovery Authority/first-administrator integration 11/11. These suites cover SQL grants, forced RLS, Recovery Authority admission, exact-scope denial, credential lifecycle, replay and audit redaction; live Flutter-to-running-Host UI acceptance passed under Stage 5, and installer/device lifecycle acceptance remains open in Stages 8 and 10.

## Authenticated diagnostic history

`POST /api/v1/management/diagnostics/recent` requires a persistent Host credential and a direct `host.diagnostics.read` grant for the exact requested company/branch pair. The request carries `managementApiVersion`, `companyId`, `branchId`, and a `limit` from 1 through 100. The Host returns only safe diagnostic event fields, newest first, with the request correlation ID. It omits protected SQLSTATE, exception type/source, credentials, connection settings, and any raw exception text. A missing readable diagnostic sink returns `HOST_DIAGNOSTICS_UNAVAILABLE`; callers without the dedicated grant receive `PERMISSION_DENIED`.

The route has local contract coverage for authorization denial, branch-scope denial, bounded pagination, correlation, and omission of protected technical details. Database-backed administration/security suites do not currently verify diagnostic history because its reader is an OS-protected local Host facility.

## Authorization and operational boundaries

- `host.status.read` is checked against the authenticated principal's exact company/branch grant for every readiness request.
- `host.diagnostics.read` is a separate direct exact-scope permission for diagnostic history; it does not grant readiness, user, role, device, or pairing administration.
- `identity.pairing.manage` is required directly in the exact branch to create a pairing code. PostgreSQL independently rechecks this permission against the caller credential's exact scope ceiling.
- `identity.devices.manage` is a separate direct exact-scope grant for listing and revoking devices. Pairing does not grant it, and role/device metadata does not imply it.
- Device registration role (`HOST`, `CLIENT`, or legacy `UNKNOWN`) is not an authorization input.
- User, role and device administration use dedicated exact-scope permissions and restricted database gateways. Pair creation and redemption use the dedicated pairing contract. Credential rotation and host-local bootstrap/service operations remain outside these routes; protected operator and Recovery Authority paths remain in force.
- No management request accepts an operating-system command, process path, shell string, SQL statement, database URL, or recovery witness value.
- The readiness contract deliberately does not bypass persistent authentication. If recovery admission prevents authentication, an authenticated remote readiness body cannot be produced; the local Diagnostics Center must explain that failure using safe local evidence.
