# Windows Ventio Installer

## Reproducible build

Prerequisites for maintainers are Flutter's Windows desktop toolchain, .NET 8 SDK and Inno Setup 6.7.3. Build from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/build-host-payload.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/build-windows-installer.ps1
```

The installer build validates the Host payload manifest, payload file count and byte count, and each critical SHA-256 before invoking Inno Setup. The Host payload includes PostgreSQL 16.15 runtime `bin`, `lib`, `share` files and license texts. It intentionally excludes PostgreSQL documentation, development headers, pgAdmin 4 and StackBuilder. This reduced the tested Host payload from 1,056,324,801 bytes to 212,081,806 bytes. Database state and credentials are never in the payload.

The resulting artifact is `dist/windows/Ventio-Setup-0.1.0.exe` for the current app version. `dist/windows/Ventio-Setup-SHA256SUMS.txt` contains its checksum. In the installer type page, **Client workstation** installs the shared Flutter application only; **Host server** installs the same app and adds the Host runtime payload. The installer uses a per-user destination and does not request elevation for either choice.

## Current verification

`scripts/windows/validate-unified-installer.ps1` installs each type into a unique temporary directory, verifies the selected file set, runs the uninstaller, and confirms an external retention marker survives:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/validate-unified-installer.ps1 -InstallerPath dist/windows/Ventio-Setup-0.1.0.exe -SetupType client
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/validate-unified-installer.ps1 -InstallerPath dist/windows/Ventio-Setup-0.1.0.exe -SetupType host
```

Both per-user install/uninstall checks passed. The reduced PostgreSQL payload also passed isolated SCRAM initialization/readiness/authentication, migrations 001–029, security bootstrap, runtime and Identity API login checks, protected DPAPI configuration validation, and the no-mutation service plan check.

## Not yet provided by this artifact

The Host selection currently stages verified Host files only. It does not yet provision the PostgreSQL Windows service, create the initial administrator, register/start `VentioHost`, configure reboot recovery, connect a first-run graphical Host wizard, or test upgrade/reboot/service lifecycle. Client/Host installation type selection therefore works, but the Host operational-install acceptance gate remains open. Do not use this artifact as a production Host installer until those workflows and their elevation boundary are implemented and tested.

Uninstallation currently removes application files in the selected install directory. No PostgreSQL data or service is created by this tested artifact; production Host data-retention choices and service-aware uninstall still need implementation.
