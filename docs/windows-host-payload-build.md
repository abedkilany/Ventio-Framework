# Windows Host payload build

`scripts/windows/build-host-payload.ps1` builds the current Host Engine and a self-contained `VentioHostService.exe`, then stages them with the pinned PostgreSQL 16.15 distribution, ordered PostgreSQL migrations, and PostgreSQL security SQL. The default output is ignored build output at `packages/ventio_host_api/build/windows/host-payload/`.

Run it from the repository root in PowerShell:

```powershell
scripts/windows/build-host-payload.ps1
```

The script accepts `-PostgresBinDirectory` when the verified PostgreSQL tools are stored elsewhere. The input must contain PostgreSQL 16.15. It fails closed on other versions. The output manifest records the upstream archive reference, total file count/size, and SHA-256 values for the Host and service executables, required PostgreSQL executables, and every migration/security SQL file. It explicitly records that credentials and an initialized database are absent. Temporary staging is confined to the Host package build directory and stale partial staging directories are removed there on the next build.

## Verification evidence

- Windows payload build completed successfully from the current repository source.
- Payload manifest and every listed SHA-256 were re-read and verified after staging.
- The current payload contains **20,295 files** totaling **1,048,577,217 bytes** (about 1000 MiB unpacked).
- The Host executable is 8,663,040 bytes; self-contained Windows service executable is 67,490,904 bytes. Packaged PostgreSQL reports `postgres (PostgreSQL) 16.15`.
- The Host executable was launched without its explicit opt-in setting; it exited with code 2 and the safe message `Local Host requires explicit opt-in.` The service executable was launched outside SCM; it returned code 2 / Win32 error 1063 with a safe message. No connection string, password, or token pattern appeared.
- `dotnet run --project installer/windows/host-service.tests/HostService.Tests.csproj -c Release --no-restore` passed: safe loopback defaults, key allowlist, invalid port rejection, external-listener TLS requirement, absolute TLS paths, and broad Users ACL rejection. Test data used temporary machine-DPAPI blobs and protected temporary directories; it did not install a service or modify system service configuration.
- `scripts/windows/test-postgres-payload.ps1` passed against the packaged PostgreSQL binaries: it created a disposable UTF-8 cluster using SCRAM-SHA-256, started PostgreSQL on loopback, passed `pg_isready`, authenticated a SQL query as its temporary role, and stopped/removed the fixture. It does not register a Windows service or verify service-account ACLs, production migrations, API readiness, or reboot behavior.
- No credentials, initialized database, service registration, or system configuration is included or changed by this build.

## Scope limit

This is a deployable build payload, not the unified Ventio installer. Host first-run provisioning, DPAPI-backed service configuration, administrator bootstrap, Windows Service Control Manager installation, recovery provisioning, lifecycle/upgrade handling, and Flutter setup UI are not implemented or verified by this artifact. The payload build earns no Stage 10 completion credit until the complete installer and required operational acceptance gates pass.

## Service supervisor source

`installer/windows/host-service/` contains a self-contained .NET 8 service supervisor. It is fixed to service name `VentioHost` and sibling `ventio_host.exe` and accepts no arbitrary executable command. It reads the fixed ProgramData `service-config.dpapi` path, calls LocalMachine DPAPI unprotect, validates a strict setting allowlist, rejects reparse points and allow ACEs outside the current service SID/SYSTEM/Administrators on the config file and its direct directory, then clears its environment dictionaries after starting the child. Child stdout/stderr are discarded. External bind addresses require certificate and key settings together. Build completed with 0 warnings and 0 errors; the self-contained publish passed the outside-SCM guard test (expected Win32 1063 / exit 2).

The service has not been installed or run under SCM. A DPAPI config writer and guarded Host registration script exist, but no PostgreSQL Windows service provisioner or unified installer integration exists. Event-log integration, production failure recovery, graceful shutdown protocol, upgrade/uninstall path, and SCM/reboot integration test are not delivered. Stop currently terminates the Host child; safety with in-flight HTTP work needs integration evidence.
