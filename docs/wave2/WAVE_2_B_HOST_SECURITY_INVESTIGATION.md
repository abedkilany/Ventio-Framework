# Host security investigation — 2026-11-15

Last evidence checkpoint: 2026-11-15 21:42 UTC.
Final code CI checkpoint: 2026-11-15 21:59 UTC; all 11 checks passed on
`e2c5fb1a592688bdcaf74e09f7a64e0781d4008a`. The later report-only commit
does not change code or the reproduced executable.

**ROOT CAUSE NOT CONFIRMED.** Wave 2 B remains **PARTIAL VERIFICATION / BLOCKED**.
Neither an infected application nor a Defender false positive has been established.
The investigation did not resume Host provisioning, service recovery, synchronization
or backup acceptance tests. PR #6 remains Draft and unmerged on `feature/wave-2-a`.

## Confirmed facts and evidence

The sanitized evidence directory is [security-investigation-20261115](security-investigation-20261115/).
The collector uses read-only Defender/WMI/Event Log commands, including the
documented `MpCmdRun -Restore -ListAll` listing operation. It never restores an
item. Only Ventio quarantine entries are included in the committed evidence.
Unrelated historical quarantine records were excluded from publication; they were
not restored or remediated. These existing lab installations are not forensic
proof of a clean operating system.
Committed text evidence has normalized UTF-8/LF line endings and trailing
formatting whitespace. Original captures/ZIPs remain in the local ignored
artifacts area and GitHub artifact store. The evidence inventory hashes the
normalized repository files, with Git text conversion disabled for this directory.

| Finding | TEST-01 | TEST-02 |
|---|---|---|
| Computer | VENTIO-TEST-01 | VENTIO-TEST-02 |
| OS | Windows 11 Pro 10.0.26300 | Windows 11 Pro 10.0.26300 |
| Defender product/engine | 4.18.26100.4 / 1.1.26100.4 | 4.18.26100.4 / 1.1.26100.4 |
| Detection time, UTC | 2026-11-15 20:10:00.859 | 2026-11-15 09:59:21.939 |
| Detection intelligence | 1.463.310.0 | 1.463.308.0 |
| Remediation event 1117, UTC | 20:11:32.336 | 09:59:45.179 |
| Action | Quarantine, successful | Quarantine, successful |
| Intelligence at collection | 1.463.317.0 | 1.463.313.0 |
| Protection | Antivirus, real-time, behavior monitoring, AM service, NIS and tamper protection enabled | Same |

Both detections identify `Trojan:Win32/Bearfoos.A!ml`, threat 2147731250, Severe,
and the path `C:\Program Files\Ventio\host-payload\ventio_host.exe`. The
quarantine listing independently confirms that path. TEST-01's manifest lists
92 verified files; hashing the 91 present files found no mismatch. Both manifests
expect Host length 8,806,400 and SHA-256
`5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`.

This is an **expected manifest hash**, not a newly measured hash of the
quarantined bytes. The exported Defender events contain no SHA-256. The earlier
pre-quarantine TEST-01 hash in the Wave 2 B ledger agrees, but no quarantined file
was restored to establish its post-detection bytes. TEST-01's service failure
stage `HOST_ENGINE_PROCESS_START`, SCM error 2, and the missing file explain its
current outage. They do not explain Defender's classification. The current
inspected Code Integrity log has no event blocking the Host engine; older Setup
Broker signing blocks are separate.

## Artifact provenance and pipeline audit

