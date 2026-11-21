# Current Wave 2 acceptance — 2026-11-21

**NOT READY. PR #6 remains Draft and unmerged.** One capability contract PASS; 21 BLOCKED. Individual case successes do not close unexecuted device/recovery gates.

Engineering HEAD `17fa1b7`; candidate product source `17fa1b7`; installed Client `81661f7`, Host `29e36a8`. The [checkpoint](nov21-checkpoint.json) and [JSON matrix](current-acceptance-matrix.json) retain exact source/run identities.

| Capability | Status | Executed subset / remaining acceptance |
|---|---|---|
| A12 | BLOCKED | Corrected installed form customization, custom data across both native Clients, old-record survival and current denials. |
| A11 | BLOCKED | Corrected installed empty-layout editor and published label/layout presentation; invalid/destructive/stale/base-digest installed denials already passed. |
| K09 | BLOCKED | Native offline draft reopen, submit, independent approval and registry install passed; multi-identity edit/retry/conflict and package-compatible rebase remain. |
| D08 | BLOCKED | Installed operation/field grant denials and mid-export revocation passed; full native transfer/hidden-field presentation and two-device current role coverage remain. |
| J01 | BLOCKED | Installed native mapping, quoted CSV, row errors and actual durable valid-row import passed; complete installed data-type/UTF-8 edge matrix remains. |
| J03 | BLOCKED | Stable real row commands, receipt identities, actual service restart and cancellation passed; lost-response/lease-race/existing-record conflict/partial failure acceptance remains. |
| K08 | BLOCKED | Native saved query/export equality and sort/columns, API pagination revocation passed; complete installed stable-page projection/filter/sort denial coverage remains. |
| M01 | BLOCKED | Native company update and installed parent/CAS/current-scope/no-implicit-branch-grant denials passed; complete membership/archive/reactivate/audit gate remains. |
| M02 | BLOCKED | Actual scoped settings persistence, job pause effect and invalid executable/outbound fields passed; native edit/reopen, role switch and secret presentation remain. |
| M05 | BLOCKED | P001-P005 installed backup/schedule/retention/tamper cases unexecuted; trusted signed operational path and effective recovery VM admission/isolation remain. |
| M09 | BLOCKED | P006 real restore/receipt/witness preservation and reconciliation unexecuted. Native upgrade backup is separate evidence. |
| B09 | BLOCKED | Native saved view revision 2, query/export equivalence and explicit-refresh read revocation passed; restart, actor/scope switch and concurrent edits remain. |
| C08 | BLOCKED | Native authorized module/workspace, no-data/loading and denied/refreshed lists observed; second role/device and stale-session/offline presentation remain. |
| C09 | BLOCKED | Native theme/density and draft/command restart persistence passed; old-DB full upgrade, actor/Host separation and Android/narrow presentation remain. |
| C12 | BLOCKED | Native dashboard/report card publication and actual record count passed; complete loading/error/empty and current field/filter revocation presentation remain. |
| F05 | BLOCKED | Installed approved report works and undeclared filter denied; actual cross-release/dependency/package unavailable and revocation compatibility remain. |
| H04 | BLOCKED | Native revision 1/2 chronology, exact command IDs, metadata-only activity and read-revocation clearing/restoration passed; deleted/restricted/cross-scope and cross-record effects remain. |
| B02 | BLOCKED | Unknown contract versions rejected and legacy approved package loaded; corrected installed legacy query/print/conflict paths and full upgrade/version compatibility remain. |
| K10 | BLOCKED | Existing governed business create/update and declarative handler refusal passed; installed submit/cancel/amend/calculation/numbering and malformed operation matrix remains. |
| L01 | BLOCKED | Real Host jobs, per-row receipts, cancellation, actual SCM restart durability and execution-grant revocation passed; multi-worker/crash/lease-fencing/complete diagnostics remain. |
| D09 | BLOCKED | Actual native Host provisioning, DPAPI handoff, pairing, business credentials, TLS matching/wrong pin and current permission denial passed; post-restore identity/credential acceptance remains a release gate. |
| J04 | PASS | None for the bounded API contract: actual authenticated requests and installed rejection of unknown routes/handlers/executable properties/oversize/spoofed scope/outbound metadata verified. Global installer/device/recovery gates remain open. |

