# Wave 2 B hosted acceptance and TEST-02 deployment gate

Historical initial hosted-resume plan. The owner subsequently deferred physical
installation pending corrective engineering. Use
[the corrective review](WAVE_2_B_CORRECTIVE_REVIEW.md) for current pins, evidence
and installation status; the earlier candidate/runtime pins below are superseded.

Owner authorization dated 2026-11-18 permits committing the preserved preparation,
targeted hosted CI tests/builds and deployment preparation. It does not accept
Wave_2_B, authorize installation on either physical test computer, or open Wave_2_C.
The earlier test-preparation report is a historical record of its unexecuted state.
Its 161 stable case IDs and all 22 capability mappings remain the coverage baseline.

This candidate is built exclusively from a committed `feature/wave-2-a` checkout
on a fresh GitHub-hosted Windows 2025 runner. No BAHAA-built ZIP, binary, compiler
cache or generated build directory is uploaded as an input. Dependencies resolve
with existing lockfiles enforced; action revisions, Host Dart 3.13.7, Flutter
3.44.1, .NET 8.0.421, PostgreSQL 16.15-5, Inno 6.7.4 and the VC++ prerequisite
are pinned. Direct native downloads are SHA-256 checked. The hosted image version,
resolved toolchains and actual compiler inputs are evidence; a Windows runner
label is not an immutable image snapshot or a promise of bit-identical rebuilds.

Run only the existing Native Flutter workflow with `wave2_resume=true` on this
branch. Its isolated reusable workflow bypasses the unrelated Android/full PR
suite selection, not a security control. Commits may carry `[skip ci]` to avoid
automatic unrelated CI; explicit workflow_dispatch still runs the selected work.
Keep PR #6 Draft and unmerged.

`tests/wave2/run_hosted_tests.py` executes C/S/W/G on Windows and H/J/D/O/U/R/E
on Linux with a new disposable migrated PostgreSQL cluster per database suite.
It preserves per-case PASSED, FAILED, BLOCKED_PREREQUISITE and UNEXECUTED outcomes.
A successful process without literal case-completion evidence cannot pass a case.
The P001–P006 installed-Windows suite requires its separately provisioned VM,
fixture marker and normal approval; a hosted runner is not relabelled to fake
those prerequisites. M001–M006 remain genuine manual acceptance. Same-machine
two-queue synchronization does not prove two physical devices or reboot recovery.

The immutable candidate ZIP includes Client/, HostPayload/, the unified installer,
the signed Microsoft VC++ prerequisite, exact committed source, build metadata and
complete SHA-256 manifests. The ZIP's separately reported SHA-256 anchors the
checksum file itself. Verify every member, not just the small Client launcher.
Both physical machines must ultimately receive identical Client/ bytes from this
same artifact; this task prepares TEST-02 only. Test/security outcomes are retained
beside the immutable ZIP, independently of its contents. A failed test never becomes
passed because an artifact uploaded successfully.

Defender evidence is collected only if the hosted image provides operational
Defender with real-time protection enabled and reviewable exclusion/archive policy.
Otherwise scan status is BLOCKED, not a clean scan. The dedicated verification job may enable protection and archive/script scanning
and remove only the fresh image's C:/ and D:/ exclusions through normal APIs.
It never adds exclusions, disables protection, overrides execution policy or
changes either test computer. Native executables remain unsigned unless
their real publisher signature is present. Hash agreement, hosted provenance and
clean scans do not establish malware absence.

The installer now performs the fresh-install VC++ prerequisite in native Inno
code: x64 registry/version check, no downgrade, pinned extracted package SHA-256,
normal elevated Microsoft installer, no automatic reboot, installed-version recheck
and fail-closed handling. It does not launch PowerShell for this prerequisite.
Other installer, Host broker and operations/removal script paths inherit the
effective PowerShell policy. They never specify Bypass, Unrestricted or a policy
override. A restrictive policy can block Host provisioning/upgrade/removal; this
is a documented prerequisite, not a reason to weaken policy. No unsigned-script
signing trust is fabricated, zone marker removed, or inline/encoded workaround used.
Fresh Client-only uninstall avoids a Host script only when there is no local
Ventio ProgramData, Host or PostgreSQL service. Existing Host safeguards remain.

Before approving TEST-02 installation, require the exact CI commit/run/artifact
identity, a complete verified ZIP/member manifest, reviewed case results, and
acceptable independent security-scan evidence. The exact candidate's fresh
Client-only install/uninstall smoke passed on a second hosted runner. A physical
Client-only installation with no launch or Host provisioning is reviewable with
a WARNING verdict, subject to current TEST-02 prerequisites and owner approval.
Known product failures, installed-VM gaps and Host dependency support findings
still block full acceptance and Host deployment; they are not silently accepted
by copying application files. See WAVE_2_B_HOSTED_REVIEW.md for the exact evidence.
Preserve all current artifacts and reports for comparison.

After a separate explicit owner authorization, the TEST-02-only procedure is:

1. Verify the SSH/server identity or local hostname is TEST-02 and the account is
   the intended administrator. Do not connect to TEST-01. Recheck local Ventio
   services/directories, free storage, Defender and pending restart. Stop if an
   unexpected Host/PostgreSQL/Recovery Authority installation exists.
2. Transfer the exact approved ZIP and independent expected SHA-256 to a new local
   staging directory. `Get-FileHash -Algorithm SHA256` must match the approved value.
   Inspect ZIP names for absolute/traversal/duplicate paths before extracting to
   an empty directory, then compare every SHA256SUMS.txt entry and member count.
   Stop on any mismatch, detection or missing file; never restore or exclude it.
3. Run current enabled Defender scans on the transferred ZIP and extracted package.
   Review matched completion events and detection history. Do not treat process
   return alone as a clean result. Record fresh endpoint protection evidence.
4. Check the native x64 VC++ v14 runtime. Minimum 14.51.36247.0 is required; the
   bundled Microsoft-signed 14.51.36247.0 package is pinned in its manifest. If needed,
   install that exact prerequisite through normal UAC after verifying its hash and
   signature. Exit 3010/1641 requires an owner-authorized TEST-02 restart and recheck;
   never restart TEST-01. Retain a newer compatible installed runtime.
5. Install the approved unified installer through normal UAC. For an explicitly
   approved unattended installation use `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-`;
   its postinstall launch is marked `skipifsilent`. With the interactive installer,
   clear Launch Ventio. Record exit status and installed payload hashes. Stop after
   installation: do not select Host setup, launch, pair, synchronize or run tests
   until separately authorized. Do not copy TEST-01 credentials or witness data.
   Stop if Defender, application control or another Windows security control
   blocks the candidate; owner installation approval is not an instruction to
   override that block. The Ventio executables have no publisher signature.
6. A later approved Client launch must use a fresh TEST-02 profile/app-support
   directory and the Client role. Pairing or synchronization can write to TEST-01's
   Host and therefore needs a separately approved acceptance step.

Rollback after a separately approved fresh Client-only installation: retain the
staging evidence, stop any subsequently authorized Client, and invoke the installed
uninstaller through normal UAC. Verify there are still no local Host/PostgreSQL
services or Ventio Host data before proceeding. If any exists, stop and review;
do not request data deletion, run a database restore or apply these steps to TEST-01.
Do not uninstall the shared Microsoft VC++ runtime as part of Client rollback.
Do not reinstall the old BAHAA-built acceptance candidate. A rollback that cannot
be completed under the effective approved policy is BLOCKED and requires review.