The locally retained original ZIP was rehashed against GitHub Actions artifact
14117789094, run [43605015043](https://github.com/abedkilany/Ventio-Framework/actions/runs/43605015043):

- Source commit `fb341a78eca1bb897e2ce09f1271dae39bbd7d11`; tree
  `9fcf6b32add93e68a70212bd45b3db155d5cb15a`.
- ZIP: 103,796,488 bytes; SHA-256
  `0c83cd20dab447e6d024fe3d62dd5e9588499deb417a986820bf10d6a13114ae`.
- Embedded installer: 104,319,695 bytes; SHA-256
  `5413f65d86235633d40e1912767dd576303ecb0a7216d4a5e846c977f955977b`,
  matching both the archived checksum and archived build evidence.
- TEST-02's later package is artifact 14136958018 from run 43653937272,
  source `17b014125b695e3242e2d9b50b3eb9732a8c5fcb`, GitHub ZIP digest
  `1c5a1076ab427cd132afc5efd1d7c2610e61376647441c00a628fb04b5f650eb`.
  This later ZIP was identified through GitHub metadata, not re-extracted here.

The original artifact contains an Inno installer and text evidence, not a bare
Host executable. Its installer was read as data and was not executed or unpacked
by running it. Consequently, this investigation does not claim a direct byte
comparison of the original embedded Host with quarantined bytes.

The complete build chain reviewed consists of the acceptance workflow,
`build-host-payload.ps1`, PostgreSQL tool acquisition, `build-windows-installer.ps1`,
`ventio.iss`, the Host and setup-broker projects, and their referenced inputs:

| Component | Observed control and remaining risk |
|---|---|
| Host | Direct `dart compile exe bin/local_host.dart`; no additional PE packer, injector, binary patcher or obfuscation stage in the build script. Dart supplies its native runtime and AOT program. |
| Dart | Original logs install 3.13.7 from the official archive before compiling Host. Action version tags were mutable; their resolved commit IDs were retained and pinned in the investigation workflow. No signed provenance attestation for the original compiler was retained. |
| Dependencies | `dart pub get --enforce-lockfile`; 13 pub.dev packages pinned with SHA-256 plus three local packages. No git dependency or native build hook is declared by the Host graph. Cached copies of the 13 packages contained no EXE/DLL or build.dart file; this is a static inventory, not proof of benign semantics. |
| .NET wrappers | First-party source, self-contained win-x64 single-file publish; no explicit external PackageReference. The `8.0.x` SDK request and installed SDK/runtime selection are not immutable pins. Wrappers are separate binaries, not incorporated into `ventio_host.exe`. |
| PostgreSQL | EDB 16.15-5 archive length 373,254,386 and pinned SHA-256 `43bb45f173a6f08cf1d29a97a6d8deb119e8e8093a24c00d2d1001a0ccaa8281`; copied as a separate runtime tree. |
| Inno / VC runtime | Inno 6.7.4 signature/publisher/version checked; no immutable Inno archive hash pin. VC 14.51.36247 is checked against the repository prerequisite metadata, including hash and publisher. Inno LZMA2 compression packages the installer; it is not an extra packer applied to Host. |
| Final inventory | Critical file hashes and full count/size checks; 92 critical entries do not hash every noncritical runtime file. Original payload manifest had no source-commit/compiler fields or signed attestation. |

The tracked Host runtime/library inputs did not change between the original
source and the investigated branch; the relevant intervening Host change was
an integration-test stdin shutdown correction. No unexpected compiler,
download, executable patch, or third-party payload was identified in the
reviewed pipeline. Original artifact provenance is GitHub run/log/checksum
correlation, not cryptographic supply-chain attestation.

## Source and dependency review

The review covered Host entry points, Host/core/PostgreSQL library process and
network boundaries, Windows protected-file/DPAPI helpers, the .NET Host service
and elevated setup broker, installer and operational scripts, lockfiles, and
recent relevant history. It was a targeted security review, not a formal proof
of the complete application or all dependencies.

- Host normally accepts authenticated HTTP on loopback and configured TLS LAN
  connections; external listeners require TLS and authoritative gateways.
  PostgreSQL connections use configured database endpoints. No unexplained
  hard-coded exfiltration destination or downloaded execution payload was found
  in the inspected first-party runtime sources.
- Windows services and scheduled backup tasks are documented product persistence.
  The service starts the fixed sibling `ventio_host.exe` with `UseShellExecute=false`;
  the broker invokes fixed setup scripts. These operations are separate from the
  Dart Host's own private-file helper. No unaccounted autorun was found in the
  reviewed product scripts.
- DPAPI reads/writes dedicated configuration, bootstrap or credential-reissue
  envelopes. Native imports include crypt32/kernel32 and ffi's ole32 allocator.
  No LSASS/browser credential harvesting, remote-process memory injection,
  CreateRemoteThread/WriteProcessMemory usage, or security-disable command was
  identified in the inspected product runtime sources.
- `private_files_windows.dart` compresses a fixed PowerShell ACL helper into
  GZip/Base64, decodes it, and uses `Invoke-Expression` via `-EncodedCommand`.
  This is present in reviewed commit `dabec563f4c262dfc344c679b14a090fe314d814`
  (2026-11-12), introduced to reduce command length. The script source is fixed;
  operation/path/secret data arrives as JSON on stdin and is not interpolated
  into its executable text. It validates identities, ACLs, fixed local paths and
  reparse points and uses bounded protected-file operations. The pattern could
  affect heuristics, but no controlled experiment or vendor evidence ties it to
  this detection. It was not removed, repacked or rewritten to change AV results.

No exploitable runtime security defect or unsafe dependency was confirmed by
this review. This limited result does not certify the executable as safe or rule
out an environment, compiler, dependency, or behavior-specific compromise.

## Reproduction and Defender verification

The dedicated workflow builds a detached original source in a fresh GitHub
Windows runner, verifies lockfile resolution, captures SDK file hashes and the
dependency graph, compiles twice, and scans without executing either Host.
It pins Actions to the resolved commits from the original run. No pub cache is
restored by this workflow. It uploads evidence and reproduction files only to
the already authorized project GitHub artifact store.

Initial investigation harness failures are retained: run 43763580961 had a
shallow checkout without the original commit; run 43763730358 stopped at the
real-time protection preflight; run 43763854759 was denied permission to change
WinDefend startup configuration. No policy bypass was attempted. The hosted
image has AM service and Antivirus enabled but real-time monitoring disabled by
its administrator. The final harness records this baseline and uses on-demand
scanning; this is not physical real-time protection acceptance.

Run [43764011101](https://github.com/abedkilany/Ventio-Framework/actions/runs/43764011101)
on investigation commit `c47dc6a4a493389589e7669d8dd78078f478f6b4` passed:

- Frozen source `fb341a78`, Dart 3.13.7, runner image 20261103.298.1.
- Both outputs: 8,806,400 bytes and SHA-256
  `02f627259cc4c96b13e87d98912a0e5a09ab3e663786c6b7f94d56e08059824b`.
- Both are unsigned PE x64, 10 sections, PE timestamp 1792704537. Identical
  repeated outputs establish local repeatability; they differ from the original
  manifest hash. A matching size alone does not establish binary equivalence.
- Defender 1.1.26100.4 with updated intelligence 1.463.317.0 reported
  `found no threats` for both, exit 0. The command was custom on-demand scan
  with `-DisableRemediation`; its output, not exit 0 alone, is the evidence.

On TEST-01 at 21:33:15 UTC, the same recompiled file was staged in a new isolated
user evidence directory and hashed before scanning. Antivirus, AM service and
real-time protection were all True. Updating intelligence completed with version
1.463.317.0. The custom scan again reported `found no threats`, exit 0; the file
remained present and **was never executed**. It was not installed in the product
directory, and neither original quarantine item was restored. This clean scan
applies to the new hash, not the original reported hash or Host runtime behavior.

## Confirmed correction and regression scope

WB-SEC-01 is a build-evidence defect: `wave2-build-evidence.txt` records Dart
after Flutter replaces PATH. The original log shows Host compiler 3.13.7, while
the archived text says 3.12.1 (the later Flutter Dart). The original payload
manifest also omits source-commit/compiler provenance. Commit `fd633bc` captures
the Host compiler before Flutter, the source commit, tracked dirty state and
lockfile SHA-256 in the existing manifest. Acceptance packaging checks source
identity, clean state and the required compiler and records Host executable
SHA-256 separately from Client Dart. Manifest format remains 1 with additive
metadata. No Host runtime source or executable compilation flags changed.

This correction supports diagnosis and future traceability. It does not explain
or remediate the original Bearfoos detection. PowerShell parser/diff checks
passed; the package CI gate exercises the new provenance assertions. The
investigation workflow records repeatability and explicit scan evidence.
The new provenance assertions passed in Windows Acceptance Package run
43764299936 on `e2c5fb1a592688bdcaf74e09f7a64e0781d4008a`.

An independent existing engineering-gate failure occurred on `c47dc6a`:
run 43764011034, `Changed migration manifest quarantines a running Host
(http=null, error=null)`. It is a migration-admission test failure, not an AV
quarantine. Its cause was not attributed to the metadata-only correction, and
the assertion was not weakened. Final CI results must be read with the tested
head recorded in the Wave 2 B test ledger.
The unchanged admission assertion passed in successor run 43764299948; the
intermittent failure remains open as WB-CI-02 because its cause is unconfirmed.
All eleven checks on the final code head `e2c5fb1` completed successfully,
including Host API 43764299949, Host crash recovery 43764300105, credential
lifecycle 43764300196, native Windows/Android 43764300057, Windows package
43764299936 and the exact-hash investigation 43764300013. The complete check
snapshot is `security-investigation-20261115/final-code-ci.json`.

## Assessment, uncertainty and handoff restriction

Confidence is high that Defender quarantine caused the two Host outages and
that the independently rebuilt reviewed source can currently pass a static
Defender scan. Confidence is insufficient to assign the original classifier
decision to a particular source feature, packaging detail or compromise.
**ROOT CAUSE NOT CONFIRMED.**

Remaining requirements are direct comparison with the actual quarantined bytes
and an explanation of the original classifier decision, including the distinction
between static file scanning and behavior during a running Host. Rebuilding the
reported expected hash does not reveal that decision. No
signature change, executable mutation or product change was made for AV evasion.

### Exact-hash reconstruction and explanation of path differences

Run [43764300013](https://github.com/abedkilany/Ventio-Framework/actions/runs/43764300013)
on `e2c5fb1a592688bdcaf74e09f7a64e0781d4008a` adds a conventional-path control.
Before compiling, Git verifies that the Host entry point, all four local runtime
package/library inputs and Host lockfile are unchanged from `fb341a78`. Compiling
under `D:\a\Ventio-Framework\Ventio-Framework` then produces the exact original
expected length 8,806,400 and SHA-256
`5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`.
Defender 1.1.26100.4 / intelligence 1.463.317.0 reports `found no threats` for
this exact hash. No program source or compiler option was modified to obtain it.
The initial worktree build used a different absolute source path; the control
establishes path sensitivity rather than a reproducible unexplained byte change.
The two variants share the complete first 5,348,864 bytes; the first differing
byte is at offset 5,349,344, in the appended program region. The binary-region
comparison is retained alongside the evidence. This prefix is the generated
executable prefix; its digest must not be confused with the separately recorded
unmodified SDK runtime digest.
Thus the reported expected binary can be recreated from the reviewed source and
toolchain, without an unaccounted executable payload. This is strong evidence
about the expected binary's provenance; it does not identify Defender's original
rule or establish what was in process memory at detection.

### Physical exact-hash static verification

The verified reproduction archive (GitHub artifact 14181556228, digest
`5a3551bf67df600803df4c9760ee56813b74779ec50d12858c3f54cff9d7008a`)
was downloaded to fresh `VentioFramework\SecurityInvestigation\e2c5fb1` evidence
directories under the two test accounts. Each archive and extracted file was
hashed. Both extracted files match the original expected SHA-256 `5a18…e5f2`.

| Test | UTC | Intelligence | Result |
|---|---|---|---|
| TEST-01 exact-hash custom scan | 21:39:23 | 1.463.319.0 | `found no threats`; exit 0; file remains present |
| TEST-02 exact-hash custom scan | 21:41:50 | 1.463.319.0 | `found no threats`; exit 0; file remains present |

Both use engine 1.1.26100.4. AM service, Antivirus and real-time protection were
True on each machine; only supported intelligence updates were requested. The
reproduction files were never executed, installed or copied to the original
service path. The original installed engine remains absent and the original
Defender quarantine remains intact. The raw results are
`TEST-01-exact-hash-scan.json` and `TEST-02-exact-hash-scan.json`.

The historical detection is not reproduced by current static scans of a byte-identical
expected binary. Signature/reputation changes and
different runtime behavior are plausible explanations, but the experiment does
not hold the old signature/cloud decision and original runtime state constant.
It therefore does not establish which explanation is correct. A successful
static scan is not a behavioral clearance or authority to restore a quarantine.

The owner initially declined sample transmission and later explicitly authorized
Microsoft-only submissions. The TEST-01 scan retained its existing MAPS=2 /
SubmitSamplesConsent=1 policy. This permits automatic samples if Defender asks;
it does not prove that a sample was transmitted. The hosted runner uses MAPS=0 /
SubmitSamplesConsent=2. There is no confirmed manual submission ID: available
MpCmdRun commands provide no explicit sample-upload operation, and no authenticated
Microsoft Security Intelligence submission session/API credential was available
through the authorized SSH-only tools. No Microsoft response was awaited.

Host physical acceptance remains stopped. The original files remain in quarantine,
Defender/Code Integrity were not disabled, no exclusions or allow rules were added,
and no Wave 2 C or merge was performed. Signing can improve deployment provenance
but by itself would not establish the original file's safety or clear this finding.

## Current candidate and updated Defender scan — 2026-11-16 17:43 UTC

The latest complete product CI candidate is `e756dcbb3cb58d8feca7e022e337f13ed398d5a5`.
All ten associated workflows passed; Host Engineering run `43906507047`
included the WB-CI-02 assertion and reported `http=503`,
`HOST_UNAVAILABLE`. The Windows acceptance artifact is ID `14246616073`,
103,808,079 bytes, ZIP SHA-256
`0f085fdae0fc9ea05484524c9640a294fa01f467e475d85aab707f5b81aa3d64`. The
package job checked that the Host payload manifest source commit matched the
checked-out commit and the tracked tree was clean. Its embedded hash evidence
was not extracted here. Both physical Host files independently hash to the
reported `5a18c389c5cce563caa8a5a5ba9222108b785680aebed6878996385c3ea1e5f2`;
this does not establish installation from the latest artifact.

At 17:24 UTC, `Get-MpComputerStatus` reported Antivirus, AM service and
real-time protection enabled on TEST-01 and TEST-02; intelligence was
`1.463.329.0`. `Get-MpPreference` returned `MAPSReporting=2` and
`SubmitSamplesConsent=1` (automatic safe-sample submission policy). This is a
policy setting, not proof that either file was transmitted. `Get-MpThreatDetection`
still returned Threat ID `2147731250` on both machines with `ActionSuccess=true`:
TEST-01 initial detection `2026-11-15T20:10:00.859Z`, last status change
`20:11:32.332Z`; TEST-02 initial detection `2026-11-15T09:59:21.939Z`, last
status change `09:59:45.177Z`. Both resources identify the current Host path;
TEST-01 also records a process resource. Existing `Get-MpThreat` status was
`IsActive=false` and `DidThreatExecute=true`.

One new custom scan per machine used the exact current Host executable with
`MpCmdRun -Scan -ScanType 3 -File <path> -DisableRemediation`. Both returned
exit 0 and `found no threats`; before/after hashes were identical, and both
files remained present. Microsoft documents that `-DisableRemediation` applies
no actions after detection and that custom-scan detections are shown in command
output rather than the event log. The use here did not disable detection,
change signatures or restore quarantined content. This current result still
does not explain the historical Defender event or `DidThreatExecute=true`.

The original security root cause remains **ROOT CAUSE NOT CONFIRMED**. No
sample-submission receipt, Microsoft disposition, or proof that Defender sent
a sample is available. The Host executable was not executed by these scans,
and no additional Host API, database, migration, backup or sync behavior test
was performed. Host physical acceptance remains blocked pending a Microsoft
disposition for the exact hash or explicit owner risk acceptance for isolated
testing with Defender left enabled. The current Client hashes also differ, so
there is no common installed Client candidate for physical synchronization.

## Primary references

- [Microsoft MpCmdRun commands and scan result semantics](https://learn.microsoft.com/en-us/defender-endpoint/command-line-arguments-microsoft-defender-antivirus)
- [Microsoft sample submission policy](https://learn.microsoft.com/en-us/powershell/module/defender/set-mppreference)
- [Microsoft file submission workflow](https://learn.microsoft.com/en-us/defender-endpoint/admin-submissions-mde)
- [Dart compile and self-contained executable structure](https://dart.dev/tools/dart-compile)
