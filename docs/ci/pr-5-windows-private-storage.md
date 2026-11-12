# PR #5: GitHub-hosted Windows private test storage

## Proven causes

The failing baseline was `c47901d8007a0c798fdd7af2646db1bbc7ee30b2`.

1. **Untrusted ancestor owner on the hosted work drive.**
   Diagnostic commit `82f21c6b054dac182e9008275515b508640ff818`,
   [Host API job 131513050102](https://github.com/abedkilany/Ventio-Framework/actions/runs/43312826443/job/131513050102),
   reported trusted Administrators ownership for `D:\a\_temp` and `D:\a`,
   but `D:\` was owned by `S-1-5-20` (Network Service).
   The existing ancestor-owner policy correctly refused that owner.
   No untrusted destructive access rule was reported on that chain.
   The initial failure was therefore ownership, rather than an assumed
   DeleteSubdirectoriesAndFiles grant.

2. **The elevated hosted process defaults new file ownership to Administrators.**
   A candidate under USERPROFILE passed the complete ancestor check.
   [Probe job 131515826249](https://github.com/abedkilany/Ventio-Framework/actions/runs/43313627090/job/131515826249)
   then proved that the created probe had owner `S-1-5-32-544`
   while the expected owner was the current runner user
   `S-1-5-21-3289802278-1561746829-1498425070-500`.
   The DACL was protected and contained exactly the expected three
   non-inherited FullControl allow entries. The production helper correctly
   rejected the owner mismatch at `verify_file_acl`.

These failures explain the original private-file creation errors, authority
lock creation errors, and subsequent RecoveryAdmissionUnavailable failure.

3. **A debug line polluted a crash worker's JSON protocol.**
   [Lifecycle job 131517076105](https://github.com/abedkilany/Ventio-Framework/actions/runs/43313986445/job/131517076105)
   reached concurrent rotation, device revocation, restore and reenrollment
   checks, then failed at lifecycle_integration.dart:674 because its first
   stdout line was a private-file diagnostic rather than the barrier JSON.
   Diagnostics are now disabled only in that machine-protocol worker.

4. **The Windows identity fixture waited for child shutdown without closing stdin.**
   [Recovery job 131517077819](https://github.com/abedkilany/Ventio-Framework/actions/runs/43313986953/job/131517077819)
   passed crash durability, fresh-cluster restore, ACL/RLS preservation and
   restored identity checks, then timed out in identity_integration.dart:1188
   while awaiting a clean child exit. The parent now closes stdin after
   sending the shutdown line, delivering EOF to the fixture's stdin
   subscription. The existing 20-second bound and zero-exit assertion remain.

## Test-environment changes

- CI provisions a unique directory under USERPROFILE, applies a private DACL,
  and exercises production create/read/verify operations before exporting it
  as `VENTIO_TEST_PRIVATE_ROOT`. USERPROFILE is a candidate, never an
  automatically trusted location.
- Only test fixture code consumes this override. Production paths, production
  helper code, trusted SIDs and ACL checks remain unchanged.
- A GitHub-hosted-Windows-only test launcher temporarily sets the process
  token's default object owner to the existing current user. It changes no
  privileges or group memberships and restores the original owner afterward.
  Test descendants use the same ownership context.
- Host API runs its complete Windows private-file test before downloading
  PostgreSQL. All existing tests remain present.
- A new negative case grants Authenticated Users only DeleteSubdirectoriesAndFiles
  on an isolated ancestor, protects the child directory, and verifies that
  creation is still rejected and no file is created.
- Diagnostics expose only test ACL metadata: ancestor paths, SIDs, access
  masks, inheritance flags and probe owner/rules. They do not print request
  data, credentials or protected file contents.

## Validation

All tests/builds are executed by GitHub Actions. No local tests/builds,
self-hosted runs, force pushes or merges are used.

### Verified source revision

Source revision: `559d3ccdbb5f48deb266aeaedea7f1204ea23acb`.

| Affected workflow | Result | Direct evidence |
| --- | --- | --- |
| Host API | Success; 605 assertions across 11 result summaries, plus private-file and unsafe-ancestor cases | [Job 131524728145](https://github.com/abedkilany/Ventio-Framework/actions/runs/43316177090/job/131524728145) |
| Credential Lifecycle | Success; 117 assertions, including all six real forced-crash barriers | [Job 131524669670](https://github.com/abedkilany/Ventio-Framework/actions/runs/43316177146/job/131524669670) |
| Host Crash Recovery | Success; 110 assertions, plus restored identity 79/79 and database security 118/118 | [Job 131524669775](https://github.com/abedkilany/Ventio-Framework/actions/runs/43316177063/job/131524669775) |

The same revision also passed Core Foundation, Host Engineering Gate,
Host Persistence, Durable Commands, and Native Flutter Client and Extension
Builder, including the Windows acceptance and Android release build.
All eight workflows completed successfully.

The logs confirm restoration of the original default object owner after each
wrapped test command. Existing security cases and their per-case deadlines
remain enabled and unchanged. No production lib/bin files were modified.

### Fresh complete verification cycle

After the affected workflows passed, publishing this report starts a new
complete CI cycle on PR #5. The source is identical to the verified revision
above; this final commit adds this report only. Its full workflow results are
available in [PR #5 checks](https://github.com/abedkilany/Ventio-Framework/pull/5/checks).
