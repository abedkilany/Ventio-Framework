# Threat Model Starter — V1.1 (not a security audit)

## Assets / trust boundaries

- **Host authoritative DB**: balances, invoices, movements, memberships, receipts, module registry, command idempotency records.
- **Client device**: cached authorized records, identities/tokens, mutable local queue and pending display state.
- **Module bundles**: external metadata must be treated as untrusted input even after transport signing; publisher identity alone does not mean business capability authorization.
- **Sync channel**: unreliable/duplicated/delayed/reordered messages; TLS protects transport but not compromised client claims.
- **Multi-tenant context**: Host derives tenant/company/branch from verified membership; all DB filters/queries are scoped.

## Abuse cases to test

1. Client sends `tenantId` of another company while using valid credentials from tenant A.
2. Client submits same `commandId` with different payload after losing a response.
3. A signed but maliciously crafted module requests unknown capability or attempts to display hidden finance fields.
4. Employee permissions revoked on Host while their device is Offline; queued operations must be revalidated when they reconnect.
5. Device lost or compromised with locally cached invoices; test encryption at rest, secrets storage, session revocation on reconnect, backup/export policy.
6. Migration replaces field semantics and old queued operations are silently dropped or incorrectly reinterpreted.
7. API instance crashes during a stock/ledger transaction; no partial posting survives commit boundary.
8. Two Host API replicas process concurrently against last available stock; database-level protection must enforce invariant.
9. A user replays an old signed module package to downgrade schema or privileges.
10. Outbox worker repeats payment/notification with non-idempotent third-party endpoint; side-effect policy and reconciliation required.

## Open controls, before go-live

- Key management and local encryption design per Windows/Android; Android Keystore/Windows DPAPI are possible adapters, not yet selected.
- Auth credentials/device enrollment/revocation, refresh and offline limits.
- Package signing, anti-rollback, signature trust/rotation, capability allowlist.
- RLS tenant scoping or proven equivalent DB enforcement; audit log retention and tamper alerts.
- Penetration/security reviews for sandbox runtime before enabling third-party executable extensions.

## V1.2: Translation boundary threat cases

11. A malicious optional translation pack contains markup, unusual bidirectional controls, forged action wording, or oversized messages: rendering must be bounded, correctly escaped and reviewed for sensitive actions.
12. A translated format string attempts to access secrets through placeholder names or malformed rich-text instructions: only explicitly provided, typed display parameters are interpolated.
13. The translation extension is uninstalled while the device is offline: English fallback must remain available, independent of sync command recovery.
14. A stale translation pack targets a different schema/module version: reject incompatible entries or fall back to the matching module's bundled English catalog.

No language pack is authorized to register capabilities, change transaction logic, modify permissions or mutate stored business records.
