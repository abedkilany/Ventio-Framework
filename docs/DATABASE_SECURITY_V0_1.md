# Database security hardening and least-privilege access

## Scope and trust model

The persistent Host now requires a restricted PostgreSQL runtime login. The
previous CI used its disposable database superuser for operational traffic; this
was never a least-privilege deployment. The new profile separates schema ownership,
Host operation and audited identity administration. The entire persistent identity
suite is now run with real restricted runtime and administrator logins. Bootstrap
fixture queries retain the disposable superuser solely for test setup, deliberate
fault injection and verification. No live database or legacy Ventio app is used.

This is a dedicated Ventio Framework database profile, not a script for an
existing shared database. Public/LAN API binding remains disabled. The local
launcher validates its connection before opening a listener, and every persistent
authentication/execution connection checks its profile again. Superusers, owners,
BYPASSRLS roles, excess memberships, extra identity ACLs, unexpected update/delete,
DDL and temporary-object privileges are rejected. The check does not substitute
for database enforcement: private tables also have forced default-deny RLS for
non-owner roles, and operational tables enforce scope through RLS.

## Role boundaries

| Role | Purpose | Authority |
| --- | --- | --- |
| `ventio_owner` | Non-login schema/function owner | Trusted DDL and private function implementation; never used by Host |
| `ventio_migrator` | Non-login migration capability | May explicitly `SET ROLE ventio_owner`; does not inherit ownership automatically |
| `ventio_identity_admin` | Non-login server maintenance capability | EXECUTE `admin_change(jsonb)` only; no direct identity/business DML or schema modification |
| `ventio_runtime` | Non-login operational capability | Auth resolution, RLS checks, scoped SELECT/INSERT on operational tables and UPDATE of journal receipt only |

Create separate private login credentials and grant each exactly one capability
role. Runtime logins must be NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE
NOREPLICATION, with no extra role memberships, CREATE or TEMP privileges. They
must not own databases, tables, schemas or functions. No capability has GRANT
OPTION. Identity administration is a server-wide maintenance authority, not a
self-service tenant administrator API. Its operator label is descriptive; the
actual authenticated `session_user` is always captured by the database audit.

Runtime cannot read credential hashes, edit users/devices/grants, issue tokens,
erase audit, execute administrative/private helpers, run migrations, change table
ownership or policies, truncate tables, or assume an administrator/owner role.
Identity administration goes through one vetted SECURITY DEFINER entry point. Its
user lock, state change and audit insert are one database transaction; audit
failure rolls back the change. Raw silent administrative DML is denied even to the
administration login. Issuance still returns a random raw token once from Dart;
the database receives only its digest and public credential identifier.

All definer functions are owned by the non-login owner, use an explicit trusted
search_path with pg_temp last, fully qualify application tables, and execute static
parameterized SQL. PUBLIC execute is revoked atomically during installation.
Runtime/admin cannot create shadow functions or temporary objects. Default PUBLIC
function/table/sequence privileges are revoked for future owner-created objects.

## RLS enforcement

`FORCE ROW LEVEL SECURITY` is enabled on all four operational tables. Policies
check tenant/company/branch and current stored identity/grants; writes also bind
command, actor/device where present, operational DocType and aggregate ID. The
runtime cannot update business records or rewrite journal identity/fingerprints.
It can update only the journal's receipt column for its current scoped command.
Approved Maintenance/Inspection command bindings live in a protected owner-only
table; new trusted module bindings require a reviewed owner deployment, not a
Client manifest changing database authorization. Journal reads support the
engine's existing same-scope dependency semantics; journal/event access is not a
complete per-field confidentiality model.

Identity tables, security audit, migration ledger and binding metadata also force
RLS, with an explicit owner-only policy and no runtime/admin row policy. This
provides a second denial layer if an individual table/column ACL is accidentally
broadened. The Host profile check additionally rejects that configuration.

### Request context is not authority

A free-form tenant GUC is unsafe as an authorization boundary. This profile does
not trust one. `resolve_identity` binds transaction-local company/branch, command
and confidential credential-digest proof settings. These settings remain
user-settable by PostgreSQL design. Every policy therefore revalidates the proof
against the current stored credential, user/device status, wall-clock expiry and
exact company/branch grant tuple under the same authorization locks. Setting an
arbitrary tenant, actor, scope or digest cannot create a missing stored grant.
No custom cryptographic signing or permanent context rows are required.

