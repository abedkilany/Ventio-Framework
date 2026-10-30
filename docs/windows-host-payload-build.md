# Windows Host payload build

`scripts/windows/build-host-payload.ps1` builds the current Host Engine, the standalone `ventio_migrate.exe` migration runner, and a self-contained `VentioHostService.exe`, then stages them with the pinned PostgreSQL 16.15 distribution, ordered migrations, and PostgreSQL security SQL. The default output is ignored build output at `packages/ventio_host_api/build/windows/host-payload/`.

Run it from the repository root in PowerShell:

```powershell
scripts/windows/build-host-payload.ps1
```

The script accepts `-PostgresBinDirectory` when the verified PostgreSQL tools are stored elsewhere. The input must contain PostgreSQL 16.15. It fails closed on other versions. The output manifest records the upstream archive reference, total file count/size, and SHA-256 values for the Host, migration and service executables, required PostgreSQL executables, and every migration/security SQL file. It explicitly records that credentials and an initialized database are absent. Temporary staging is confined to the Host package build directory and stale partial staging directories are removed there on the next build.

## Verification evidence

- Windows payload build completed successfully from the current repository source.
- Payload manifest and every listed SHA-256 were re-read and verified after staging.
- The current payload contains **20,296 files** totaling **1,056,324,801 bytes** (about 1008 MiB unpacked); all 46 manifest SHA-256 entries passed re-verification.
- The Host executable is 8,663,040 bytes; `ventio_migrate.exe` is 7,747,584 bytes; self-contained Windows service executable is 67,490,904 bytes. Packaged PostgreSQL reports `postgres (PostgreSQL) 16.15`.
- The Host executable was launched without its explicit opt-in setting; it exited with code 2 and the safe message `Local Host requires explicit opt-in.` The service executable was launched outside SCM; it returned code 2 / Win32 error 1063 with a safe message. No connection string, password, or token pattern appeared.
- `dotnet run --project installer/windows/host-service.tests/HostService.Tests.csproj -c Release --no-restore` passed: safe loopback defaults, key allowlist, invalid port rejection, external-listener TLS requirement, absolute TLS paths, and broad Users ACL rejection. Test data used temporary machine-DPAPI blobs and protected temporary directories; it did not install a service or modify system service configuration.
- `scripts/windows/test-postgres-payload.ps1` passed against the packaged PostgreSQL binaries: it created a disposable UTF-8 cluster using SCRAM-SHA-256, started PostgreSQL on loopback, passed `pg_isready`, authenticated a SQL query as its temporary role, and stopped/removed the fixture. It does not register a Windows service or verify service-account ACLs, production migrations, API readiness, or reboot behavior.
- `scripts/windows/test-host-service-config-writer.ps1` passed: the writer created a LocalMachine-DPAPI-protected config in a disposable directory, applied restricted ACLs, emitted no plaintext fixture credentials, and the compiled service validator accepted the file. The service configuration unit/integration suite also passed. `register-host-service.ps1 -PlanOnly` returned `HOST_SERVICE_PLAN_BLOCKED_POSTGRES_MISSING`; service enumeration confirmed there is no `VentioPostgres` or `VentioHost` service. No system service was changed.
- `scripts/windows/provision-postgres-service.ps1` now has a read-only default plan and a separate `-Apply` path for an isolated `VentioPostgres` service using its service-specific Windows virtual account, protected ProgramData data directory, loopback listener, SCRAM authentication and automatic recovery actions. `scripts/windows/test-postgres-service-plan.ps1` passed and verified that planning changed neither service state nor product data. The provisioner's `-TestInitDbOnly` integration passed with an ephemeral PostgreSQL cluster and a current-user-only named-pipe bootstrap secret; it verified readiness and authenticated SQL, then stopped and removed the test cluster. Production `-Apply` was not run, so the SCM service, persistent ACLs, DB migrations, role bootstrap and reboot behavior remain unverified.
- The payload now includes `ventio_migrate.exe`; its disposable integration applied all 29 ordered migrations and the PostgreSQL security bootstrap from the packaged directories, then verified the 29-row migration ledger. Cluster authentication used SCRAM and a current-user-only named pipe; the disposable server was stopped and removed. No database login roles, first administrator, persistent service, Host API, or installer were provisioned by this test.
- No credentials, initialized database, service registration, or system configuration is included or changed by this build.

## Scope limit

This is a build payload, not the unified Ventio installer. Host first-run orchestration, database login-role provisioning, administrator bootstrap, integration of DPAPI-backed service configuration, Windows Service Control Manager installation, production recovery, lifecycle/upgrade handling, and Flutter setup UI are not implemented or verified by this artifact. The payload build earns no Stage 10 completion credit until the complete installer and required operational acceptance gates pass.

## Service supervisor source

`installer/windows/host-service/` contains a self-contained .NET 8 service supervisor. It is fixed to service name `VentioHost` and sibling `ventio_host.exe` and accepts no arbitrary executable command. It reads the fixed ProgramData `service-config.dpapi` path, calls LocalMachine DPAPI unprotect, validates a strict setting allowlist, rejects reparse points and allow ACEs outside the current service SID/SYSTEM/Administrators on the config file and its direct directory, then clears its environment dictionaries after starting the child. Child stdout/stderr are discarded. External bind addresses require certificate and key settings together. Build completed with 0 warnings and 0 errors; the self-contained publish passed the outside-SCM guard test (expected Win32 1063 / exit 2).

Neither PostgreSQL nor Host service has been installed or run under SCM. The PostgreSQL provisioner currently stops at source-level plus no-mutation and temporary-cluster tests; its explicit elevated `-Apply` path has not been run. The packaged migration runner and SQL bootstrap passed on a disposable process cluster, but database login-role provisioning and administrator bootstrap remain open. The DPAPI Host config writer passed temporary-file integration with the real validator, and a guarded Host registration script exists. Unified installer integration, production event logging, Host graceful shutdown, upgrade/uninstall, and SCM/reboot tests remain open. Host service stop currently terminates its child; safety with in-flight HTTP work needs integration evidence.
