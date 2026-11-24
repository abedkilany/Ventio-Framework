# Wave 2 B hosted acceptance review — 2026-11-18

SUPERSEDED candidate checkpoint: installation was subsequently deferred by the
owner. Use [the corrective review](WAVE_2_B_CORRECTIVE_REVIEW.md) for the current
source, runtime, candidate and deployment disposition. All evidence below remains
historical; its Client-only WARNING is not a current installation recommendation.

Status: PARTIAL VERIFICATION / BLOCKED. No physical installation is authorized by
this report. Wave_2_B still needs explicit owner acceptance; Wave_2_C remains closed.

TEST-02 installation readiness: WARNING. The exact candidate passed the protected
fresh Client-only install/uninstall smoke and is reviewable for owner-approved
installation without launch or Host provisioning. This is not Host deployment
readiness or product acceptance. Current TEST-02 baseline/prerequisites must be
rechecked only after approval; neither test machine was inspected during this task.

## Candidate identity and verification

- Identity: `Ventio-W2B-0.1.21+22-20261118-7218c1c9994a-gh44239309334-a1`.
- Exact build commit: `7218c1c9994acc31cfa86008b92d2950367c6fac`;
  Git tree: `0844b2559f9a4e91d4e042e2413cac68b0e9e190`.
- Canonical [Host + Client + Installer artifact](https://github.com/abedkilany/Ventio-Framework/actions/runs/44239309334/artifacts/14399588881):
  266,045,465-byte candidate ZIP, SHA-256
  `45e93ef465d43ae44f4e484fc2fc1e3284ae0ddb08ff26bbb0e47bf7af4b4b97`.
- GitHub transport artifact ID 14399588881, SHA-256
  `e84a5fd77b27363c79f5ea061acd6c23b8c312780986be9836f89e3296cf68bd`.
  This is the outer Actions download, not the inner candidate ZIP.
- All 1,762 members were verified in the build and independently on a second
  fresh runner. SHA256SUMS.txt has 1,761 entries; its own bytes are anchored by
  the independently checked ZIP hash. The payload inventory contains 1,760 entries.
- [Protected verification run 44242987286](https://github.com/abedkilany/Ventio-Framework/actions/runs/44242987286)
  passed. Enabled Defender scanned the exact ZIP and extracted payload with
  signatures 1.463.351.0, matched target-specific start/finish IDs, no new detections
  and unchanged post-scan hashes. Effective exclusion probes became non-excluded
  after ten seconds; no excluded probe was ignored. No exclusions were added,
  protection disabled or quarantined file restored.
- The same runner installed and uninstalled the fresh Client-only candidate with
  exit codes 0/0, compared all 1,741 installed Client/Host payload files, and
  confirmed no application launch, Host provisioning, Host data/services or
  execution-policy change. It did not exercise an existing Host upgrade or every
  missing-runtime/reboot/error branch. Its pre-existing effective PowerShell
  policy was Unrestricted; this task did not set it. Restrictive-policy paths
  remain a separate validation boundary. Tamper protection was false on these
  ephemeral hosted images; this is not a hardened production-host assessment.

The full manifests, executable signature inventory, compiler metadata and scan
evidence are retained under `docs/wave2/evidence/20261118-7218c1c/`. The source
archive is checked against a regenerated archive of the exact Git commit; Windows
Git checkout line-ending conversion is recorded rather than misrepresented as
raw Git blob equality. Evidence-export/report commits after the build do not
change the immutable candidate's source identity. The previous BAHAA-built ZIP
was never a build input. This work does not establish trust in BAHAA or clear the
historically detected binaries. The optional full local mirror was stopped due
to slow transport; complete package verification occurred on the approved hosted
runners. The canonical complete binary artifact remains on GitHub.

Review files: [complete member hashes](evidence/20261118-7218c1c/SHA256SUMS.txt),
[compiler/dependency metadata](evidence/20261118-7218c1c/build-metadata.json),
[all executable signatures/hashes](evidence/20261118-7218c1c/executable-signatures.json),
[independent scan/install/uninstall evidence](evidence/20261118-7218c1c/protected-verification.json),
and [source proof](evidence/20261118-7218c1c/exported-artifact-review.json).
The evidence export is [run 44244798737](https://github.com/abedkilany/Ventio-Framework/actions/runs/44244798737),
at verification commit `c816135ab28b48f17d60acbf31aea3c9e64bc41c`.
Its locally verified transport SHA-256 is
`7527ffa02f7838e1e81c45033d5228ba9f8f04f7bd1bd7ad8ea6384f4955990c`.
All 723 archived source entries match the regenerated archive byte for byte;
71 also match raw blobs and 652 use Git's Windows checkout representation.
Evidence-directory attributes preserve raw retained evidence bytes in Git.
GitHub binary artifacts expire on 2026-12-18 unless retained elsewhere before then.

The new Client PE reports `0.1.21+22`. Its launcher SHA-256 is
`929caa604cba6da72c1d1b4f99fbd6cb6a7f74441ac951a58e4a9b57e7e75586`;
the actual Dart application payload, `Client/data/app.so`, is
`4195a7e5d6bc51cd1ff2bdbeec3d905452f7e06317d04182a41b5349f51c898e`.
Compare all 16 Client files when eventually distributing one candidate to both
machines. Launcher version/hash alone cannot identify the complete application.
The installer SHA-256 is
`99e2cf73e4964dc3542e72e66d7ed593022aba89a8ece8e973c2ab5fd1c90a99`.
Its compiled AppVersion is 0.1.21; the signature inventory reports a blank PE
FileVersion string. Use the immutable artifact identity/hash rather than claiming
that this missing resource independently identifies the build. Review explicit
installer PE version resources in the next packaging correction.

Build/integrity and the limited protected installer smoke passed; the acceptance
job failed its result gate. The aggregate recorded outcomes are 131 PASSED,
5 FAILED, 19 UNEXECUTED_AFTER_SUITE_FAILURE and 6 BLOCKED_PREREQUISITE,
plus six separate MANUAL_UNEXECUTED cases. Earlier-revision Linux results are
identified in the ledger. No new test is declared passed merely from static review.
Linux R001/R002, including the real WB-CI-02 unavailable/recovery probes, passed
in run 44229473249; this closes that narrow regression's CI evidence gap, not the
physical recovery or owner-acceptance gates.

## Preservation and source review

The original 24 changed/untracked files were preserved before edits in
`C:/v2b/20261118-hosted/prepared-work-before-review.zip` (SHA-256
`1de444ddbe7ac288127354c2787a8f0a1b9c2c58f46074a8bca6d70a7e56b373`),
with a per-file hash inventory and binary Git diff beside it. Commit `c96f154`
preserved all 23 test-preparation files, including the existing engineering audit
change. The remaining version change was preserved in that backup and advanced
explicitly for the new candidates. All 161 automated case IDs, all 22 capability
mappings and the six additional manual cases remain in the inventory.

Review followed actual Core, HTTP gateway, restricted PostgreSQL pool/security
SQL, durable worker, SQLite queue, workspace, backup and installer contracts.
Corrections made after real CI failures concern fixtures and orchestration:
mutable JSON decoding, contract-valid lowercase label keys, a structurally valid
delete envelope before testing authorization, Windows object-owner scope, UTF-8
machine output, fresh private paths, root-owned sudoers permissions and cleanup
exit handling. Positive/negative assertions were retained. A fixture/setup failure
was not relabelled as a product pass. Original failed attempts remain in GitHub
and downloaded evidence rather than being erased by the latest case ledger.

The initial workflow attempt was cancelled when a legacy test helper policy
override was found; that helper was corrected before further execution. Later
runs used narrow scope selectors, not the unrelated Android/full PR workflow.
There were repeated setup/build failures; their corrections are recorded in the
branch history. No local Ventio executable, product test, installer or quarantined
binary was executed during this resumed work. Neither physical test machine was
accessed or changed.

## Result interpretation

The case-level source and exact run/revision/artifact evidence are in
[HOSTED_RESULTS.json](WAVE_2_B_HOSTED_RESULTS.json) and its
[readable capability/case matrix](WAVE_2_B_HOSTED_RESULTS.md). Earlier green
Linux suites are retained as earlier-revision evidence, with mapped source-path
differences recorded. They are not described as execution at the final candidate
commit. Shared fixture corrections and the limited scope of dependency equality
are explicit. CI success or artifact upload is not physical product acceptance.

The real same-machine offline integration uses two SQLite queues, independent
identities, PostgreSQL and HTTP, including response loss after commit. It does not
establish physical network disconnect/reboot behavior. The credential backend in
desktop/offline tests is explicitly ephemeral; Windows credential-store behavior
remains manual. Operations SQL transitions are not evidence that Task Scheduler
has copied and restored a real installed cluster.

## Findings, blockers and unresolved causes

| Priority | Problem / evidence | Established cause and corrective action | Resolution evidence / interaction |
|---|---|---|---|
| P0 | Customization save returns 503/22P02; H013 and G005 fail | `security/postgres/wave2.sql` subtracts a text array before the JSON extraction because `-` binds more tightly than `->`. A real isolated PostgreSQL control reproduced the failure and the parenthesized expression succeeded. Prepare a reviewed forward-compatible correction, including supported existing-Host security profile/checksum and Recovery Authority transition. Do not rewrite an already-applied migration silently. No production SQL fix was made in this task. | Gateway/customization positive and negative cases, subsequent H014–H029 and G005 must execute. Engineering correction and CI are independently executable after scope approval; no physical machine is needed to reproduce it. |
| Resolved CI setup | Effective Defender exclusion visibility | A fresh hosted image starts with disabled monitoring/archive scanning and C:/, D:/ exclusions. Normal Defender APIs strengthened only the disposable image and removed those roots. The final verifier observed excluded results initially, then actual non-excluded results after ten seconds before scanning. This supports delayed effective propagation for this run; it does not prove every earlier failure had the same cause. | Final ZIP/tree non-excluded probes, matching scan IDs, current enabled protection, no detections and unchanged hashes are retained. Earlier blocked scans remain historical failures rather than clean scans. No security bypass was used. |
| P1 | W008 rejects a fresh private operation path | Actual `HOST_OPERATION_UNTRUSTED_ANCESTOR`; W009–W011 are unexecuted after fail-fast. `HostOperationStorage.psm1` evaluates inherited/inherit-only ACEs differently from the private-file helper. An inherit-only false positive is a hypothesis pending precise ancestor ACL evidence. Do not weaken ACL assertions or trusted identities to obtain a pass. | Capture effective ancestor owner/ACE/propagation metadata on a disposable runner, establish whether fixture or implementation violates the contract, then rerun W. Engineering work is independent of TEST-01/02. |
| P1 | Native navigation/report G001/G006 fail | Expected authorized module/report UI is absent. Windows private-file create errors also appear in the log; causality for these UI failures is not yet established. G005 has the separately confirmed SQL cause. Keep the failures visible; do not replace real Host traffic with mocks or loosen widget assertions. | Diagnose Host package authorization, private-file failure and actual UI error paths on a disposable runner; repeat the affected tests after correction. Physical GUI checks remain separate. |
| P1 | Bundled PostgreSQL is 16.15-5 | PostgreSQL 16.16 was released 2026-11-12 with security fixes. Existing test/version guards intentionally pin 16.15, so this task did not silently substitute another release or touch TEST-01. Review exposure and prepare a supported patch candidate before Host deployment. This is not a claim that every listed CVE is exploitable through Ventio. | Reviewed pinned upstream build/hash, payload/version guards, migrations/RLS/restore regression and supported existing-Host upgrade evidence. No TEST-01 change without separate authorization. |
| P1 | Self-contained service and broker use .NET 8 | Both project files target net8.0-windows; SDK 8.0.421 resolves runtime 8.0.27 in the recorded assets. Microsoft ended .NET 8 support on 2026-11-10. Installing a newer system runtime does not patch these self-contained executables. Prepare a reviewed supported-target/runtime transition; do not treat the newer dotnet launcher file version as the embedded runtime version. | Supported pinned SDK/runtime and regenerated runtime assets, service/broker and installer/upgrade/recovery regressions. This is engineering work; it does not require changing either test machine to investigate. |
| P1 | Installed backup/scheduler/restore P001–P006 lack their fixture | The required separately provisioned disposable installed Windows VM, private marker/manifest, independent witness and supported test identities are absent. These are automated cases blocked by setup, not six intrinsically manual GUI tests. A hosted runner must not be renamed or marked just to evade their admission contract. | Provision a reviewed disposable VM through supported installation/bootstrap, with explicit destructive restore/local-operation approval. Then execute scheduling, integrity, retention and restore tests there. Do not use either preserved test computer. |
| P2 | Unsigned Ventio/third-party executable content | No signing credential was available. Provenance hashes identify bytes; they do not supply publisher trust. The full PostgreSQL upstream bin/lib/share payload includes administrative and upstream test utilities. They are accounted for by the input/package manifest, not unexplained additional Ventio components. | Review the complete executable inventory and any future signing/distribution policy. A clean Defender scan cannot replace provenance review or establish malware absence. |

The SQL control is retained in run 44234943309. Relevant primary references:
[PostgreSQL operator precedence](https://www.postgresql.org/docs/16/sql-syntax-lexical.html#SQL-PRECEDENCE),
[PostgreSQL 16.16 release/security fixes](https://www.postgresql.org/docs/release/16.16/),
[Defender effective exclusion exit codes](https://learn.microsoft.com/en-us/defender-endpoint/configure-exclusions-microsoft-defender-antivirus),
and [Microsoft runtime compatibility](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist).
The [.NET lifecycle table](https://learn.microsoft.com/en-us/lifecycle/products/microsoft-net-and-net-core)
records .NET 8 support ending 2026-11-10. PDFium 5200 and other native dependencies
are provenance-checked; this work does not establish a complete CVE audit for them.

## Installer and coexistence decision

Installer runtime prerequisite handling is now native Inno code with exact package
SHA-256, x64 installed-version detection, no downgrade, no automatic restart,
post-install registry recheck and fail-closed errors. Minimum runtime is
14.51.36247.0, matching the selected MSVC 14.51 generation; CRT headers and the
actual hosted compiler are checked before building. All installer/broker/operational
launches changed by this task inherit effective policy without Bypass or another
policy override. No zone marker removal or new inline/encoded file-policy
workaround was introduced. The existing native ACL helper is unchanged.

Some legacy tests outside this selected execution still contain Bypass arguments
(`test-host-service-recovery-policy.ps1`, `test-host-upgrade-backup-diagnostics.ps1`).
They were not executed or packaged as runtime setup scripts. Do not use those
commands in a later acceptance phase without review/correction.

A fresh Client installation copies HostPayload but does not provision PostgreSQL,
create a database/Recovery Authority or start Host services. Silent installation
skips the post-install launch. With an existing local Host, the unified installer
is an upgrade operation that can stop services and change local database state;
it must never be run on TEST-01 under a TEST-02-only approval. Effective policy may
block Host script operations, which must fail closed rather than trigger a bypass.

TEST-02 can ultimately receive exactly the same Client bytes as TEST-01 from one
immutable approved artifact. No installer invocation, transfer to a physical
machine, Host pairing, remote endpoint write or credential/witness copy occurred.
Fresh Client-only uninstall can roll back TEST-02 application files without a Host
script only when no local Host data/services exist. It is not a database rollback.

## Commands and remaining approvals

From a GitHub-authenticated engineering environment, the targeted entry point is:

```text
gh workflow run native-flutter-client.yml --repo abedkilany/Ventio-Framework --ref feature/wave-2-a -f wave2_resume=true -f wave2_scope=gateway-jobs
gh workflow run native-flutter-client.yml --repo abedkilany/Ventio-Framework --ref feature/wave-2-a -f wave2_resume=true -f wave2_scope=windows-tests
gh workflow run native-flutter-client.yml --repo abedkilany/Ventio-Framework --ref feature/wave-2-a -f wave2_resume=true -f wave2_scope=verify-candidate -f candidate_run_id=REVIEWED_HOSTED_BUILD_RUN_ID
```

These are instructions for later approved corrections/verification, not a request
to dispatch more runs now. Record the resolved SHA before treating any rerun as
candidate evidence. `windows` produces a new artifact; `linux` runs the Linux
integration group; `core` isolates Core and the SQL diagnostic. The workflow
contains exact actual test commands; fixture prerequisites and manual cases remain
in [the preparation runbook](WAVE_2_B_TEST_PREPARATION.md). Local execution of
hosted controllers is refused. Do not run `all` merely to repeat unchanged suites.

The shortest safe path is to resolve the confirmed SQL defect, diagnose the
Windows path/UI failures, and decide the PostgreSQL/.NET support updates; execute
only affected suites; then provide a fresh reviewed candidate and repeat integrity
and protected scans for its changed bytes before owner approval. Provision the installed operations
VM and execute its six cases before claiming full backup/restore acceptance.

Owner interaction is needed for physical installation approval, normal interactive
UAC/restart where required, final secure-store/bootstrap UX, real two-device
disconnect/reboot/conflict checks, GUI/accessibility and recovery trust decisions.
Source investigation, corrective preparation, targeted CI, manifest verification
and disposable fixture engineering do not require the owner to operate TEST-01.

The detailed TEST-02 prerequisites, integrity checks, no-launch installation and
Client-only rollback steps are in [the deployment gate](WAVE_2_B_HOSTED_RESUME.md).
They require explicit owner authorization of this exact WARNING candidate and
its fresh Client-only, no-launch scope. Full Host deployment and acceptance stay
blocked until their findings are resolved. The owner may choose corrective work
before any physical installation; no corrective business-SQL/runtime-target work
or physical installation is inferred from this report.
