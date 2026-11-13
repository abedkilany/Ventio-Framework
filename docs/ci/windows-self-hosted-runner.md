# Windows GitHub-hosted CI

All Windows jobs use the standard `windows-latest` GitHub-hosted runner. No job requires a registered Ventio machine, persistent runner tool cache, local Flutter checkout, or preinstalled PostgreSQL service.

## Workflows

- **Ventio Core Foundation** runs Dart foundation tests, demos, Python package checks, and contract tests.
- **Ventio Host API** runs API, authorization, PostgreSQL RLS, extension package, credential reissue, pairing, and administration integration tests.
- **Ventio Host Persistence**, **Ventio Durable Commands**, **Ventio Credential Lifecycle**, and **Ventio Host Crash Recovery** use disposable PostgreSQL 16 instances provisioned inside each job's `RUNNER_TEMP` directory.
- **Native Flutter Client and Extension Builder** installs pinned Dart/Flutter, Java 17, Android API 36, Build Tools 36.0.0, and NDK 28.2.13676358, then runs localization, client, Windows acceptance, and Android build coverage.

Dart is pinned at 3.13.7 for the Host and core jobs. Flutter 3.44.1 supplies Dart 3.12.1 for the native client. Python 3.14 is installed with `actions/setup-python`; Android and Java dependencies are provisioned explicitly in the workflow. Pub, Flutter, and Gradle caches are keyed from tracked dependency manifests or lockfiles.

The Windows PostgreSQL installer downloads the pinned EDB PostgreSQL 16.15-5 archive, verifies its published SHA-256 metadata and repository-pinned digest, and installs tools under `RUNNER_TOOL_CACHE`. Test clusters bind only to IPv4 loopback and use run-scoped directories and credentials. An `always()` cleanup step stops and removes each cluster.

Every workflow grants only `contents: read`, disables checkout credential persistence, and uses concurrency cancellation scoped to the workflow and pull request or ref. Pull-request workflows run on GitHub-hosted runners without contributor or actor exclusions. No Windows workflow uses a self-hosted runner.
