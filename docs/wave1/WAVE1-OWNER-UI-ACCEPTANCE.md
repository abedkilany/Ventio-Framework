# Wave 1 owner UI acceptance

**Current disposition — 2026-11-11:** No `OWNER_UI_REQUIRED` checks remain for internal Wave 1 acceptance. The owner evidence below is retained for review; do not repeat those procedures for closure. The [final audit](final-audit-preparation-20261102.md) reconciles the accepted stages and the environment limitations.

| Required owner evidence | Computer and tested version | Accepted result |
|---|---|---|
| Enrollment and restart; extension review; offline sync; independent readback and denial | Physical Host and Windows Client, `0.1.18+19`, plus the physical Android Client | Enrolled sessions persisted, distinct authorized reviewer approved, offline commands were accepted and confirmed, independent readback succeeded, and a separate ungranted user was denied. [Physical evidence](wave1-ssh-engineering-completion-2026-11-09.md) |
| Fresh setup, exact failure and sanitized export, resume and repeated readiness | Development Host, Wave1fix18 `0.1.18+19` | Exact retryable PostgreSQL port conflict, broker continuation after Flutter exited, a single consumed first-admin handoff and authenticated READY. Both repeat screenshots match the original scope and saved operation. [Installed evidence](evidence-closure-2026-11-08/development-wave1fix18-installed-20261110.json) |
| Installed repair, reboot, default retention and explicit delete | Development Host, Wave1fix16 and Wave1fix17 `0.1.18` | Missing runner restored; original database and record preserved by recovery and retention; automatic startup and authenticated readiness; deletion stayed within the designated fixture. [Lifecycle evidence](wave1-ssh-engineering-completion-2026-11-09.md) |

The candidate containing the user-list fix, [Wave1fix19](evidence-closure-2026-11-08/development-wave1fix19-candidate-20261111.json), passed the focused automated tests and Windows build verification. It has not been installed. Leave the current fixture and protected archive intact; there is no additional deployment required for the internal closure.

## Historical procedures and evidence

The following steps were the handoff used during testing. Individual pending labels describe their dated checkpoint and are superseded by the current disposition above. Keep pairing codes, tokens, passwords, database URLs and private keys out of all screenshots and exports.

## Historical handoff — Native Development Host fixture

The owner authorized using the current Windows installation as the Ventio Framework fixture and authorized discarding the old Framework test data. The separate Ventio `1.0.64+64` app has a different installer ID and remains outside the fixture scope, as do the source repository, developer services and the two physical test devices. The baseline is clean for the Framework product on a used Windows installation. Use a supported, verified backup of new synthetic fixture data before any data removal or restore.

1. **PASS.** The owner approved the verified Wave1fix15 application install. Engineering verified exit 0, all installed payload hashes and absence of provisioned Host services. The installed dry-run fresh plan passed. The Framework executable is `C:\Program Files\Ventio\ventio_native_client.exe`.
2. **PARTIAL.** First setup completed in `wave1lab / fixture / devhost`. Windows was configured to elevate administrators without prompting, so UAC cancellation remains untested. The saved profile authenticated after application reopen. Prepare a fresh fixture baseline for the controlled setup failure and interruption cases and use a fixture-only listener on `127.0.0.1:54329` for the failure. Authenticated readiness after a coordinated Windows reboot passed in item 3.
3. **PASS for upgrade, restore, repair and reboot.** The installed Wave1fix15 to Wave1fix16 upgrade, coordinated restore and missing-runner repair preserved the authenticated synthetic record, Host certificate and PostgreSQL identity. Both services started automatically after reboot. The owner verified authenticated Host Overview READY with the same profile. Follow with item 6 once engineering verifies the retained-data reinstall path. [Owner screenshot](evidence-closure-2026-11-08/owner-development-host-overview-post-reboot-20261110.png)

## Start here after the clean reinstall

The owner removed both prior installations. The fresh Wave1fix15 installation succeeded on both devices. On physical Host, open Ventio, choose **Set up this computer as a Host**, enter the intended test scope, approve the Windows elevation prompt, and complete creation of the first administrator. Record the first-run phases and outcome. Continue to item 1 when the new administrator can open **Host overview**. On physical Client, wait until Host setup completes, then use **Connect this device to an existing Host** as described in item 2.

