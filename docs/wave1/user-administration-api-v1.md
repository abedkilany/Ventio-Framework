# Scoped User Administration API v1

**Status:** implemented in the persistent Host API and available only when the dedicated identity-administration database profile is configured.
**Authorization:** direct `identity.users.manage` grant and credential ceiling for the exact company/branch pair, revalidated by PostgreSQL in the admitted transaction.
**Version:** every request body and successful response carries `managementApiVersion: 1`.

## Routes

All routes are authenticated `POST` requests under `/api/v1/management/users/`.

| Route | Additional request fields | Operation |
|---|---|---|
| `list` | none | List users with a grant, role assignment, or scoped creation audit in this exact branch. |
| `create` | none | Create a new user with no grants or role assignments. Host generates an opaque actor ID so callers cannot probe tenant-global IDs across branches. |
| `grant` | `actorId`, `permission` | Grant a normal permission directly to a user in this exact branch. |
| `revoke` | `actorId`, `permission` | Revoke a direct grant in this exact branch. |
| `disable` | `actorId` | Disable a user only when it is not the caller and has no direct grants, role assignments, or active credential scopes outside the requested branch. |

Every request includes:

```json
{
  "managementApiVersion": 1,
  "companyId": "company-001",
  "branchId": "branch-001"
}
```

The Host derives tenant, actor, device, credentials, and permissions from persistent authentication. Additional caller fields are rejected. Device role is not read by these authorization checks.

## Successful responses

`list` wraps a scoped inventory in the `users` property:

```json
{
  "apiVersion": 1,
  "managementApiVersion": 1,
  "correlationId": "cor_0123456789abcdef0123456789abcdef",
  "users": {
    "tenantId": "tenant-001",
    "companyId": "company-001",
    "branchId": "branch-001",
    "items": [
      {
        "actorId": "technician-001",
        "state": "ACTIVE",
        "directPermissions": ["maintenance.read"],
        "roles": []
      }
    ]
  }
}
```

Grant, revoke, and disable return:

```json
{
  "apiVersion": 1,
  "managementApiVersion": 1,
  "correlationId": "cor_0123456789abcdef0123456789abcdef",
  "userOperation": {"status": "APPLIED"}
}
```

Create returns the generated ID to the authorized caller only:

```json
{
  "apiVersion": 1,
  "managementApiVersion": 1,
  "correlationId": "cor_0123456789abcdef0123456789abcdef",
  "userOperation": {
    "status": "APPLIED",
    "actorId": "usr_0123456789abcdef0123456789abcdef"
  }
}
```

All responses include the matching `X-Correlation-ID` header. Errors use the shared Host error envelope with stable codes and never return SQL exception text.

## Security and persistence

- User reads run through `ventio_security.identity_users_snapshot` using the restricted runtime connection. The function returns only users with grant, role, or scoped identity-audit activity in the exact branch, including their branch-local direct permissions and role projections.
- Mutations run through `ventio_security.scoped_user_admin_change`, not the broad trusted-local `admin_change` surface. PostgreSQL locks identity changes, validates the live user/device/credential, checks the dedicated direct grant and credential scope ceiling, and requires Recovery Authority admission before changing state.
- The credential ceiling must contain `identity.users.manage` for the exact requested pair; a permission inherited from a role does not satisfy the direct-grant check.
- `identity.*`, `host.*`, `system.*`, `security.*`, `recovery.*`, and `authorization.*` permissions are reserved and cannot be delegated by these routes. Role administration also rejects those namespaces, and identity resolution does not derive them from legacy role rows. Domain permissions such as `extension.foo.item.manage` remain valid.
- User creation records its company/branch in the existing administrative audit event, making the unprivileged account visible to that branch's manager while keeping it out of other branch inventories.
- Actor IDs are tenant-global. Create never accepts a caller-supplied actor ID; PostgreSQL generates a random ID in the recovery-admitted transaction and returns it only to that caller. Grant, revoke, disable, and list paths return the same scoped not-found result for a missing ID and an ID active only in another branch.
- Disablement is refused if any direct grant, role assignment, or active credential ceiling crosses the exact company/branch boundary. The route also refuses self-disable.
- The persistent Host API database login is checked for least privilege, database ownership, raw mutation/reset function access, and direct table, sequence, or unrelated function access. It cannot invoke `admin_change` or recovery reset. The trusted local CLI keeps its separate `ventio_identity_admin` profile and DSN.
- Migration `025_identity_audit_scope_index.sql` adds an exact-scope recent-event index for the bounded administrative audit query; it preserves existing audit rows. The scoped functions are installed by the PostgreSQL security bootstrap.
- The Host's persistent API connection uses `VENTIO_HOST_IDENTITY_API_DATABASE_URL`, a distinct `ventio_identity_api` profile with only the scoped mutation functions plus Recovery Authority admit/snapshot calls. The broad trusted local identity-admin URL is rejected by the persistent launcher and remains confined to the private local operator workflow.
- `IdentityAdministration.bootstrapFirstAdministrator` is a trusted local bootstrap primitive, not an HTTP route. PostgreSQL accepts it only through `admin_change` for a `ventio_identity_admin` member, only while the tenant has no user, and only inside a Recovery Authority transaction. It creates one opaque user, a branch-bound device credential, and a fixed direct Host-management grant set. The raw token is returned once to the trusted caller; only its digest and exact scope are stored. Windows production must invoke it through a fixed-operation broker running as the pinned Recovery Authority owner; an interactive setup process cannot impersonate that SID.

## Verification

- `dart run test/management_users_api_test.dart` exercises routing, exact scope, contract versioning, reserved permissions, correlated errors, and unauthorized-user denial without PostgreSQL.
- `dart run test/management_users_integration.dart` requires the disposable `ventio_host_test` PostgreSQL database and explicit `VENTIO_ALLOW_DATABASE_TESTS=yes` opt-in. It verifies restricted API versus trusted-local database profiles, scoped reads and writes, direct-grant and credential-ceiling revalidation, cross-branch non-disclosure, disablement restrictions, and sanitized durable audit. The CI Host API workflow runs it after installing both database profiles.
