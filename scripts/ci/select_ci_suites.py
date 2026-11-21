#!/usr/bin/env python3
"""Select Ventio CI suites from the changes since the last fully green PR head.

The selector deliberately fails closed: an unknown product/configuration path or
an unavailable/incomplete comparison selects the full suite set.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


REQUIRED_WORKFLOWS = (
    "Ventio Core Foundation",
    "Ventio Credential Lifecycle",
    "Ventio Host API",
    "Ventio Durable Commands",
    "Ventio Host Engineering Gate",
    "Ventio Host Persistence",
    "Ventio Host Crash Recovery",
    "Host Security Investigation",
    "Native Flutter Client and Extension Builder",
    "Wave 2 B Windows Acceptance Package",
)

SUITE_OUTPUTS = (
    "core_foundation",
    "credential_lifecycle",
    "host_api",
    "durable_commands",
    "host_engineering_gate",
    "postgres_adapter",
    "host_recovery",
    "host_security_investigation",
    "native_client",
    "windows_acceptance_package",
)

ALL_SUITES = {name: True for name in SUITE_OUTPUTS}
NO_SUITES = {name: False for name in SUITE_OUTPUTS}
# The Defender investigation reproduces a frozen historical source revision.
# Running that forensic comparison against unrelated product edits would report
# an expected source mismatch, so normal component suites cover product edits.
ALL_PRODUCT_SUITES = dict(ALL_SUITES)
ALL_PRODUCT_SUITES["host_security_investigation"] = False

HOST_SUITES = (
    "credential_lifecycle",
    "host_api",
    "durable_commands",
    "host_engineering_gate",
    "postgres_adapter",
    "host_recovery",
    "windows_acceptance_package",
)
DATABASE_SUITES = (
    "credential_lifecycle",
    "host_api",
    "durable_commands",
    "host_engineering_gate",
    "postgres_adapter",
    "host_recovery",
    "windows_acceptance_package",
)


@dataclass(frozen=True)
class Selection:
    suites: dict[str, bool]
    docs_only: bool
    changed_paths: tuple[str, ...]


def is_documentation_path(path: str) -> bool:
    path = path.replace("\\", "/").lstrip("./")
    if path.startswith((".github/", "spec/", "security/", "migrations/")):
        return False
    if path.startswith("docs/"):
        return True
    basename = path.rsplit("/", 1)[-1].lower()
    if basename in {"readme.md", "changelog.md", "contributing.md", "code_of_conduct.md"}:
        return True
    return False


def classify_paths(paths: list[str] | tuple[str, ...], force_full: bool = False) -> Selection:
    normalized = tuple(sorted({p.replace("\\", "/").lstrip("./") for p in paths if p}))
    if force_full:
        return Selection(dict(ALL_SUITES), False, normalized)
    if normalized and all(is_documentation_path(path) for path in normalized):
        return Selection(dict(NO_SUITES), True, normalized)
    if not normalized:
        return Selection(dict(NO_SUITES), False, ())

    selected = dict(NO_SUITES)
    for path in normalized:
        lower = path.lower()
        parts = lower.split("/")

        # Workflow, test harness, package manager, compiler, and shared contract
        # changes can alter the behavior of any check; never narrow these.
        if (
            lower.startswith((".github/", "scripts/ci/", "scripts/ci_android/", "spec/"))
            or lower in {"analysis_options.yaml", "pubspec.yaml", "pubspec.lock", "pyproject.toml", "requirements.txt"}
            or lower.endswith((".lock", ".g.dart", ".freezed.dart"))
            or any(part in {".dart_tool", "build", "node_modules"} for part in parts)
        ):
            return Selection(dict(ALL_SUITES), False, normalized)

        if lower.startswith("packages/ventio_core/"):
            return Selection(dict(ALL_PRODUCT_SUITES), False, normalized)

        # Any package dependency manifest affects the package that owns it.
        if lower.startswith("packages/") and parts[-1] in {
            "pubspec.yaml",
            "pubspec.lock",
            "package.json",
            "package-lock.json",
            "gradle.lockfile",
        }:
            owner = "/".join(parts[:2]) if len(parts) > 2 else ""
            if owner == "packages/ventio_core":
                return Selection(dict(ALL_PRODUCT_SUITES), False, normalized)
            if owner in {"packages/ventio_host", "packages/ventio_host_api"}:
                for name in HOST_SUITES:
                    selected[name] = True
                continue
            if owner == "packages/ventio_native_client":
                selected["native_client"] = True
                selected["windows_acceptance_package"] = True
                continue
            if owner == "packages/ventio_postgres":
                for name in DATABASE_SUITES:
                    selected[name] = True
                continue
            return Selection(dict(ALL_SUITES), False, normalized)

        if lower.startswith(("migrations/postgres/", "security/postgres/", "packages/ventio_postgres/")):
            for name in DATABASE_SUITES:
                selected[name] = True
            continue

        if lower.startswith(("packages/ventio_host/", "packages/ventio_host_api/")):
            for name in HOST_SUITES:
                selected[name] = True
            continue

        if lower.startswith("packages/ventio_native_client/"):
            selected["native_client"] = True
            selected["windows_acceptance_package"] = True
            continue

        if lower.startswith(("installer/windows/", "scripts/windows/")):
            selected["windows_acceptance_package"] = True
            continue

        if lower in {
            "scripts/prepare_native_client_platforms.ps1",
            "scripts/check_localization_gate.py",
            "scripts/test_check_localization_gate.py",
        }:
            selected["native_client"] = True
            selected["windows_acceptance_package"] = True
            continue

        # Recognized source areas are handled above. Everything else is
        # conservative until an owner explicitly adds a narrower mapping.
        return Selection(dict(ALL_SUITES), False, normalized)

    return Selection(selected, False, normalized)


def validate_doc_patches(files: list[dict[str, Any]]) -> list[str]:
    """Lightweight `git diff --check` equivalent for added documentation lines."""
    errors: list[str] = []
    for changed in files:
        path = str(changed.get("filename", ""))
        if path.lower().endswith((".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf", ".pem", ".exe", ".zip")):
            continue
        patch = changed.get("patch")
        if not isinstance(patch, str):
            errors.append(f"{path}: GitHub did not provide a text patch for the changed document")
            continue
        for line_number, line in enumerate(patch.splitlines(), start=1):
            if not line.startswith("+") or line.startswith("+++"):
                continue
            added = line[1:]
            if added.endswith((" ", "\t")):
                errors.append(f"{path}: added line {line_number} has trailing whitespace")
            if "\x00" in added:
                errors.append(f"{path}: added line {line_number} contains a NUL character")
    return errors


class GitHubApi:
    def __init__(self, repository: str, token: str):
        self.repository = repository
        self.token = token
        self.base = f"https://api.github.com/repos/{repository}"

    def get(self, url: str) -> dict[str, Any]:
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "Ventio-CI-change-selector",
            },
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read().decode("utf-8"))

    def compare(self, base_sha: str, head_sha: str) -> dict[str, Any]:
        base = urllib.parse.quote(base_sha, safe="")
        head = urllib.parse.quote(head_sha, safe="")
        return self.get(f"{self.base}/compare/{base}...{head}")

    def pull_request_runs(self, branch: str) -> list[dict[str, Any]]:
        runs: list[dict[str, Any]] = []
        # Recent PR history fits in one page for ordinary updates. If it does
        # not contain a complete baseline, the caller safely falls back to the
        # full PR diff rather than fetching an unbounded Actions history.
        for page in range(1, 2):
            query = urllib.parse.urlencode(
                {"event": "pull_request", "branch": branch, "per_page": 100, "page": page}
            )
            result = self.get(f"{self.base}/actions/runs?{query}")
            batch = result.get("workflow_runs", [])
            runs.extend(batch)
            if len(batch) < 100 or len(runs) >= result.get("total_count", 0):
                break
        return runs


def find_prior_green_head(api: GitHubApi, branch: str, current_sha: str) -> str | None:
    latest_by_sha_workflow: dict[str, dict[str, dict[str, Any]]] = {}
    for run in api.pull_request_runs(branch):
        sha = run.get("head_sha")
        name = run.get("name")
        if not sha or sha == current_sha or name not in REQUIRED_WORKFLOWS:
            continue
        prior = latest_by_sha_workflow.setdefault(sha, {}).get(name)
        key = (int(run.get("run_attempt", 1)), str(run.get("updated_at", "")))
        prior_key = (
            int(prior.get("run_attempt", 1)), str(prior.get("updated_at", ""))
        ) if prior else (-1, "")
        if key > prior_key:
            latest_by_sha_workflow[sha][name] = run

    candidates = []
    for sha, workflow_runs in latest_by_sha_workflow.items():
        if set(workflow_runs) != set(REQUIRED_WORKFLOWS):
            continue
        if all(
            run.get("status") == "completed" and run.get("conclusion") == "success"
            for run in workflow_runs.values()
        ):
            updated = max(str(run.get("updated_at", "")) for run in workflow_runs.values())
            candidates.append((updated, sha))

    for _, sha in sorted(candidates, reverse=True):
        try:
            comparison = api.compare(sha, current_sha)
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError):
            continue
        if comparison.get("status") == "ahead":
            return sha
    return None


def paths_for_event(api: GitHubApi, environ: dict[str, str]) -> tuple[list[str], list[dict[str, Any]]]:
    event_name = environ.get("CI_EVENT_NAME", "")
    head_sha = environ.get("CI_HEAD_SHA", "")
    if event_name == "pull_request":
        base_sha = environ.get("CI_BASE_SHA", "")
        pr_number = environ.get("CI_PR_NUMBER", "")
        branch = environ.get("CI_REF_NAME", "")
        if not (base_sha and head_sha and pr_number and branch):
            raise ValueError("Pull request comparison input is incomplete")
        baseline = None
        if environ.get("CI_EVENT_ACTION") == "synchronize":
            try:
                baseline = find_prior_green_head(api, branch, head_sha)
            except Exception as exc:
                print(
                    "Prior green-head lookup unavailable; using the full PR diff "
                    f"({type(exc).__name__}).",
                    file=sys.stderr,
                )
                baseline = None
        compare_from = baseline or base_sha
    elif event_name == "push":
        compare_from = environ.get("CI_BEFORE_SHA", "")
        if not compare_from or set(compare_from) == {"0"}:
            return ["__missing_push_before_sha__"], []
    else:
        return [], []

    comparison = api.compare(compare_from, head_sha)
    files = comparison.get("files", [])
    # GitHub's compare endpoint limits the returned file list. A truncated view
    # must never be mistaken for a narrow change set.
    if len(files) >= 300:
        return ["__change_set_exceeds_github_compare_limit__"], files
    paths = []
    for item in files:
        if item.get("filename"):
            paths.append(str(item["filename"]))
        if item.get("previous_filename"):
            paths.append(str(item["previous_filename"]))
    return paths, files


def run() -> int:
    environ = os.environ
    force_full = environ.get("CI_FORCE_FULL", "false").lower() == "true"
    event_name = environ.get("CI_EVENT_NAME", "")
    if force_full or event_name in {"workflow_dispatch", "workflow_call"}:
        selection = Selection(dict(ALL_SUITES), False, ())
        files: list[dict[str, Any]] = []
    elif event_name not in {"pull_request", "push"}:
        selection = Selection(dict(NO_SUITES), False, ())
        files = []
    else:
        repository = environ.get("GITHUB_REPOSITORY", "")
        token = environ.get("GITHUB_TOKEN", "")
        if not repository or not token:
            raise ValueError("Repository or read-only GitHub token is unavailable")
        api = GitHubApi(repository, token)
        paths, files = paths_for_event(api, dict(environ))
        selection = classify_paths(paths)
        if selection.docs_only:
            errors = validate_doc_patches(files)
            if errors:
                print("Documentation validation failed:", file=sys.stderr)
                for error in errors:
                    print(f"- {error}", file=sys.stderr)
                return 1
            print(f"Validated {len(paths)} documentation-only changed path(s).")
        elif not any(selection.suites.values()) and paths:
            print("No product suites selected for this change set.")
        else:
            print("Selected suites: " + ", ".join(name for name, run in selection.suites.items() if run))

    output_path = environ.get("GITHUB_OUTPUT")
    if not output_path:
        raise ValueError("GITHUB_OUTPUT is not set")
    lines = [f"run_{name}={'true' if selected else 'false'}" for name, selected in selection.suites.items()]
    lines.append(f"docs_only={'true' if selection.docs_only else 'false'}")
    with open(output_path, "a", encoding="utf-8") as output:
        output.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run())
    except Exception as exc:  # fail closed; aggregator jobs keep required checks visible
        print(f"CI change selection failed safely: {exc}", file=sys.stderr)
        raise SystemExit(1)
