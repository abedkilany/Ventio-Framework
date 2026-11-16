# Wave 2 B — GitHub Actions CI Optimization

## Scope

This change keeps PR #6 Draft and unmerged. It changes workflow selection and
status reporting only; product behavior, tests, security assertions, branch
protection, and release rules are not modified.

## Previous behavior and measured waste

The ten existing workflows used pull request `paths` filters. Those filters
were evaluated against the complete pull request diff. As a result, later
documentation-only report commits still matched product paths already present
in the pull request and repeated all ten workflows.

GitHub Actions history for six documentation-only commits on PR #6 showed:

| Head | Workflow runs | Result | Runner minutes | Elapsed minutes |
| --- | ---: | --- | ---: | ---: |
| `e6d30b218128` | 10 | 10 successful | 117.7 | 40.2 |
| `b33ccbc2e792` | 10 | 10 successful | 108.6 | 42.0 |
| `8738c92c7c9d` | 10 | 10 successful | 115.9 | 32.1 |
| `a630e1a63f94` | 10 | 10 successful | 119.8 | 41.6 |
| `a7c85ef5617b` | 10 | 10 successful | 122.3 | 40.4 |
| `cd8f80f1997e` | 10 | 10 successful | 115.6 | 33.4 |
| **Average** | **10** | **10 successful** | **116.7** | **38.3** |

The six commits changed only files under `docs/`. Each run nevertheless executed
the Windows/Android, Host/PostgreSQL, and installer checks. The six updates used
about 700 runner-minutes in total. The latest run had all eleven existing
check contexts successful.

## Workflow inventory

| Workflow | Existing required job context(s) | Previous timeout(s) | Main coverage |
| --- | --- | ---: | --- |
| Core Foundation | `dart-core`, `architecture-contracts` | 20, 15 min | Core Dart tests and architecture/contracts |
| Credential Lifecycle | `credential-lifecycle` | 45 min | Credentials, PostgreSQL, least privilege, recovery admission |
| Host API | `host-api` | 45 min | Host API, identity, RLS, authorization, pairing, extensions |
| Durable Commands | `durable-commands` | 30 min | Durable PostgreSQL command processing |
| Host Engineering Gate | `host-engineering-gate` | 45 min | Host audit and PostgreSQL security invariants |
| Host Persistence | `postgres-adapter` | 30 min | PostgreSQL adapter integration |
| Host Crash Recovery | `host-recovery` | 45 min | Host/PostgreSQL crash and restore recovery |
| Host Security Investigation | `reproduce` | 30 min | Frozen-source Defender reproduction and evidence |
| Native Flutter Client | `native-client-windows-android` | 90 min | Flutter tests, Windows integration, Windows/Android builds |
| Wave 2 B Windows Package | `windows-acceptance-package` | 90 min | Host payload and unified Windows installer build |

## Implemented selection behavior

All existing workflows now start for pull requests and `main` pushes without
workflow-level path filters. This ensures the known check contexts are always
created. A reusable selector compares the new commit range with the last PR head
for which every existing workflow completed successfully. If no complete green
baseline is available, it compares the full PR diff. A failed, cancelled,
missing, or unreadable baseline therefore causes conservative suite selection
instead of suppressing tests.

Each original required job ID remains as an always-running, lightweight gate.
The previous test body runs under a separate conditional suite job. The gate
fails if selection/documentation validation fails or if a selected suite does
not pass. For report-only changes, the selector checks added documentation
lines for trailing whitespace and NUL bytes; all existing required job IDs
then report success after that validation. Heavy test jobs are skipped only
when their inputs have not changed since a successful PR verification.

| Change | Selected suites |
| --- | --- |
| Documentation/report-only | Lightweight documentation validation and all required gates |
| Flutter client | Native Flutter/Android/Windows suite and Windows package build |
| Host/API source | Host API, credential, durable command, engineering, PostgreSQL, recovery, and Windows package suites |
| PostgreSQL migrations, adapter, or RLS/security SQL | Database/Host integration, security, recovery, and Windows package suites |
| Shared Core source | Every product component suite |
| Workflow, CI harness, contract, unknown, or broad security configuration | All ten suites |
| Manual `Ventio Full Verification` dispatch | All ten suites, regardless of changed paths |

The Host Security Investigation check reproduces a specific frozen historical
source revision. Normal product edits therefore run the applicable current Host
security and integration suites plus the package build; they do not run that
historical comparison against intentionally different Host source. The
historical investigation still runs for workflow/CI configuration changes and
in the manual full-verification workflow.

The concurrency groups remain workflow- and PR-scoped. Only superseded PR runs
are cancelled. Pushes to `main`, direct manual verification, and the manual full
verification workflow are not cancelled. The full-verification workflow has no
concurrency cancellation policy and gives each called suite a unique scope.

## Required status checks and branch protection

The eleven check-run names observed on PR #6 at `cd8f80f1997e32bed88861c6c08abb89758ea2fd`
are preserved exactly: `dart-core`, `architecture-contracts`,
`credential-lifecycle`, `host-api`, `durable-commands`,
`host-engineering-gate`, `postgres-adapter`, `host-recovery`, `reproduce`,
`native-client-windows-android`, and `windows-acceptance-package`.

No branch-protection or repository ruleset changes were made. The connected
GitHub integration returned HTTP 403 for the required-status-check protection
endpoint, so the configured rule list itself could not be read in this session.
Compatibility is preserved by retaining each existing check context and
making its gate always run; the local workflow-structure tests enforce this.

## Verification status

Local selection and workflow-structure tests cover documentation-only, Flutter,
Host, database/security, shared Core, broad CI/security changes, and forced full
verification. All workflow YAML files are parsed locally and all existing
required job IDs are checked against their new gate jobs.

Actual GitHub Actions execution after this optimization is being recorded in
the follow-up update to this report. A first run is expected to execute all
suites because the workflow and selector configuration itself changed. A
subsequent documentation-only update is used to verify that only the lightweight
selector/gate jobs execute. Final Wave 2 B acceptance must continue to use the
manual full-verification workflow and cannot rely on suites skipped by this
optimization.
