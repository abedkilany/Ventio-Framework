# Wave 2 B corrective engineering — 2026-11-18

Status: IN PROGRESS / NOT OWNER ACCEPTED. This record supersedes the previous
candidate's deployment recommendation when completed. No installation on TEST-01
or TEST-02 is authorized or performed. PR #6 stays Draft; Wave_2_C remains closed.

## Scope and preservation

All original 161 prepared case IDs remain; S021–S023 add exact imported-package
identity, same-version substitution rejection and genuine SQLite v12→v13 upgrade
coverage. The source inventory now contains 164 cases covering aspects of all 22
capabilities. It deliberately supplies no execution status. CI evidence identifies
actual revisions, cases and fixtures separately. Six manual cases stay separate.
The original uncommitted-work backup and historical hosted evidence are retained.

No product/test/installer was executed locally, and neither physical computer was
accessed. All product execution in this correction phase uses fresh GitHub-hosted
runners. No old BAHAA-built artifact is an input. Normal protection was enabled;
no Defender exclusion, policy bypass or quarantine restoration was introduced.

## Corrections and established causes

| Finding | Cause and correction | Evidence boundary |
|---|---|---|
| Customization SQL | PostgreSQL parsed unparenthesized JSON extraction/subtraction incorrectly. Append-only migration 041 replaces the function body with explicit parentheses, preserving its owner/ACL. The vetted bootstrap/upgrade overlay reapplies the same correction. Original migrations 001–040, original wave2.sql and Recovery Authority implementation remain unchanged. | H/D/O/U pass in Linux run 44259614116. U runs independently from admitted 036 and 040 baselines; 040 interruption proves function/ledger/witness rollback before retry, preserved identities and security-overlay replay. Not physical installed-Host recovery acceptance. |
| Invalid history cursor | PostgreSQL SQLSTATE 22023 escaped the history-list gateway as a server error. Only that operation now maps it to INVALID_CURSOR/400. | H023 passes with the unchanged invalid-cursor expectation. Authorization errors remain distinct. |
| Windows ancestor ACL | InheritOnly ACEs do not apply to the ancestor itself; the validator treated them as effective destructive grants. Ignore that flag only in the ancestor effective-right check. Direct destructive grants remain rejected. | W001–W011 pass in Windows run 44261204268; W008 covers a private child under inherit-only rights and rejects a direct Delete ACE. |
| Atomic operation replacement | PowerShell converted an untyped null backup-file argument to an empty string for File.Replace. Use the typed NullString.Value. | W008–W011 pass, including real replacement and residue/security boundary checks. |
| Authorized native navigation | Re-exporting imported metadata changed its canonical representation, so the real current Host-approved SHA did not match. SQLite v13 stores the original complete bundle and verifies its projection before reading it; same-version content replacement is rejected. Current Host approval/digest verification remains mandatory. | G001 passes in run 44261204268. New S021–S023 require the recorded corrective candidate execution; legacy snapshot-less packages remain fail-closed until explicitly replenished with an approved package. |
| Same-session customization refresh | Refresh temporarily removes authorized module tiles. The unkeyed ExpansionTile loses expansion state. Add profile/release-scoped PageStorage identity without retaining authority or links. | G005 passes in focused run 44265006802, along with all six other G cases. |
| Report rendering/test synchronization | Aggregate output used raw aggregate IDs. Resolve the label from approved report metadata. The test previously treated frame settling as completion of real HTTP/SQL work; use a bounded wait for a real dialog or error banner and retain Count: 1 assertion. | G006 passes in focused run 44265006802 against real authenticated HTTP/PostgreSQL. Error diagnostics remain available rather than substituted results. |

## Supported runtime update

