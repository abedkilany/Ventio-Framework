# Ventio Windows Client Package

This package installs the existing Ventio Flutter application for the current Windows user. It is an early Client-only distribution; it is not the unified Host/Client installer required by Wave 1.

## Build

Prerequisites:

- Windows x64
- Flutter SDK compatible with the repository's `pubspec.yaml`
- Inno Setup 6 at `%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe`

From the repository root, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/build-client-installer.ps1
```

Use `-SkipFlutterBuild` only to recompile the installer after changing the `.iss` file while reusing a previously verified Release directory.

The script builds the Flutter Windows Release directory, compiles `installer/windows/ventio-client.iss`, writes `dist/windows/Ventio-Client-Setup-<version>.exe`, and creates a SHA-256 manifest. The installer source and build script are the reproducible configuration; the unsigned binary is a local build artifact. Production distribution still needs a reviewed code-signing identity and signed release process.

## Install, upgrade, and remove

The installer runs without administrator elevation and installs under `%LOCALAPPDATA%\Programs\Ventio`. Upgrades use the same product identity and replace application files in that directory. The installer does not install PostgreSQL, a Host service, or any Windows service.

Uninstall removes files inside the application directory. It intentionally preserves SQLite data, credentials, backups, recovery material, and other user data outside the application directory. This package does not yet offer the required explicit uninstall data-retention choices; preservation is the safe default for this early client package.

To validate a built artifact in a reversible temporary directory, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/validate-client-installer.ps1 -InstallerPath dist/windows/Ventio-Client-Setup-0.1.0.exe
```

The validator performs a silent current-user install into a unique temporary directory, checks the executable and core Flutter/SQLite files, repeats the same installer as a repair/reinstall smoke test, invokes that installation's uninstaller, verifies the install directory is gone, and checks that an unrelated data-retention marker remains. This does not prove an upgrade between distinct application versions. It does not start services or modify a machine-wide installation.

## Acceptance status

The artifact provides a real Windows Client installer and reversible install/uninstall smoke test. It does **not** satisfy Stage 10 acceptance: there is no Host/Client mode selection, Host prerequisite detection, isolated PostgreSQL provisioning, Host Engine Windows service, administrator bootstrap, reboot/recovery validation, pairing flow, signed release, or full integration test. Do not select Host mode or describe this package as a completed unified installer.
