# Wave1fix14 Resumed Closure Checkpoint — 2026-11-09

## Host access and readiness

Connected from Development (`192.168.1.104`) to Host (`192.168.1.102`) with the existing `%USERPROFILE%\.ssh\ventio_lab` key, account `abedkilany`. SSH exited 0. Remote command output:

```text
ABEDKILANY
abedkilany\abedkilany
Mandatory Label\High Mandatory Level   Label   S-1-16-12288

VentioHost     Running Automatic
VentioPostgres Running Automatic

0.0.0.0
```

`0.0.0.0` is the listening address for TCP 8443. The Host product registry reports Ventio `0.1.18`. A certificate-pinned HTTPS check from Development used the preserved Host public certificate:

```text
HTTP=200 TLS_VERIFY=0
{"apiVersion":1,"status":"alive"}
CURL_EXIT=0
```

This verifies HTTPS transport and process liveness. It is not authenticated application readiness.

## Installed Host Setup retry result

The existing Host RDP session at `192.168.1.102` showed Ventio Host Setup with scope `AB/CD/EF`. The retry reached the Host-readiness step but ended with the visible message:

```text
Host setup did not complete. Review the service status and retry. No credential was displayed.
```

The saved local profile database confirms the existing local endpoint `http://127.0.0.1:8080`, the same exact scope, and a previously bound actor/device profile updated on 2026-11-07. The setup coordinator therefore followed its existing-profile verification branch; it did not issue a second first-administrator bootstrap request. No Host service, database, or configuration was changed by this retry.

The sanitized local diagnostic database records:

```text
code: HOST_SESSION_AUTHENTICATION_FAILED
component: client.host_setup.host_readiness
correlation: cor_4d29c2a9223e6e95739d952a06da9b12
protected failure type: HostSetupException
protected failure source: LocalHostSetupCredentialStore.verifyAndBindExistingProfile
```

The exact underlying Host response/transport code is still unknown. The current wrapper discards `HostPackageTransportException.code`; it can no longer be recovered from the sanitized event. Read-only copies of the local diagnostics SQLite database and Host profile metadata database, including SQLite sidecars present at capture time, are preserved in this directory. No credential, DPAPI data, private certificate key, Host database payload, or Recovery Authority witness was read or copied.

## Correction and regression

`LocalHostSetupCredentialStore.verifyAndBindExistingProfile` now preserves the already validated Host transport error code in `HostSetupException`, allowing the next supported setup retry to record the exact safe code. Other unexpected exceptions retain the generic authentication failure code.

Regression evidence:

```text
flutter test --no-pub test/host_setup_test.dart
00:04 +26: All tests passed!
exit: 0

flutter analyze --no-pub lib/src/host_setup.dart test/host_setup_test.dart
No issues found!
exit: 0
```

This fix has not yet been deployed to the Host. Therefore it does not reveal whether the underlying saved credential is expired, revoked, mismatched, or failing for another reason.

## Rebuilt Windows acceptance candidate

The current source built successfully as an unsigned internal 0.1.18 candidate. The verified Host payload `host-payload-wave1fix11` was reused unchanged; its manifest declares 1,707 files / 311,290,663 bytes and includes migration 036. The installer builder passed its unified-installer path contract, deferred Host provisioning boundary, Visual C++ prerequisite checks, and machine-wide Host privilege guard.

```text
Artifact: artifacts/ventio-windows-acceptance-0.1.18-wave1fix14-20261109/installers/unified/Ventio-Setup-0.1.18.exe
Size: 104,200,157 bytes
SHA-256: 02e832639a2dd86757b5b91f2f644014304d8097f92e8a4ccd1ea1cc6ce59c3a
Checksum manifest: exact match
Authenticode: NotSigned
Installer compile: Successful (Inno Setup 6.7.3)
```

The artifact was copied to the Host temporary directory and independently rehashed there; the Host copy matched `02e832639a2dd86757b5b91f2f644014304d8097f92e8a4ccd1ea1cc6ce59c3a`. It was subsequently installed in place and reproduced the service-order defect documented below. The RDP session showed the Windows lock screen; no UI action was taken there.

## Targeted Stage 9 review of this checkpoint

- `HostPackageTransportException.code` is produced by the existing transport parser only after an uppercase code-format check (`[A-Z0-9_]{1,80}`); the correction forwards that code and does not persist response bodies, headers, or credentials.
- Host identity binding failures keep their existing specific code path; unexpected exceptions still map to the generic authentication failure code.
- The regression uses a synthetic `HOST_CREDENTIAL_EXPIRED` response code and verifies propagation through the existing-profile path. It does not access the test Host credential.
- `git diff --check` passed. Git emitted existing line-ending normalization warnings only.
- The 0.1.18 acceptance candidate compiled and passed the build-time path, Host privilege, and prerequisite checks. Its first physical run exposed the service-order defect documented below; the corrected Wave1fix15 candidate has since passed a Host in-place installation. Both artifacts are internal and unsigned.

