# Windows Self-hosted CI

## Runner and security boundary

The repository's Windows CI jobs target `Ventio-Windows-Runner` with the labels
`self-hosted`, `Windows`, `X64`, and `ventio-windows`. The runner is registered
to this repository and runs as `NT AUTHORITY\NETWORK SERVICE` with its own
checkout and work directory under `C:\actions-runner`.

The runner service does not have access to the Docker Engine named pipe. Keep
that restriction in place: Docker daemon access can mount and modify arbitrary
host paths. PostgreSQL tests instead use a disposable native PostgreSQL 16
instance bound only to `127.0.0.1`. The instance data and logs live in the
current Actions run's private temporary directory and are stopped and removed
by an `always()` cleanup step. No system PostgreSQL service or production
database is used.

`install-postgres-tools.ps1` installs the pinned EDB PostgreSQL 16.15-5 binary
archive into `RUNNER_TOOL_CACHE`. It checks the EDB-published SHA-256 sidecar
against the repository-pinned digest before extracting the tools. The instance
startup script creates a run-specific data directory with a protected Windows
ACL, chooses an available loopback port, initializes a test-only cluster, and
publishes only fixture connection strings to subsequent steps. Recovery tests
create a second private cluster and use PostgreSQL's immediate-stop/crash
recovery behavior before verifying restored data and security metadata.

The `Ventio Host Engineering Gate` remains on `ubuntu-latest`. It checks Linux
UID changes, POSIX permissions and capabilities, FIFO-based process control,
and Linux-specific filesystem separation; replacing it with Windows commands
would change the properties under test. Its path filters limit this GitHub-hosted
exception to Host recovery and security changes. It is the only routine
workflow job that still uses GitHub-hosted minutes.

## Workflow triggers

The migrated Windows workflows run on relevant changes pushed to `main`, on
pull requests targeting `main`, or through `workflow_dispatch` on
`codex/windows-self-hosted-runner`. They use per-workflow concurrency groups to
cancel superseded runs and path filters to avoid unrelated work. Feature-branch
pushes do not automatically schedule all CI jobs; dispatch the relevant workflow
from the dedicated branch when validating before opening a pull request.

Every Windows job has read-only `contents` permission and an actor guard for
`abedkilany`. The repository-level Actions setting must continue to block
workflows from fork pull requests. Do not run workflows from untrusted branches
on the self-hosted runner.

## Windows jobs

- **Ventio Core Foundation**: Dart foundation tests, demos, Python package and
  contract checks.
- **Ventio Host API**: API, authorization, PostgreSQL RLS and extension-package
  integration tests.
- **Ventio Host Persistence**: PostgreSQL adapter and persistence tests.
- **Ventio Durable Commands**: durable-command and idempotency integration tests.
- **Ventio Host Crash Recovery**: crash, backup, restore, and recovery tests.
- **Ventio Credential Lifecycle**: credential rotation, revocation, audit and
  recovery-admission tests.
- **Native Flutter Client and Extension Builder**: Flutter analysis and tests,
  Windows acceptance/builds, and Android debug/release builds.
- **Windows Self-hosted Runner Smoke**: runner identity and platform dispatch
  check; it does not require Docker access.

Windows Dart jobs use the verified Dart 3.13.7 SDK provisioned by
`scripts/ci/install-dart-sdk.ps1` at
`C:\actions-runner\_work\_tool\ventio-dart-sdk-3.13.7-x64`. The script pins the
official archive's SHA-256 and gives the `NETWORK SERVICE` runner read/execute
access only, so jobs do not download the large SDK or modify it.

The native Flutter job uses the machine's pinned Flutter 3.44.1 SDK at
`C:\flutter`. Its setup step checks the exact version and adds the Windows SDK
to `PATH`; the Flutter composite action invokes Bash through WSL, which is not
installed on this Windows host. Flutter 3.44.1 satisfies the client package's
Dart SDK constraint. Its Git ownership check uses an exact `safe.directory`
entry scoped to this job. The Android Studio JDK 21 is verified from its
installed path and is compatible with the job's Gradle 9.1 wrapper. The Android
SDK packages live in a dedicated
`C:\actions-runner\_work\_tool\ventio-android-sdk-36` directory. A setup step
creates it with a protected ACL for `NETWORK SERVICE`, SYSTEM, and
Administrators. The workflow seeds only the pinned command-line tools, API 36,
Build Tools 36.0.0, platform-tools, and licenses from a read-only staging copy;
`scripts/ci/stage-android-sdk.ps1` creates the persistent staging copy at
`C:\actions-runner\_work\_tool\ventio-android-sdk-seed` with runner read-only
access. The source SDK remains in the signed-in user's profile.
`scripts/ci/verify-android-sdk.ps1` checks the package revisions and required
files and adds the SDK tools to the job PATH. It avoids the Android setup
action's Windows behavior of downloading command-line tools instead of using
the staged `sdkmanager.bat`. The user's SDK, emulator images, and other Android
data are not shared with the runner.

The architecture-contract job uses the runner's machine-wide Python 3.14 at
`C:\Python314\python.exe`; its JSON Schema dependency is installed into the
run's temporary directory. This avoids changing the runner's PowerShell
execution policy, which blocks the installer script used by
`actions/setup-python` under the `NETWORK SERVICE` identity. The runner machine
must retain that Python runtime and Visual Studio Build Tools with the Windows
desktop C++ workload and Windows SDK for Flutter desktop builds.
