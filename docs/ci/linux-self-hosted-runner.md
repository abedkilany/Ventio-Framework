# Linux GitHub-hosted Host Engineering Gate

The Host Engineering Gate runs on `ubuntu-latest` and uses the hosted PostgreSQL 16 service container. The workflow installs the repository-reviewed privilege helper into a root-owned path during each job, validates a narrowly scoped `sudoers` rule, and tests the helper allowlist before the audit. Nothing is pre-provisioned on a persistent runner.

The helper accepts only the UID assertion, a bounded filesystem-boundary check, and the compiled Host launcher. It validates the GitHub runner identity, reads the runner's primary group from sudo's authenticated environment, drops to UID 65534 before executing any request-supplied command or environment, and keeps the runner-owned read-only witness group. The workflow runs the Host audit, recovery boundary checks, and bounded performance checks without relying on a machine-local helper installation.

The workflow retains read-only repository permissions, loopback-only PostgreSQL service publication, run-scoped concurrency cancellation, and the existing audit test coverage. No Linux workflow uses a self-hosted runner.
