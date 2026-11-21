import unittest

from select_ci_suites import (
    ALL_PRODUCT_SUITES,
    ALL_SUITES,
    REQUIRED_WORKFLOWS,
    SUITE_OUTPUTS,
    classify_paths,
    find_prior_green_head,
    validate_doc_patches,
)


class ChangeSelectionTests(unittest.TestCase):
    def test_documentation_reports_select_only_lightweight_validation(self):
        result = classify_paths(
            [
                "docs/wave2/WAVE_2_B_PROGRESS.md",
                "docs/wave2/WAVE_2_B_TEST_RESULTS.md",
                "docs/wave2/evidence/desktop.png",
            ]
        )
        self.assertTrue(result.docs_only)
        self.assertEqual(result.suites, {name: False for name in SUITE_OUTPUTS})

    def test_flutter_changes_select_native_and_package_checks(self):
        result = classify_paths(["packages/ventio_native_client/lib/src/main.dart"])
        self.assertTrue(result.suites["native_client"])
        self.assertTrue(result.suites["windows_acceptance_package"])
        self.assertFalse(result.suites["host_api"])
        self.assertFalse(result.docs_only)

    def test_host_changes_select_host_suites_and_packaging(self):
        result = classify_paths(["packages/ventio_host_api/lib/src/host_api.dart"])
        for name in (
            "credential_lifecycle",
            "host_api",
            "durable_commands",
            "host_engineering_gate",
            "postgres_adapter",
            "host_recovery",
            "windows_acceptance_package",
        ):
            self.assertTrue(result.suites[name], name)
        self.assertFalse(result.suites["host_security_investigation"])
        self.assertFalse(result.suites["native_client"])

    def test_database_security_changes_select_database_and_host_acceptance(self):
        result = classify_paths(["security/postgres/pairing.sql", "migrations/postgres/041_example.sql"])
        for name in (
            "credential_lifecycle",
            "host_api",
            "durable_commands",
            "host_engineering_gate",
            "postgres_adapter",
            "host_recovery",
            "windows_acceptance_package",
        ):
            self.assertTrue(result.suites[name], name)
        self.assertFalse(result.suites["native_client"])

    def test_shared_core_changes_select_every_product_component(self):
        result = classify_paths(["packages/ventio_core/lib/src/entity.dart"])
        self.assertEqual(result.suites, ALL_PRODUCT_SUITES)

    def test_ci_security_and_build_configuration_changes_select_every_suite(self):
        for path in (
            ".github/workflows/host-api.yml",
            "scripts/ci/start-postgres-test-instance.ps1",
            "packages/ventio_native_client/pubspec.lock",
            "unknown_component/source.bin",
        ):
            with self.subTest(path=path):
                self.assertEqual(classify_paths([path]).suites, ALL_SUITES)

    def test_manual_full_verification_selects_every_suite(self):
        self.assertEqual(classify_paths([], force_full=True).suites, ALL_SUITES)

    def test_empty_compare_does_not_claim_documentation_validation(self):
        result = classify_paths([])
        self.assertFalse(result.docs_only)
        self.assertFalse(any(result.suites.values()))

    def test_markdown_contract_file_is_not_treated_as_report_documentation(self):
        self.assertFalse(classify_paths(["spec/v1.2/README.md"]).docs_only)
        self.assertEqual(classify_paths(["spec/v1.2/README.md"]).suites, ALL_SUITES)

    def test_documentation_validation_checks_added_whitespace_only(self):
        valid_patch = [{"filename": "docs/report.md", "patch": "@@ -1 +1 @@\n-old\n+new text\n"}]
        invalid_patch = [{"filename": "docs/report.md", "patch": "@@ -1 +1 @@\n-old\n+new text \n"}]
        self.assertEqual(validate_doc_patches(valid_patch), [])
        self.assertTrue(validate_doc_patches(invalid_patch))

    def test_last_common_green_head_is_used_as_the_incremental_baseline(self):
        class Api:
            def pull_request_runs(self, branch):
                self.branch = branch
                return [
                    {
                        "head_sha": "previous-green",
                        "name": workflow,
                        "run_attempt": 1,
                        "updated_at": "2026-11-15T00:00:00Z",
                        "status": "completed",
                        "conclusion": "success",
                    }
                    for workflow in REQUIRED_WORKFLOWS
                ]

            def compare(self, base, head):
                self.comparison = (base, head)
                return {"status": "ahead"}

        api = Api()
        baseline = find_prior_green_head(api, "feature/wave-2-a", "current-head")
        self.assertEqual(baseline, "previous-green")
        self.assertEqual(api.branch, "feature/wave-2-a")
        self.assertEqual(api.comparison, ("previous-green", "current-head"))

    def test_failed_latest_attempt_is_not_a_safe_baseline(self):
        class Api:
            def pull_request_runs(self, branch):
                runs = [
                    {
                        "head_sha": "previous-green",
                        "name": workflow,
                        "run_attempt": 1,
                        "updated_at": "2026-11-15T00:00:00Z",
                        "status": "completed",
                        "conclusion": "success",
                    }
                    for workflow in REQUIRED_WORKFLOWS
                ]
                runs.append(
                    {
                        "head_sha": "previous-green",
                        "name": REQUIRED_WORKFLOWS[0],
                        "run_attempt": 2,
                        "updated_at": "2026-11-15T00:01:00Z",
                        "status": "completed",
                        "conclusion": "failure",
                    }
                )
                return runs

            def compare(self, base, head):
                raise AssertionError("A failed attempt must not be compared as a baseline")

        self.assertIsNone(find_prior_green_head(Api(), "feature/wave-2-a", "current-head"))


if __name__ == "__main__":
    unittest.main()
