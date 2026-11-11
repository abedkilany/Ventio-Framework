# Ventio Windows Physical Acceptance Guide

**Package class:** Internal acceptance candidate; unsigned
**Client package version:** 0.1.18
**Release status:** BLOCKED until the results below are completed on the designated devices.

This guide is for the product owner or an authorized Windows operator. It preserves the existing `SYNC-TEST-001` operation and the `sync.test` candidate. Do not install over the target Host until an approved maintenance window and a verified backup are in place. Run the Host upgrade scenario first on an isolated Windows installation with preserved prior-version data.

## Package and prerequisites

Use the checksummed artifacts in this acceptance package. Verify their SHA-256 values against `SHA256SUMS.txt` before copying or installing. Windows will identify these development artifacts as unsigned; accept them only for this controlled internal test. Do not distribute them as a signed commercial release.

The Host requires PostgreSQL 16.15 and the packaged Host payload. The unified installer supports Client installation and optional Host installation. A separate Client-only installer is not included in this candidate. The installer does not include credentials, database contents, Recovery Authority data, or the Host’s private TLS key.

Before starting:

- Confirm the Host is `ABEDKILANY` at `192.168.1.102:8443` and the separate Client is `192.168.1.105`.
- Confirm tenant `AB`, company `CD`, branch `EF`, the existing extension `sync.test / 0.1.0`, and the pending record `SYNC-TEST-001` are the intended acceptance scope.
- Record the current Host and Client versions and confirm a verified, restorable Host backup exists before any Host upgrade.
- Keep the second independently enrolled Client available for cross-client readback.
- Open `physical-acceptance-evidence-template.json` as the run record. Record safe IDs and status only; never record pairing codes, passwords, access tokens, private keys, database connection strings, or credential contents.
- Do not reset SQLite/PostgreSQL, clear the queue, recreate the record, reenroll an already enrolled Client, or approve/reject the existing candidate until the product owner explicitly authorizes that decision.

## A — Host readiness and certificate identity

1. On the Host, open Ventio Host Overview with an authorized account. Record Host version, the API/database/schema/Recovery Authority component states, correlation reference, and timestamp.
2. In Windows Services, confirm `VentioHost` and `VentioPostgres` are Running. Confirm port 8443 is listening with the supported Host diagnostic view or `Get-NetTCPConnection -State Listen -LocalPort 8443`.
3. On the Host, obtain the public `host-lan-certificate.pem` and the SHA-256 fingerprint from the supported Host LAN information view. Send the public certificate and fingerprint to the Client operator through an authenticated channel independent of the new HTTPS connection. The private key must never leave the Host.
4. Inspect the certificate SAN and validity on the Host using the Windows certificate viewer or `certutil -dump`. Choose an endpoint whose exact DNS name or IP address is present in the SAN. For this deployment, use `ABEDKILANY` or `192.168.1.102` only if that exact identity appears in the SAN.
5. Record the endpoint, public-certificate fingerprint, and SAN identity in the evidence record. Do not proceed if Host readiness, listener state, fingerprint provenance, or SAN identity is uncertain.

Read-only service check:

```powershell
Get-Service VentioHost,VentioPostgres | Select-Object Name,Status
Get-NetTCPConnection -State Listen -LocalPort 8443
```

## B — Client HTTPS trust

1. Compare the received certificate’s SHA-256 fingerprint with the Host administrator over the separate authenticated channel. Never obtain the confirmation from the same untrusted connection being evaluated.
2. On the Client, run the packaged `trust-host-certificate.ps1` using the SAN-matching endpoint and the independently confirmed fingerprint:

```powershell
.\support\trust-host-certificate.ps1 `
  -Endpoint 'https://ABEDKILANY:8443' `
  -CertificatePath '.\host-lan-certificate.pem' `
  -ExpectedSha256 '<independently-confirmed-64-character-SHA-256>'
