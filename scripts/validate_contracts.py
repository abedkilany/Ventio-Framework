#!/usr/bin/env python3
"""Validate V1.2 draft contracts, example catalogs and English-only source policy.

Development-only structural checks; not a live translation engine, extension
security validator, Host runtime, sync harness or financial transaction test.
"""
import json
import re
import subprocess
import unicodedata
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
PAIRS = {
    'module_manifest': 'maintenance_manifest',
    'doctype': 'maintenance_doctype',
    'capability': 'maintenance_capability',
    'command_envelope': 'create_maintenance_command',
    'command_receipt': 'accepted_receipt',
    'language_pack': 'pseudo_language_pack',
}


def load_json(path: Path):
    with path.open(encoding='utf-8') as stream:
        return json.load(stream)


def validate_numeric_bounds(doctype):
    for field in doctype['fields']:
        minimum = field.get('minValue')
        maximum = field.get('maxValue')
        if minimum is None and maximum is None:
            continue
        if field['type'] not in {'integer', 'decimal'}:
            raise ValueError(f"{field['name']}: numeric bounds require a numeric field")
        if field['type'] == 'integer' and any(
            type(bound) is not int for bound in (minimum, maximum) if bound is not None
        ):
            raise ValueError(f"{field['name']}: integer bounds must be whole numbers")
        if minimum is not None and maximum is not None and minimum > maximum:
            raise ValueError(f"{field['name']}: minimum exceeds maximum")


def validate_length_bounds(doctype):
    for field in doctype['fields']:
        minimum = field.get('minLength')
        maximum = field.get('maxLength')
        if minimum is not None and field['type'] != 'text':
            raise ValueError(f"{field['name']}: minLength requires a text field")
        if minimum is not None and maximum is not None and minimum > maximum:
            raise ValueError(f"{field['name']}: minimum length exceeds maximum length")


def validate_schema_pair(schema_name: str, example_name: str):
    schema = load_json(ROOT / 'contracts' / f'{schema_name}.schema.json')
    Draft202012Validator.check_schema(schema)
    payload = load_json(ROOT / 'examples' / f'{example_name}.json')
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = list(validator.iter_errors(payload))
    if errors:
        formatted = '; '.join(f'{list(err.absolute_path)}: {err.message}' for err in errors)
        raise ValueError(f'{example_name}: {formatted}')
    if schema_name == 'doctype':
        validate_numeric_bounds(payload)
        validate_length_bounds(payload)
    return payload


def english_only_label(value: str) -> bool:
    """English starter catalogs contain ASCII letters only (punctuation may vary)."""
    return isinstance(value, str) and bool(value.strip()) and not any(
        ord(char) > 127 and unicodedata.category(char).startswith('L')
        for char in value
    )


def validate_english_catalog(catalog):
    assert catalog and isinstance(catalog, dict), 'English catalog is empty or invalid'
    for key, message in catalog.items():
        assert re.fullmatch(r'[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2,}', key), f'invalid message key: {key}'
        assert english_only_label(message), f'non-English or empty default English message: {key}'


def assert_key_with_fallback(key, english, catalog):
    assert english_only_label(english), f'English fallback is missing or non-English: {key}'
    assert key in catalog, f'missing English catalog key: {key}'
    assert catalog[key] == english, f'English fallback differs from catalog: {key}'


def validate_localization(manifest, doctype, catalog):
    validate_english_catalog(catalog)
    assert_key_with_fallback(manifest['displayNameKey'], manifest['displayName'], catalog)
    if 'description' in manifest:
        assert_key_with_fallback(manifest['descriptionKey'], manifest['description'], catalog)
    assert_key_with_fallback(doctype['labelKey'], doctype['label'], catalog)
    if 'description' in doctype:
        assert_key_with_fallback(doctype['descriptionKey'], doctype['description'], catalog)
    seen = set()
    for field in doctype['fields']:
        assert_key_with_fallback(field['labelKey'], field['label'], catalog)
        assert field['labelKey'] not in seen, 'duplicate field label key'
        seen.add(field['labelKey'])
        if 'description' in field:
            assert_key_with_fallback(field['descriptionKey'], field['description'], catalog)
        if field['type'] == 'enum':
            assert set(field['enumLabels']) == set(field['enumValues']), 'enum English labels must cover all stable values exactly'
            for value, option in field['enumLabels'].items():
                assert_key_with_fallback(option['labelKey'], option['label'], catalog)
                assert option['labelKey'] not in seen, 'duplicate enum label key'
                seen.add(option['labelKey'])
    # A module can use its own extension namespace, not claim any Core key.
    assert all(key.startswith('maintenance.') for key in catalog), 'Unexpected module namespace in fixture'


