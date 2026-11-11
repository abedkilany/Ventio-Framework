# Ventio Inventory Operations

This official reference extension is a data-only Ventio package. Import `extension.json` through the ordinary Extension Studio package import flow, review it, and submit it for normal Host approval. It contains no executable code, SQL, scripts, or privileged Core/Host hooks.

The package declares:

- `Product` with a quantity balance.
- `Movement` with typed `lines` and calculated line and document totals.
- Generic governed Submit (number allocation, row-based Product quantity effect, status transition), Cancel (reverse row effect, status transition), and Amend operations.
- A movement totals report and an A4 movement print format.
- Stable namespaced permissions for ordinary record operations and governed operations.

Local draft commands remain provisional in the Windows SQLite store and reconcile only from Host receipts. Business operations run through the approved generic Host engine. The package deliberately declares no offline executable handlers.

The PostgreSQL Host integration loads this exact JSON package as an ordinary submitted and operator-approved extension. Core parsing is also covered by `packages/ventio_core/test/all_tests.dart`.
