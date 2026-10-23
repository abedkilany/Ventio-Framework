> Historical stage evidence. Current launcher settings, separate OS witness ownership, schema compatibility and witness upgrade requirements are defined in [Host operations](HOST_ENGINE_V0_1_OPERATIONS.md). See the [final engineering audit](HOST_ENGINE_V0_1_FINAL_ENGINEERING_AUDIT.md) for the current acceptance boundary.

# Host API and Authentication: scoped implementation

## Boundary decision

Use the Dart SDK's `dart:io` HttpServer for two small routes, with separate
routing, identity-provider and command-executor contracts. This adds no HTTP
framework dependency and leaves Core independent of networking and PostgreSQL.
The tradeoff is responsibility for explicit body/admission limits and future
transport hardening. Reevaluate a higher-level stack before production exposure.

Official references checked during implementation:
- https://api.dart.dev/dart-io/HttpServer-class.html
- https://api.dart.dev/dart-io/HttpServer/close.html
- postgres 3.5.20 installed API source: Connection.openFromUrl, ConnectionSettings.

A new `ventio_host_api` package wraps `ventio_host`; existing Core, migration and
stable command contracts remain unchanged. API version 1 does not rename or
freeze the draft command protocol version 0. HTTP request claims are validated
against a separately authenticated server Principal and checked again by the
existing command engine.

## Security choice

This slice uses the handoff's allowed controlled development identity provider.
It is not a production IAM implementation. Opaque high-entropy bearer tokens are
looked up by SHA-256 digest; identity, permission and scope grants come from private
server configuration. Expiry and process-local revocation are enforced. A hard
loopback-only bind and explicit development launcher prevent accidental external
listening or implicit test-auth activation. No public API deployment is provided.
See the package README for protocol, limits, setup and known limitations.

## Validation evidence and scope

Baseline verified before implementation at feature HEAD `8e797ce`:
- Remote Core, persistence and durable workflows all successful.
- Prior durable job log confirms 26 assertions; Core tests rerun locally: 47/47.
- Local SDK is Dart 3.13.7. Old source formatting differs under this SDK; older
  workflows format before analyzing. Existing Core/Host files are not reformatted
  as part of the API slice. New package CI requires clean formatting.

New tests include actual HTTP requests, isolated PostgreSQL effects, retries under
concurrency, pre-commit rollback, DB connection loss, simulated post-commit result
loss and independent graceful OS-process restart. A new HTTP server alone is not
claimed as a full process restart; independent subprocess checks cover that case.
Process restart tests do not prove abrupt termination during commit or restore.

## Remaining Host closure work

This is an operational-create API proof, not Host v0.1 closure. Durable auditable
policy, production identity/device lifecycle, external TLS, request rate limiting,
header limits, pooling, monitoring, crash/restore and migration rollout proofs,
stronger tenant isolation and commit-order outbox publication are still open.
No Flutter client, actual Offline Engine, financial posting or module code
execution is implemented. Preserve `main` and `v0.2.0` pending explicit review.
