"""Structural tests for the V1.2 English-first localization contract."""
import copy
import json
import sys
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from validate_contracts import (  # noqa: E402
    check_package_language, cross_check, english_only_label,
    load_json, validate_english_catalog, validate_language_pack,
    validate_localization, validate_schema_pair,
)


def fixture(name):
    return load_json(ROOT / 'examples' / f'{name}.json')


def schema(name):
    return load_json(ROOT / 'contracts' / f'{name}.schema.json')


class EnglishFirstContractTests(unittest.TestCase):
    def setUp(self):
        self.manifest = fixture('maintenance_manifest')
        self.doctype = fixture('maintenance_doctype')
        self.catalog = fixture('localization/en.maintenance')
        self.pack = fixture('pseudo_language_pack')

    def test_builtin_default_catalog_and_module_english_coverage(self):
        validate_english_catalog(load_json(ROOT / 'localization' / 'en.core.json'))
        validate_localization(self.manifest, self.doctype, self.catalog)

    def test_manifest_requires_english_catalog_and_key(self):
        bad = copy.deepcopy(self.manifest)
        bad.pop('englishCatalog')
        self.assertFalse(Draft202012Validator(schema('module_manifest')).is_valid(bad))
        bad = copy.deepcopy(self.manifest)
        bad.pop('displayNameKey')
        self.assertFalse(Draft202012Validator(schema('module_manifest')).is_valid(bad))

    def test_doctype_requires_english_fallbacks_and_keys(self):
        bad = copy.deepcopy(self.doctype)
        bad['fields'][0].pop('label')
        self.assertFalse(Draft202012Validator(schema('doctype')).is_valid(bad))
        bad = copy.deepcopy(self.doctype)
        bad['fields'][0].pop('labelKey')
        self.assertFalse(Draft202012Validator(schema('doctype')).is_valid(bad))

    def test_enum_labels_cover_all_stable_values(self):
        bad = copy.deepcopy(self.doctype)
        bad['fields'][-1]['enumLabels'].pop('ready')
        with self.assertRaises(AssertionError):
            validate_localization(self.manifest, bad, self.catalog)

    def test_missing_translation_key_cannot_remove_english_fallback(self):
        assert self.doctype['fields'][0]['label'] == 'Customer Name'
        assert self.doctype['fields'][0]['labelKey'] == 'maintenance.request.customer_name'
        # Partial pseudo-pack intentionally lacks this key; English metadata remains.
        self.assertNotIn('maintenance.request.customer_name', self.pack['messages'])

    def test_missing_english_catalog_key_rejected(self):
        bad = copy.deepcopy(self.catalog)
        del bad['maintenance.request.customer_name']
        with self.assertRaises(AssertionError):
            validate_localization(self.manifest, self.doctype, bad)

    def test_catalog_english_fallback_mismatch_rejected(self):
        bad = copy.deepcopy(self.catalog)
        bad['maintenance.request.device_model'] = 'Different English Label'
        with self.assertRaises(AssertionError):
            validate_localization(self.manifest, self.doctype, bad)

    def test_non_english_default_label_rejected(self):
        self.assertFalse(english_only_label('\u0627\u0644\u062d\u0641\u0638'))
        self.assertTrue(english_only_label('Save Invoice'))
        bad = copy.deepcopy(self.catalog)
        bad['maintenance.request.status'] = '\u0627\u0644\u062d\u0627\u0644\u0629'
        with self.assertRaises(AssertionError):
            validate_english_catalog(bad)

    def test_optional_language_pack_is_structurally_valid(self):
        validate_schema_pair('language_pack', 'pseudo_language_pack')
        validate_language_pack(self.pack, self.manifest, self.catalog)

    def test_translation_cannot_register_unknown_key(self):
        bad = copy.deepcopy(self.pack)
        bad['messages']['other.module.key'] = 'Unexpected Override'
        with self.assertRaises(AssertionError):
            validate_language_pack(bad, self.manifest, self.catalog)

    def test_rejected_receipt_can_omit_public_message(self):
        payload = fixture('rejected_receipt')
        del payload['publicMessage']
        self.assertTrue(Draft202012Validator(schema('command_receipt'), format_checker=FormatChecker()).is_valid(payload))
        self.assertIn(payload['messageKey'], load_json(ROOT / 'localization' / 'en.core.json'))

    def test_user_data_remains_raw_english_stable_enums(self):
        cmd = fixture('create_maintenance_command')
        self.assertEqual(cmd['payload']['status'], 'new')
        self.assertIn('new', self.doctype['fields'][-1]['enumValues'])
        self.assertEqual(self.pack['targetModuleId'], self.manifest['moduleId'])

    def test_files_contain_no_non_english_script_letters(self):
        self.assertGreater(check_package_language(), 12)


if __name__ == '__main__':
    unittest.main()
