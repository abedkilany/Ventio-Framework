import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
REQUIRED_CONTEXTS = {
    "core-foundation.yml": ("dart-core", "architecture-contracts"),
    "credential-lifecycle.yml": ("credential-lifecycle",),
    "host-api.yml": ("host-api",),
    "host-durable-commands.yml": ("durable-commands",),
    "host-engineering-gate.yml": ("host-engineering-gate",),
    "host-persistence.yml": ("postgres-adapter",),
    "host-recovery.yml": ("host-recovery",),
    "host-security-investigation.yml": ("reproduce",),
    "native-flutter-client.yml": ("native-client-windows-android",),
    "wave2-b-windows-acceptance-package.yml": ("windows-acceptance-package",),
}
WORKFLOW_NAMES = {
    "core-foundation.yml": "Ventio Core Foundation",
    "credential-lifecycle.yml": "Ventio Credential Lifecycle",
    "host-api.yml": "Ventio Host API",
    "host-durable-commands.yml": "Ventio Durable Commands",
    "host-engineering-gate.yml": "Ventio Host Engineering Gate",
    "host-persistence.yml": "Ventio Host Persistence",
    "host-recovery.yml": "Ventio Host Crash Recovery",
    "host-security-investigation.yml": "Host Security Investigation",
    "native-flutter-client.yml": "Native Flutter Client and Extension Builder",
    "wave2-b-windows-acceptance-package.yml": "Wave 2 B Windows Acceptance Package",
}


class WorkflowOptimizationTests(unittest.TestCase):
    def test_all_existing_workflow_check_contexts_remain_as_gate_jobs(self):
        for filename, contexts in REQUIRED_CONTEXTS.items():
            text = (WORKFLOWS / filename).read_text(encoding="utf-8")
            for context in contexts:
                with self.subTest(workflow=filename, context=context):
                    self.assertRegex(text, rf"(?m)^  {re.escape(context)}:\s*$")
                    gate_condition = (
                        "${{ always() && !inputs.wave2_resume }}"
                        if filename == "native-flutter-client.yml"
                        else "always()"
                    )
                    self.assertRegex(
                        text,
                        rf"(?m)^  {re.escape(context)}:\n    needs: \[select-changes, [^\]]+\]\n    if: {re.escape(gate_condition)}$",
                    )
                    self.assertRegex(text, rf"(?m)^          SHOULD_RUN: \$\{{\{{ needs\.select-changes\.outputs\.run_[a-z_]+ \}}\}}$")

    def test_heavy_suites_are_conditioned_on_selector_outputs(self):
        for filename, contexts in REQUIRED_CONTEXTS.items():
            text = (WORKFLOWS / filename).read_text(encoding="utf-8")
            self.assertRegex(text, r"(?m)^  push:\n    branches: \[main\]$")
            self.assertRegex(text, r"(?m)^  pull_request:\n    branches: \[main\]$")
            self.assertIn("  workflow_dispatch:\n", text)
            self.assertIn("  workflow_call:\n", text)
            self.assertRegex(text, rf"(?m)^name: {re.escape(WORKFLOW_NAMES[filename])}$")
            self.assertIn(
                "ci_force_full: ${{ github.event_name == 'workflow_dispatch' || github.event_name == 'workflow_call' }}",
                text,
            )
            for context in contexts:
                suite = context + "-suite"
                self.assertRegex(text, rf"(?m)^  {re.escape(suite)}:\n    needs: select-changes\n    if: needs\.select-changes\.outputs\.run_[a-z_]+ == 'true'$")
            self.assertIn("uses: ./.github/workflows/ci-change-selector.yml", text)
            self.assertNotRegex(text, r"(?m)^    paths:\s*$")

    def test_full_verification_is_manual_and_calls_every_existing_workflow(self):
        text = (WORKFLOWS / "full-verification.yml").read_text(encoding="utf-8")
        self.assertRegex(text, r"(?ms)^on:\n  workflow_dispatch:\s*$")
        self.assertNotIn("concurrency:", text)
        for filename in REQUIRED_CONTEXTS:
            self.assertIn(f"uses: ./.github/workflows/{filename}", text)
            self.assertIn("ci_run_scope: full-${{ github.run_id }}", text)

    def test_change_selector_checkout_does_not_persist_or_duplicate_credentials(self):
        text = (WORKFLOWS / "ci-change-selector.yml").read_text(encoding="utf-8")
        self.assertEqual(text.count("persist-credentials:"), 1)
        self.assertIn("persist-credentials: false", text)

    def test_windows_acceptance_caches_flutter_pub_and_hash_pinned_postgres_archive(self):
        text = (REPO_ROOT / ".github/workflows/wave2-b-windows-acceptance-package.yml").read_text()
        self.assertIn("pub-cache: true", text)
        self.assertIn("uses: actions/cache@v4", text)
        self.assertIn("windows-postgresql-16.16-1-5c0d06f3d26a929ecb36dd931409f1e51a4181355794a259b90aae8bffc57a9f", text)
        installer = (REPO_ROOT / "scripts/ci/install-postgres-tools.ps1").read_text()
        self.assertIn("$cachedHash -eq $expectedSha256", installer)
        self.assertIn("$actualSha256 -ne $expectedSha256", installer)

if __name__ == "__main__":
    unittest.main()
