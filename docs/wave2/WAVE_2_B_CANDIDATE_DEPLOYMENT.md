# Corrected Wave 2 B candidate — installation gate and rollback

INSTALLATION DEFERRED. No physical installation is authorized by this document.
The owner must review the exact corrected candidate and remaining blockers and
explicitly approve TEST-02 installation. Wave_2_B is not accepted; Wave_2_C is closed.

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

## Owner-approved TEST-02-only procedure

1. Confirm the approval identifies the exact candidate, source commit, ZIP hash
   and TEST-02-only Client installation without launch/Host setup. Use normal UAC.
   Do not connect to TEST-01 or transfer its data, credentials or recovery witness.
2. Verify TEST-02 identity and current baseline using read-only checks: intended
   hostname/account, Windows updates and pending restart, enabled/current Defender,
   no current threat, free storage, existing Ventio directories/services/processes.
   Stop on unexpected VentioHost/VentioPostgres service, ProgramData/Ventio state,
   database, Recovery Authority or previous Client data. Review coexistence first;
   the fresh-install procedure is not an existing-Host upgrade procedure.
3. Stage the exact approved ZIP in a new TEST-02 directory. Compare the complete
   ZIP with the independent expected SHA-256. Validate ZIP paths for traversal,
   rooted/drive paths, reparse/symlink entries and case-insensitive duplicates.
   Extract into a new empty directory. Verify all manifest entries, the complete
   member set/count and the individual executable/payload hashes before execution.
4. Scan both the exact ZIP and extracted directory with current enabled Defender.
   Confirm each target's matched scan start/completion events and no new detection,
   and recheck all hashes afterward. Stop on a missing, changed or quarantined file.
   Review signature inventory: Microsoft's bundled prerequisite must be Valid;
   NotSigned Ventio files are a distribution limitation, not a forged trust claim.
5. Run only the exact approved Ventio-Setup executable. For an explicitly approved
   unattended installation use `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-`;
   interactive installation must have Launch Ventio cleared. The native installer
   verifies the pinned x64 VC++ prerequisite, keeps a newer compatible runtime,
   requests normal elevation and does not force a reboot. Stop for an authorized
   restart if a prerequisite returns 3010/1641; do not continue automatically.
6. Record installer exit status, installed Client and host-payload file hashes,
   installed version and protection state. Verify the entire Client member set,
   including data/app.so; launcher version/hash alone is insufficient. Confirm
   there was no Ventio launch, local Host provisioning or new Host/PostgreSQL data.
   Stop here. Later Client launch, pairing, synchronization or tests need their
   own approval. Both machines must eventually receive identical Client/ bytes
   from this same artifact, never separate local rebuilds.

There is no remote setup action or bundled database. Merely staging/installing on
TEST-02 without launch/Host provisioning does not contact TEST-01. Later pairing
or synchronization can write to TEST-01's authoritative Host and therefore needs
separate approval. Do not copy the candidate over TEST-01's existing installation.
Its Host update requires a separately verified backup/upgrade/recovery plan.

## Fresh Client-only rollback

Retain staging files, full manifests, install log and scan evidence. Under later
explicit rollback approval, use the installed uninstaller through normal UAC only
after confirming there are no local Ventio Host/PostgreSQL services, Host data or
recovery witness. Stop if any exists; do not approve data deletion or cluster
restoration using this procedure. Verify the installed directory is removed and
there are still no product services/data. Keep the shared Microsoft VC++ runtime.
Do not reinstall a superseded BAHAA candidate. SQLite v13 Client data is not
automatically compatible with older Clients; do not downgrade an initialized
profile or delete it to hide a failure. Preserve it for an explicit recovery plan.

Installed Host operations, credential recovery and backup/retention/restoration
remain separate gates. P001–P006 require a genuinely disposable installed Windows
VM; the owner reported no such VM and authorized preparation only. A failing or
unexecuted recovery test does not become passed because this package exists.
