# Ventio First Prototype Delivery

This guide covers the first usable Windows and Android prototype. It describes the current extension platform; it does not provide a prebuilt ERP module.

## Local delivery files

On the development workspace, freshly built local artifacts are placed in `deliverables/Ventio-First-Prototype-20261025/`:

- `Ventio-Prototype-Windows-x64.zip`: the complete Flutter Windows Release directory. Extract the entire archive, then run `ventio_native_client.exe` from the extracted directory. Keep `data/`, `flutter_windows.dll`, `sqlite3.dll`, and the secure-storage plugin DLL beside the executable.
- `Ventio-Prototype-Android.apk`: the Android Release APK. Install with `adb install -r Ventio-Prototype-Android.apk`, then launch package `com.ventio.ventio_native_client`. The APK is test-signed with Flutter's local debug key; it is not a store/distribution-signed package.
- `SHA256SUMS.txt`: SHA-256 digests for both packages.

These generated binaries are local delivery artifacts and are not committed to Git. Recreate them from the repository root on Windows with:

```powershell
Set-Location packages/ventio_native_client
flutter pub get
flutter build windows --release --no-pub
flutter build apk --release
```

The Windows package is created from `build/windows/x64/runner/Release/`. The Android APK is created at `build/app/outputs/flutter-apk/app-release.apk`.

## First run

The Builder works locally without a Host. Open **Extension Builder**, create a new extension, add a DocType and fields, preview its generated list/form/detail pages, activate it, then create and edit records. Create a second extension with a different DocType to verify the Builder is metadata-driven. Local extension definitions and records live in SQLite and remain device-local until separately submitted and accepted by a Host.

To connect to a Host, use **Connect to Host**, enter its origin and a provisioned credential, choose the exact company/branch scope offered by the authenticated session, and verify the connection. Use HTTPS for a Host on another device. The app uses the device's normal TLS trust roots; the test-only certificate pinning used by integration tests is not a configurable end-user feature. Do not expose the development Host or use test credentials on a production network.

Host package approval is an operator action. The app can submit a package candidate and browse/install the approved immutable release, but a client cannot approve its own package. Host deployment requires PostgreSQL, protected recovery-authority provisioning and restricted credentials; follow [Host Engine operations](HOST_ENGINE_V0_1_OPERATIONS.md) before starting a persistent Host.

When offline, local edits and commands remain provisional in SQLite. On reconnect, the client submits the same durable command IDs. Only Host receipts mark work accepted; revision conflicts keep both the local draft and the fetched Host snapshot available for review. A local preview or fixture response is not Host acceptance.

## Reproducible verification

On the Windows development setup with Docker Desktop, the repository Dart dependencies, Flutter, and an API 37 x86_64 Android emulator connected through `adb`, run:

```powershell
pwsh -File scripts/test-extension-package-windows.ps1 -HostProcessOnly -AndroidDeviceIntegration
```

The runner creates and removes a disposable PostgreSQL container, starts the production Windows Host process with test-only credentials and a temporary protected authority witness, verifies HTTP/TLS behavior, and runs the Android integration against the Windows Host network-interface address. The Android flow uses two independent authenticated logical clients, local stores and command queues on one emulator. It verifies offline queue persistence/retry, accepted Host records, stale-revision rejection, Host snapshot refresh, a reviewed merge at Host revision 3, and queue/record/schema persistence after SQLite close/reopen. This is not evidence from two physical devices or a separate LAN client.

The Builder's native Windows and Android integration tests create and use two different extensions through the app interface, preview generated UI, exercise validation and lifecycle/version updates, and verify data after restart. The Windows Release process and Android Release APK were also smoke-tested locally; the APK was installed and launched on the API 37 emulator.

See [implementation status](IMPLEMENTATION_STATUS.md) for the complete evidence matrix and current boundaries.

## Verified boundaries and production work

- Local SQLite is a device cache/workspace, not a security boundary. A device offline during a permission revocation cannot learn the change until it reconnects.
- A Windows Host with PostgreSQL and HTTPS was tested on the development machine, including access from its Android emulator. A separate Windows LAN Host/client deployment has not been demonstrated.
- Android physical-device behavior, production APK signing, Windows installer/signing, service installation, certificate provisioning/rotation, remote enrollment and credential rotation are not included in this prototype delivery.
- Schema upgrades are deliberately bounded to supported non-destructive metadata operations. Type conversion, field deletion, constraint narrowing, resumable migrations and automatic upcasting of pending commands are not implemented.
- Hosted CI has not evaluated the latest source commits. The local Windows and emulator checks above are separate evidence; see the implementation status for CI runner details.

This is a testable prototype, not a production-ready deployment.
