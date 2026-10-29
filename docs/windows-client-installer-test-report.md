# Windows Client Installer Test Report

**Run date:** 2026-10-30 (Asia/Beirut)
**Environment:** Windows x64, Flutter 3.44.1, Inno Setup 6.7.3
**Package:** [`Ventio-Client-Setup-0.1.0.exe`](../dist/windows/Ventio-Client-Setup-0.1.0.exe)
**SHA-256:** `47cc471db0651a229c51a125909c4b46978a12491e2727bbbf3ceddf3b1dac59`
**Size:** 14,562,917 bytes

## Executed checks

| Check | Result | Evidence |
|---|---|---|
| Flutter Windows release build through the packaging script | PASS | `flutter build windows --release` produced `ventio_native_client.exe` and its release runtime files. |
| Inno Setup compilation | PASS | Inno Setup 6.7.3 compiled `installer/windows/ventio-client.iss` into the package above. |
| Fresh current-user install into a unique temporary directory | PASS | Validator found the executable, Flutter runtime, SQLite library, and bundled Flutter asset manifest. No elevation was requested. |
| Repeat install of the same version | PASS | Second invocation completed; installed executable and external retention marker remained. This is a repair/reinstall smoke test, not a version-to-version upgrade test. |
| Uninstall from the temporary installation directory | PASS | The uninstaller removed the temporary application directory. The external retention marker remained. |
| Test cleanup | PASS | The validator isolated installer and uninstaller temporary files in its unique test root and removed that generated directory. |
| Artifact checksum manifest | PASS | `dist/windows/SHA256SUMS.txt` matches the package hash above. |

The package was rebuilt from current Flutter source after adding the integrated synchronization page, stored-Host-receipt status, safe Host error references, Host Overview, user identity privacy masking, local Diagnostics Center, HTTPS-only Client enrollment, and Host-authorized device/pairing administration. The install, repeat-install, uninstall, and retention checks above were rerun against this rebuilt artifact. It remains Client-only; device administration is available when the signed-in Host user has the required exact-scope permission.

The first compile attempt exposed an unsupported Inno Setup directive. It was removed, then the package compiled successfully. An initial validator run also rejected a Windows path separator in its temp-directory guard; the guard was corrected. A follow-up exposed that Inno Setup's uninstaller creates a separate temporary executable outside the validator's test root. The validator now points `TEMP`/`TMP` at its unique test root while installation and removal run; a second full install/reinstall/uninstall run passed with no residue inside that root.

## Not tested / not accepted

This artifact installs only the existing Flutter Client application. It does not configure Host mode, PostgreSQL, Host Engine as a Windows service, bootstrap an administrator, enroll a paired device, or test authenticated synchronization. It is unsigned and has no version-to-version upgrade, reboot/service recovery, explicit uninstall data-retention choice, diagnostics-export, or physical-device evidence. Therefore this report does **not** pass Stage 10 or Wave 1.

## Reproduction

From the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/build-client-installer.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/validate-client-installer.ps1 -InstallerPath dist/windows/Ventio-Client-Setup-0.1.0.exe
```
