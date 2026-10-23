# Native Flutter Client and Offline-first Proof

## Non-negotiable boundary

Deliver real installed Windows and Android Flutter applications, with English as the native default and localization keys ready for an optional future module. The original Ventio application is outside this work. AI Builder and Marketplace are later phases.

Host is the final authority. A local edit is provisional until Host accepts its immutable command. Local success must never imply shared acceptance, authorization or financial posting. No client receives PostgreSQL, recovery-writer or identity-administration privileges.

## Proposed slices and acceptance evidence

| Slice | Implementation | Required evidence |
| --- | --- | --- |
| 1. Portable client contracts | Reuse immutable Core envelopes/receipts; versioned transport interface, secure credential import boundary and explicit pending/confirmed/conflict/denied states | Serialization compatibility with Host; client claims cannot grant authority; no raw secret logs |
| 2. Durable local queue | SQLite transaction stores original command ID/envelope, dependencies and provisional projection; separate confirmed projection and reconciliation metadata | Kill/restart at enqueue/send/receipt persistence; no lost local intent, duplicate IDs or premature confirmation |
| 3. Reconciliation | Retry unchanged envelope on unknown outcome; bounded backoff/jitter; persist authoritative receipts atomically; reauthenticate with current credentials | Drop before/after Host commit and before local receipt commit; eventually one Host effect; expired/revoked credential and changed scopes deny replay |
| 4. Conflict and recovery | Explicit schema/module versions, dependency rejection and revision conflict; pause queue on recovery quarantine; reviewed user resolution creates a new intent only after resolving the old outcome | Two clients conflict; tenant/company/branch changes; logout/re-enrollment never attach one identity's queue to another |
| 5. Confirmed-state synchronization | Design authorized snapshot/export and resumable incremental protocol before UI depends on it | No cross-scope reads; repeat/drop/reorder events; consistent snapshot/delta boundary and deletion semantics |
| 6. Native packaging | Windows installer and Android APK, SQLite migrations and OS secure storage adapters | Windows CI build plus install/launch proof; Android emulator install/launch and device keystore checks; offline restart and reconnect on each target |

Use a small operational DocType, initially Maintenance, for the proof. Generic create remains prohibited for accounting/inventory posting. Pending inventory or money values cannot be treated as authoritative balances.

SQLite queue state, receipt and projection transitions must be transactional. Retain idempotency IDs across retries and process restarts. A transport exception does not justify assigning another ID. Separate locally staged changes from Host-confirmed records in both storage and UI. Document whether local records are encrypted and how logout, key loss and device replacement affect unsubmitted work.

Store credentials through reviewed Windows OS protection and Android Keystore-backed storage. Dart memory, clipboard, debug output, crash reports and delivery files need explicit controls. Do not call an untested package's behavior a secure-storage proof. Offline use after revocation can only remain provisional; enforcement of latest rights requires Host contact. Define local expiry and lock behavior without claiming the offline clock proves server authorization.

An outbox sequence is not automatically a safe synchronization cursor: PostgreSQL transactions can allocate IDs and commit out of order. A future export protocol must prevent skipped late commits with a tested cursor/snapshot scheme, provide scope-aware authorization on every fetch, and avoid publishing uncommitted or unauthorized rows. The current outbox is a durable internal event store, not a completed client sync service.

## Transport and platform gate

The audited Host is Linux-specific and only listens on 127.0.0.1. It is not currently a usable direct LAN endpoint for Windows/Android clients. Initial queue/reconciliation proofs may use a clearly labeled deterministic transport fixture; that is not real cross-device Host integration. Linux laboratory loopback tests can exercise the actual Host contract independently.

Before claiming Windows/Android-to-Host end-to-end proof, choose and audit a permitted deployment/transport: either a reviewed local Host platform adapter or a separately gated authenticated secure transport. Do not expose the existing prototype, add a proxy/tunnel, bypass recovery admission or reuse administrative credentials to make a demo connect. Keep network exposure blocked pending the separate security release gate.

## Completion gate for the next phase

Require repeatable Windows/Android builds, actual native install/launch evidence, persistent offline queue tests, accepted/denied/conflicted reconciliation tests, credential lifecycle tests, crash-boundary tests and a compatibility matrix for Core/Host/client protocols. Explicitly list real-device versus emulator coverage. Keep production readiness separate. Dynamic metadata UI, financial modules, production sync, remote enrollment, AI Builder and marketplace are not implied by this proof.
