# ADR-009 — English-First, Localization-Ready Core

**Decision date:** 2026-10-23  
**Status:** Accepted product principle; runtime API and translation-pack format remain draft.

## Context

Ventio's initial installed Windows and Android product, code, bundled UI, documentation and developer artifacts must be in English only. The future ecosystem must nonetheless support full localization through an **optional** module that can install, update, disable and cache language packs as data, without modifying Core or recompiling Flutter for every new language.

## Decision

1. Embed an English Core catalog in the initial application, and require every business module to supply English labels and a versioned English catalog.
2. Give every translatable metadata label a stable namespaced key plus a reliable English fallback. Preserve stable identifiers for enums, data, permissions, commands and errors.
3. Provide a small, UI-framework-independent localization resolution *contract* from the outset; avoid building a full runtime translation system in the first stage.
4. Treat translations as untrusted **display data** with version compatibility and no implicit command, code execution or permission authority.
5. Make active locale a presentation concern. Number and currency formatting must not alter stored decimal values, money codes or accounting logic.
6. Default permanently to English in the absence of a valid Translation Module or message key. Disabling translation must not affect records or pending sync commands.
7. Design Flutter UI for flexible text length, bidirectional text and dynamic rerendering. Verify RTL and language formatting before releasing actual additional locales.

## Implications

- Updating the V1.1 manifest and DocType draft schemas and the Maintenance fixtures is necessary before Dart Core implementation.
- English user-visible messages, including structured errors, must remain available without network access.
- Optional future language packs may be cached offline and must fail safely to English.
- Catalog completeness, namespaced key collisions, placeholder integrity and locale compatibility require validation before module activation.
- Reports, exports, receipts, accessibility labels and official printed documents must eventually honor independent locale/document compliance policies.

## Open implementation decisions

Exact Dart API shape; ICU/CLDR formatting engine; signed catalog distribution; language pack update and rollback; policy for partial overrides; accessibility and rich-text rendering; locale preference storage. The draft `language_pack.schema.json` is **not** a frozen public protocol.

## Acceptance tests

- Boot an installed app with the translation extension absent; all screens and installed module UI show English.
- Install a test-only pseudo-pack, switch locale dynamically, then remove it and return to English without rebuilding or changing data.
- Resolve a missing or malformed translation key with a deterministic English fallback.
- Confirm that Host error reason codes, enum IDs, invoice amounts, stored dates, tenant authorization and local command queues never change because of UI language.
- Verify RTL layout, pluralized messages, multiline content and offline cache in later runtime integration tests.