PostgreSQL is pinned to upstream Windows 16.16-1 (archive SHA-256
`5c0d06f3d26a929ecb36dd931409f1e51a4181355794a259b90aae8bffc57a9f`,
378,078,504 bytes), with exact current-engine checks. Restore validators explicitly
accept 16.15 and 16.16 backup producers while retaining existing identity, schema,
manifest and integrity checks. They do not accept arbitrary major-version matches.
No old backup or database is removed. See the
[PostgreSQL 16.16 release notes](https://www.postgresql.org/docs/release/16.16/).

Service and broker builds/tests target self-contained .NET 10.0.15 with exact SDK
10.0.404 and roll-forward disabled. The inputs file records the official SDK
archive SHA-512 and release metadata. See the
[official .NET 10 downloads](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)
and [.NET support lifecycle](https://learn.microsoft.com/en-us/lifecycle/products/microsoft-net-and-net-core).
The SDK/runtime pins affect services/broker; the Flutter and Host Dart pins remain
3.44.1 and 3.13.7 respectively, with lockfiles enforced.

Both real .NET service/broker test programs pass in run 44260885899. The former
service-test fixture assumed a registered virtual-account name; it now obtains
the real deterministic service SID through the read-only SCM showsid operation,
without registering a service or replacing the ACL assertions.

Run 44262789016 passes PG-PHYSICAL-MINOR-UPDATE: initializes an actual 16.15
cluster from separately downloaded, hash-pinned upstream binaries, seeds data and
a forced-RLS restricted role, stops it, opens the same data files with 16.16,
authenticates, and verifies data and tenant filtering. This is a storage-layer
minor-update check, not a Recovery Authority or installed-service pass.

## Open recovery finding — do not relabel as passed

PG-SINGLE-USER-RECOVERY fails in run 44260885899 before fixture database creation:
direct postgres --single refuses the runner's administrative token. The retained
stderr explicitly requires an unprivileged user. Credential rotation and later
recovery assertions consequently remain UNEXECUTED, despite two earlier narrow
backup-collision/failure-classification checks completing.

Source review finds the same direct elevated launch in
recover-host-database-credentials.ps1: normal mode requires Administrator and then
invokes postgres --single without a supported non-administrative execution
boundary. This is a production contract incompatibility identified statically;
the full installed recovery path was not reproduced on a service-owned cluster.
It is not established that the 16.16 update introduced it. Existing protected
data ACLs admit Administrators, SYSTEM and the PostgreSQL service SID; merely
filtering out Administrator membership is not sufficient evidence that a child
can access those data files.

Required closure: a bounded, reviewed maintenance execution path under the
supported PostgreSQL service identity, tested on a genuinely disposable installed
cluster, retaining exclusive shutdown, private backup-before-write, exact paths,
role/migration validation, secret redaction and the external Recovery Authority.
Prove success, denied token/path, interrupted rotation and failed post-validation
recovery. Do not broaden data ACLs, turn off PostgreSQL's administrator refusal,
extract arbitrary process tokens, reactivate bootstrap access or treat a mock as
that evidence. No speculative token/service-identity change was made here.

## Installed fixture and physical gates

The owner confirmed that no dedicated VM is available and requested preparation
only. The [VM provisioning/admission runbook](WAVE_2_B_DISPOSABLE_VM_RUNBOOK.md)
and prepare_installed_vm_fixture.ps1 are supplied and statically parsed, never
invoked. P001–P006 remain BLOCKED_PREREQUISITE. Their absence blocks installed
schedule, retention, integrity, restore and reconciliation acceptance.

Genuine M001–M006 manual GUI/two-device/restart acceptance also remains unexecuted.
Same-machine offline queue tests and a hosted Client-only installation smoke
cannot establish physical synchronization, manual usability or owner acceptance.

## Candidate and deployment gate

The eeeb32a candidate built in run 44262578696 is SUPERSEDED: its acceptance gate
failed G005/G006. It is retained as failure evidence and must not be deployed.
The final corrected candidate uses version 0.1.23+24. Complete member manifest,
protected scan results and exact-revision case ledger are pending its new hosted
build/verification. Static Dart formatting was applied to changed source files;
that text transformation did not execute a Ventio product or test locally.

No physical installation is currently approved. Preserve TEST-01's existing Host,
PostgreSQL data, services, credentials, backups and external Recovery Authority.
Any later TEST-02 Client-only deployment must use a fresh exact verified artifact,
normal UAC/security policy, no automatic launch or Host provisioning, and a fresh
Client profile. Pairing/synchronizing against TEST-01 can write to its Host and
requires a separately approved acceptance step. A later TEST-01 Host upgrade needs
its own verified backup/recovery and owner-approved plan; copying new payloads is
not a substitute for that plan.
