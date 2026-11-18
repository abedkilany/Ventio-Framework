# Wave 2 B corrective engineering — 2026-11-18

Status: PARTIAL VERIFICATION / BLOCKED — NOT OWNER ACCEPTED. The SQL, Windows
integrity and GUI corrections passed their stated CI checks. Full installed
credential recovery, P001–P006 and physical/manual acceptance remain open.
TEST-02 installation stays DEFERRED under the owner's instruction. No installation
on TEST-01 or TEST-02 is authorized or performed. PR #6 stays Draft; Wave_2_C is closed.

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
| Authorized native navigation | Re-exporting imported metadata changed its canonical representation, so the real current Host-approved SHA did not match. SQLite v13 stores the original complete bundle and verifies its projection before reading it; same-version content replacement is rejected. Current Host approval/digest verification remains mandatory. | G001 and S021–S023 pass at candidate commit 50d4d2b in run 44267441630. Legacy snapshot-less packages remain fail-closed until explicitly replenished with an approved package. |
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

Fixture/test-preparation commit `51dbb1815d651de6f099f7667c81dd0b0a4dd0a0`
also corrects a source-identified scheduler assertion race: observing an old Ready
state after Start-ScheduledTask did not prove a new invocation completed. The
prepared helper now waits for a new LastRunTime and successful LastTaskResult.
This strengthened P003/P004 preparation is UNEXECUTED; it does not change candidate
binaries or turn a blocked test into a pass.

Genuine M001–M006 manual GUI/two-device/restart acceptance also remains unexecuted.
Same-machine offline queue tests and a hosted Client-only installation smoke
cannot establish physical synchronization, manual usability or owner acceptance.

## Candidate and deployment gate

The eeeb32a candidate built in run 44262578696 is SUPERSEDED: its acceptance gate
failed G005/G006. It is retained as failure evidence and must not be deployed.
The corrected candidate is
`Ventio-W2B-0.1.23+24-20261118-50d4d2bb4189-gh44267441630-a1`.

