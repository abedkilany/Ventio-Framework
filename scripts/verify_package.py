#!/usr/bin/env python3
"""Static artifact checks; NOT a substitute for the Dart compiler or runtime tests."""
from __future__ import annotations
import json
import pathlib
import re
import sys
import jsonschema

ROOT = pathlib.Path(__file__).resolve().parents[1]
PKG = ROOT / 'packages' / 'ventio_core'
SPEC = ROOT / 'spec' / 'v1.2'

required = [
  PKG/'pubspec.yaml', PKG/'lib'/'ventio_core.dart',
  PKG/'lib'/'src'/'contracts.dart', PKG/'lib'/'src'/'modules.dart',
  PKG/'lib'/'src'/'metadata.dart', PKG/'lib'/'src'/'host.dart',
  PKG/'lib'/'src'/'permissions.dart', PKG/'lib'/'src'/'localization.dart',
  PKG/'lib'/'src'/'bootstrap.dart',
  PKG/'bin'/'maintenance_demo.dart', PKG/'bin'/'two_module_demo.dart',
  PKG/'lib'/'src'/'installation.dart', PKG/'test'/'all_tests.dart',
  ROOT/'fixtures'/'inspection'/'manifest.json', ROOT/'fixtures'/'inspection'/'doctype.json',
  ROOT/'fixtures'/'inspection'/'capability.json',
  ROOT/'fixtures'/'inspection'/'create_command.json',
  ROOT/'fixtures'/'inspection'/'localization'/'en.inspection.json',
  SPEC/'examples'/'maintenance_manifest.json',
  SPEC/'localization'/'en.runtime.json'
]
for path in required:
  assert path.is_file(), f'Missing file: {path.relative_to(ROOT)}'

files = [p for p in ROOT.rglob('*') if p.is_file() and p.suffix in ('.md','.dart','.json','.yaml','.py')]
for path in files:
  content = path.read_text(encoding='utf-8')
  for ch in content:
    # Excludes non-English script letters; English typography is not forbidden.
    if ('\u0600' <= ch <= '\u06ff' or '\u0750' <= ch <= '\u077f' or
        '\u0400' <= ch <= '\u04ff' or '\u4e00' <= ch <= '\u9fff' or
        '\u0590' <= ch <= '\u05ff' or '\u0900' <= ch <= '\u097f'):
      raise AssertionError(f'Non-English script in {path.relative_to(ROOT)}')

for path in ROOT.rglob('*.json'):
  json.loads(path.read_text(encoding='utf-8'))

base = json.loads((SPEC/'localization'/'en.core.json').read_text())
runtime = json.loads((SPEC/'localization'/'en.runtime.json').read_text())
module_catalog = json.loads((SPEC/'examples'/'localization'/'en.maintenance.json').read_text())
all_keys = {**base, **runtime, **module_catalog}
assert len(all_keys) == len(base) + len(runtime) + len(module_catalog), 'Duplicate catalog keys'
for code in ('SCOPE_DENIED','PERMISSION_DENIED','UNKNOWN_COMMAND', 'UPGRADE_REQUIRED',
             'DEPENDENCY_PENDING','EXPECTED_REVISION_MUST_BE_NULL','INVALID_PAYLOAD',
             'RECORD_ALREADY_EXISTS','COMMAND_ID_REUSED'):
  key = 'core.error.' + code.lower()
  assert key in all_keys, f'No English fallback for error {key}'
manifest = json.loads((SPEC/'examples'/'maintenance_manifest.json').read_text())
doc = json.loads((SPEC/'examples'/'maintenance_doctype.json').read_text())
assert manifest['englishCatalog'] == 'localization/en.maintenance.json'
assert manifest['displayNameKey'] in all_keys
assert doc['labelKey'] in all_keys
for field in doc['fields']:
  assert field['labelKey'] in all_keys
  for option in field.get('enumLabels', {}).values():
    assert option['labelKey'] in all_keys
# The new extension fixture must retain the original V1.2 wire contracts.
inspection = ROOT/'fixtures'/'inspection'
for contract, fixture in (
    ('module_manifest', 'manifest.json'),
    ('doctype', 'doctype.json'),
    ('capability', 'capability.json'),
    ('command_envelope', 'create_command.json'),
):
  schema = json.loads((SPEC/'contracts'/f'{contract}.schema.json').read_text())
  data = json.loads((inspection/fixture).read_text())
  jsonschema.validate(data, schema)

inspection_manifest = json.loads((inspection/'manifest.json').read_text())
inspection_doc = json.loads((inspection/'doctype.json').read_text())
inspection_cap = json.loads((inspection/'capability.json').read_text())
inspection_labels = json.loads((inspection/'localization'/'en.inspection.json').read_text())
assert inspection_manifest['moduleId'] == inspection_doc['moduleId']
assert inspection_doc['name'] in inspection_manifest['docTypes']
assert inspection_manifest['commands'][0]['capabilityId'] == inspection_cap['id']
assert inspection_manifest['commands'][0]['permission'] in inspection_cap['requiredPermissions']
assert not set(inspection_labels).intersection(all_keys), 'Duplicate English catalog keys across modules'
needed = {inspection_manifest['displayNameKey'], inspection_manifest['descriptionKey'],
          inspection_doc['labelKey'], inspection_doc['descriptionKey']}
for field in inspection_doc['fields']:
  needed.add(field['labelKey'])
  for option in field.get('enumLabels', {}).values():
    needed.add(option['labelKey'])
assert needed <= set(inspection_labels), f'Missing Inspection labels: {needed - set(inspection_labels)}'

source = (PKG/'lib'/'src'/'host.dart').read_text()
assert 'COMMAND_ID_REUSED' in source and 'SCOPE_DENIED' in source
assert 'Map.unmodifiable' in source and '_HostState' in source
assert 'TrustedCommandBinding' in source
assert 'decimal' in source and 'INVALID_BINDING' in source
# Ensure package imports resolve locally (besides dart:* and package self).
for dart_file in PKG.rglob('*.dart'):
  for path in re.findall(r"^import\s+'([^']+)'\s*;", dart_file.read_text(), flags=re.M):
    if path.startswith('dart:'): continue
    if path.startswith('package:ventio_core/'):
      candidate = PKG/'lib'/path.removeprefix('package:ventio_core/')
    else:
      candidate = dart_file.parent/path
    assert candidate.is_file(), f'Import does not exist: {candidate}'
print(f'PASS: {len(required)} required files, {len(files)} text files, two modules, JSON V1.2 schema and English checks')
print('LIMIT: Static validation only. Dart execution and compilation remain unverified.')