```

3. Require `TRUSTED_AND_VALIDATED`. The script adds only the public leaf to the current Windows user’s `TrustedPeople` store, then calls `/healthz` using `curl.exe --cacert` with that fingerprint-confirmed public certificate. This validates the HTTPS SAN, certificate dates, and Server Authentication usage without accepting an arbitrary certificate or following redirects. The script checks the exact leaf fingerprint before the request and removes a certificate newly added by that run if validation fails. Do not use `-k`, `--insecure`, or any permissive certificate callback.
4. In the Ventio Client, open **Host Settings → Host certificate trust**. Enter the same independently confirmed fingerprint and choose **Verify and update Host trust**. Require the success message. This updates only the app’s secure endpoint pin; the enrolled identity, credential, local database, and pending queue remain unchanged.
5. Record the result and fingerprint. If any check fails, stop enrollment and preserve existing credentials and queue data. Check SAN/endpoint match, validity, and the out-of-band fingerprint with the Host administrator.

### Certificate renewal

For renewal, obtain the new public certificate and fingerprint over the authenticated Host-admin channel, inspect the SAN and validity, and repeat steps B1–B4. The Client retains the old pin unless the new certificate has passed both exact fingerprint comparison and normal TLS endpoint/validity checks. Only after successful rotation, an operator may remove a previously imported old certificate from that Windows user’s `TrustedPeople` store with `trust-host-certificate.ps1 -Remove`, supplying the old public certificate and its old fingerprint. Do not remove the old app pin or trust entry before the new certificate is verified. Rotation never changes Host credentials or queued operations.

## C — Client enrollment and restart

1. If the Client already has a valid enrolled profile, do not reenroll. Record its current device ID and verify it reconnects after restarting Ventio.
2. For a new/disposable Client only, use the supported **Connect this device to an existing Host** flow. Enter the HTTPS origin, fingerprint confirmed in step B, and a newly issued single-use code from an authorized Host operator. The Host assigns the exact actor/company/branch scope.
3. Require successful enrollment and a successful authenticated Host Overview refresh. Restart the Client and verify the same device ID and scope reconnect. Never export or record the one-time pairing code or credential.

## D — Existing extension candidate and review

1. In Host Administration → Extension review, use an account with `extension.package.review` granted at the exact `AB/CD/EF` scope.
2. Locate `sync.test / 0.1.0` and inspect submitter, package identity, digest, permissions, and review data. Record only module/version/digest and visible status.
3. Confirm the submitter cannot review its own candidate. Confirm a non-reviewer is denied and cannot see out-of-scope candidates.
4. **Do not approve or reject the existing candidate without explicit product-owner authorization.** After that authorization, the reviewer may choose the requested decision and record a non-sensitive reason. Confirm the Host displays the durable decision and reason safely.
5. Verify the approved package identity and SHA-256 digest on the Client. Confirm a rejected or pending candidate remains unavailable and that the Client cannot self-approve or activate an unapproved package.

The disposable PostgreSQL integration has already verified these server-side boundaries. This physical UI sequence remains untested until performed on the target machines.

## E — Preserve and synchronize `SYNC-TEST-001`

1. Before any retry, use the Client’s pending-operations view to confirm the exact existing record/operation identity `SYNC-TEST-001`, pending status, and current retryable/authorization/conflict state. Record the operation ID and counts, not payload secrets.
2. Confirm the Client still has its original enrolled identity, secure Host pin, and `AB/CD/EF` scope. Confirm Host authorization and the approved extension prerequisites are valid.
3. Restore network access and retry the same pending operation using the supported synchronization control. Do not create another `SYNC-TEST-001` and do not clear/rebuild the queue.
4. Require an accepted Host receipt for the same operation ID, a valid receipt verification result, durable SQLite receipt recording, and `Host confirmed` state. A timeout, HTTP error, or lost response is not confirmation; retry only the same operation ID after checking its authoritative status.
5. On the Host, verify the accepted record and receipt through authorized Host administration/read APIs. Record receipt ID, operation ID, and Host confirmation state; do not paste credentials or raw request bodies into the report.
6. If the Host rejects the operation, record the safe reason code and leave the operation visible as rejected. If a conflict is reported, record it as a conflict and follow the existing conflict-review workflow; do not label it as a generic retry failure.

## F — Independent Client visibility

On a second independently enrolled Client, sign in under a valid `AB/CD/EF` read grant and read `SYNC-TEST-001` from the Host. Record the second Client device ID, exact scope, visible Host revision, and timestamp. Verify a user lacking that grant receives an authorization denial. A database query, mock Client, or second session in the same Client does not satisfy this scenario.

## G — Release performance capture

Use the Release executable from this package and the packaged `measure-ventio-performance.ps1` on the Client. It writes a JSONL app timing trace and a JSON summary with Client process CPU, private/working memory, process I/O, system CPU, and system disk utilization samples. The app trace contains workflow names, durations, and outcomes only. For Host-side correlation, start the packaged read-only `measure-ventio-host-performance.ps1` on the Host before the workflow; it samples only `VentioHostService`, `postgres`, and system counters, and records no request or database content:

```powershell
& .\support\measure-ventio-host-performance.ps1 `
  -OutputPath (Join-Path (Get-Location) 'evidence\host-setup-resources.jsonl') `
  -DurationSeconds 1800