The digest is a confidential internal database proof handle, not a public API
credential. Runtime has no direct SELECT on stored digests. Never log, expose or
reuse handles as user-visible tokens. A database login plus an already valid proof
can authorize SQL within that identity's actual grants. SQL policies do not infer
identity from Client JSON or from the database login alone. The HTTP interface
continues to require the raw opaque token and hashes it server-side.

Conflicting command IDs hidden by another branch's RLS are rejected without
returning that branch's receipt. Normal same-envelope retries remain stable.

Context is local to the transaction, explicitly cleared before reauthentication,
and revalidated rather than cached. Tests cover missing/forged context, scope
mixing, expired/revoked proof and savepoint rollback followed by permission
withdrawal. A copied proof context cannot retain a removed permission. Definer
identity reads acquire the same user/device/credential/grant locks as before;
revocation ordering and deterministic durable retry behavior remain intact.

## Install and operate

Use a newly provisioned dedicated database and reviewed deployment credentials.
No installation is performed against a user's database automatically.

1. Apply ordered migrations 001-011 with a trusted initial database owner.
2. As the trusted bootstrap/cluster operator, run `security/postgres/bootstrap.sql`
   using psql `-v expected_database=YOUR_DEDICATED_DATABASE`. Database-name
   confirmation is mandatory. Installation is transactional and rerunnable;
   it transfers only the explicitly listed Framework objects, installs policies
   and functions, and revokes PUBLIC database CONNECT/CREATE/TEMP privileges.
3. Provision three distinct private LOGIN roles and grant the corresponding
   runtime, identity-administration or migrator capability. Configure SCRAM and
   secure credential delivery outside source control. Use TLS verification for
   remote PostgreSQL; fixture passwords/sslmode=disable are CI-only.
4. Set the local Host's `VENTIO_HOST_DATABASE_URL` to the runtime login only.
   Use the separate administration connection with `IdentityAdministration`.
   Never pass either URL to Clients or put operator credentials in Host config.
5. For later migrations, use the migration URL as `VENTIO_DATABASE_URL` and
   explicitly set `VENTIO_MIGRATION_ROLE=ventio_owner` for the migration CLI.
   Run the reviewed bootstrap/profile upgrade after relevant schema or trusted
   command-binding changes. Do not assume future objects automatically receive
   runtime grants/policies. Verify the profile and integration suites before use.

`security/postgres/test_logins.sql` is a separately guarded disposable
`ventio_host_test` fixture only. It must never provision deployment credentials.
The legacy explicit development launcher/test engine does not provide this runtime
profile and must not be used as the deployment entry point. `local_host.dart` is
the persistent, checked, loopback-only assembly.

## Deliberate limits

- PostgreSQL superusers/BYPASSRLS roles and trusted owners/migrators can bypass or
  alter policy. They are outside the runtime threat boundary. RLS is not protection
  against a compromised DBA, restored stale backups or a malicious migration.
- An explicitly overpowered role membership granted by a DBA changes that role's
  authority. The Host refuses it, but no application check can remove the DBA's
  ability to grant privileges. Keep operator/migration credentials separate.
- RLS is not business validation. SQL with a valid scoped proof can insert allowed
  operational data without DocType field validation or a complete record/journal/
  audit/outbox transaction. A test demonstrates this limit rather than claiming
  otherwise. API traffic must continue through DurableCommandHost and its current
  authorization checks. Full DB-level business execution would need a separately
  designed trusted command procedure, not just RLS policies.
- Unique/FK checks and generic database errors can reveal constraint conflicts;
  RLS does not promise zero existence side channels. Host responses redact raw
  database diagnostics. Payload JSON and receipt semantics remain Host-owned.
- Every policy rechecks/locks identity state. This slice proves correctness, not
  production throughput. Pooling, rate limits, monitoring, restore/crash tests,
  external TLS/enrollment and audited production deployment remain open gates.
- RLS may reject a credential that expires between Host authorization and a later
  SQL statement. The transaction rolls back; no false success is returned. The
  subsequent request must authenticate again.

PostgreSQL references checked: official version 16 documentation for row security,
GRANT, explicit locking and SECURITY DEFINER search_path/default execution grants.
- https://www.postgresql.org/docs/16/ddl-rowsecurity.html
- https://www.postgresql.org/docs/16/sql-createfunction.html
- https://www.postgresql.org/docs/16/sql-grant.html
