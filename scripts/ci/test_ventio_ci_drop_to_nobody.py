"""Unit tests for the allowlist enforced by the root-owned CI helper."""

import importlib.util
import unittest
from pathlib import Path


HELPER_PATH = Path(__file__).with_name("ventio-ci-drop-to-nobody.py")
SPEC = importlib.util.spec_from_file_location("ventio_ci_drop_to_nobody", HELPER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not load CI privilege helper")
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


class PrivilegeDropRequestTests(unittest.TestCase):
    def test_allows_only_uid_assertion(self):
        program, arguments, environment = HELPER.validated_request(
            {"command": ["id", "-u"], "environment": {"PATH": "/usr/bin:/bin"}}
        )
        self.assertEqual(program, "/usr/bin/id")
        self.assertEqual(arguments, ["/usr/bin/id", "-u"])
        self.assertEqual(environment, {"PATH": "/usr/bin:/bin"})

    def test_rejects_unapproved_program(self):
        with self.assertRaises(SystemExit):
            HELPER.validated_request(
                {"command": ["/bin/sh"], "environment": {"PATH": "/usr/bin:/bin"}}
            )

    def test_rejects_extra_arguments_to_uid_probe(self):
        with self.assertRaises(SystemExit):
            HELPER.validated_request(
                {
                    "command": ["id", "-u", "--help"],
                    "environment": {"PATH": "/usr/bin:/bin"},
                }
            )

    def test_rejects_invalid_python_invocation_shape(self):
        with self.assertRaises(SystemExit):
            HELPER.validated_request(
                {
                    "command": ["python3", "script.py"],
                    "environment": {"PATH": "/usr/bin:/bin"},
                }
            )

    def test_rejects_non_string_environment_values(self):
        with self.assertRaises(SystemExit):
            HELPER.validated_request(
                {"command": ["id", "-u"], "environment": {"PATH": None}}
            )


if __name__ == "__main__":
    unittest.main()
