# Windows Host payload build

`scripts/windows/build-host-payload.ps1` builds the current Host Engine as a Windows executable and stages it with the pinned PostgreSQL 16.15 distribution, ordered PostgreSQL migrations, and PostgreSQL security SQL. The default output is ignored build output at `packages/ventio_host_api/build/windows/host-payload/`.

Run it from the repository root in PowerShell:

```powershell
scripts/windows/build-host-payload.ps1
```

The script accepts `-PostgresBinDirectory` when the verified PostgreSQL tools are stored elsewhere. The input must contain PostgreSQL 16.15. It fails closed on other versions. The output manifest records the upstream archive reference, total file count/size, and SHA-256 values for the Host executable, required PostgreSQL executables, and every migration/security SQL file. It explicitly records that credentials and an initialized database are absent. Temporary staging is confined to the Host package build directory and stale partial staging directories are removed there on the next build.

## Verification evidence

- Windows payload build completed successfully from the current repository source.
- Payload manifest and every listed SHA-256 were re-read and verified after staging.
- The payload contains **20,294 files** totaling **981,086,313 bytes** (about 936 MiB unpacked).
- The Host executable is 8,663,040 bytes. Packaged PostgreSQL reports `postgres (PostgreSQL) 16.15`.
- The Host executable was launched without its explicit opt-in setting; it exited with code 2 and the safe message `Local Host requires explicit opt-in.` No connection string, password, or token pattern appeared.
- No credentials, initialized database, service registration, or system configuration is included or changed by this build.

## Scope limit

This is a deployable build payload, not the unified Ventio installer. Host first-run provisioning, DPAPI-backed service configuration, administrator bootstrap, Windows Service Control Manager installation, recovery provisioning, lifecycle/upgrade handling, and Flutter setup UI are not implemented or verified by this artifact. The payload build earns no Stage 10 completion credit until the complete installer and required operational acceptance gates pass.
