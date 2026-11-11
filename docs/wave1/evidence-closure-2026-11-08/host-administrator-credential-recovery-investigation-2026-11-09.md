# Host Administrator Credential Failure and Recovery Investigation — 2026-11-09

## Result

The owner reports that Host application access returns HTTP 401 UNAUTHENTICATED; SSH, PostgreSQL, services and HTTPS liveness are working. No current sanitized Host authentication-failure diagnostic was available. The only Host diagnostic event in the installed safe diagnostic log is PAIRING_REQUEST_STARTED at 2026-11-07T21:53:37.160558Z, correlation cor_a948398b68c1353ae2b02796197918de.

The most likely cause is expiration of the original first-administrator bootstrap credential:

- The installed Host service broker creates the first-administrator credential with ExpiresAtUtc = DateTimeOffset.UtcNow.AddDays(1) in installer/windows/host-service/FirstAdminBootstrapBroker.cs.
- Host SetupStatus contains four completed first-administrator handoff records dated November 5 and November 7, all at phase HOST_READINESS.
- The latest broker receipt metadata is timestamped 2026-11-07T21:43:44.340Z. The current date is November 9. A credential from that bootstrap generation is older than its documented one-day lifetime.
- Two protected .credential.dpapi result files remain from November 7. Their metadata was checked only: each is 566 bytes, ACL-protected, and readable by the ABEDKILANY\AbedKilany account. Their contents were not opened, decrypted, copied, or displayed. The user-profile pending-setup file is absent.
- The first-run code saves the bootstrap token to HostCredentialVault, then clears the protected setup result and pending operation. The broker clears token fields from its protected service receipt after acknowledgement.

This evidence strongly supports expired if the currently selected Host profile still uses the original bootstrap credential. It does not prove which credential the vault currently holds because no token or authentication record was inspected.

## Why the HTTP 401 cannot distinguish the alternatives

PersistentTokenAuthenticator hashes the bearer token and asks PostgresIdentityStore.resolve for a valid identity. The SQL identity snapshot returns no identity when the digest is absent, the user is disabled, the device is revoked, the credential is revoked, or its expiry has passed. The HTTP layer maps a null authentication result to UNAUTHENTICATED. The sanitized diagnostics do not log the digest or differentiate those cases.

Therefore the available evidence does not establish whether the current vault entry is missing, mismatched, revoked, or expired. There is no evidence of a later revoke or identity change in the inspected sanitized diagnostics, but that is not a direct database audit.

## Supported recovery boundaries

- Re-running first-administrator bootstrap is not valid recovery: it is restricted to an empty identity tenant and would not preserve the existing administrator identity.
- The installed Windows trusted credential-reissue broker requires a currently authenticated operator credential with the required management authority and an explicit local UAC approval. It is for an already-registered device; it cannot recover an administrator who has no valid operator credential.
- The existing trusted local operator CLI has a scoped provision action that can issue a replacement credential for an existing actor and device, constrained by that actor's current grants and exact scope. It requires the trusted ventio_identity_admin database connection, the current Recovery Authority, a private request/output path, and execution by the configured Recovery Authority writer. The Windows operations guide requires that operator context and private credential delivery. No such operator request, database credential, or delivery authorization is available in this session.
- The destructive reset-for-reenrollment path revokes all credentials and devices and removes grants. It is explicitly out of scope and was not used.

No credential material, Recovery Authority contents, database authentication records, or private database URLs were read. No credential, service, database, setup state, or configuration was changed. No new administrator or device was created.

## Required owner action

Make the trusted Windows Recovery Authority writer/operator available to run the existing audited identity_admin.dart provision action for the existing administrator actor/device and its exact currently authorized scope, using the current ventio_identity_admin connection and current Recovery Authority. Arrange confidential local delivery into the existing application's protected credential store; do not send any URL, witness, bearer token, or credential file through chat. If no supported local vault-delivery path exists on this Host build, an owner-authorized operator or product maintainer must supply that supported delivery path before issuance is attempted.

After the operator path is available, verify in the application that the existing profile authenticates, obtain sanitized readiness at its exact scope, and inspect Host Overview. The previous Computer Use input attempt failed with GetCursorPos failed: Access is denied. (0x80070005); no retry was made.

Disposition: BLOCKED — ENVIRONMENT for credential restoration and post-recovery UI/readiness verification. The one-day bootstrap expiration is strongly indicated, while the exact current vault credential state remains unverified.
