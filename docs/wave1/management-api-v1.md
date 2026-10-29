# Host Management API Contract v1

**Status:** implemented readiness, pairing create/redeem contracts, and safe diagnostic event contracts. Device inventory, revocation/rotation, synchronization, and broader administrative APIs remain subsequent work.
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

Unexpected Host API failures are recorded in a bounded, process-local buffer as `ManagementDiagnosticEvent` contracts using safe codes and user guidance. Raw exception text and request bodies are not retained. The buffer is not durable and is not remotely queryable in this stage; the Diagnostics Center will add an authorized, sanitized presentation in Stage 6.

## Shared management contracts

`ventio_core/src/management_contracts.dart` defines versioned, Flutter-independent types for readiness snapshots, diagnostic categories/severity, device roles, device registration, credential lifecycle, pairing lifecycle, synchronization summary, and administrative operation state. Credential and pairing inventory projections intentionally contain no bearer token, digest, or one-time pairing code. `HostDeviceRole` is descriptive infrastructure metadata; it grants no user permission.

`POST /api/v1/management/pairing/create` and `POST /api/v1/pairing/redeem` are active. Their versioned request/response and security behavior are documented in [pairing-api-v1.md](pairing-api-v1.md). Other routes reserved in the shared contract file are not active merely because a route constant exists. The PostgreSQL integration suite for pairing has been added but has not been run; local API contract tests do not prove SQL grants, RLS, recovery admission, or replay behavior.

## Authorization and operational boundaries

- `host.status.read` is checked against the authenticated principal's exact company/branch grant for every readiness request.
- `identity.pairing.manage` is required directly in the exact branch to create a pairing code. PostgreSQL independently rechecks this permission against the caller credential's exact scope ceiling.
- Device registration role (`HOST` or `CLIENT`) is not an authorization input.
- User and role administration use their dedicated exact-scope permissions and restricted database gateway. Pair creation and redemption use the dedicated pairing contract. Device inventory, revocation/rotation, and host-local bootstrap/service operations are not exposed by these routes; protected operator and Recovery Authority paths remain in force.
- No management request accepts an operating-system command, process path, shell string, SQL statement, database URL, or recovery witness value.
- The readiness contract deliberately does not bypass persistent authentication. If recovery admission prevents authentication, an authenticated remote readiness body cannot be produced; the local Diagnostics Center must explain that failure using safe local evidence.