The legacy credential-recovery instruction below applies only if an old Host installation is restored. Keep the controlled failure, interruption, and uninstall cases on a disposable Windows fixture. If the historical `SYNC-TEST-001` operation is unavailable on the reinstalled Client, retain the archived evidence and report the historical result separately. Use a distinct record ID for the fresh offline scenario.

## Prerequisites and order

- Use the verified Wave1fix15 internal Windows installer, product **0.1.18**, Flutter **0.1.18+19**, SHA-256 `8e921367a6a7139a232fdf0a9f5fd3d1d61703bbf53d25c3ca705991d446b284`. It is unsigned. Host is `192.168.1.102` (hardware UUID ending `F343032`), Client is `192.168.1.105` (ending `6E398C6C`). Host HTTPS is `https://192.168.1.102:8443`. The intended application scope is `AB / CD / EF`.
- Before interacting with the existing installation, establish a supported valid Ventio operator session. Windows administrator access is for setup elevation. The application requires the selected scope and current Ventio grants. See [credential recovery disposition](evidence-closure-2026-11-08/host-administrator-credential-recovery-investigation-2026-11-09.md). If no authorized session is available, record `CREDENTIAL_RECOVERY_REQUIRED` and defer items 1–4. Keep the existing Host and Client profiles intact.
- Reuse the valid operator session for the applicable actions. Reserve a separate disposable Windows user profile for Client enrollment so it has its own application storage and credential vault. Use distinct submitter and reviewer identities and an independently enrolled second physical Client for readback. The Host workstation's existing Host profile and a second login on the same physical Client do not satisfy the independent Client criterion. Record device/OS and build provenance for the separate Android hardware evidence required by the existing ledger.
- Keep the [historical pending command snapshot](evidence-closure-2026-11-08/client-queue-preservation-20261109.json) and its SQLite database/WAL/SHM copies together. Preserve the original Client profile. For items 5–6 use only the designated Ventio Framework fixture with synthetic data and a verified backup. On Development, scope actions to the new Framework fixture and preserve the workstation and separate Ventio app.

## 1. Authenticated Host Overview

**Device and initial state:** Host, 0.1.18+19, existing configured profile; signed in with exact-scope `host.status.read`. Both Ventio services are expected to be running.

1. Open Ventio. Confirm the intended profile and scope. Open **Host overview → Refresh Host readiness**.
2. Record the displayed Host version, scope, API/database/schema/Recovery Authority cards, timestamp and correlation reference. Close and reopen Ventio normally. Refresh using the same profile.

**PASS:** The authenticated screen shows READY for all four components, visible Host version, and the same scope after reopening. Capture the overview without any private data. **FAIL:** A 401, degraded component or missing version/reference. Keep the profile and capture the safe code and reference. A public health response is only transport evidence.

## 2. Client trust and enrollment

**Device and initial state:** Client, 0.1.18+19, fresh disposable profile. An operator with exact-scope `identity.pairing.manage` issues a single-use code for the intended test identity. The target grants must cover only the test actions that identity performs. Keep the historical Client profile available for item 4.

1. Confirm the public certificate fingerprint independently with the operator. Use **Connect this device to an existing Host** and enter the SAN-matching HTTPS origin and verified fingerprint. Enter the one-time code privately. For an already enrolled test profile needing an updated pin, use **Host Settings → Host certificate trust → Verify and update Host trust**.
2. Confirm enrollment, assigned scope, and successful authenticated use. Reopen Ventio and verify the same device ID and scope reconnect. Capture only the post-enrollment status and safe device ID.

**PASS:** The new Client persists the enrolled identity and verified endpoint across restart, and requests succeed within scope. **FAIL:** Trust, enrollment, scope, or restart fails. Preserve the existing profile, capture the safe error/reference, and ask the authorized operator to check the original pairing request before issuing a new code. Do not photograph the code.

## 3. Submission and independent review from a Client

**Device and initial state:** Client, 0.1.18+19, approved test profiles at `AB / CD / EF`. Submitter has `extension.package.submit`. A different Ventio user on a Client has `extension.package.review` for that scope. Have a user without the review grant and an out-of-scope test identity available for denial checks.

