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

The first valid configuration run completed on
`e756dcbb3cb58d8feca7e022e337f13ed398d5a5`. Because this commit changed workflow
and selector configuration, all ten suites were selected. All ten workflows
and all 11 existing required check contexts succeeded. The run contained 32
jobs, used 114.1 summed runner-minutes, and completed in 32.8 wall-clock
minutes. [Host API run](https://github.com/abedkilany/Ventio-Framework/actions/runs/43906507207)
and the other nine workflow runs are attached to this exact PR head.

Two earlier workflow-configuration attempts failed before test jobs started:
the first had a duplicate YAML key in the selector, and the second passed an
empty string where GitHub required a boolean input. Both issues were corrected;
the selector/workflow unit tests and YAML duplicate-key parse then passed. No
product tests or security assertions were removed or changed.

The documentation-only path completed on
`153a76b5b2181e0e1126b8f26d15fddaf68c3dc2`, which changed one report file after
the green baseline. All ten workflow runs succeeded. Their 32 jobs comprised
ten selectors, eleven skipped heavy suite jobs, and eleven successful required
gate jobs. The run used 2.3 summed runner-minutes and 0.4 wall-clock minutes.
All eleven existing required check contexts completed successfully. The
selector log confirmed `Validated 1 documentation-only changed path(s).`

Compared with the historical documentation-only average of 116.7 runner-minutes,
this is a 98.0% reduction. The suite-configuration verification itself used
114.1 runner-minutes and selected every suite as intended. The ten
documentation-only workflow runs on the measured commit are:

| Workflow | Run |
| --- | --- |
| Core Foundation | [43912812233](https://github.com/abedkilany/Ventio-Framework/actions/runs/43912812233) |
| Credential Lifecycle | [43912812473](https://github.com/abedkilany/Ventio-Framework/actions/runs/43912812473) |
| Host API | [43912812148](https://github.com/abedkilany/Ventio-Framework/actions/runs/43912812148) |
| Durable Commands | [43912812477](https://github.com/abedkilany/Ventio-Framework/actions/runs/43912812477) |
| Host Engineering Gate | [43912812380](https://github.com/abedkilany/Ventio-Framework/actions/runs/43912812380) |
| Host Persistence | [43912812423](https://github.com/abedkilany/Ventio-Framework/actions/runs/43912812423) |
| Host Crash Recovery | [43912812470](https://github.com/abedkilany/Ventio-Framework/actions/runs/43912812470) |
| Host Security Investigation | [43912812282](https://github.com/abedkilany/Ventio-Framework/actions/runs/43912812282) |
| Native Flutter Client | [43912812050](https://github.com/abedkilany/Ventio-Framework/actions/runs/43912812050) |
| Windows Acceptance Package | [43912812255](https://github.com/abedkilany/Ventio-Framework/actions/runs/43912812255) |

The report-and-results update at
`b194bfc1d6a0f357113d117529d78c7a10628204` was also verified through the
documentation-only path: all ten workflows and 11 existing required contexts
passed, all eleven heavy suite jobs were skipped, and the run used 1.9
runner-minutes over 0.3 wall-clock minutes. This confirms subsequent report
updates stay on the lightweight path. Final Wave 2 B acceptance must continue
to use the manual full-verification workflow and cannot rely on suites skipped
by this optimization.
