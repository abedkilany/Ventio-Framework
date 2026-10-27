# B05 Record Query Acceptance Evidence

Date: 2026-10-27

## Acceptance

B05 is accepted as **Hardened**. Existing local search, declared-field filtering, stable ordering, tombstone exclusion, and exact-scope enforcement were reviewed. The Host's offset paging did not meet the fixed keyset continuation criterion, so bounded query-bound cursors were added and threaded through the native client and Extension Studio.

## Evidence

- PostgreSQL 17.11 isolated extension integration: **102 passed, 0 failed** (`packages/ventio_host_api/test/extension_package_integration.dart`). This includes exact-scope and permission checks, bounded search/filter/sort behavior, and query paging.
- Keyset continuation remained stable when a new row sorting before the cursor was inserted between pages; the second page returned the next expected record without overlap.
- Reusing the cursor with different search parameters was rejected.
- Flutter Host client, Extension Studio, and SQLite focused suites: **67 passed, 0 failed**.
- Host query API analysis and focused source checks passed.

## Implementation note

Cursor payloads encode arbitrary sort values as base64url. Decoding now restores required base64 padding for both the outer cursor token and its encoded sort value. Tokens remain bounded and are bound to the full normalized query, scope, and page size. Offset paging remains available for compatibility.

Checkpoint: recorded with the B05 acceptance dashboard commit on `codex/extension-platform`.