1. In Extension Studio, locate the intended `sync.test / 0.1.0` bundle. Compare identity and SHA-256 with the existing candidate, if present. Submit it for Host review only if the authorized candidate has not already been submitted. Retain the existing digest and decision state. Record the submitter and candidate reference.
2. Verify the candidate is unavailable in the approved registry while pending. Verify a submitter with review permission cannot approve their own candidate, a non-reviewer cannot review, and an out-of-scope reviewer cannot see the candidate. Avoid repeatedly submitting or creating another version.
3. From the authorized **Client** session open **Host administration → Review extension candidates**. Confirm the exact module, version, scope, submitter and digest. Approve only the intended test candidate after the owner confirms the decision. Refresh the review list and the approved registry from an authorized reader.

**PASS:** Host records the scoped approval for that digest, the approved registry returns it, and the negative cases are denied. Capture the safe candidate decision, digest, reviewer device/scope and denial results. **FAIL:** Wrong digest, missing candidate, unexpected grants or a Host rejection. Preserve candidate state and capture safe references. Leave an already approved candidate intact and provide its historical submission and decision evidence; a read-only registry observation by itself does not prove this sequence.

## 4. Offline write, receipt and independent readback

**Device and initial state:** Original Client for the historical pending operation; enrolled disposable Client for any fresh offline operation; independent second physical Client for readback. Use 0.1.18+19 on Windows. Writers have the package and DocType read/create grants, and the reader has the exact-scope read grants. Install/activate the exact approved digest before writing.

1. Before retrying, compare the original profile, scope and command ID with the saved evidence for `SYNC-TEST-001`: `986963e9-1695-458a-85cc-aa5f4267aad8`. Capture Pending in Synchronization. If the operation is missing or its original identity cannot be verified, keep the backup and record that exact outcome. Do not recreate this ID or transplant its command into a new profile.
2. If the original run does not show offline creation, create a distinctly named disposable record in the same approved DocType on the enrolled Client with only that Client's network disconnected. Record the newly queued ID and provisional state. Reopen while offline and verify the same ID is still pending. Restore network and choose **Retry pending** on the appropriate profile for each operation that can legitimately run. Confirm an accepted Host receipt for the original command ID of each tested operation and a visible Host-confirmed state. Reopen to check receipt persistence.
3. On the independent Client, query the approved extension records from Host, using the same exact scope. Capture the safe record ID, independent device ID, revision and time. Verify a user lacking the read grant is denied.
4. **PASS.** The owner used a separate Windows profile and Ventio account to install and activate the approved `sync.test / 0.1.0`. **Product → Open records** returned `PERMISSION_DENIED` with neither test record visible. [Physical read-denial evidence](evidence-closure-2026-11-08/owner-windows-product-read-denied-20261110.png)

**PASS:** Evidence traces offline creation or the preserved pending operation to an accepted, durable receipt for the same command, then shows the authoritative record on the independent Client and denial without permission. Record the result for the historical operation separately. **FAIL:** Pending forever, 401, rejection, conflict, duplicate effect or missing independent record. Preserve queue, package and profile; export the sanitized status. Reuse the same command ID only through the supported retry flow when retryable. A transport error or locally displayed row is not Host acceptance.

## 5. Installed first run, interruption, resume and failure export

**Device and initial state:** Designated Ventio Framework Host fixture, 0.1.18+19. The current native Development fixture starts without Framework Host data or services. Use a Windows administrator to approve the broker and a new synthetic first-admin identity for this fixture only.

1. Install the verified unified package. Open Ventio as the normal user and choose **Set up this computer as a Host**. Capture the first-run choices and the initial setup phase. Start setup with a synthetic scope.
2. On this fixture, decline the first UAC prompt and capture the safe error or cancellation and **Copy sanitized setup report** result if offered. If no failure report is offered for cancellation, capture cancellation separately. Use a controlled pre-API provisioning failure on a restorable snapshot, such as a fixture-owned listener occupying the requested PostgreSQL port; capture the actual reported setup code, phase, correlation, safe action and sanitized export. Remove only the fixture-owned collision. If the scenario does not reproduce a product failure, record it as untested and keep the fixture for a supported failure case.
3. Retry the same setup. After the broker has a durable pending operation and before readiness, close only Flutter using its window control. Record the phase/reference. Reopen and resume the same operation. If the chosen checkpoint completed before interruption, it does not demonstrate interrupted resume; repeat on the clean snapshot at a valid checkpoint. Let engineering verify any required SCM-level interruption through SSH on this fixture in a coordinated maintenance run.
4. Verify the original scope, a single first-admin handoff, an authenticated READY overview and safe repeat behavior from Setup. Reboot the fixture and verify the existing profile authenticates and the service remains available. Pair a disposable Client only if needed for the clean-install integration. Capture phase transitions, failure export, readiness before/after restart, and the safe operation reference. Engineering records service identities and ACLs through CLI.

