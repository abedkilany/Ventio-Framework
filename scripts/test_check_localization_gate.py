import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("check_localization_gate.py")
SPEC = importlib.util.spec_from_file_location("check_localization_gate", SCRIPT)
gate = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(gate)


class LocalizationGateTests(unittest.TestCase):
    def test_catalog_requires_valid_nonempty_unique_english_fallbacks(self):
        _, errors = gate.validate_catalog("'native.ui.ok': 'Okay',\n'bad-key': '',")
        self.assertTrue(any("invalid stable key" in error for error in errors))
        self.assertTrue(any("empty English fallback" in error for error in errors))

    def test_catalog_rejects_duplicate_keys(self):
        _, errors = gate.validate_catalog("'native.ui.ok': 'Okay',\n'native.ui.ok': 'Okay',")
        self.assertTrue(any("duplicate key" in error for error in errors))

    def test_catalog_rejects_non_english_script(self):
        sample = "".join(chr(point) for point in (0x039A, 0x03B1, 0x03BB))
        _, errors = gate.validate_catalog(f"'native.ui.ok': '{sample}',")
        self.assertTrue(any("non-English text" in error for error in errors))

    def test_rejects_literal_widget_text_and_missing_catalog_key(self):
        source = "Text('New invoice'); VentioText('native.ui.missing');"
        errors = gate.scan_dart(source, "sample.dart", {"native.ui.ok"})
        self.assertTrue(any("hardcoded UI text" in error for error in errors))
        self.assertTrue(any("missing English fallback" in error for error in errors))

    def test_rejects_hardcoded_validator_message(self):
        source = "validator: (value) { if (value == null) return 'Enter a valid date.'; }"
        errors = gate.scan_dart(source, "sample.dart", {"native.ui.ok"})
        self.assertTrue(any("hardcoded UI text" in error for error in errors))

    def test_allows_dynamic_business_data_and_catalog_backed_ui(self):
        source = "Text(record.customerName); VentioText('native.ui.ok');"
        self.assertEqual(gate.scan_dart(source, "sample.dart", {"native.ui.ok"}), [])


if __name__ == "__main__":
    unittest.main()
