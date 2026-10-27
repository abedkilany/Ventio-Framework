# A07 Acceptance — Child / Table DocTypes

**Status:** Accepted  
**Historical status:** Missing  
**Wave 1 work performed:** Newly Implemented  
**Architecture:** [ADR-011 — Embedded Child DocTypes](../decisions/ADR-011_EMBEDDED_CHILD_DOCTYPES.md)

## Accepted behavior

- A parent `table` field may declare one bounded, nested child DocType schema with 1–50 uniquely named child fields. Nested tables are rejected; existing untyped table fields remain compatible.
- Child rows preserve order and are stored inside the parent record. Child values receive defaults and are validated for declared fields, required values, types, precision, constraints, and row limits.
- Child fields inherit the parent table field's permissions and lifecycle. They have no independent record IDs, commands, status, permissions, or orphan state.
- Child reference targets must be declared top-level DocTypes in the same extension and resolve within the exact tenant/company/branch scope. Parent deletion is restricted while another live parent references the target through a child row.
- Extension Studio can author and edit a child DocType declaratively. The child schema and its label keys survive package export/import.

## Verification evidence

- Core contract harness: **70/70**. Covers child schema validation, bounds, defaults, references, nested-table rejection, parent payload behavior, and package validation.
- SQLite ExtensionStore suite: **35/35**. Covers scoped child references, typed rows/defaults, persistence across restart, and package metadata round-trip.
- Extension Studio widget suite: **23/23**. Includes authoring a typed child DocType and verifying its exported catalog label.
- PostgreSQL 17.11 Host extension integration: **107/107**. New acceptance cases verified defaulted child-row persistence with the parent, invalid precision rejection with no stored parent, safe parent tombstoning, exact-scope child reference enforcement, refusal to delete a referenced target, and release of that restriction after deleting the referencing parent.
- Core, Host, Host API, and native-client targeted Dart analysis: **no issues found**.
- Localization CI gate and its six tests: **passed**.

All checks used the declarative extension package and generic Host record operations. Child records use the parent record's existing persistence, authorization, and lifecycle path.