**PASS:** Installed first run, broker elevation, failure/export, durable interruption/resume, idempotent repeat, authenticated readiness and reboot all work on the fixture; CLI evidence corroborates the single handoff and SCM/ACL state. **FAIL:** A duplicate bootstrap, unrelated port/service change, lost pending operation, exposed secret, or missing readiness. Preserve the failed snapshot and sanitized logs, then restore the fixture baseline only after capturing evidence.

## 6. Host uninstall data choice

**Device and initial state:** Isolated Host fixture only, 0.1.18+19, Windows administrator and a working synthetic Host with a seeded record, backup, and snapshot. Use an authorized Ventio reader to establish the seeded record and revision before changing anything.

1. Open the installed uninstaller. Capture the default unchecked **Permanently delete all Ventio Host data and backups** option. Leave it unchecked and finish. Record application and service removal and CLI inventory of retained database, configuration, Recovery Authority, diagnostics and backups. Reinstall the same verified candidate via the supported path and verify the same synthetic row/revision and authenticated readiness.
2. If the ledger requires the deletion branch, restore a separate disposable snapshot containing only synthetic data. Select the deletion checkbox, confirm the explicit irreversible action and verify that the fixture's Ventio product root is removed. Preserve the snapshot and a control directory outside that root for comparison. Never select this option on the live Host.

**PASS:** Default retention and reinstall preserve the seeded data and identity evidence; explicit deletion on a separate disposable fixture removes only the intended product data. **FAIL:** Any loss during retention, removal outside the Ventio boundary, or failed reinstall/readback. Keep the isolated snapshot and logs for diagnosis. Stop before another uninstall.

### Native Development retention sequence with Wave1fix17

**PASS on 2026-11-10.** The original Product row returned at Host revision 1 after removal, reinstall and reactivation. The following steps record the completed procedure. Explicit permanent deletion remains a separate test. [Evidence](evidence-closure-2026-11-08/development-wave1fix17-installed-baseline-20261110.json)

1. First install Wave1fix17 over the working Wave1fix16 fixture. Keep the pre-upgrade backup. Verify the installed manifest, the same PostgreSQL identifier, the original HTTPS certificate pin and an authenticated read of the same `W1-RETENTION-CONTROL-01` row at revision 1. Keep this baseline before removing anything.
2. After the upgrade baseline passes, open the exact Framework uninstaller at `C:\Program Files\Ventio\unins000.exe` and capture the unchecked retention dialog. Complete removal with the delete option unchecked. Confirm both services are absent and the fixture data remains before reinstalling the same verified installer. Leave the normal application closed until reactivation finishes.
3. Run the following command in elevated Windows PowerShell for the native Development fixture. The default is a read-only plan. After it reports `HOST_RETAINED_REACTIVATION_PLAN_VALID`, rerun the same command with `-Apply` appended. Keep the output.

```powershell
& 'C:\Program Files\Ventio\host-payload\setup\reactivate-retained-host.ps1' -ExpectedManifestSha256 'E793308BDD1177EE826BED1B717E117901E4141AE4B0802F80B207E8DA46065C' -ExpectedClusterId '7706529747229262104'
```

4. Expect `HOST_RETAINED_REACTIVATION_COMPLETE`. Verify that both services are Automatic and Running, then open the existing profile and capture Host Overview READY and the same Product row at revision 1. Confirm the original PostgreSQL identifier and certificate pin again. Keep the checkbox screenshot and sanitized command output. If planning or reactivation fails, leave the retained data in place and save the exact failure code before any further install or setup.

### Same-machine safety checkpoint before explicit deletion

