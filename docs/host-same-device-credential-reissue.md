# Same-Device Credential Reissue

## Purpose and boundary

This workflow updates the permission ceiling of one already-enrolled Windows Client without creating a device registration or changing its Host profile. A new device identity is never used as a credential-recovery shortcut.

An active Host identity manager and a local Windows administrator must both approve the operation. The Host checks live operator authority, the target device and source credential, exact tenant/company/branch scope, the target user's current direct and role-derived permissions, Recovery Authority admission, and the selected complete replacement ceiling. New management permissions are rejected by this workflow. Ordinary Client APIs, pairing, and credential rotation cannot widen a ceiling.

## Threat model

The protected assets are the raw Client bearer, the source credential, exact-scope permission ceiling, durable transition state, Recovery Authority witness, and Client-local records and pending command IDs. Threats include a stolen Client token, a forged or replayed operation reference, a credential manager without Host authority, a Host user grant changing during a transition, a lost HTTP response, concurrent revocation, a process crash, and PostgreSQL rollback.

The source token must authenticate the same existing actor/device and exact scope to claim a replacement. The operation reference is random and idempotent, but is not treated as authorization. Preparation also requires the caller's live Host `identity.devices.manage` authority and an explicit UAC approval. SQL checks the target's live effective permissions and disallows newly added management namespaces. The Recovery Authority serializes and fingerprints each mutation outside PostgreSQL's backup/rollback domain. The new token is DPAPI-protected at rest, sent only over pinned TLS, staged in OS-protected Client storage, and activated only after possession is acknowledged.

Local Windows administrators, the Host service identity, and an attacker who can already read the relevant machine-DPAPI scope remain inside the trusted local computing boundary. This workflow proves possession of the enrolled bearer and exact stored profile; it does not claim TPM-backed physical-machine attestation. Host authorization and branch isolation remain authoritative even after local approval.

## Transition protocol

1. The Windows Client persists a random operation reference in its OS-protected credential store. The reference contains no credential material.
2. The Host application asks the trusted Windows service for UAC approval. The elevated broker displays the exact user, device, scope, complete replacement ceiling, and removals. The named pipe accepts only a local administrator caller. The service passes a bounded request to the fixed trusted helper through standard input. The raw replacement bearer is never placed in command arguments or request files; the short-lived operator request file is ACL-protected and carries only the operator credential digest and reviewed scope fields.
3. The trusted helper creates a random replacement token, computes its SHA-256 digest, and protects the token with machine DPAPI using the operation reference as entropy. PostgreSQL receives only the digest and DPAPI ciphertext. The Recovery Authority admits and fingerprints the durable transition. One prepared transition is allowed per tenant/device and expires after 15 minutes.
4. The current credential remains the only active database credential. The enrolled Client claims the pending replacement over its pinned HTTPS connection using that current credential. The Host rechecks the device, actor, scope, source credential, and current permissions. If a permission was removed while the request was pending, the claim is denied.
5. The Client validates every identity and scope field, writes the replacement to protected storage as a staged credential, and verifies the stage before acknowledging with the replacement token. The staged token has no ordinary Host authority before finalization.
6. The Host rechecks the target grant set and source credential inside the Recovery Authority-admitted transaction. It inserts the new credential and revokes the source credential atomically, clears the DPAPI delivery ciphertext, and audits the transition. The Client activates its staged credential only after it receives a matching `FINALIZED` response.

The old and replacement credentials do not have simultaneous ordinary authorization: before finalization only the source is active; afterward only the replacement is active. The replacement credential expires after 30 days, subject to the Host's normal revocation and grant checks.

## Restart and ambiguous outcomes

