# Changelog — V1.2

## English-first and localization readiness

- Converted the original Arabic README, implementation backlog and architecture document to English; revised the architecture as V1.2.
- Adopted ADR-009: the base product contains English only, and localization is an optional future module.
- Required `displayNameKey` and a bundled `englishCatalog` path in the module manifest; added paired English labels and localization keys to DocTypes and fields.
- Added English labels and keys for every enum option without changing the stable machine values.
- Extended command receipts with an optional localization `messageKey` and structured `messageParams`; `reasonCode` remains required for final rejections and conflicts, while `publicMessage` is optional.
- Added bundled English Core and Maintenance catalog examples, plus a draft language-pack schema and a test-only English pseudo-locale fixture.
- Added ADR, threat cases, proof gates, implementation tasks and contract/catalog verification.
- Added a scan for non-English-script letters in package source, JSON and Markdown files.

## Compatibility and limitations

- This is a **draft contract-breaking update** from V1.1. Before implementing Dart clients/Host, use the new v0.1 draft schemas and examples together.
- Existing command, capability and accounting-authority principles are unchanged. Business transaction/runtime semantics are not implemented in this architecture package.
- No real alternative-language pack is shipped. No production Translation Module or localization runtime is implemented.
- The original Ventio application source was not accessed or modified.

## Verification

Run:

```bash
python scripts/validate_contracts.py
python -m unittest discover -s tests -v
```

All 20 included unit tests passed in the environment used to create this package. These checks are structural and do not certify a running application.
