# C02 Generated Form Acceptance Evidence

Date: 2026-10-27

## Acceptance

C02 is accepted as **Hardened**. Generated create/edit forms use the DocType's configured field order and declared field types, initialize metadata defaults, apply field constraints and validation, and honor Host-readable, creatable, and writable masks. Partial edits omit inaccessible fields and preserve their stored values. Local saves remain provisional and can enqueue durable Host commands.

## Targeted hardening

Moved the generated form's first-party status notices, save actions, field type labels, constraint summaries, and operation/validation/save-failure guidance to stable English catalog keys. UI no longer displays raw storage exception text. Extension-owned field labels/descriptions still resolve through metadata keys and English fallbacks.

## Evidence

- `packages/ventio_native_client/test/extension_studio_test.dart`: **22 passed, 0 failed**.
- Covered long text and table round-trip, defaults and decimal precision validation, Host-granted field permissions, offline durable command queueing, hidden-value preservation on partial edit, and phone-sized generated form layout.
- Targeted Flutter analysis of `extension_studio_page.dart`: no issues.
- `python scripts/check_localization_gate.py`: passed.
- Localization gate regression suite: **6 passed**.

Checkpoint: recorded with the C02 acceptance dashboard commit on `codex/extension-platform`.