Windows stable 72 PASS at fa080fc / run 44912845335 attempt 2; Linux stable 86 PASS at 5374496 / run 44911145739, with implementation applicability checked. The same 158 stable IDs are not added to earlier revisions. Separate: 88 native Client regressions, 14 NHI engineering cases, 54 distinct installed IAPI cases.

The fa080fc unified installer failed safely before file replacement on both test machines. The copied helper lacked explicit DACL protection. The unchanged broker security guard correctly rejected it. 7fbab32 applies the exact protected Administrators/SYSTEM ACL before execution; actual production Inno function passed on TEST-02 and the pinned hosted runner. This is not yet a corrected full-installer upgrade PASS.

P001–P006 remain NOT EXECUTED. Actual native upgrade backup does not substitute for recovery acceptance. A physical TEST-01 Client to TEST-02 Host offline/restart/reconnect subset now passed; concurrent conflict and corrected two-Client convergence remain NOT EXECUTED. Release signing is deferred by the owner; enforced policies stay intact.

Update: pinned SSH to the exact Recovery-Lab VM now succeeds through a single-source rule. Its Hyper-V vNIC has no isolation ACL, and P001–P006 remain unexecuted. The current-address isolation plan was corrected in `15fa989` and checked without applying it. The older verified Client also displayed Host job success, a permission-denied row, and a six-row dashboard report; see [the UI result](native-jobs-dashboard-report-20261121.json).

The full `fa080fc` package has now passed authenticated transport, inner archive, complete 1767-file SHA-256 inventory and exact 1508-entry Git source comparison; its installer still failed both upgrades. The corrected `7fbab32` candidate run `44945607457` failed on attempt 1 during Client dependency preparation and was restarted as attempt 2. No corrected full upgrade is claimed.

A second, independent physical upgrade defect appeared on TEST-01 after the copied-helper ACL correction: the installer copied 1746 expected files, then the strict Host payload check rejected nine retained PostgreSQL 16.15 DLLs absent from the new manifest. The stopped services, database and witness were preserved; the test is **FAIL**, not an upgrade PASS. The silent installer also waited on an unsuppressible message. [Failure evidence](test01-local-acl-upgrade-failure-summary.json) records the exact local hybrid provenance. `17fa1b7` implements verified old-only retirement and bounded silent failure exit; hosted regression run `44955685351` and a new installed candidate remain pending.

`17fa1b7` passed hosted run `44955685351`: 14 native installed/denied Host cases under Restricted, plus an actual Inno silent postinstall fixture that exited 0 on success and 9 on failure within 30 seconds. [Hosted evidence](native-17fa-hosted/results.json) and [the Inno result](native-17fa-hosted/postinstall-exit-postinstall-exit-results.json) are engineering evidence; the physical old-payload upgrade remains open. TEST-01 separately enrolled as a second native Client to TEST-02 with a distinct scoped actor. The first attempt correctly rejected a new IP absent from the Host certificate SAN; a fresh code and `TEST-02` DNS name succeeded. [Enrollment evidence](test01-second-client-pairing-20261121.json). No two-device offline/conflict PASS is yet claimed.

On 2026-11-22, TEST-01 activated the Host-approved Wave 2 package and displayed six TEST-02 Host records in native Workspace. A local command then received an accepted Host receipt and appeared as the seventh record. With only `VentioHost` stopped on TEST-02, a second native command remained `PENDING` in TEST-01 SQLite through a Client restart; the Host still had seven records after restart. Native reconnect sync accepted that exact command once; the Host returned eight records and repeated sync did not duplicate it. [Case evidence](test01-test02-client-host-sync-20261122.json). This closes the outage/restart subset, not the full two-Client conflict or network-disconnect gate.

TEST-02 still runs Client `81661f7`; its `LOCAL_PACKAGE_DIFFERS_FROM_HOST_APPROVED_RELEASE` view uses the older `exportBundle` digest path. Installed SQLite bundle, Dart canonical roundtrip, authenticated Host approved digest and Host records digest all match. Current source has the retained-bundle correction from `5374496`; installed retest waits for the `17fa1b7` full candidate. PR #6 remains Draft, **NOT READY**.
