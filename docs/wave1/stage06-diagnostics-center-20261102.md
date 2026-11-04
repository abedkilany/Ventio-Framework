# Stage 6 — Diagnostics Center Acceptance Evidence

**Status:** IN PROGRESS — 0 / 10 points accepted<br>
**Weight:** 10%<br>
**Formal Wave 1 acceptance:** 50 / 100<br>
**Branch:** `codex/extension-platform`

Stage 6 receives no partial credit. The evidence below accepts all currently demonstrated requirements except persistence of an installed Host diagnostic event across a Windows reboot after that event was created. The owner explicitly confirmed that the previous reboot preceded creation of the reported Host pairing event.

## Existing automated evidence

The isolated Windows PostgreSQL/Host diagnostics run `20261102175242706-1` passed **11/11 Host/process assertions** and **1/1 native Windows Flutter integration test**. It injected a Host startup authentication failure against disposable PostgreSQL, initialized a missing protected diagnostics file, persisted a correlated Host event across two independent Host process generations, and rejected retrieval without the exact-scope diagnostics grant or outside the authorized branch. Public responses omitted the protected failure type and test credentials. The Flutter integration rendered the protected Host event with a device-local SQLite event and exported both with safe source labels and no protected values, credentials, or local filesystem path.

Previously recorded checks remain accepted evidence and were not rerun:

- `flutter test test/host_diagnostics_test.dart test/local_diagnostics_test.dart` — **16/16 passed** before the current refresh regression was added.
- `dart run test/api_tests.dart` — **70/70 passed**, including scoped authorization, stable errors, correlation, and safe Host diagnostic retrieval.
- `dart run test/private_files_windows.dart` — missing and ACL-inaccessible protected diagnostic files failed safely without exposing the protected path or test value; temporary ACL changes were restored.
- Diagnostics hardening tests cover pre-API Host Setup failure reporting, local correlation, safe context separation, sanitized export, schema upgrade, and safe fallback when diagnostic storage is unavailable. See [`host-setup-diagnostics-hardening-20261101.md`](host-setup-diagnostics-hardening-20261101.md).

## Owner-provided installed Windows evidence

The owner verified the following on the installed Windows Host; no repeated service tests were performed for this report:

- `VentioHost` and `VentioPostgres` use the expected service identities. All four Host readiness components were READY after a Windows reboot.
- Stopping `VentioHost` generated a device-local `HOST_UNREACHABLE` event. It survived Flutter closure/restart with its correlation ID and remained available for sanitized export after Host recovery.
- Submitting an invalid Client pairing code over HTTPS generated a protected Host event with `source=host`, code `PAIRING_INVALID_OR_EXPIRED`, and correlation ID `cor_132a87155648e6f9a83eefefaa0a9318`.
- After an actual `VentioHost` service restart, a fresh readiness check returned READY and that same Host event remained available. This accepts installed service-restart persistence under the service lifecycle.
- The earlier Windows reboot verification occurred before creation of this specific Host pairing event. It proves service startup and readiness after reboot, but does **not** prove that this Host diagnostic event persisted across a subsequent Windows reboot.

## Pre-API Host Setup failure review

The recorded real setup attempt produced and exported a safe device-side `HOST_SETUP_PROVISIONING_FAILED` event with correlation ID `cor_206a9a891024560b031a3f437e30e1d8`. A later retry produced a distinct correlation ID, `cor_25f49980d8c563052b40101f164856e0`; its protected installer record identified `DATABASE_INITIALIZATION` and `HOST_DATABASE_MIGRATION_LEDGER_INVALID`. The two attempts are separate events and are not merged in this record.

Together, the real pre-API sanitized export and the existing failure-screen tests satisfy the Stage 6 requirement to report and export a setup failure before Host API readiness. The original export intentionally contained only a generic safe code and component; the correlated protected installer record supplied the exact migration-ledger cause without exposing it through the public event. The defect itself was fixed by deriving the migration ledger expectation from packaged migrations; no reinstall, database reset, or deliberate failure injection was performed for this acceptance review. Full defect evidence is in [`host-setup-provisioning-defect-closure-20261104.md`](host-setup-provisioning-defect-closure-20261104.md).

## Refresh / reconnection investigation

