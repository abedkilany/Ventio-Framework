# Ventio Core Architecture — V1.2 Starter

**Status:** English-first, localization-ready **architecture and contract draft**, dated October 23, 2026.

This package defines a proposed Ventio Framework Core boundary, extension model, command contracts and localization compatibility rules. It is **not** compiled Dart/Flutter product code and does not authorize rewriting the existing Ventio application.

## Product language policy

- **English is the only built-in product language.** Source comments, documentation, sample resources, developer tooling, user-visible base UI and logs are in English.
- A **separate, optional Translation Module** may add alternate locales later, without changing Core or rebuilding Flutter binaries merely to add message data.
- Every UI label supplied by a module has a stable localization key and a mandatory English fallback; a module also supplies its versioned English catalog.
- Commands, database field identifiers, enum values, permission codes, currency values and financial amounts never depend on the active display locale.

## Contents

- `ARCHITECTURE_V1_2.md` — architecture boundaries, safety protocols, extension tiers, English-first localization contract and staged proofs.
- `IMPLEMENTATION_BACKLOG.md` — proposed implementation tasks and acceptance gates.
- `decisions/` — Architecture Decision Records (ADRs), including the localization principle.
- `contracts/` — five existing draft JSON Schemas, enhanced for localization where needed, plus a new optional language-pack draft schema.
- `examples/` — validated Maintenance module example, command/receipt fixtures, English catalog and test-only pseudo-language-pack metadata.
- `localization/en.core.json` — built-in English Core messages, with stable keys.
- `diagrams/` — command lifecycle scenarios.
- `proof/` — proof-of-platform plan and initial threat model.
- `scripts/` and `tests/` — runnable structural validation only.

## Run structural validation

Requires Python 3.10+ and the `jsonschema` package. Run from the extracted package directory:

```bash
python -m pip install 'jsonschema>=4.18,<5'
python scripts/validate_contracts.py
python -m unittest discover -s tests -v
```

These tests validate proposed JSON schemas, examples, default English key coverage and negative cases. They do **not** prove runtime locale switching, Flutter rendering, Host transactions, sync reliability, PostgreSQL behavior, SQLite durability, extension sandbox security, or translations in actual languages.

## Important architecture limitations

L0–L2 declarative extensions can describe data, UI and workflows composed of approved capabilities; they cannot necessarily implement any arbitrary new business algorithm. This limitation must be evaluated with explicit proof cases before broad extension-marketplace claims. The starter contains no arbitrary executable extension system and no implementation of the optional Translation Module.

The current Ventio source was **not** inspected as part of this upgrade. No accounting-data or code migration is attempted here.