```

Choose a new output filename for each capture. Keep the Host and Client timestamps aligned. A missing Host process or unavailable Windows performance counter is written as a null/zero-count observation, not treated as proof that the workflow completed. The collector does not change Host services or databases.

For a fresh startup profile, choose a new empty profile directory outside `%APPDATA%\VentioFramework`:

```powershell
.\support\measure-ventio-performance.ps1 `
  -ExecutablePath "$env:ProgramFiles\Ventio\ventio_native_client.exe" `
  -OutputDirectory '.\evidence' `
  -RunLabel 'cold-start-01' `
  -CloseAfterFirstScreen `
  -AppSupportDirectory "$env:LOCALAPPDATA\VentioFramework\AcceptanceProfiles\cold-start-01"
```

For a warm launch, use the same isolated profile with a new run label and add `-ReuseIsolatedProfile -CloseAfterFirstScreen`. To collect five comparable pairs without resetting any profile:

```powershell
$ventioExe = "$env:ProgramFiles\Ventio\ventio_native_client.exe"
for ($n = 1; $n -le 5; $n++) {
  $ventioProfile = "$env:LOCALAPPDATA\VentioFramework\AcceptanceProfiles\startup-$n"
  & .\support\measure-ventio-performance.ps1 -ExecutablePath $ventioExe -OutputDirectory '.\evidence' -RunLabel "cold-$n" -AppSupportDirectory $ventioProfile -CloseAfterFirstScreen
  & .\support\measure-ventio-performance.ps1 -ExecutablePath $ventioExe -OutputDirectory '.\evidence' -RunLabel "warm-$n" -AppSupportDirectory $ventioProfile -ReuseIsolatedProfile -CloseAfterFirstScreen
}
```

For existing enrolled-user workflows, omit `-AppSupportDirectory` so the installed profile is used; do not reset or change it. After the app launches, complete one named workflow and close Ventio to finish collection. Capture at least five comparable runs per workflow, recording device power mode, CPU/RAM, network, OS/build, and cold/warm state. The trace records page navigation, pairing-page sub-stages, pairing generation, Host Setup, SQLite startup, and first-screen readiness. Host setup and Pairing Code generation may modify Host state; use the authorized isolated Host/VM and a disposable reviewer/operator account. Do not trigger initial Host Setup against the owner’s active Host.

Report medians and ranges by workflow, together with sampled contention. Do not compare dissimilar device states or invent pass thresholds. Mark workflows not safely available as `NOT TESTED`.

## H — Installed upgrade

Perform the original installed Host upgrade only in an isolated Windows VM first. Install a real prior-version Host with preserved database rows, Windows service identities, backup, and valid Recovery Authority witness state; use the target installer; verify migration 031–035, Recovery Authority receipts, PostgreSQL, Host service startup, HTTPS trust/readiness, and Client connectivity. This disposable migration-030 fixture does not prove the original 0.1.9 installed upgrade. Never use a clean install as upgrade evidence. The owner’s active target Host must not be the first upgrade trial.

## Pass/fail and recovery

Record each A–H result in the JSON evidence template with one classification: `PASS — VERIFIED`, `FAIL — REPRODUCED`, `BLOCKED — ENVIRONMENT`, or `NOT TESTED`. Attach only sanitized timing traces, safe correlation IDs, checksums, and public certificate fingerprints.

If trust, enrollment, authorization, readiness, or receipt verification fails, stop that dependent workflow and retain the current database, credentials, and pending operation. Use the visible safe error code/correlation reference and Host administrator diagnostics to investigate. Do not rerun installation, reset databases, delete pins, or alter Recovery Authority state as an improvised repair.
