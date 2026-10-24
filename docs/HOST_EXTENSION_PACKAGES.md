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
returning it. This route can return an older approved release for installation
or review; a revoked version is unavailable to future reads.

`POST /api/v1/extensions/approved` requires the same exact-scope read grant and
returns at most 50 approved summaries per request. Clients continue with the
last `(moduleId, version)` pair; both cursor fields must be supplied together.
The query is tenant-bound, keyset-paginated, and backed by a partial approved
registry index. Summaries contain identity, display name, description, and the
immutable package digest, never package JSON. Before installing a selection the
client fetches that exact version through `/read` and requires its verified
digest to match the summary, so a changed or revoked release cannot silently
replace the selected artifact.

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

The highest approved release is the only release that can query or mutate live
records. A newer approved release makes all earlier releases return
`UPGRADE_REQUIRED`; a newer revoked release blocks older releases with
`EXTENSION_REVOKED` instead of silently restoring them. Package bytes for older
approved releases remain available as immutable history, but their metadata
cannot authorize runtime access. Runtime requests hold a shared per-tenant,
per-module release lock, while approval and revocation hold its exclusive form,
so a release change is ordered before or after every in-flight query or command.
New commands authored against a superseded release are rejected. An identical
retry of a command that the Host had already accepted still returns its saved
receipt before the stale-release gate, preserving idempotency after an
upgrade. Automatic command upcasting or merging is not implemented; the client
must upgrade its package and resolve any rejected local draft.

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

The Flutter Builder can submit local bundles as Host candidates and browse the
scoped approved registry. It fetches a selected immutable release, verifies its
digest, and installs it as a device-local draft until explicitly activated.
Dynamic DocType records can be queried, changed offline through durable generic
commands, and reconciled from Host receipts. The Host remains authoritative;
local installation and metadata declarations never confer package approval or
Host grants. Background registry polling and automatic package upgrades are not
implemented.
