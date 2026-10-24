# Host extension package registry

## Trust boundary

The Host stores validated extension metadata in a tenant-scoped PostgreSQL
registry. Runtime submissions are candidates only. The registry accepts bounded
JSON bundles that pass `ExtensionBundle` validation; bundles cannot carry
commands, capabilities, scripts, SQL or executable handlers. Submissions do not
grant the package's permission keys to any user.

`POST /api/v1/extensions/submit` requires a persistent Host credential and the
exact company/branch grant `extension.package.submit`. The Host re-resolves the
credential and grant inside the PostgreSQL transaction before storing the
candidate. Repeating the same module, version, digest and content is idempotent;
reusing that version for different content is a conflict.

`POST /api/v1/extensions/read` requires `extension.package.read` in the exact
company/branch scope and returns only a release with `APPROVED` status. The Host
validates the returned metadata and recomputes its canonical SHA-256 before
returning it. Revoked versions are unavailable to future reads.

`GET /api/v1/session` lets an authenticated client discover its tenant, device,
and current exact company/branch permission grants. The response contains no
credential material; the Builder uses it to offer valid Host scopes.

## Approval and recovery

Shared approval is a trusted local operator action, not a permission an
extension or ordinary device can grant itself. The operator tool reads the
submitted candidate through a restricted database function, validates it with
the same Core parser, checks the submitted digest, and invokes the protected
administration function. Approval requires every declared dependency to have a
compatible Host-approved version and requires a strictly newer release than any
previously approved or revoked release of that module. Revocation requires a
reason and is permanent for that version; publish a newer version to restore an
extension.

The operator action writes the package state and an audit event in the same
PostgreSQL transaction. Approved/revoked release state and its audit events are
part of the recovery fingerprint. The independent witness is marked pending
before the transaction and advanced only after the commit is acknowledged. A
missing or stale witness leaves Host admission closed; use the documented
re-enrollment procedure rather than rebuilding witness state from a database
backup.

The package tables have forced row-level security and no direct runtime or
identity-admin table grants. Runtime transfer uses narrow security-definer
functions, which re-resolve exact-scope grants. Operator access uses a separate
restricted security-definer review/action path. Runtime users cannot approve,
revoke, query candidates, or change package bytes.

## Operator requests

`packages/ventio_host_api/bin/identity_admin.dart` accepts a private request-file
path. For `approve-extension`, provide `tenantId`, `moduleId`, `version`, and the
candidate `packageSha256`; for `revoke-extension`, also provide `reason`. Every
request also needs the standard private `authorityFile`, `operatorLabel`, and
administration database URL settings. On Windows, run the tool as the trusted
witness writer and include the configured `witnessReaderSid`. Do not put request
JSON, database URLs, tokens, or credentials on the process command line or in
the repository.

## Current boundary

The Flutter Builder can submit local bundles as Host candidates and fetch only
Host-approved releases after authenticating and selecting an exact scope. An
installed package stays a device-local draft until explicitly activated. The
Host command engine still handles only explicitly bound trusted commands, and
dynamic DocType records still use the local store. Record synchronization and
multi-device conflict resolution are not implemented.