- [Canonical Host + Client + Installer artifact](https://github.com/abedkilany/Ventio-Framework/actions/runs/44267441630/artifacts/14411753686).
  Build run 44267441630 passed. Source commit
  `50d4d2bb41891d8d598d9e6f2408773411dc97b1`; Git tree
  `969701db747c5a2293f5fa348b6ab6a5a14b8d3d`.
- Complete inner ZIP: 276,469,023 bytes; SHA-256
  `2acbf5bf37698a0876a9a78b5eb6a8a0e586fbe352f08d05c4b30734cd82b85c`.
  GitHub outer transport: artifact 14411753686, 275,581,219 bytes, SHA-256
  `1a04f1c12dfa84a4eb370ca6d3de862f3766e41b18af223266015224fbe533ea`.
- All 1,765 members verified independently; 1,764 checksum entries and 1,763
  inventory entries. The checksum file itself is anchored by the ZIP digest.
  All 822 archived source entries match the independently regenerated Git archive.
  Git checkout line-ending representation is recorded rather than equated to raw
  blobs: 157 match raw blobs, 665 use the recorded checkout representation.
- Windows run 44267441630 records C31/S23/W11/G7 = 72 passed cases at the exact
  candidate commit. Linux run 44259614116 records H29/J27/D11/O8/U3/R2/E6 = 86
  unique passed IDs at e56fbe3, with both U baseline variants retained. Total:
  **158 PASSED, 6 BLOCKED_PREREQUISITE**, plus six separate MANUAL_UNEXECUTED cases.
  These are partial capability checks, not complete acceptance of 22 capabilities.
- [Protected verification run 44271082527](https://github.com/abedkilany/Ventio-Framework/actions/runs/44271082527)
  passed at verification commit 8488602. Enabled/current Defender scanned the exact
  ZIP and extracted payload with signatures 1.463.353.0 and matched target-specific
  start/completion IDs; no threats/detections were reported. Post-scan hashes match.
  Real-time, behavior, IOAV and archive scanning remained enabled; scan exclusions
  were empty. The build's separately retained scans also reported no new detection.
- The protected fresh Client-only installer/uninstaller smoke returned 0/0 and
  compared all 1,744 installed Client/Host payload files. No application launch,
  Host provisioning, product data/service or execution-policy change occurred.
  This does not validate an existing Host upgrade, restrictive-policy operation,
  missing-runtime/reboot/error branches or a Windows 11 physical GUI session.
- [Final data-only source/header review run 44273406077](https://github.com/abedkilany/Ventio-Framework/actions/runs/44273406077)
  passed at review commit 4b905b4. Its locally verified 210,002-byte report artifact
  14412649567 has SHA-256
  `6b06a32ad0fee70810460f6984e37a3ed4d1db10c1ed619163254d644f00bf77`.
  Source/sidecar exports and header review ran no product or test. Earlier data-only
  exports are retained as iterative evidence, not additional product-test passes.

The [complete member hashes](evidence/20261118-corrective/runs/44273406077/SHA256SUMS.txt),
[build metadata](evidence/20261118-corrective/runs/44273406077/build-metadata.json),
[source proof](evidence/20261118-corrective/runs/44273406077/exported-artifact-review.json),
[PE/AOT header inventory](evidence/20261118-corrective/runs/44273406077/pe-header-inventory.json)
and [protected scan/install evidence](evidence/20261118-corrective/runs/44271082527/protected-verification.json)
are retained with raw-byte Git attributes and an evidence hash index. The full
binary ZIP remains on GitHub; no full local mirror is claimed. Actions artifacts
have 30-day retention; this binary artifact expires 2026-12-18 08:53:15 UTC and
needs preservation before expiry if testing is delayed.

Recorded toolchain: Host Dart 3.13.7; Flutter 3.44.1/Dart 3.12.1; .NET SDK
10.0.404/runtime 10.0.15; PostgreSQL 16.16-1; Inno 6.7.4; MSVC 14.51.36231
(cl 19.51.36260.0); image win25-vs2026, version 20261103.298.1. Compiler hashes,
actual package assets and enforced Dart lockfiles are retained. Reproduction inputs
are pinned/recorded; a byte-identical rebuild has not been demonstrated. Static
Dart formatting was a text transformation, not local product/test execution.

Static content review finds 208 PE files: 192 Valid signatures, 16 NotSigned, no
invalid signatures or additional unexpected PE paths. Client/data/app.so is an
ELF64 little-endian x86-64 AOT payload (header 7f454c4602010100...), not a PE;
Windows Authenticode does not apply. Its complete hash and build provenance are
verified. No package-member names indicate IntelRapid.exe, KMSpico or ProtoFsg
Tuner. These findings do not clear historical BAHAA detections or establish that
BAHAA is trusted. Hosted tamper protection was false; the smoke inherited the
image's existing Unrestricted policy without setting it. Unsigned distribution,
restrictive-policy and physical-machine behavior remain explicit limitations.
Matching hashes, signatures and clean scans do not guarantee malware absence.

Selected payload SHA-256 values (all other files are in the complete manifest):

| File | SHA-256 |
|---|---|
| Client/ventio_native_client.exe | 0a72dd4d2979e3948b7b1121c13d9023cc80689f17f5b67a30eec6c55df2e822 |
| Client/data/app.so | d41f35895c6a78389d80711015656f58b5fdc3816cd08cd7ee92cd80168efa25 |
| HostPayload/ventio_host.exe | 056d434333f57c2bb6288617cc1c2fd256d06a44e8e016b58c62ddabd1af6cc1 |
| Ventio-Setup-0.1.23.exe | cb9c1ff294ff4053f8d3fd214ed6bc8c8c297a1ed90b441bf55f27c9cf1329a1 |

Both test computers must receive all 16 Client files from this same artifact, not
independent rebuilds. The installer uses AppVersion 0.1.23; its PE FileVersion
resource remains blank, so it is identified by immutable identity/source/hash.
The installer/broker/operations paths use no ExecutionPolicy override. The native
VC++ prerequisite retains its signature/hash/version/no-downgrade and reboot gates.
It does not use PowerShell. A denying OS policy remains a stop condition.

Later evidence-only commits retain raw logs/reports and do not become binary
inputs. Earlier Linux results remain exact-revision evidence: subsequent Host
gateway/upgrade-test differences are formatter output; Client workspace/store
corrections do not execute in those Linux Host suites. The final ledger lists
changed mapped paths explicitly, rather than using this review as a rerun or an
exhaustive dependency-closure claim. The two U baseline variants are counted as
three stable case IDs with two executions each, not six additional coverage cases.

Auxiliary .NET/PostgreSQL outcomes and the unexecuted recovery phases are recorded
in [CORRECTIVE_AUXILIARY.json](WAVE_2_B_CORRECTIVE_AUXILIARY.json). They are not
silently added to the stable-ID capability ledger. Windows GUI logs include
coarse create-new private-file diagnostics. Expected Recovery Authority lock-file
reuse can produce these: the implementation retries through a verified private
read. Individual inner causes are not captured, so the outer exception text alone
must not be relabelled as an ACL breach or a successful installed recovery test.

The [case ledger](WAVE_2_B_CORRECTIVE_RESULTS.md) and its
[JSON evidence mapping](WAVE_2_B_CORRECTIVE_RESULTS.json) identify every stable ID,
requirement, capability, revision, CI report and transport digest. Subsequent
fixture/data-review/report changes are not silently represented as executed tests.

## Remaining actions and ownership

| Priority | Problem / established cause | Corrective action and closure evidence | Independent work / owner need |
|---|---|---|---|
| 1 | Direct administrative postgres --single launch is rejected; the same normal-mode launch contract exists in recovery source. Installed end-to-end failure has not been reproduced. | Review a bounded service-identity maintenance path, then prove actual credential rotation, denied access, interruption, backup/role/migration checks and external witness preservation on an installed disposable cluster. | Source design/test preparation can proceed independently. Installed proof needs the dedicated fixture; do not broaden ACLs or suppress PostgreSQL's refusal. |
| 2 | No disposable installed Windows VM; supported dedicated observer access is also a prerequisite. | Provision the isolated VM through the supplied runbook, establish legitimate fixture access, rehearse admission and run P001–P006 with actual task/backup/restore evidence. | Owner must supply/authorize an environment. Source preparation is done; no physical test machine is a substitute. |
| 3 | Real release-GUI/two-device/offline/restart and owner acceptance are unexecuted. | After blocker review and separate approval, perform controlled TEST-02 Client deployment and then the agreed physical acceptance sequence, preserving TEST-01. | Genuine device availability/local approvals and owner decisions remain necessary; no repeat of already-passed unrelated CI is proposed. |

Build/integrity and the stated CI checks: PASS. Available security evidence:
WARNING (unsigned components/CI limitations, not a current detection). Full Host
deployment and Wave_2_B acceptance: BLOCKED. Fresh TEST-02 Client-only installation
is a concrete reviewable option, but the owner's deferral remains in effect; this
report does not approve or schedule it. The shortest safe path is recovery/VM
closure, explicit installation approval, then the remaining physical acceptance.
No automatic Wave_2_C transition or PR merge follows any of these checks.

No physical installation is currently approved. Preserve TEST-01's existing Host,
PostgreSQL data, services, credentials, backups and external Recovery Authority.
Any later TEST-02 Client-only deployment must use a fresh exact verified artifact,
normal UAC/security policy, no automatic launch or Host provisioning, and a fresh
Client profile. Pairing/synchronizing against TEST-01 can write to its Host and
requires a separately approved acceptance step. A later TEST-01 Host upgrade needs
its own verified backup/recovery and owner-approved plan; copying new payloads is
not a substitute for that plan.