def validate_language_pack(pack, manifest, english_catalog):
    assert pack['targetModuleId'] == manifest['moduleId']
    assert pack['targetModuleVersion'] == manifest['version']
    assert set(pack['messages']).issubset(english_catalog), 'Unknown translated message key'
    # Real translation content and placeholder security require additional runtime checks.


def cross_check(manifest, doctype, capability, command, receipt, *, catalog=None, pack=None):
    assert doctype['moduleId'] == manifest['moduleId']
    assert doctype['name'] in manifest['docTypes']
    assert command['clientContext']['moduleVersion'] == manifest['version']
    assert command['clientContext']['docTypeVersion'] == doctype['schemaVersion']
    assert command['type'] in {decl['type'] for decl in manifest['commands']}
    declaration = next(decl for decl in manifest['commands'] if decl['type'] == command['type'])
    assert declaration['version'] == command['typeVersion']
    assert declaration['capabilityId'] in manifest['requiredCapabilities']
    assert declaration['capabilityId'] == capability['id']
    assert declaration['permission'] in capability['requiredPermissions']
    assert receipt['commandId'] == command['commandId']
    assert manifest['offline']['enabled']
    assert set(manifest['offline']['allowedCommands']) <= {decl['type'] for decl in manifest['commands']}
    assert capability['offlineMode'] == 'provisional'
    assert doctype['kind'] == 'operational', 'Generic CRUD must not modify a sensitive DocType'
    fields = {field['name']: field for field in doctype['fields']}
    assert len(fields) == len(doctype['fields']), 'Duplicate DocType field'
    assert all(name in fields for name in doctype['ui']['listColumns'])
    assert all(name in fields for name in doctype['ui']['formFields'])
    assert all(name in fields for name in command['payload'])
    assert all(name in command['payload'] for name, field in fields.items() if field['required'])
    if catalog is not None:
        validate_localization(manifest, doctype, catalog)
        if pack is not None:
            validate_language_pack(pack, manifest, catalog)
    # Static checks never replace Host identity, permission and field-level checks.


def check_package_language():
    """Reject non-English-script text in bundled docs, source and JSON fixtures."""
    scanned = 0
    # CI checks the checked-out repository. Limit the scan to Git-tracked
    # project files so unrelated local notes do not fail a product contract.
    tracked_paths = subprocess.check_output(
        ['git', 'ls-files', '-z'], cwd=ROOT
    ).decode('utf-8').split('\0')
    for relative_path in tracked_paths:
        if not relative_path:
            continue
        path = ROOT / relative_path
        if not path.is_file() or path.suffix not in {'.md', '.json', '.py'}:
            continue
        source = path.read_text(encoding='utf-8')
        for character in source:
            if ord(character) > 127 and unicodedata.category(character).startswith('L'):
                raise AssertionError(f'Non-English letter U+{ord(character):04X} found in {path.relative_to(ROOT)}')
        scanned += 1
    return scanned


def main():
    examples = {name: validate_schema_pair(name, fixture) for name, fixture in PAIRS.items()}
    rejected = validate_schema_pair('command_receipt', 'rejected_receipt')
    assert rejected['reasonCode'] and rejected['messageKey']
    manifest = examples['module_manifest']
    catalog_path = (ROOT / 'examples' / manifest['englishCatalog']).resolve()
    assert catalog_path.is_relative_to((ROOT / 'examples').resolve()), 'English catalog path escapes module package'
    catalog = load_json(catalog_path)
    validate_english_catalog(load_json(ROOT / 'localization' / 'en.core.json'))
    cross_check(manifest, examples['doctype'], examples['capability'],
                examples['command_envelope'], examples['command_receipt'],
                catalog=catalog, pack=examples['language_pack'])
    print(f'PASS: {len(examples) + 1} schema fixtures, English catalog coverage and cross-contract checks')
    print(f'PASS: {check_package_language()} text/source/JSON files scanned for non-English letters')
    print('LIMIT: No actual Flutter, translation runtime, Host, sync, security or database execution is tested.')


if __name__ == '__main__':
    main()
