# Wave 2 B corrective case evidence

Candidate commit `50d4d2bb41891d8d598d9e6f2408773411dc97b1`; Windows run [44267441630](https://github.com/abedkilany/Ventio-Framework/actions/runs/44267441630).

Actual outcomes at listed exact revisions. Earlier Linux evidence remains revision-specific; mapped-path equality is limited dependency evidence, not a full dependency closure or a rerun. Auxiliary runtime/storage checks are separate from this 164-case ledger. P001-P006 and M001-M006 remain unexecuted.

164 automated source cases: {'PASSED': 158, 'BLOCKED_PREREQUISITE': 6}. All original 161 IDs are preserved. Six separate manual cases remain unexecuted. No capability is owner-accepted.

## Capability evidence

| Capability | Passed | Failed | Unexecuted | Blocked |
|---|---:|---:|---:|---:|
| A11 | 5 | 0 | 0 | 0 |
| A12 | 18 | 0 | 0 | 0 |
| B02 | 15 | 0 | 0 | 0 |
| B09 | 15 | 0 | 0 | 0 |
| C08 | 12 | 0 | 0 | 0 |
| C09 | 18 | 0 | 0 | 0 |
| C12 | 5 | 0 | 0 | 0 |
| D08 | 16 | 0 | 0 | 0 |
| D09 | 21 | 0 | 0 | 1 |
| F05 | 10 | 0 | 0 | 0 |
| H04 | 4 | 0 | 0 | 0 |
| J01 | 13 | 0 | 0 | 0 |
| J03 | 28 | 0 | 0 | 1 |
| J04 | 10 | 0 | 0 | 0 |
| K08 | 4 | 0 | 0 | 0 |
| K09 | 24 | 0 | 0 | 0 |
| K10 | 4 | 0 | 0 | 0 |
| L01 | 30 | 0 | 0 | 0 |
| M01 | 9 | 0 | 0 | 0 |
| M02 | 12 | 0 | 0 | 0 |
| M05 | 24 | 0 | 0 | 6 |
| M09 | 21 | 0 | 0 | 3 |

## Case-level outcomes

| Case | Capabilities | Outcome | Run / revision | Requirement |
|---|---|---|---|---|
| W2-C001 | A12 | PASSED | 44267441630 / 50d4d2bb4189 | All seven optional scalar custom types merge without mutating package bytes |
| W2-C002 | A12 | PASSED | 44267441630 / 50d4d2bb4189 | Required, executable, reference and table custom fields are refused |
| W2-C003 | A12 | PASSED | 44267441630 / 50d4d2bb4189 | Twenty custom fields accepted; twenty-one and duplicate names rejected |
| W2-C004 | A12 | PASSED | 44267441630 / 50d4d2bb4189 | ACL weakening and collisions with base fields are rejected by effective merge |
| W2-C005 | A12,K09 | PASSED | 44267441630 / 50d4d2bb4189 | Saved custom fields cannot be removed or structurally converted |
| W2-C006 | A11 | PASSED | 44267441630 / 50d4d2bb4189 | Presentation merge retains required fields and is deterministic |
| W2-C007 | A11 | PASSED | 44267441630 / 50d4d2bb4189 | Duplicate/unknown layout fields, unsupported icons and out-of-range order fail |
| W2-C008 | A11,A12 | PASSED | 44267441630 / 50d4d2bb4189 | Namespace and catalog collisions cannot overwrite labels |
| W2-C009 | K09,A12 | PASSED | 44267441630 / 50d4d2bb4189 | Explicit newer-release rebase preserves ACLs and custom fields |
| W2-C010 | A12,K09 | PASSED | 44267441630 / 50d4d2bb4189 | Validated overlays deep-copy caller-owned JSON |
| W2-C011 | J01 | PASSED | 44267441630 / 50d4d2bb4189 | CSV handles BOM, CRLF, escaped quotes, empty and multiline cells |
| W2-C012 | J01 | PASSED | 44267441630 / 50d4d2bb4189 | CSV rejects malformed quotes, NUL, duplicate and empty headers |
| W2-C013 | J01 | PASSED | 44267441630 / 50d4d2bb4189 | CSV exact row/column/cell limits and UTF-8 byte bound are enforced |
| W2-C014 | J01,J03 | PASSED | 44267441630 / 50d4d2bb4189 | Mixed invalid rows preserve original logical source-row numbers |
| W2-C015 | J01,D08 | PASSED | 44267441630 / 50d4d2bb4189 | CSV cannot map record identity, duplicate targets, unknown or unwritable fields |
| W2-C016 | J01 | PASSED | 44267441630 / 50d4d2bb4189 | Typed imports reject exponent/hex, non-boolean and excess decimal scale |
| W2-C017 | K08,J01 | PASSED | 44267441630 / 50d4d2bb4189 | Export escapes formula strings but preserves numeric negatives and JSON |
| W2-C018 | B09 | PASSED | 44267441630 / 50d4d2bb4189 | Saved-view filters, sorting and columns round-trip immutably |
| W2-C019 | B09,J04 | PASSED | 44267441630 / 50d4d2bb4189 | Saved views reject nested filters, duplicate columns and executable properties |
| W2-C020 | C09 | PASSED | 44267441630 / 50d4d2bb4189 | Preferences enforce theme, density and unique bounded module order |
| W2-C021 | C12,F05 | PASSED | 44267441630 / 50d4d2bb4189 | Dashboard accepts twelve declarative cards and rejects thirteen or executable cards |
| W2-C022 | M01 | PASSED | 44267441630 / 50d4d2bb4189 | Organization change has bounded identity, explicit CAS and fixed parent rules |
| W2-C023 | M02 | PASSED | 44267441630 / 50d4d2bb4189 | Operational bounds accept maxima and reject zero, excess and wrong types |
| W2-C024 | M05 | PASSED | 44267441630 / 50d4d2bb4189 | Backup policy bounds include retention, retries and UTC schedule |
| W2-C025 | M09,M05 | PASSED | 44267441630 / 50d4d2bb4189 | Restore needs exact backup identity and pinned plan; arbitrary paths denied |
| W2-C026 | B02,J04 | PASSED | 44267441630 / 50d4d2bb4189 | Unknown contract versions, kinds and executable integration keys are refused |
| W2-C027 | B02,K10 | PASSED | 44267441630 / 50d4d2bb4189 | Existing v1 record envelope round-trips and rejects unsupported command version |
| W2-C028 | A12,B02,J04 | PASSED | 44267441630 / 50d4d2bb4189 | Definitions enforce encoded byte ceiling and reject unknown overlay keys |
| W2-C029 | J01,K10 | PASSED | 44267441630 / 50d4d2bb4189 | CSV date enum reference and child JSON preserve types with exact defaults and calculations |
| W2-C030 | J01 | PASSED | 44267441630 / 50d4d2bb4189 | CSV rejects invalid calendar enum reference and malformed forbidden or imprecise child rows |
| W2-C031 | J01,D08,K10 | PASSED | 44267441630 / 50d4d2bb4189 | CSV cannot map a calculated output or read-only field even with writable-field labels |
| W2-S001 | C09,D09 | PASSED | 44267441630 / 50d4d2bb4189 | unbound profiles cannot open the workspace |
| W2-S002 | K09,C09 | PASSED | 44267441630 / 50d4d2bb4189 | offline draft body and stable request survive reopening |
| W2-S003 | K09,C09 | PASSED | 44267441630 / 50d4d2bb4189 | a newer Host definition marks conflict without replacing local intent |
| W2-S004 | K09 | PASSED | 44267441630 / 50d4d2bb4189 | unchanged base revision does not overwrite a dirty local edit |
| W2-S005 | K09 | PASSED | 44267441630 / 50d4d2bb4189 | replayed matching publication can acknowledge a lost response |
| W2-S006 | K09 | PASSED | 44267441630 / 50d4d2bb4189 | stale acknowledgement cannot mark an intervening edit synced |
| W2-S007 | K09 | PASSED | 44267441630 / 50d4d2bb4189 | explicit rebase preserves chosen content and creates new CAS intent |
| W2-S008 | B09,C08,K09 | PASSED | 44267441630 / 50d4d2bb4189 | authoritative retirement removes synced metadata and preserves drafts/conflicts |
| W2-S009 | B09,C08,C09 | PASSED | 44267441630 / 50d4d2bb4189 | owner isolation covers endpoint tenant company branch and actor |
| W2-S010 | C08,F05 | PASSED | 44267441630 / 50d4d2bb4189 | cached package stays owner-isolated metadata and retains its original digest inputs |
| W2-S011 | J03,K09 | PASSED | 44267441630 / 50d4d2bb4189 | import command IDs and sparse source rows persist before dispatch |
| W2-S012 | J03 | PASSED | 44267441630 / 50d4d2bb4189 | invalid later batch rolls back all staged jobs atomically |
| W2-S013 | J03 | PASSED | 44267441630 / 50d4d2bb4189 | missing source-row mapping and oversized batch leave no retry intent |
| W2-S014 | J03,C09 | PASSED | 44267441630 / 50d4d2bb4189 | another owner cannot acknowledge pending import intent |
| W2-S015 | M05,M09 | PASSED | 44267441630 / 50d4d2bb4189 | operation retry IDs persist and the twenty-pending bound fails closed |
| W2-S016 | M05,M09 | PASSED | 44267441630 / 50d4d2bb4189 | discarding a local retry cannot discard another owner operation |
| W2-S017 | K09,J03,C09 | PASSED | 44267441630 / 50d4d2bb4189 | workspace v1 to v3 preserves pending commands and dirty CAS drafts |
| W2-S018 | J03,C09 | PASSED | 44267441630 / 50d4d2bb4189 | workspace v2 to v3 preserves import correlation and commands exactly |
| W2-S019 | C09,K09 | PASSED | 44267441630 / 50d4d2bb4189 | real workspace connection uses WAL FULL and foreign-key enforcement |
| W2-S020 | B09,C09,C12 | PASSED | 44267441630 / 50d4d2bb4189 | invalid authoritative receive is atomic and cannot erase valid local definitions |
| W2-S021 | C08,F05,B09 | PASSED | 44267441630 / 50d4d2bb4189 | imported package identity survives reopen without draft catalog normalization |
| W2-S022 | C08,F05,B09 | PASSED | 44267441630 / 50d4d2bb4189 | same-version catalog substitution is rejected and preserves installed identity |
| W2-S023 | C08,F05,B09 | PASSED | 44267441630 / 50d4d2bb4189 | additive v12 upgrade preserves metadata and projected tampering fails closed |
| W2-H001 | D09,J04 | PASSED | 44259614116 / e56fbe3304ea | Platform routes reject missing and invalid bearer credentials |
| W2-H002 | D09,B02 | PASSED | 44259614116 / e56fbe3304ea | Real session discovery resolves current authoritative actor and scope |
| W2-H003 | J04,B02 | PASSED | 44259614116 / e56fbe3304ea | Platform methods content type versions and unknown properties fail strictly |
| W2-H004 | J04 | PASSED | 44259614116 / e56fbe3304ea | Malformed UTF-8 oversized bodies and excessive nesting fail before gateway execution |
| W2-H005 | M02,D09 | PASSED | 44259614116 / e56fbe3304ea | A stale authenticated snapshot cannot retain revoked configuration authority |
| W2-H006 | M02,D09 | PASSED | 44259614116 / e56fbe3304ea | Later user grants cannot widen a credential ceiling |
| W2-H007 | C09,K09 | PASSED | 44259614116 / e56fbe3304ea | Definition publication retries are idempotent and request reuse with different content conflicts |
| W2-H008 | B09,C09,K09 | PASSED | 44259614116 / e56fbe3304ea | Concurrent same-revision saves yield exactly one winner |
| W2-H009 | B09,C08,C09 | PASSED | 44259614116 / e56fbe3304ea | User-owned definitions stay separate for actors and tenants |
| W2-H010 | C09,M02 | PASSED | 44259614116 / e56fbe3304ea | Company branch pairs are checked exactly and shared settings remain scoped |
| W2-H011 | B09,C09 | PASSED | 44259614116 / e56fbe3304ea | Hundred-definition owner bound refuses the next save without dropping content |
| W2-H012 | M02 | PASSED | 44259614116 / e56fbe3304ea | Configuration persists through HTTP reassembly and denied writes have no effect |
| W2-H013 | A11,A12 | PASSED | 44259614116 / e56fbe3304ea | SQL and Core effective overlays agree while approved package bytes stay immutable |
| W2-H014 | A12,K09 | PASSED | 44259614116 / e56fbe3304ea | Wrong base digest and destructive field conversion fail without advancing revision |
| W2-H015 | A12,D08 | PASSED | 44259614116 / e56fbe3304ea | Authoritative record writes use effective custom fields and preserve old records |
| W2-H016 | D08,J01 | PASSED | 44259614116 / e56fbe3304ea | Import preview requires current create and field-write grants |
| W2-H017 | J01,J03 | PASSED | 44259614116 / e56fbe3304ea | Preview preserves sparse source rows and detects readable existing IDs |
| W2-H018 | M02,J01 | PASSED | 44259614116 / e56fbe3304ea | Configured import row bound is consumed by the real gateway |
| W2-H019 | K08,D08 | PASSED | 44259614116 / e56fbe3304ea | Export projection matches query and safely escapes formula strings |
| W2-H020 | K08,B09,D08 | PASSED | 44259614116 / e56fbe3304ea | Hidden fields cannot be used to filter or sort visible exports |
| W2-H021 | K08,B09 | PASSED | 44259614116 / e56fbe3304ea | Query cursors bind pagination to filter sort limit release and scope |
| W2-H022 | H04 | PASSED | 44259614116 / e56fbe3304ea | History is ordered metadata-only activity and command replay creates no duplicate event |
| W2-H023 | H04 | PASSED | 44259614116 / e56fbe3304ea | History cursor and deleted-ID lookup stay record and tenant bound |
| W2-H024 | M01 | PASSED | 44259614116 / e56fbe3304ea | Organization CAS retries do not duplicate entities or confer grants |
| W2-H025 | M01,D09 | PASSED | 44259614116 / e56fbe3304ea | Current scope cannot be archived and unauthorized hierarchy changes are denied |
| W2-H026 | C12,F05 | PASSED | 44259614116 / e56fbe3304ea | Dashboard report query uses approved metadata and rejects unknown filters/report IDs |
| W2-H027 | M05,M09 | PASSED | 44259614116 / e56fbe3304ea | HTTP operation requests do not execute local operations when not provisioned |
| W2-H028 | A12,K09 | PASSED | 44259614116 / e56fbe3304ea | Rebase agrees with Core and requires every affected scope atomically before approval |
| W2-H029 | F05,C08,D09 | PASSED | 44259614116 / e56fbe3304ea | Release revocation denies metadata queries and dashboard reports despite stored local definitions |
| W2-J001 | J03,L01 | PASSED | 44259614116 / e56fbe3304ea | Jobs accept one and twenty-five commands and remain cancellable before dispatch |
| W2-J002 | J03,J04 | PASSED | 44259614116 / e56fbe3304ea | Empty twenty-six-command and oversized wire jobs are rejected |
| W2-J003 | J03,L01 | PASSED | 44259614116 / e56fbe3304ea | Duplicate command IDs in one job are refused by SQL |
| W2-J004 | B02,J04 | PASSED | 44259614116 / e56fbe3304ea | Direct job envelopes receive strict HTTP command-shape validation |
| W2-J005 | D08,D09,J03 | PASSED | 44259614116 / e56fbe3304ea | Job tenant actor device scope dependencies and delete restrictions are enforced |
| W2-J006 | J03,L01 | PASSED | 44259614116 / e56fbe3304ea | Lost submit-response retries preserve identity; changed payload or source labels conflict |
| W2-J007 | J03 | PASSED | 44259614116 / e56fbe3304ea | Source-row labels must match commands be unique integers and retain original range |
| W2-J008 | L01,D08 | PASSED | 44259614116 / e56fbe3304ea | Public job listing redacts command payloads digests and lease tokens |
| W2-J009 | L01 | PASSED | 44259614116 / e56fbe3304ea | Concurrent real transactions cannot claim the same runnable job twice |
| W2-J010 | L01,J03 | PASSED | 44259614116 / e56fbe3304ea | Expired lease is reclaimed and stale completion is fenced |
| W2-J011 | L01,J03 | PASSED | 44259614116 / e56fbe3304ea | Retry transition retains row identity backoff and original source correlation |
| W2-J012 | L01 | PASSED | 44259614116 / e56fbe3304ea | Five failed attempts produce bounded terminal rejection without an effect |
| W2-J013 | L01,J03 | PASSED | 44259614116 / e56fbe3304ea | Cancellation before claim prevents execution and is idempotent |
| W2-J014 | L01,J03 | PASSED | 44259614116 / e56fbe3304ea | In-flight acceptance survives cancellation with original source row |
| W2-J015 | L01,J03 | PASSED | 44259614116 / e56fbe3304ea | Cancellation during ambiguous retry records unknown outcome without automatic replay |
| W2-J016 | D09,L01 | PASSED | 44259614116 / e56fbe3304ea | Revocation before claim prevents execution under the stored credential |
| W2-J017 | D08,D09,L01 | PASSED | 44259614116 / e56fbe3304ea | Authority is rechecked inside effect after claim even with a stale session |
| W2-J018 | M02,L01 | PASSED | 44259614116 / e56fbe3304ea | Scoped jobsPaused and maintenanceMode prevent claims until cleared |
| W2-J019 | L01,J03,M02 | PASSED | 44259614116 / e56fbe3304ea | Terminal archival scrubs executable state and keeps IDs hashes totals labels and outcomes |
| W2-J020 | J03,L01 | PASSED | 44259614116 / e56fbe3304ea | Real timed worker executes rows and retains nonconsecutive CSV source labels |
| W2-J021 | J03,L01 | PASSED | 44259614116 / e56fbe3304ea | Commit-before-finish recovery replays the journal receipt instead of duplicating effect |
| W2-J022 | L01,J03 | PASSED | 44259614116 / e56fbe3304ea | Two real workers finish one job without duplicate journal audit or outbox effects |
| W2-J023 | L01,D09 | PASSED | 44259614116 / e56fbe3304ea | Missing independent recovery witness fails closed and records safe worker diagnostics |
| W2-J024 | L01,D08 | PASSED | 44259614116 / e56fbe3304ea | Job visibility and cancellation respect actor ownership and tenant |
| W2-J025 | L01 | PASSED | 44259614116 / e56fbe3304ea | Twenty-active-job ceiling is per actor and does not silently discard jobs |
| W2-J026 | K10,L01,J04 | PASSED | 44259614116 / e56fbe3304ea | Undeclared governed operation cannot acquire an executable handler through a job |
| W2-J027 | L01,J03 | PASSED | 44259614116 / e56fbe3304ea | An actually terminated worker with a committed claim is recovered by a fresh process exactly once |
| W2-D001 | B02,M01,M02,L01 | PASSED | 44259614116 / e56fbe3304ea | All forty-one migration identities match canonical repository sources |
| W2-D002 | B02 | PASSED | 44259614116 / e56fbe3304ea | Applying the same migration directory is idempotent |
| W2-D003 | M01,A12,L01,M05,M09 | PASSED | 44259614116 / e56fbe3304ea | Every new private Wave 2 table has owner RLS FORCE RLS and no public grants |
| W2-D004 | D08,M01,L01 | PASSED | 44259614116 / e56fbe3304ea | Operational roles cannot directly read or mutate private Wave 2 storage |
| W2-D005 | L01,M05,M09 | PASSED | 44259614116 / e56fbe3304ea | Runtime cannot claim finish or manufacture trusted local-operation outcomes |
| W2-D006 | D08,D09,H04 | PASSED | 44259614116 / e56fbe3304ea | Forged tenant and actor GUCs do not create an RLS proof |
| W2-D007 | B09,C09,D08 | PASSED | 44259614116 / e56fbe3304ea | SQL-level saved definitions derive tenant from real digest and remain actor isolated |
| W2-D008 | M01,M02,A12 | PASSED | 44259614116 / e56fbe3304ea | Platform administration permission cannot be manufactured through a business role |
| W2-D009 | B02 | PASSED | 44259614116 / e56fbe3304ea | A later failed migration rolls back earlier new DDL and ledger entries |
| W2-D010 | B02,D09 | PASSED | 44259614116 / e56fbe3304ea | Modified applied checksum is rejected before additional migrations execute |
| W2-D011 | M09,J03,L01,D09 | PASSED | 44259614116 / e56fbe3304ea | Logical restore retains Wave 2 data and receipts but cannot resurrect revoked authority |
| W2-O001 | M05 | PASSED | 44259614116 / e56fbe3304ea | SQL prepares no scheduled operation before an explicit approved policy outcome |
| W2-O002 | M05,M09,D09 | PASSED | 44259614116 / e56fbe3304ea | Operation identity is idempotent and tenant-bound; unauthorized callers cannot prepare |
| W2-O003 | M05 | PASSED | 44259614116 / e56fbe3304ea | SQL approved-policy transition produces one daily offer with stable request identity |
| W2-O004 | M05 | PASSED | 44259614116 / e56fbe3304ea | SQL schedule retry requires known retryable failure backoff and bounded attempt count |
| W2-O005 | M05,M02 | PASSED | 44259614116 / e56fbe3304ea | Changing or disabling policy invalidates old approval instead of silently rearming |
| W2-O006 | M05,M09 | PASSED | 44259614116 / e56fbe3304ea | Trusted outcome inputs are fenced by offer identity exact scope and terminal immutability |
| W2-O007 | M09 | PASSED | 44259614116 / e56fbe3304ea | SQL restore preparation requires a recent successful exact backup plan |
| W2-O008 | M05,D09 | PASSED | 44259614116 / e56fbe3304ea | Expired pending requests and revoked credentials lose executable offers |
| W2-U001 | B02,M01 | PASSED | 44259614116 / e56fbe3304ea | Materialize exact accepted baseline and seed representative legacy records and identity |
| W2-U002 | B02,M01,M02,A12,L01 | PASSED | 44259614116 / e56fbe3304ea | Witness-aware 036/040-to-041 transitions preserve data and reapply real security contracts |
| W2-U003 | B02,M09 | PASSED | 44259614116 / e56fbe3304ea | Replaying the same completed transition does not run its migration callback again |
| W2-R001 | B02,D09,J04 | PASSED | 44259614116 / e56fbe3304ea | WB-CI-02: a changed manifest returns an actual 503 HOST_UNAVAILABLE without transport substitution or effects |
| W2-R002 | B02,D09 | PASSED | 44259614116 / e56fbe3304ea | WB-CI-02: removing the fixture mutation restores admission on the same process |
| W2-E001 | K09,C09,J03 | PASSED | 44259614116 / e56fbe3304ea | offline queued intent survives reopen and reconnect gets a real Host receipt |
| W2-E002 | J03,K09,L01 | PASSED | 44259614116 / e56fbe3304ea | real lost response after commit is recovered without duplicate effects |
| W2-E003 | K09,J03,D08 | PASSED | 44259614116 / e56fbe3304ea | two identities conflict and explicitly reconcile while old receipts remain immutable |
| W2-E004 | K09,D09 | PASSED | 44259614116 / e56fbe3304ea | reconciliation cannot redirect a terminal draft to another owner scope record or device |
| W2-E005 | A12,K09 | PASSED | 44259614116 / e56fbe3304ea | effective-schema queue receipts never project into the immutable base-package cache |
| W2-E006 | D08,D09,K09 | PASSED | 44259614116 / e56fbe3304ea | revocation prevents queued offline work from becoming Host-confirmed |
| W2-G001 | C08,F05,B09 | PASSED | 44267441630 / 50d4d2bb4189 | workspace exposes only current approved installed modules and native navigation |
| W2-G002 | C08,D09 | PASSED | 44267441630 / 50d4d2bb4189 | locally installed metadata grants no navigation without current package authority |
| W2-G003 | C08,F05 | PASSED | 44267441630 / 50d4d2bb4189 | a local package digest mismatch contributes no authorized workspace links |
| W2-G004 | C08,C09,C12 | PASSED | 44267441630 / 50d4d2bb4189 | narrow large-text workspace navigation has no overflow or uncaught rendering error |
| W2-G005 | A11,A12,K09 | PASSED | 44267441630 / 50d4d2bb4189 | repeated Host customization labels refresh in the same app session |
| W2-G006 | C12,F05 | PASSED | 44267441630 / 50d4d2bb4189 | a saved dashboard card opens a real current-authorized Host report |
| W2-G007 | H04,D08 | PASSED | 44267441630 / 50d4d2bb4189 | native document activity renders real command identity without protected values |
| W2-W001 | M05 | PASSED | 44267441630 / 50d4d2bb4189 | Real nested backup inventory contains sorted per-file lengths and SHA-256 |
| W2-W002 | M05,M09 | PASSED | 44267441630 / 50d4d2bb4189 | Same-size one-byte corruption is detected |
| W2-W003 | M05,M09 | PASSED | 44267441630 / 50d4d2bb4189 | Missing files cannot pass inventory verification |
| W2-W004 | M05,M09 | PASSED | 44267441630 / 50d4d2bb4189 | Unexpected files cannot pass inventory verification |
| W2-W005 | M05,M09 | PASSED | 44267441630 / 50d4d2bb4189 | Manifest path traversal absolute paths duplicate names invalid hashes and negative lengths fail |
| W2-W006 | M05,M09 | PASSED | 44267441630 / 50d4d2bb4189 | Junction ancestors are rejected and their target remains intact |
| W2-W007 | M05,M09 | PASSED | 44267441630 / 50d4d2bb4189 | Staged backup copies must match original content before acceptance |
| W2-W008 | M05,M09 | PASSED | 44267441630 / 50d4d2bb4189 | Protected operation JSON is replaced atomically with no temporary residue |
| W2-W009 | M05,M09 | PASSED | 44267441630 / 50d4d2bb4189 | Protected operation JSON enforces byte bounds before decoding |
| W2-W010 | M05,M09 | PASSED | 44267441630 / 50d4d2bb4189 | An untrusted read ACL on a fixture file is rejected |
| W2-W011 | M09 | PASSED | 44267441630 / 50d4d2bb4189 | The real restore entry point refuses missing confirmation before touching services |
| W2-P001 | D09,M05,M09 | BLOCKED_PREREQUISITE | VM absent | Real disposable installed Host authenticates the approved fixture identity |
| W2-P002 | M05 | BLOCKED_PREREQUISITE | VM absent | Supported Host authorization and elevated local approval arm the fixed SYSTEM schedule |
| W2-P003 | M05 | BLOCKED_PREREQUISITE | VM absent | Real scheduled backup verifies content and does not repeat a completed daily offer |
| W2-P004 | M05 | BLOCKED_PREREQUISITE | VM absent | Actual retention removes only eligible old copies and preserves pins foreign kinds and newest backup |
| W2-P005 | M05,M09 | BLOCKED_PREREQUISITE | VM absent | Real restore planning detects same-size corruption before stopping Host |
| W2-P006 | M09,M05,J03 | BLOCKED_PREREQUISITE | VM absent | Disposable restoration preserves current cluster external witness and original record/receipt while leaving Host stopped |

## Manual cases

| Case | Requirement |
|---|---|
| W2-M001 | Owner-visible first-admin bootstrap, independent local login/pairing, TLS fingerprint verification and OS credential-store behavior on the final installed candidate |
| W2-M002 | Two physical cleared devices, independent identities, real network disconnect/reboot/reconnect, conflict resolution and protected-field presentation |
| W2-M003 | Windows keyboard/focus/high-DPI/narrow layout and Android tablet/320-400 px/rotation/accessibility acceptance; desktop size simulation is not Android acceptance |
| W2-M004 | Normal local UAC/approval UX, disk-full/copy/interruption/power-loss scenarios on disposable VM/storage, and review of uncertain physical operation journals |
| W2-M005 | Supported post-restore Recovery Authority reconciliation and fresh authentication without adopting a stale witness or resurrecting credentials |
| W2-M006 | Final installed Windows first-run, upgrade/uninstall, data-retention choices and cleanup in the same interactive session |