- If the Host stops before preparing the transition, no new credential is active.
- If the Host commits preparation but its local response is lost, the protected operation reference and database row identify the same transition. Repeating the same request is idempotent and cannot mint a second credential.
- If Client secure storage cannot stage the replacement, the source credential remains active and the Client can retry the authenticated claim.
- If the Client stages the replacement but loses the acknowledgment response or restarts, it retries acknowledgment from the staged token. The Host's finalized response is idempotent for that same operation and token digest.
- If the 15-minute window expires before acknowledgment, the Host wipes the encrypted delivery value and marks the operation expired. The source credential stays active; the operator can start a new reviewed operation after reconciliation.
- If current target permissions change while the operation is pending, claim/finalization cannot activate permissions that are no longer granted. A terminal `REJECTED` or `EXPIRED` response clears the staged value while retaining the source credential.
- If Recovery Authority is unavailable, pending, or mismatched, mutations fail closed. The source credential and local SQLite state remain unchanged.

If the Client's protected credential store is destroyed after Host finalization, neither the revoked source credential nor the staged replacement is available for proof. This release does not silently create a new identity or provide an unauthenticated credential recovery endpoint. Preserve the local protected store and use the supported reissue retry while the source credential is active; loss after finalization requires a separately approved recovery procedure and remains a limitation.

## Identity and offline-data preservation

The Host validates equality of tenant, actor, device, company, and branch between the enrolled profile, source credential, pending operation, and replacement. The transition changes credential rows only. It does not write Client settings or SQLite, and does not re-enroll, delete, or alter a device row.

The Client does not open or migrate SQLite during reissue. Durable command IDs, envelopes, queue states, local records, offline drafts, accepted revisions, and receipts therefore remain under their original device identity. A SQLite regression test queues a real local command, restarts the Client around the credential transition, and verifies the same command ID, scope, and Pending state afterward. Physical PostgreSQL synchronization and receipt acceptance still require owner acceptance on the real Host.

## Database and Recovery Authority impact

Migrations `031_identity_credential_reissues.sql` and `032_identity_credential_reissue_pending.sql` add the protected transition table and the one-pending-operation-per-device index. Each file is one migration statement. The reviewed security contract applies forced RLS, owner-only policy, narrow Identity API function grants, and Recovery Authority mutation triggers. The new security functions recheck live grants on preparation, claim, and finalization.

For existing installations, Setup first stops the Host and creates and verifies the restricted PostgreSQL backup. It then applies migrations, re-applies the pairing and reissue security contracts, verifies function privileges, forced RLS, Recovery Authority triggers, migration checksums, and `assert_schema()`, and only then permits Host restart. A failed backup, migration, or verification leaves the Host stopped. Registered devices, existing credential digests, certificates, local Client databases, and Recovery Authority files are not reset.

Raw bearer tokens are not stored in PostgreSQL or written to logs, diagnostics, request files, or command-line arguments. The pending DB row contains a digest and machine-DPAPI ciphertext for at most 15 minutes. Audits record the operation reference, scope, credential IDs, result, and approved permissions, never the raw token or digest.

## Owner procedure for the enrolled Client

1. Verify the installer SHA-256 from the release report, then run Ventio Setup 0.1.12 on the Host and choose the existing Host upgrade. Do not uninstall or select data removal. Wait for the verified backup, migration, security-contract check, and service restart.
2. Update the existing Client application in place to the corresponding 0.1.12 build. Keep the existing Windows user profile and application data. Do not clear app data, delete the SQLite file, remove the Host profile, or re-enroll.
3. On the Host, verify API, Database, Schema, and Recovery Authority readiness and confirm the existing tenant `a`, company `b`, branch `c`, device ID, certificate, and device registration remain present.
4. As an authorized identity manager, grant only `extension.package.read` to the intended user directly or through a role scoped to tenant `a`, company `b`, branch `c`.
5. In **Host devices & pairing**, select the already-registered device. Choose **Reissue credential ceiling** and review the full resulting permission list. Retain all currently authorized permissions; approve no unrelated permissions or removals. Approve the Windows UAC prompt on the Host.
6. On the existing Client, open the Host device/credential status card and select **Check for update**. Keep the application open through staging and Host acknowledgment. If the result is retryable or unknown, use **Resume credential update** with the same operation reference; do not enroll again or clear local data.
7. Verify the device ID and scope are unchanged, the Client's existing records and Pending command IDs remain visible, and `POST /api/v1/extensions/approved` succeeds. Confirm a Client without the grant, a different branch, and unrelated permissions remain denied.
8. Complete physical acceptance separately: install an approved declarative extension, create an offline record, restart and verify durable Pending state, reconnect to the real Host, verify the authoritative receipt and Host record revision, and read it from another authorized Client. Keep Crash Recovery as a separate open gate.

