import copy
import json
import sys
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from validate_contracts import (  # noqa: E402
    cross_check,
    validate_length_bounds,
    validate_numeric_bounds,
    validate_schema_pair,
)


def read(folder, name):
    return json.loads((ROOT / folder / name).read_text(encoding='utf-8'))


class ContractDraftTests(unittest.TestCase):
    def _is_valid(self, schema, instance):
        return Draft202012Validator(schema, format_checker=FormatChecker()).is_valid(instance)

    def test_all_examples(self):
        for schema, example in {
            'module_manifest': 'maintenance_manifest',
            'doctype': 'maintenance_doctype',
            'capability': 'maintenance_capability',
            'command_envelope': 'create_maintenance_command',
            'command_receipt': 'accepted_receipt',
        }.items():
            with self.subTest(schema=schema):
                validate_schema_pair(schema, example)

    def test_refuse_executable_field_in_manifest(self):
        schema = read('contracts', 'module_manifest.schema.json')
        example = read('examples', 'maintenance_manifest.json')
        example['runDart'] = 'print(123)'
        self.assertFalse(self._is_valid(schema, example))

    def test_numeric_field_bounds_are_typed_and_ordered(self):
        schema = read('contracts', 'doctype.schema.json')
        doctype = read('examples', 'maintenance_doctype.json')
        field = doctype['fields'][0]
        field['type'] = 'integer'
        field.pop('maxLength')
        field['minValue'] = 1
        field['maxValue'] = 10
        self.assertTrue(self._is_valid(schema, doctype))
        validate_numeric_bounds(doctype)

        field['minValue'] = 1.5
        self.assertFalse(self._is_valid(schema, doctype))

        field['type'] = 'text'
        field['minValue'] = 1
        self.assertFalse(self._is_valid(schema, doctype))

        field['type'] = 'decimal'
        field['minValue'] = 11
        field['maxValue'] = 10
        self.assertTrue(self._is_valid(schema, doctype))
        with self.assertRaises(ValueError):
            validate_numeric_bounds(doctype)

    def test_text_length_bounds_are_typed_and_ordered(self):
        schema = read('contracts', 'doctype.schema.json')
        doctype = read('examples', 'maintenance_doctype.json')
        field = doctype['fields'][0]
        field['minLength'] = 2
        field['maxLength'] = 12
        self.assertTrue(self._is_valid(schema, doctype))
        validate_length_bounds(doctype)

        field['type'] = 'integer'
        self.assertFalse(self._is_valid(schema, doctype))

        field['type'] = 'text'
        field['minLength'] = 13
        with self.assertRaises(ValueError):
            validate_length_bounds(doctype)

    def test_invalid_command_id(self):
        schema = read('contracts', 'command_envelope.schema.json')
        example = read('examples', 'create_maintenance_command.json')
        example['commandId'] = 'not-a-uuid'
        self.assertFalse(self._is_valid(schema, example))

    def test_refuse_accepted_receipt_without_host_revision(self):
        schema = read('contracts', 'command_receipt.schema.json')
        example = read('examples', 'accepted_receipt.json')
        del example['hostRevision']
        self.assertFalse(self._is_valid(schema, example))

    def test_refuse_trusted_capability_not_in_manifest(self):
        objects = [read('examples', f) for f in [
            'maintenance_manifest.json', 'maintenance_doctype.json', 'maintenance_capability.json',
            'create_maintenance_command.json', 'accepted_receipt.json']]
        bad = copy.deepcopy(objects)
        bad[0]['requiredCapabilities'] = []
        with self.assertRaises(AssertionError):
            cross_check(*bad)

    def test_refuse_generic_crud_for_sensitive_doctype(self):
        objects = [read('examples', f) for f in [
            'maintenance_manifest.json', 'maintenance_doctype.json', 'maintenance_capability.json',
            'create_maintenance_command.json', 'accepted_receipt.json']]
        bad = copy.deepcopy(objects)
        bad[1]['kind'] = 'sensitive'
        with self.assertRaises(AssertionError):
            cross_check(*bad)

    def test_offline_commands_must_be_declared(self):
        objects = [read('examples', f) for f in [
            'maintenance_manifest.json', 'maintenance_doctype.json', 'maintenance_capability.json',
            'create_maintenance_command.json', 'accepted_receipt.json']]
        bad = copy.deepcopy(objects)
        bad[0]['offline']['allowedCommands'].append('unknown.delete')
        with self.assertRaises(AssertionError):
            cross_check(*bad)


if __name__ == '__main__':
    unittest.main()
