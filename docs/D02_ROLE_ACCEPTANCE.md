# D02 Scoped Roles and Assignments Acceptance Evidence

Date: 2026-10-27

## PostgreSQL-backed role administration

- Used the temporary PostgreSQL 17.11 `ventio_host_test` database with SCRAM-authenticated `ventio_runtime_test` and `ventio_admin_test` connections.
- Ran `dart run test/role_administration_integration.dart` from `packages/ventio_host_api`.
- Result: **16 passed, 0 failed**.

The HTTP/API integration verifies exact-scope manager access, denial to a regular data reader, rejection of company/branch cross-products, direct role creation, scoped assignment, permission grant and role metadata changes, prohibition on delegating `identity.roles.manage`, and refusal to change a shared role unless the manager has direct authority in every affected branch. Effective role permissions reach an assignee only at the assigned branch; assignees cannot administer identities. Removing the direct manager grant takes effect on the next request.

The test queries `ventio_identity_audit` and verifies durable role creation, rename, permission-grant, and assignment entries. Assignment evidence includes the exact role, actor, company and branch; all role audit entries identify the database actor.

## Related identity verification

The D01 PostgreSQL identity integration passed **79/79** and independently verifies scoped role-derived permissions on Host commands, credential permission ceilings, non-cross-product company/branch grants, and role/permission revocation effects.

No production credential is included in the evidence. The temporary PostgreSQL server was stopped after testing.
