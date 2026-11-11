# ADR-014: Declarative Print Formats

- Status: Accepted for Wave 1 G01
- Date: 2026-10-28
- Scope: bounded printable document formats for approved extension DocTypes

## Context

Wave 1 G01 requires an ordinary extension creator to define a print layout for scalar fields, Child Table rows, totals, and page breaks, then render a stable PDF from a document the caller is currently authorized to read. Uploaded templates, HTML, scripting, and arbitrary extension code are outside the trust boundary.

The record page may contain a cached or provisional value. A print operation must not treat that local state as current Host authority. Field permissions apply to every selected source field, and the approved extension package digest must match the local declarative metadata before rendering.

## Decision

1. Print formats are top-level declarative data in the ordinary extension bundle, alongside DocTypes and reports. The Local Extension Studio persists drafts and exports them for the same Host review and approval path. A format declares a stable ID, English label/catalog key, source DocType, paper size/orientation, and ordered content blocks.
2. The only block kinds are `field` for one scalar DocType field, `table` for selected scalar Child DocType columns, and `page_break`. A format cannot declare HTML, CSS, SQL, expressions, scripts, executable templates, or arbitrary handlers. Structural bounds are enforced by Core before package installation.
3. The native print action fetches the exact record from the configured Host using the authenticated package client. It verifies the approved package digest, record identity, and Host-returned readable field mask. It renders only that response and the selected format from the same digest. A missing, denied, stale-package, local-only, pending, or deleted record is not printed.
4. The trusted native renderer maps the selected blocks into a fixed page layout and creates PDF output using the platform PDF library. Page size/orientation are selected from the format metadata; tables flow across pages, and explicit page-break blocks create a new page. Labels resolve through the shared English-first localization mechanism; stored business values are rendered verbatim and are never interpreted as markup.
5. Rendering limits bound the output: 64 blocks per format, 10 columns per table block, 32 formats per bundle, and no more than Core's existing 500 rows per Child Table field. Exceeding a bound fails with a stable localized message rather than silently truncating content.
6. Printing is a read-only presentation operation. It cannot alter business records, numbering, lifecycle state, offline commands, or Host receipts. A canceled system print dialog is a normal user cancellation.

## Consequences

- Ordinary extension creators can author and export a printable document layout without Core or Host-specific business code.
- The Host remains authoritative for document visibility and field masks; the local renderer receives a fresh approved record snapshot before it prints.
- The layout contract stays small and reviewable. More complex conditional layouts or jurisdiction-specific document policy require a new versioned contract.
- Windows is the primary native print target for Wave 1. The PDF output remains a standard document artifact and does not require changing stored business data.

## Acceptance mapping

- Core validates and round-trips supported format metadata and rejects unknown block kinds, fields, child columns, and out-of-bound definitions.
- SQLite persistence and package export prove an ordinary creator can save a format and its English labels.
- Extension Studio proves a creator can add field, Child Table, and explicit page-break blocks.
- Renderer tests prove a valid PDF is produced with stable declared layout, field/row values, totals, and explicit page breaks; unauthorized or missing fields fail closed.
- Host-backed record detail tests prove the print path requests one exact approved record, verifies package digest and returned field permissions, and rejects inaccessible or stale records before invoking the printer.
- Windows print integration uses the system print dialog. Existing Host authorization, field-mask, and package-approval integration remains the authority evidence.
- Localization gate covers all first-party print authoring and error messages.
