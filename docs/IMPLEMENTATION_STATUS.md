# Implementation status

Current scope: Extension Builder and device-local dynamic data/UI foundation on `codex/extension-platform`, based on `feature/native-flutter-offline-proof` at `b60530a`. Stable `main` and `v0.2.0` are not updated. The original Ventio application and its data are outside this repository's implementation scope.

| Layer | Implemented | Remaining boundary |
| --- | --- | --- |
| Core | Immutable JSON contracts, metadata/module installer, shared capability validation, English fallback, two independent operational fixtures | No executable third-party module sandbox, financial/inventory posting or Flutter UI |
| PostgreSQL | Checksummed migrations, atomic preflight/batch, approved schema manifest, isolated record storage; migration hashes now normalize Windows/Unix newlines | No universal schema attestation or online migration policy; no local PostgreSQL instance was available for this turn's transactional tests |
| Durable Host | One transaction for journal/record/audit/outbox/receipt; original-ID retry and replay authorization | No distributed side-effect exactly-once claim or completed sync protocol |
| Identity/API | Persistent scoped credentials, user/device withdrawal, current grants checked on execute/retry; loopback-only bounded HTTP | No Windows Host service proof, external-network deployment, end-user remote enrollment or platform secure-storage proof |
| SQL security | Separate owner/runtime/admin/migrator capabilities; forced credential-checked RLS and direct-SQL regressions | Superuser/owner remain trusted; RLS is defense in depth, not business validation |
| Recovery | Actual process kills/ambiguous commit tests; fresh-cluster logical restore; pending/ready independent witness; conservative re-enrollment | No hardware power-loss proof, PITR/RPO/RTO, HA or independently monotonic rollback authority |
| Credential lifecycle | Private Linux delivery, bounded scopes, renewal/rotation/revocation and interruption regressions | Recipient transfer/import/keystore management and joint database+witness rollback remain production blockers |
| Final audit | Shared-contract and migration fixes; real OS write separation; growth/concurrency/lock/drain tests | 75 engineering assertions and all implementation workflows passed; published final commit must retain all seven green; no numerical quality score |
| Native Flutter client | Responsive Extension Builder and metadata-driven local list/form/details screens; persistent SQLite extension, DocType and record storage; scoped relationships; optimistic revisions; lifecycle controls; non-destructive additive metadata upgrades; separate transactional command queue | Extension definitions/records are device-local only, outside the Host queue. No Host sync, shared approval flow, role administration, Windows/Android install proof, production key storage, or real offline/reconnect integration |

The device-local scope filters are useful for dynamic UI and regression tests; they are **not an authentication or security boundary**. The application has no signed-in user/organization/company/branch identity yet. Host-side branch authorization and current-grant checks remain required before shared records are exposed.

See [the final engineering audit](HOST_ENGINE_V0_1_FINAL_ENGINEERING_AUDIT.md) for the measured acceptance decision and [operations](HOST_ENGINE_V0_1_OPERATIONS.md) for current launcher settings. Earlier stage reports describe their tested slices; their old same-account launcher examples and historical limitations are superseded by these current documents.

See [Extension Builder device-local foundation](EXTENSION_BUILDER_FOUNDATION.md) for exact local behavior, tests and remaining Host/security gates.

The historical lifecycle suite deliberately uses a test-only same-account launcher guarded by disposable-database flags. The engineering gate separately executes the real compiled launcher under another OS UID and verifies that it cannot modify the witness or read operator secrets. Test fixtures are not supported service launchers.

See [Native Flutter Phase 1 implementation notes](NATIVE_FLUTTER_OFFLINE_FIRST_PHASE_1.md) and the [Native Flutter Client and Offline-first Proof plan](NATIVE_FLUTTER_OFFLINE_FIRST_PROOF_PLAN.md). Client-local work stays pending until Host accepts it. Production readiness is a separate, blocked decision.
