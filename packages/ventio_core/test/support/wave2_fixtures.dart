import 'dart:convert';

import 'package:ventio_core/ventio_core.dart';

// Test metadata, never an installed or implicitly trusted package.
const w2Module = 'com.example.wave2';
const w2Permission = 'extension.com_example_wave2.asset';
const w2Label = 'extension.com_example_wave2';

String w2Id(int value) =>
    '20000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';

Map<String, dynamic> w2Copy(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

Map<String, dynamic> w2BundleJson({String version = '1.0.0'}) => {
  'manifest': {
    'manifestVersion': 0,
    'moduleId': w2Module,
    'version': version,
    'minPlatformApi': '0.3.0',
    'displayName': 'Wave 2 fixture',
    'displayNameKey': '$w2Label.module',
    'englishCatalog': 'localization/en.wave2.json',
    'dependencies': <String>[],
    'docTypes': ['Asset'],
    'commands': <Object>[],
    'requiredCapabilities': <String>[],
    'offline': {'enabled': false, 'allowedCommands': <String>[]},
  },
  'docTypes': [
    {
      'name': 'Asset',
      'moduleId': w2Module,
      'schemaVersion': 1,
      'kind': 'operational',
      'label': 'Asset',
      'labelKey': '$w2Label.asset',
      'operations': ['read', 'create', 'update', 'delete'],
      'permissions': {
        'read': '$w2Permission.read',
        'create': '$w2Permission.create',
        'update': '$w2Permission.update',
        'delete': '$w2Permission.delete',
      },
      'fields': [
        {
          'name': 'name',
          'type': 'text',
          'required': true,
          'maxLength': 120,
          'label': 'Name',
          'labelKey': '$w2Label.name',
        },
        {
          'name': 'secret',
          'type': 'text',
          'required': false,
          'maxLength': 120,
          'label': 'Secret',
          'labelKey': '$w2Label.secret',
          'readPermission': '$w2Permission.secret_read',
          'writePermission': '$w2Permission.secret_write',
        },
      ],
      'ui': {
        'listColumns': ['name'],
        'formFields': ['name', 'secret'],
        'detailFields': ['name', 'secret'],
      },
    },
  ],
  'reports': [
    {
      'id': 'asset_count',
      'docType': 'Asset',
      'label': 'Asset count',
      'labelKey': '$w2Label.report.count',
      'filters': ['name'],
      'groupBy': 'name',
      'sortBy': 'count',
      'descending': false,
      'aggregates': [
        {
          'id': 'count',
          'operation': 'count',
          'label': 'Count',
          'labelKey': '$w2Label.report.count.value',
        },
      ],
    },
  ],
  'dependencyVersions': <String, String>{},
  'englishCatalog': {
    '$w2Label.module': 'Wave 2 fixture',
    '$w2Label.asset': 'Asset',
    '$w2Label.name': 'Name',
    '$w2Label.secret': 'Secret',
    '$w2Label.report.count': 'Asset count',
    '$w2Label.report.count.value': 'Count',
  },
};

Map<String, dynamic> w2Overlay({String hash = ''}) => {
  'contractVersion': 1,
  'moduleId': w2Module,
  'moduleVersion': '1.0.0',
  'docType': 'Asset',
  'baseSha256': hash.isEmpty ? 'a' * 64 : hash,
  'fields': [w2CustomField('text')],
  'properties': <String, dynamic>{},
  'ui': <String, dynamic>{},
};

Map<String, dynamic> w2CustomField(
  String type, {
  String name = 'custom_note',
}) => {
  'name': name,
  'type': type,
  'required': false,
  'label': 'Custom note',
  'labelKey': '$w2Label.custom.$name',
  'readPermission': '$w2Permission.read',
  'writePermission': '$w2Permission.update',
  if (type == 'text' || type == 'long_text') 'maxLength': 120,
  if (type == 'decimal') 'precision': 2,
};

Map<String, dynamic> w2Preferences({String theme = 'dark'}) => {
  'contractVersion': 1,
  'theme': theme,
  'density': 'compact',
  'moduleOrder': [w2Module],
};

Map<String, dynamic> w2View() => {
  'contractVersion': 1,
  'title': 'Assets',
  'moduleId': w2Module,
  'moduleVersion': '1.0.0',
  'docType': 'Asset',
  'search': '',
  'filters': <String, dynamic>{},
  'sortField': 'name',
  'descending': false,
  'columns': ['name'],
};

Map<String, dynamic> w2Policy() => {
  'contractVersion': 1,
  'enabled': true,
  'utcTime': '00:00',
  'retainDays': 7,
  'retainCopies': 2,
  'maximumAttempts': 3,
  'retryMinutes': 5,
};

Map<String, dynamic> w2Settings() => {
  'contractVersion': 1,
  'displayName': 'Test organization',
  'maintenanceNotice': '',
  'maintenanceMode': false,
  'jobsPaused': false,
  'defaultPageSize': 50,
  'maxImportRows': 500,
  'completedJobRetentionDays': 30,
};

CommandEnvelope w2Create(
  int id, {
  String tenant = 'w2-prepared',
  String company = 'company-a',
  String branch = 'branch-a',
  String actor = 'author',
  String device = 'device-author',
  String? record,
  Map<String, dynamic>? values,
}) => ExtensionRecordCommand.create(
  commandId: w2Id(id),
  tenantId: tenant,
  companyId: company,
  branchId: branch,
  recordId: record ?? 'asset-$id',
  actorId: actor,
  deviceId: device,
  moduleId: w2Module,
  moduleVersion: '1.0.0',
  docType: 'Asset',
  schemaVersion: 1,
  values: values ?? {'name': 'Asset $id'},
).envelope;