This is a targeted review of the new diagnostic change, not the final Stage 9 release audit. Stages 3, 8, and 10 have unresolved physical installed criteria, so Stage 9 and formal Wave 1 closure remain open.

## In-place Host installer run and ordering defect

The checksum-matched Wave1fix14 installer was run on Host with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` and an Inno log. Its log shows file replacement and database-upgrade execution reached the LAN listener step, then reported:

```text
Installation process succeeded.
Error code: HOST_LAN_HOST_SERVICE_MUST_BE_STOPPED.
```

Source and observed state identify the exact ordering defect. The Recovery Authority database upgrade starts `VentioHost` to process its one-time upgrade request and leaves it running on success. The installer then called `enable-host-lan-listener.ps1 -RestartServices`, whose validated precondition correctly requires `VentioHost` to be stopped. The installer omitted a stop between these operations. The LAN helper rolled back its attempted configuration, restarted services, and loopback `/healthz` returned HTTP 200. Both Ventio services remained Running/Automatic. The installer had not reset the database; its own failure text confirms that explicitly.

The locked RDP session left the installer’s final message box in Session 0. After preserving the log, the blocked installer processes were terminated. That prevented Inno’s `DeinitializeSetup` cleanup. A follow-up attempt to invoke the bundled service-recovery script directly was refused by Host PowerShell execution policy (`running scripts is disabled`); no execution-policy setting was changed. The protected recovery-policy record remains available for the next supported installer cleanup. The authorized owner was asked to unlock the Host RDP session; no interaction with the lock screen was attempted.

Correction: after successful database upgrade and before LAN configuration, `ventio.iss` now invokes the existing `stop-host-services.ps1 -ResumePostgresOnly -KeepHostRecoveryPolicySuppressed` operation. The helper leaves PostgreSQL available, stops Host, and retains the recovery-policy journal until LAN readiness succeeds. The installer path-contract regression now asserts this precise order. `test-unified-installer-path-contract.ps1` passed with the new assertion, and Wave1fix15 subsequently passed the physical in-place upgrade.

## Previous SSH outage

The pre-existing reboot timeline remains the verified explanation: System event 1074 records the controlled Host restart at 02:57:12; OpenSSH terminated during shutdown and restored its listener at 02:57:53 after boot at 02:57:40. The saved event sample showed no failed public-key authentication. Current SSH with the same key succeeds. See [the Host upgrade root-cause report](host-upgrade-root-cause-2026-11-09.md) for the event chronology and retained logs.

## Acceptance disposition

- Stage 10: **OPEN**. Current service identity/start mode and pinned HTTPS liveness are verified; the installed Host authentication/readiness and full install, repair, upgrade-preservation, retention, failure, and offline-integration matrix remain incomplete.
- Stage 3: **OPEN — FAIL reproduced**. The installed setup retry reaches readiness but cannot verify the existing administrator session. Installed interruption/resume, first-admin operational verification, retry/idempotency, failure export, and clean-install/reboot lifecycle are not accepted.
- Stage 8: **OPEN**. No enrollment-through-receipt physical Host–Client synchronization sequence was run in this checkpoint.
- Stage 9: **OPEN**. Earlier mandatory gates remain incomplete.
- Accepted Wave 1 progress: **60%**, unchanged.

## No changes to accepted scope

Stages 0, 1, 2, 4, 5, 6, and 7 remain accepted. No prior accepted-stage test was repeated. The targeted setup regression covers only the newly changed exception mapping.

## Wave1fix15 physical Host in-place upgrade

Wave1fix15 reused the current Windows Release app and verified Host payload; only the changed installer source was recompiled. Artifact: `artifacts/ventio-windows-acceptance-0.1.18-wave1fix15-20261109/installers/unified/Ventio-Setup-0.1.18.exe`, 104,200,244 bytes, SHA-256 `8e921367a6a7139a232fdf0a9f5fd3d1d61703bbf53d25c3ca705991d446b284`, Authenticode `NotSigned`. The checksum manifest and Host copy matched. The physical Host installer exited 0, required no reboot, and its log completed `Deinitializing Setup` / `Log closed`.

After installation, `VentioHost` and `VentioPostgres` were Running/Automatic. The LAN listener was enabled at `0.0.0.0:8443`; loopback `/healthz` returned HTTP 200; Development’s pinned LAN HTTPS returned HTTP 200, TLS verification 0, and `{"apiVersion":1,"status":"alive"}`. The listener fingerprint remained stable. SCM failure actions were restored to Restart at 5, 30, and 60 seconds with non-crash actions enabled; the protected recovery-policy journal was absent. This verifies the in-place installed upgrade sequence and recovery-policy cleanup. It does not prove Host business-record preservation or authenticated application readiness; those assertions remain open.

The installed Host Setup transport-code correction is now deployed. A new UI retry, Host Overview, exact safe authentication response, Stage 3 lifecycle, and Stage 8 physical sync remain pending the unlocked RDP desktop. Formal Wave 1 acceptance remains 60%; Stages 10, 3, 8, and 9 remain open.
