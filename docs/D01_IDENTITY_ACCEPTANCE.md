# D01 Persistent Identity and Authentication Acceptance Evidence

Date: 2026-10-27

## PostgreSQL-backed Host verification

- PostgreSQL 17.11 ran from a temporary user-owned directory on loopback only.
- Applied the repository migration set and the PostgreSQL security bootstrap twice, then created the dedicated runtime, identity-administration, and migration test logins.
- Changed temporary loopback host authentication to SCRAM-SHA-256 and verified the runtime connection reports `current_user = ventio_runtime_test`.
- Ran `dart run test/identity_integration.dart` from `packages/ventio_host_api` with the disposable `ventio_host_test` database and the explicit database-test opt-in.
- Result: **79 passed, 0 failed**.

Coverage includes random opaque credential issuance and digest-only persistence; invalid/malformed token denial; server-authoritative actor, device, tenant and scope identity; client claim forgery rejection; exact company/branch permission binding; expiration and credential/device/user revocation; stale HTTP-session rechecks before command execution and receipt replay; audit atomicity and redaction; fail-closed database errors; separate Host-process restart/recovery; and idempotent business effects.

## Client and static verification

- `dart analyze .` in `packages/ventio_host_api`: no issues.
- `flutter test test/host_credentials_test.dart`: **4 passed** (origin-scoped storage, loopback-only plain HTTP, endpoint validation, and opaque token shape).

The temporary PostgreSQL process was stopped after verification. No token or database password is recorded in this evidence file.