Source review found no cached Host diagnostics response or retained `HttpClient`: each Host management request creates and closes its own certificate-validating HTTP client. `Refresh diagnostics` reloads the device event store and then fetches Host events; `Refresh Host diagnostics` fetches only the scoped Host event list; `Run Host readiness check` calls the separate `host.status.read` readiness route and does not reload event history.

The earlier manual-refresh incident has no retained failure code or request correlation for the unsuccessful refresh, so its exact historical cause cannot be proven. The current implementation reproduced no stuck-refresh state. The behavior was consistent with a refresh request made while the service was still starting, or with using the readiness action when the intent was to refresh the event list; these remain hypotheses, not findings. UI descriptions now state the three actions' distinct scope.

A new one-session regression simulates a Host disconnection and recovery without disposing the Flutter page. It verifies that `Refresh diagnostics` reloads local and Host feeds, `Refresh Host diagnostics` reloads only the Host feed, `Run Host readiness check` sends only the readiness request, and the local event remains available throughout. No polling or automatic retry was added.

Current verification:

- `flutter test test/host_diagnostics_test.dart test/local_diagnostics_test.dart test/host_readiness_test.dart` — **25/25 passed**, including the new same-session recovery regression.
- `flutter analyze lib/src/diagnostics_center_page.dart test/host_diagnostics_test.dart` — no issues.
- `flutter build windows --release` — passed after the UI text and test changes on source commit `c1cc23f3a3d5d16e4abdd928a25d5db28bb81190`; the 0.1.7 unified development installer was also built from that committed source. Neither build closes the outstanding post-event Windows reboot persistence check.
- Existing Host API, protected-file, authorization, persistence, and sanitized-export evidence above was reused, not rerun.

## Requirement-by-requirement acceptance matrix

| Requirement | Result | Evidence / boundary |
|---|---|---|
| Device-local diagnostic events and persistence across Flutter restart | PASS | Owner verified `HOST_UNREACHABLE` with the same correlation ID; local SQLite and export tests passed. |
| Protected Host event categories, correlation, retrieval, and redaction | PASS | Existing injected Host failure/process tests and 70/70 API tests; owner verified a real source=host pairing event and correlation. |
| Authorization by exact Host diagnostics permission and scope | PASS | Existing Host API tests deny missing permission and out-of-scope requests. |
| Sanitized local, Host, and pre-API setup exports | PASS | Existing export/redaction tests and owner-provided installed setup and local-event exports. |
| Safe behavior with missing or inaccessible protected logs | PASS | Existing Windows protected-file test. |
| Real failure injection | PASS | Disposable PostgreSQL Host startup failure plus owner-observed pairing rejection and setup failure. |
| Installed Host event persistence across SCM service restart | PASS | Owner verified the same Host pairing event remains after actual `VentioHost` restart and a fresh READY check. |
| Same-session diagnostics refresh after Host disconnection/recovery | PASS | Clarified action scopes and added a Flutter widget regression; fresh retrieval succeeds without restarting the page. No refresh logic defect reproduced. The historical incident's exact request cause remains unidentifiable because no safe error reference was retained. |
| Protected Host event persists across Windows reboot after event creation | NOT VERIFIED | The owner rebooted before this Host event was created. No post-event reboot evidence is available, and this workstation was not rebooted. |
| Useful sanitized setup failure reporting before Host API readiness | PASS | Real setup failure and sanitized export, correlated protected retry record, and existing Flutter setup diagnostic/export/storage-failure tests. The two attempt correlations remain distinct. |

## Remaining acceptance gate

Stage 6 remains **IN PROGRESS — 0 / 10 points accepted**. The only mandatory Stage 6 assertion not verified is that an installed protected Host diagnostic event created before shutdown is still retrievable after Windows reboots and the Host service becomes READY again.

Least-disruptive verification: on the already-working Host, retain the existing pairing event; perform one planned Windows reboot when the owner can tolerate the downtime; after services return, confirm all four readiness components, refresh Host diagnostics, and confirm the same event code, `source=host`, and correlation ID `cor_132a87155648e6f9a83eefefaa0a9318`. Export the sanitized report or capture the Diagnostics Center result. Do not reinstall, stop PostgreSQL separately, clear logs, or alter Host data. Until this assertion is supplied, formal Wave 1 acceptance remains **50 / 100** and Stage 6 receives no points.
