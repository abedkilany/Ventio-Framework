# Wave 2 B candidate — disposable test deployment and rollback

The owner has authorized Ventio installation, upgrade, reset, data deletion,
Host/Client integration and recovery tests on TEST-01, TEST-02 and the disposable
Ventio-Recovery-Lab VM. No repeated approval is required for those Ventio-scoped
operations. BAHAA and its unrelated applications, disks and personal data remain
outside that authorization. Test deployment does not establish Wave_2_B acceptance.

This package is one immutable Host + Client + Installer artifact. Its actual
identity, source commit/tree, compilers, dependency locks and upstream pins are in
Evidence/build-metadata.json and the other Evidence files. SHA256SUMS.txt covers
every other member; the independently recorded complete ZIP SHA-256 anchors that
checksum file. Security/test reports retained beside the artifact are required too.
Matching hashes or clean scans do not establish malware absence or acceptance.

Do not deploy a BAHAA-built ZIP or the superseded 0.1.21+22 / 0.1.22+23 candidates.
The corrected source pins PostgreSQL 16.16-1, .NET SDK 10.0.404/runtime 10.0.15,
Host Dart 3.13.7, Flutter 3.44.1 and Microsoft VC++ x64 14.51.36247.0 minimum.
Ventio executables remain unsigned. If Defender, Smart App Control, AppLocker,
WDAC or script policy blocks an action, stop and retain the diagnostic. Do not
disable protection, add exclusions, restore quarantine, remove zone markers,
change execution policy or use a bypass/encoded/inline-script workaround.

Release signing is a deferred prerequisite: the approved identity is unavailable.
Continue independent tests through existing trusted development/test workflows
where the environment permits them. Retain policy failures as evidence; never
turn an unsigned blocked script into an inline/encoded command to evade policy.

## Disposable test deployment

1. Record the exact candidate, source commit/tree, ZIP hash, destination identity
   and intended fresh-install or upgrade test. Use normal Windows elevation.
   Keep credentials and Recovery Authority witnesses within their intended scope.
2. Verify the target identity and current baseline using read-only checks: intended
   hostname/account, Windows updates and pending restart, enabled/current Defender,
   no current threat, free storage, existing Ventio directories/services/processes.
   Inventory existing VentioHost/VentioPostgres services, ProgramData/Ventio state,
   database, Recovery Authority and Client data before selecting the test. Keep
   upgrade fixtures and expected preserved data identifiable; a fresh installation
   is not proof of the supported upgrade path.
3. Stage the exact verified ZIP in a new directory on the designated test target. Compare the complete
   ZIP with the independent expected SHA-256. Validate ZIP paths for traversal,
   rooted/drive paths, reparse/symlink entries and case-insensitive duplicates.
   Extract into a new empty directory. Verify all manifest entries, the complete
   member set/count and the individual executable/payload hashes before execution.
4. Scan both the exact ZIP and extracted directory with current enabled Defender.
   Confirm each target's matched scan start/completion events and no new detection,
   and recheck all hashes afterward. Stop on a missing, changed or quarantined file.
   Review signature inventory: Microsoft's bundled prerequisite must be Valid;
   NotSigned Ventio files are a distribution limitation, not a forged trust claim.
5. Run the exact verified Ventio-Setup executable. For unattended installation use
   `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-`. The native installer
   verifies the pinned x64 VC++ prerequisite, keeps a newer compatible runtime,
   requests normal elevation and does not force a reboot. Stop for an authorized
   restart if a prerequisite returns 3010/1641; record the restart and retry.
6. Record installer exit status, installed Client and host-payload file hashes,
   installed version and protection state. Verify the entire Client member set,
   including data/app.so; launcher version/hash alone is insufficient. Confirm
   the outcome of Client launch, Host provisioning and any Host/PostgreSQL changes.
   Continue the authorized installed capability, pairing and synchronization tests.
   Both machines must receive identical Client/ bytes
   from this same artifact, never separate local rebuilds.

Installing the Client does not itself provision a Host database. Exercise the
actual supported Host setup and upgrade workflows, and record policy or product
failures. Preserve enabled protection and scoped credentials throughout testing.

## Fresh Client-only rollback

Retain staging files, full manifests, install log and scan evidence. Use the
installed uninstaller through normal elevation within the disposable Ventio test
scope. Inventory services, Host data and recovery witnesses before testing retain
or delete behavior. Verify both the intended removal and intended preservation.
Keep the shared Microsoft VC++ runtime.
Do not reinstall a superseded BAHAA candidate. SQLite v13 Client data is not
automatically compatible with older Clients; do not downgrade an initialized
profile or delete it to hide a failure. Preserve it for an explicit recovery plan.

Installed Host operations, credential recovery and backup/retention/restoration
remain separate acceptance gates. P001–P006 require the identified disposable VM,
verified isolation, permitted signed execution and Recovery Authority controls.
The VM is available, but its admission and installed cases must actually pass. A failing or
unexecuted recovery test does not become passed because this package exists.