The owner selected Development for the remaining fixture tests. Its verified Wave1fix17 Host is still running. Its five retained backups are inside the deletion boundary. The next operation is an elevated, offline archive of the designated Framework product root into a new administrator-and-SYSTEM-only sibling outside that boundary. The prepared procedure checks the pinned installed manifest, stops only the two Ventio services, verifies the cleanly stopped original cluster, compares the source and archive file hashes and ACLs, verifies the archived cluster identifier, and restarts the services in its cleanup path. Preserve the output and independently confirm service health before any deletion. Archive integrity and recovery from the archive are separate checks. Keep the separate Ventio 1.0.64+64 application and the development environment outside the test scope.

## 7. Physical Android Client

**Device and initial state:** Separate physical Android test device (Android 7/API 24 or later), disposable profile, existing verified Host, and a scoped user with package/DocType read and test create grants. Use the [internal 0.1.18+19 APK](../../artifacts/ventio-android-acceptance-0.1.18-20261109/Ventio-Android-0.1.18+19-internal.apk), [checksum](../../artifacts/ventio-android-acceptance-0.1.18-20261109/SHA256SUMS.txt) and [verified debug signer fingerprint](evidence-closure-2026-11-08/ssh-only-android-build.log). The Android emulator result is already recorded. Keep any existing Android profile and queued work.

1. Verify the candidate's checksum and signer. Install it only in the disposable test profile. If Android reports a signing conflict with an existing install, stop and use separate test equipment instead of uninstalling it.
2. Enroll with a fresh single-use code and independently confirmed Host fingerprint as in item 2. Use the approved digest and exact scope from item 3. Confirm the existing accepted record with a Host refresh.
3. Disconnect only Android networking, create a distinct synthetic record, and verify its pending operation survives app reopen. Reconnect, retry the same operation and require an accepted receipt. On the already enrolled Windows Client, refresh and verify the authoritative record and revision.

**PASS:** Enrollment, TLS pin, offline queue, accepted receipt and Windows readback are evidenced for the physical Android device. Capture Android version, app version, safe device and command IDs, receipt/status and independent readback. **FAIL:** Record the safe reference, keep the device profile and pending data, and follow the retry guidance in item 4. Keep secrets out of the screenshots.

**PASS:** Independent Android and Windows readback passed in both directions. The owner confirmed that the Pending screenshot was taken after restarting the phone and reopening Ventio while still offline. The same command was confirmed by Host on the first attempt after reconnection. The owner deferred Android Name sorting until after Wave 1.

## Separate CLI policy hold

Stage 10 file repair is `POLICY_APPROVAL_REQUIRED`. Once the original launcher is approved, use the [verified repair procedure](evidence-closure-2026-11-08/installer-process-policy-source-and-client-queue-2026-11-09.md#verified-installer-for-owner-assisted-execution), with a confirmed restorable backup and maintenance window. The owner can close the existing Ventio window before that approved run. Final acceptance also requires the corresponding CLI evidence.

### Native Development repair handoff

**PASS on 2026-11-10.** Owner returned `REPAIR_TEST_RUNNER_RESTORED`; engineering verified the executable, payload, original cluster, service policy, pinned HTTPS and control record. [Attestation](evidence-closure-2026-11-08/development-wave1fix16-repair-verification-20261110.json)

Open PowerShell as Windows administrator. With Framework closed, run this single command. The helper validates the exact installer hash and cluster identity, moves only the Framework runner to a unique evidence folder, and verifies its replacement and service state. The original runner and installer log are retained there.

```powershell
& 'C:\Users\User\Desktop\Ventio Framework\scripts\windows\test-installed-host-runner-repair.ps1' -InstallerPath 'C:\Users\User\Desktop\Ventio Framework\artifacts\ventio-windows-acceptance-0.1.18-wave1fix16-20261110\installers\unified\Ventio-Setup-0.1.18.exe' -InstallerSha256 '1f82c559e2cf3b8d7078ad0147fd76f944d4687247319e4a41bdabda324b9354' -ExpectedClusterId '7706529747229262104'
```

Capture `REPAIR_TEST_RUNNER_RESTORED` and the evidence directory. Engineering then verifies pinned HTTPS, authenticated readiness and the same control record. If the helper reports a failure, preserve the reported directory and log for diagnosis before any retry.
