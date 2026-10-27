# C01 Generated List Acceptance Evidence

Date: 2026-10-27

## Acceptance

C01 is accepted as **Hardened**. The generated DocType screen already renders configured list columns, search, declared-field filters and sorting, and stable loading, empty, error and Host-denial states. Host queries use the authorized record-query API and support continuation paging. The view masks inaccessible fields and hides cached rows after Host denies read access.

## Targeted hardening

Replaced first-party list-page status, preview, action, authorization, row-summary and retry copy with stable English catalog keys. Replaced raw list query exception display with catalog-backed retry messages. DocType and field labels continue to resolve through the extension metadata translation keys and English fallbacks.

## Evidence

- `packages/ventio_native_client/test/extension_studio_test.dart`: **22 passed, 0 failed**.
- The widget suite exercises configured list columns, Host-scoped reads, Host cursor paging, permission denial with cached-row hiding, empty state, offline workflow, and a phone-sized layout.
- `python scripts/check_localization_gate.py`: passed.
- `python -m unittest scripts.test_check_localization_gate`: **6 passed**, including deliberate invalid UI/catalog cases.
- Flutter formatter completed; source changes are limited to generated-list UI and the English catalog.

Checkpoint: recorded with the C01 acceptance dashboard commit on `codex/extension-platform`.
