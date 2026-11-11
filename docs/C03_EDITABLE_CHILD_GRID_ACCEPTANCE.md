# C03 Acceptance — Editable Child-Row Grid

**Status:** Accepted  
**Historical status:** Missing  
**Wave 1 work performed:** Newly Implemented  
**Schema contract:** [ADR-011 — Embedded Child DocTypes](../decisions/ADR-011_EMBEDDED_CHILD_DOCTYPES.md)  
**Prerequisite:** [A07 Child / Table DocTypes](A07_CHILD_DOCTYPE_ACCEPTANCE.md)

## Accepted behavior

- Generated forms render typed child tables as a metadata-driven grid; legacy untyped table fields retain their JSON editor.
- Users can add, edit, remove, and reorder multiple child rows. Defaults are populated for new rows, and the grid displays the current row count.
- Every editable child cell uses its declared field type and constraints. Required values and invalid decimal precision are reported at the cell, and invalid rows prevent saving.
- The parent field's existing read/write permission controls the whole grid. Child rows remain part of the parent payload and lifecycle.
- Saving produces one parent record write and one durable parent command containing the same ordered child rows. A restart preserves that pending command and its row payload.

## Verification evidence

- Extension Studio suite: **24/24** passed, including the child-row grid flow. A final focused rerun after adding the decimal precision validation case passed **1/1**.
- Grid scenario: three rows added and edited; required-value and decimal-precision violations rejected without creating a parent; one row removed; remaining rows reordered; saved parent values and pending command payload matched exactly.
- Durable queue child-row restart test: **1/1** passed; the parent command remained pending and retained row values and order after close/reopen.
- A07 SQLite ExtensionStore suite: **35/35** passed, including typed child-row persistence across database restart.
- Native-client targeted analysis: **no issues found**. Localization CI gate and its six scanner tests passed.
- The full queue test file has **13 passing tests and one unrelated failure**: its abrupt child-process recovery case exits with a Dart FFI transformer error (exit 252) before the test body. The dedicated child-row queue restart test passes **1/1**.

The grid uses the same declarative child schema, parent field permissions, SQLite record store, and generic extension command path available to ordinary extension creators.