Physical acceptance is not complete until these checks run against the real Host and existing Client. Isolated tests and the deterministic test transport do not replace this work.

## Verification record for this implementation

- Host installer: Ventio Setup 0.1.12, `dist/windows/same-device-reissue-0.1.12-release/Ventio-Setup-0.1.12.exe`, 103,810,740 bytes, SHA-256 `de520fc4c95771489cdcf71d884e67c348af9e262c94fd411199abbdf669f226`.
- Windows Client Release build: PASS, 65.7 seconds, isolated at `packages/ventio_native_client/build-0.1.12/windows/x64/runner/Release`. The temporary Flutter build directory setting was removed after compilation.
- Windows Host payload and Setup Broker/Host Service Release builds: PASS. Payload contains PostgreSQL 16.15, reviewed migrations and security contracts, and no database or credential state.
- Unified installer compilation: PASS, Inno Setup 6.7.3, 88.219 seconds. Machine-wide Host boundary, deferred Stage A provisioning, path, VC runtime, and payload manifest checks passed.
- Host API analysis: PASS, zero issues.
- Host API route suite: PASS, 79 assertions.
- Client Dart analysis: PASS, zero issues.
- Client credential reissue suite: PASS, 5 tests, including rejected-stage cleanup and SQLite Pending command preservation across Client restarts.
- Full Client Flutter suite: PASS, 228 passed; 2 existing Windows Host integration tests skipped because they require the elevated physical Host process runner.
- Fresh first-administrator bootstrap and legacy-style contract replay: PASS, 17 assertions. The reissue contract, schema profile, and pairing contract all reapplied while retaining the six-permission ceiling and original active device identity; the test verified narrow API grants, forced RLS, and Recovery Authority triggers.
- Disposable PostgreSQL fresh-initialize/upgrade test: PASS. It verified the migration ledger, restricted backup, RLS and Recovery Authority contract, schema assertion, protected Host configuration, and service startup tests.
- Disposable PostgreSQL Host security suites passed individually: database security 118, user administration 40, role administration 20, pairing 45, approved package authorization 138, and credential reissue 17 assertions.
- Host service Windows checks: PASS for readiness, state/configuration, TLS, ACL, named pipe, first-administrator response, and service lifecycle; service-owner SID integration is BLOCKED because this runner was not elevated. Setup Broker test executable completed successfully.
- Credential-reissue PostgreSQL integration: PASS, 17 assertions, including same-device identity, exact scope, current grants, protected delivery, and revocation only after acknowledgment.
- Offline-first SQLite/PostgreSQL/Host integration: PASS, 1 end-to-end test. Two original queued commands survive an offline Client restart, credential reissue, and another Client restart; the prerequisite command is accepted first, the dependent command stays Pending with its original ID, then receives Host acceptance on retry. SQLite keeps the same records and receipt history, and the Host record readback confirms the expected revision.
- Physical Host/Client acceptance and real Host PostgreSQL synchronization: NOT RUN. No installed Host or active database was modified.
- Crash Recovery gate: OPEN.

The current operator UI adds only `extension.package.read` while retaining the complete existing active credential ceiling. SQL supports explicit removals, but the current UI intentionally does not offer permission-removal controls; use the existing grant/revoke administration workflow and a new review if the target grant set changes.
