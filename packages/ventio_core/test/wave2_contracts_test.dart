// PREPARED / NOT EXECUTED. Dependency-free contract suite; no database or GUI.
import 'dart:convert';

import 'package:ventio_core/ventio_core.dart';

import 'support/wave2_cases.dart';
import 'support/wave2_fixtures.dart';

DocTypeDefinition _csvDefinition() {
  final doc =
      (w2BundleJson()['docTypes'] as List).single as Map<String, dynamic>;
  Map<String, dynamic> field(String name, String type) => {
    'name': name,
    'type': type,
    'required': true,
    'label': name,
    'labelKey': '$w2Label.${name.toLowerCase()}',
  };
  (doc['fields'] as List).addAll([
    field('due', 'date'),
    field('state', 'enum')
      ..['enumValues'] = ['open', 'closed']
      ..['enumLabels'] = {
        'open': {'label': 'Open', 'labelKey': '$w2Label.state.open'},
        'closed': {'label': 'Closed', 'labelKey': '$w2Label.state.closed'},
      },
    field('linked', 'reference')..['referenceTo'] = 'Asset',
    field('lines', 'table')
      ..['childDocType'] = {
        'name': 'AssetLine',
        'label': 'Asset line',
        'labelKey': '$w2Label.line',
        'fields': [
          field('asset', 'reference')..['referenceTo'] = 'Asset',
          field('quantity', 'decimal')
            ..['precision'] = 2
            ..['default'] = 1.25,
          field('unitPrice', 'decimal')
            ..['precision'] = 2
            ..['default'] = 2.0,
          field('lineTotal', 'decimal')
            ..['precision'] = 2
            ..['calculation'] = {
              'type': 'multiply',
              'leftField': 'quantity',
              'rightField': 'unitPrice',
            },
        ],
      },
    field('total', 'decimal')
      ..['precision'] = 2
      ..['readOnly'] = true
      ..['calculation'] = {
        'type': 'sum',
        'rowsField': 'lines',
        'valueField': 'lineTotal',
      },
    field('locked', 'text')
      ..['required'] = false
      ..['readOnly'] = true,
  ]);
  (doc['ui'] as Map)['formFields'] = [
    'name',
    'secret',
    'due',
    'state',
    'linked',
    'lines',
    'total',
    'locked',
  ];
  return DocTypeDefinition.fromJson(doc);
}

List<ImportPreviewRow> _typedCsv({
  String due = '2024-02-29',
  String state = 'open',
  String linked = 'asset-reference',
  Object? lines = const [
    {'asset': 'asset-child'},
  ],
}) => previewCsvImport(
  source: StructuredCsv.encode([
    ['id', 'Name', 'Due', 'State', 'Linked', 'Lines'],
    ['row-a', 'CSV asset', due, state, linked, lines],
  ]),
  definition: _csvDefinition(),
  mapping: {
    'Name': 'name',
    'Due': 'due',
    'State': 'state',
    'Linked': 'linked',
    'Lines': 'lines',
  },
  recordIdHeader: 'id',
  writableFields: {'name', 'due', 'state', 'linked', 'lines'},
);

Future<void> main() async {
  final cases = W2Cases();
  final base = ExtensionBundle.fromJson(w2BundleJson());

  await cases.run(
    'W2-C001',
    'A12',
    'All seven optional scalar custom types merge without mutating package bytes',
    () {
      final original = canonicalJson(base.toJson());
      for (final type in [
        'text',
        'long_text',
        'integer',
        'decimal',
        'boolean',
        'date',
        'datetime',
      ]) {
        final body = w2Overlay()..['fields'] = [w2CustomField(type)];
        final merged = MetadataCustomization.fromJson(body).merge(base);
        w2Expect(
          merged.docTypes.single.fields.last.type == type,
          'Scalar type lost',
        );
        w2Expect(
          !merged.docTypes.single.fields.last.required,
          'Custom field became required',
        );
      }
      w2Equal(
        canonicalJson(base.toJson()),
        original,
        'Immutable package changed',
      );
    },
  );
  await cases.run(
    'W2-C002',
    'A12',
    'Required, executable, reference and table custom fields are refused',
    () {
      for (final type in ['reference', 'table', 'sql', 'script']) {
        w2Contract(
          () => MetadataCustomization.fromJson(
            w2Overlay()..['fields'] = [w2CustomField(type)],
          ),
        );
      }
      final body = w2Overlay();
      (body['fields'] as List).single['required'] = true;
      w2Contract(
        () => MetadataCustomization.fromJson(body),
        code: 'INVALID_CUSTOMIZATION',
      );
    },
  );
  await cases.run(
    'W2-C003',
    'A12',
    'Twenty custom fields accepted; twenty-one and duplicate names rejected',
    () {
      final body = w2Overlay()
        ..['fields'] = [
          for (var i = 0; i < 20; i++) w2CustomField('text', name: 'custom_$i'),
        ];
      w2Expect(
        MetadataCustomization.fromJson(
              body,
            ).merge(base).docTypes.single.fields.length ==
            22,
        'Boundary rejected',
      );
      (body['fields'] as List).add(w2CustomField('text', name: 'custom_20'));
      w2Contract(
        () => MetadataCustomization.fromJson(body),
        code: 'INVALID_CUSTOMIZATION',
      );
      body['fields'] = [w2CustomField('text'), w2CustomField('text')];
      w2Contract(
        () => MetadataCustomization.fromJson(body),
        code: 'INVALID_CUSTOMIZATION',
      );
    },
  );
  await cases.run(
    'W2-C004',
    'A12',
    'ACL weakening and collisions with base fields are rejected by effective merge',
    () {
      final body = w2Overlay();
      (body['fields'] as List).single['writePermission'] = '$w2Permission.read';
      w2Contract(
        () => MetadataCustomization.fromJson(body).merge(base),
        code: 'INVALID_CUSTOMIZATION',
      );
      final source = w2BundleJson();
      final doc = (source['docTypes'] as List).single as Map<String, dynamic>;
      (doc['fields'] as List).add(w2CustomField('text'));
      (source['englishCatalog'] as Map)['$w2Label.custom.custom_note'] =
          'Custom note';
      w2Contract(
        () => MetadataCustomization.fromJson(
          w2Overlay(),
        ).merge(ExtensionBundle.fromJson(source)),
      );
    },
  );
  await cases.run(
    'W2-C005',
    'A12,K09',
    'Saved custom fields cannot be removed or structurally converted',
    () {
      final previous = MetadataCustomization.fromJson(w2Overlay());
      for (final fields in [
        <Object>[],
        [w2CustomField('integer')],
        [w2CustomField('text')..['maxLength'] = 119],
      ]) {
        w2Contract(
          () => MetadataCustomization.fromJson(
            w2Overlay()..['fields'] = fields,
          ).merge(base, previous: previous),
        );
      }
      final relabel = w2Overlay();
      (relabel['fields'] as List).single['label'] = 'Renamed note';
      w2Expect(
        MetadataCustomization.fromJson(relabel)
                .merge(base, previous: previous)
                .docTypes
                .single
                .fields
                .last
                .label ==
            'Renamed note',
        'Presentation-only change refused',
      );
    },
  );
  await cases.run(
    'W2-C006',
    'A11',
    'Presentation merge retains required fields and is deterministic',
    () {
      final body = w2Overlay()
        ..['ui'] = {
          'listColumns': ['custom_note', 'name'],
          'formFields': ['name', 'secret', 'custom_note'],
          'pageTitle': 'Custom assets',
          'pageTitleKey': '$w2Label.custom.page',
        };
      final overlay = MetadataCustomization.fromJson(body);
      w2Equal(
        overlay.merge(base).toJson(),
        overlay.merge(base).toJson(),
        'Nondeterministic merge',
      );
      final invalid = w2Copy(body)
        ..['ui'] = {
          'formFields': ['secret'],
        };
      w2Contract(() => MetadataCustomization.fromJson(invalid).merge(base));
    },
  );
  await cases.run(
    'W2-C007',
    'A11',
    'Duplicate/unknown layout fields, unsupported icons and out-of-range order fail',
    () {
      for (final ui in [
        {
          'listColumns': ['name', 'name'],
        },
        {
          'formFields': ['missing'],
        },
        {'pageIcon': 'run_script'},
        {'pageOrder': -1},
      ]) {
        w2Contract(
          () => MetadataCustomization.fromJson(
            w2Overlay()..['ui'] = ui,
          ).merge(base),
        );
      }
    },
  );
  await cases.run(
    'W2-C008',
    'A11,A12',
    'Namespace and catalog collisions cannot overwrite labels',
    () {
      final body = w2Overlay();
      (body['fields'] as List).single['labelKey'] = '$w2Label.name';
      w2Contract(
        () => MetadataCustomization.fromJson(body),
        code: 'INVALID_CUSTOMIZATION',
      );
      final source = w2BundleJson();
      (source['englishCatalog'] as Map)['$w2Label.custom.custom_note'] =
          'Another label';
      w2Contract(
        () => MetadataCustomization.fromJson(
          w2Overlay(),
        ).merge(ExtensionBundle.fromJson(source)),
        code: 'CUSTOMIZATION_LABEL_COLLISION',
      );
    },
  );
  await cases.run(
    'W2-C009',
    'K09,A12',
    'Explicit newer-release rebase preserves ACLs and custom fields',
    () {
      final old = MetadataCustomization.fromJson(w2Overlay());
      final target = ExtensionBundle.fromJson(w2BundleJson(version: '1.1.0'));
      final rebased = old.rebase(target, 'b' * 64);
      w2Equal(
        rebased.json['fields'],
        old.json['fields'],
        'Rebase changed structural fields',
      );
      w2Expect(
        rebased.moduleVersion == '1.1.0' && rebased.baseSha256 == 'b' * 64,
        'Target not pinned',
      );
      w2Expect(
        rebased
            .merge(target, previous: old)
            .docTypes
            .single
            .formFields
            .contains('custom_note'),
        'Rebased layout omitted field',
      );
      w2Contract(
        () => old.rebase(base, 'b' * 64),
        code: 'INVALID_CUSTOMIZATION_REBASE',
      );
    },
  );
  await cases.run(
    'W2-C010',
    'A12,K09',
    'Validated overlays deep-copy caller-owned JSON',
    () {
      final source = w2Overlay();
      final overlay = MetadataCustomization.fromJson(source);
      (source['fields'] as List).clear();
      w2Expect(
        (overlay.json['fields'] as List).length == 1,
        'Caller mutation changed overlay',
      );
    },
  );
  await cases.run(
    'W2-C011',
    'J01',
    'CSV handles BOM, CRLF, escaped quotes, empty and multiline cells',
    () {
      w2Equal(
        StructuredCsv.decode(
          '\uFEFFid,name\r\na,"one,""two""\r\nthree"\r\nb,""',
        ),
        [
          ['id', 'name'],
          ['a', 'one,"two"\r\nthree'],
          ['b', ''],
        ],
        'CSV semantic mismatch',
      );
    },
  );
  await cases.run(
    'W2-C012',
    'J01',
    'CSV rejects malformed quotes, NUL, duplicate and empty headers',
    () {
      for (final source in [
        '',
        'id,id\na,b',
        'id,\na,b',
        'id\n"open',
        'id\n"a"tail',
        'id\na"b',
        'id\n\u0000',
      ]) {
        w2Contract(() => StructuredCsv.decode(source), code: 'INVALID_CSV');
      }
    },
  );
  await cases.run(
    'W2-C013',
    'J01',
    'CSV exact row/column/cell limits and UTF-8 byte bound are enforced',
    () {
      w2Expect(
        StructuredCsv.decode(
              ['id', ...List.filled(500, 'a')].join('\n'),
            ).length ==
            501,
        '500 rows rejected',
      );
      w2Contract(
        () => StructuredCsv.decode(['id', ...List.filled(501, 'a')].join('\n')),
        code: 'CSV_LIMIT',
      );
      w2Expect(
        StructuredCsv.decode(
              List.generate(100, (i) => 'h$i').join(','),
            ).single.length ==
            100,
        '100 columns rejected',
      );
      w2Contract(
        () => StructuredCsv.decode(List.generate(101, (i) => 'h$i').join(',')),
        code: 'CSV_LIMIT',
      );
      w2Expect(
        StructuredCsv.decode('id\n${'x' * 65535}').last.single.length == 65535,
        'Cell limit rejected',
      );
      w2Contract(
        () => StructuredCsv.decode('id\n${'x' * 65536}'),
        code: 'CSV_LIMIT',
      );
      w2Contract(
        () => StructuredCsv.decode('é' * (StructuredCsv.maxBytes ~/ 2 + 1)),
        code: 'CSV_TOO_LARGE',
      );
    },
  );
  await cases.run(
    'W2-C014',
    'J01,J03',
    'Mixed invalid rows preserve original logical source-row numbers',
    () {
      final rows = previewCsvImport(
        source: 'id,Name\na,Valid\nb\nc,Next\na,Duplicate',
        definition: base.docTypes.single,
        mapping: {'Name': 'name'},
        recordIdHeader: 'id',
        writableFields: {'name'},
      );
      w2Equal(rows.map((r) => r.rowNumber).toList(), [
        2,
        3,
        4,
        5,
      ], 'Rows renumbered');
      w2Expect(
        rows[0].errors.contains('DUPLICATE_RECORD_ID') &&
            rows[1].errors.contains('COLUMN_COUNT_MISMATCH') &&
            rows[2].errors.isEmpty &&
            rows[3].errors.contains('DUPLICATE_RECORD_ID'),
        'Row errors lost',
      );
    },
  );
  await cases.run(
    'W2-C015',
    'J01,D08',
    'CSV cannot map record identity, duplicate targets, unknown or unwritable fields',
    () {
      for (final mapping in [
        {'id': 'name'},
        {'Name': 'secret'},
        {'Name': 'missing'},
        {'Name': 'name', 'Other': 'name'},
      ]) {
        w2Contract(
          () => previewCsvImport(
            source: 'id,Name,Other\na,Value,Other',
            definition: base.docTypes.single,
            mapping: mapping,
            recordIdHeader: 'id',
            writableFields: {'name'},
          ),
        );
      }
    },
  );
  await cases.run(
    'W2-C016',
    'J01',
    'Typed imports reject exponent/hex, non-boolean and excess decimal scale',
    () {
      final source = w2BundleJson();
      final doc = (source['docTypes'] as List).single as Map<String, dynamic>;
      doc['fields'] = [
        {
          'name': 'number',
          'type': 'integer',
          'required': false,
          'label': 'Number',
          'labelKey': '$w2Label.number',
        },
        {
          'name': 'amount',
          'type': 'decimal',
          'precision': 2,
          'required': false,
          'label': 'Amount',
          'labelKey': '$w2Label.amount',
        },
        {
          'name': 'active',
          'type': 'boolean',
          'required': false,
          'label': 'Active',
          'labelKey': '$w2Label.active',
        },
      ];
      doc['ui'] = {
        'listColumns': ['number'],
        'formFields': ['number', 'amount', 'active'],
        'detailFields': ['number', 'amount', 'active'],
      };
      final definition = DocTypeDefinition.fromJson(doc);
      List<ImportPreviewRow> preview(String cells) => previewCsvImport(
        source: 'id,N,A,B\na,$cells',
        definition: definition,
        mapping: {'N': 'number', 'A': 'amount', 'B': 'active'},
        recordIdHeader: 'id',
        writableFields: {'number', 'amount', 'active'},
      );
      w2Expect(
        preview('12,1.20,true').single.errors.isEmpty,
        'Typed valid values rejected',
      );
      for (final cells in [
        '0x10,1.20,true',
        '1e2,1.20,true',
        '12,1.201,true',
        '12,1e2,true',
        '12,1.20,TRUE',
        '12,99999999999999999,true',
      ]) {
        w2Expect(
          preview(cells).single.errors.isNotEmpty,
          'Invalid inference accepted',
        );
      }
    },
  );
  await cases.run(
    'W2-C017',
    'K08,J01',
    'Export escapes formula strings but preserves numeric negatives and JSON',
    () {
      final encoded = StructuredCsv.encode([
        [
          '=1',
          '+1',
          '@x',
          '-12',
          -12,
          '\tcell',
          {'a': 1},
          '"quoted"',
        ],
      ]);
      w2Equal(
        StructuredCsv.decode('a,b,c,d,e,f,g,h\r\n$encoded').last,
        ["'=1", "'+1", "'@x", "'-12", '-12', "'\tcell", '{"a":1}', '"quoted"'],
        'Export escape mismatch',
      );
    },
  );
  await cases.run(
    'W2-C018',
    'B09',
    'Saved-view filters, sorting and columns round-trip immutably',
    () {
      final body = w2View()..['filters'] = {'name': 'Asset'};
      final view = SavedRecordView.fromJson(body);
      (body['filters'] as Map)['name'] = 'Changed';
      w2Equal(view.json['filters'], {'name': 'Asset'}, 'View mutated');
    },
  );
  await cases.run(
    'W2-C019',
    'B09,J04',
    'Saved views reject nested filters, duplicate columns and executable properties',
    () {
      for (final body in [
        w2View()
          ..['filters'] = {
            'name': {'sql': 'select 1'},
          },
        w2View()..['columns'] = ['name', 'name'],
        w2View()..['sql'] = 'select 1',
        w2View()..['search'] = 'x' * 257,
      ]) {
        w2Contract(() => SavedRecordView.fromJson(body));
      }
    },
  );
  await cases.run(
    'W2-C020',
    'C09',
    'Preferences enforce theme, density and unique bounded module order',
    () {
      validateWave2Definition('preferences', w2Preferences());
      for (final body in [
        w2Preferences()..['theme'] = 'javascript',
        w2Preferences()..['moduleOrder'] = [w2Module, w2Module],
        w2Preferences()..['density'] = 'sql',
        w2Preferences()
          ..['moduleOrder'] = List.generate(65, (i) => 'com.example.m$i'),
      ]) {
        w2Contract(() => validateWave2Definition('preferences', body));
      }
    },
  );
  await cases.run(
    'W2-C021',
    'C12,F05',
    'Dashboard accepts twelve declarative cards and rejects thirteen or executable cards',
    () {
      Map<String, dynamic> dashboard(int count) => {
        'contractVersion': 1,
        'title': 'Dashboard',
        'cards': List.generate(
          count,
          (_) => {
            'title': 'Assets',
            'moduleId': w2Module,
            'moduleVersion': '1.0.0',
            'docType': 'Asset',
            'reportId': 'asset_count',
            'filters': <String, dynamic>{},
          },
        ),
      };
      validateWave2Definition('dashboard', dashboard(12));
      w2Contract(
        () => validateWave2Definition('dashboard', dashboard(13)),
        code: 'INVALID_DASHBOARD',
      );
      final body = dashboard(1);
      (body['cards'] as List).single['handler'] = 'run';
      w2Contract(() => validateWave2Definition('dashboard', body));
    },
  );
  await cases.run(
    'W2-C022',
    'M01',
    'Organization change has bounded identity, explicit CAS and fixed parent rules',
    () {
      final change = {
        'kind': 'branch',
        'id': 'branch-b',
        'parentId': 'company-a',
        'displayName': 'Branch B',
        'archived': false,
        'expectedRevision': 0,
        'requestId': w2Id(1),
      };
      validateOrganizationChange(change);
      for (final invalid in [
        {...change, 'id': 'a\u0000b'},
        {...change, 'expectedRevision': -1},
        {...change, 'kind': 'company', 'parentId': 'company-a'},
        {...change, 'role': 'admin'},
      ]) {
        w2Contract(() => validateOrganizationChange(invalid));
      }
    },
  );
  await cases.run(
    'W2-C023',
    'M02',
    'Operational bounds accept maxima and reject zero, excess and wrong types',
    () {
      validateWave2Definition(
        'configuration',
        w2Settings()..addAll({
          'defaultPageSize': 100,
          'maxImportRows': 500,
          'completedJobRetentionDays': 3650,
        }),
      );
      for (final entry in {
        'defaultPageSize': 100,
        'maxImportRows': 500,
        'completedJobRetentionDays': 3650,
      }.entries) {
        for (final value in [0, entry.value + 1, '1']) {
          w2Contract(
            () => validateWave2Definition(
              'configuration',
              w2Settings()..[entry.key] = value,
            ),
          );
        }
      }
      w2Contract(
        () => validateWave2Definition(
          'configuration',
          w2Settings()..['jobsPaused'] = 'true',
        ),
      );
    },
  );
  await cases.run(
    'W2-C024',
    'M05',
    'Backup policy bounds include retention, retries and UTC schedule',
    () {
      BackupPolicy.fromJson(
        w2Policy()..addAll({
          'retainDays': 3650,
          'retainCopies': 1000,
          'maximumAttempts': 5,
          'retryMinutes': 1440,
          'utcTime': '23:59',
        }),
      );
      for (final entry in {
        'retainDays': [0, 3651],
        'retainCopies': [1, 1001],
        'maximumAttempts': [0, 6],
        'retryMinutes': [4, 1441],
        'utcTime': ['24:00', '12:60', '1:00'],
      }.entries) {
        for (final value in entry.value) {
          w2Contract(
            () => BackupPolicy.fromJson(w2Policy()..[entry.key] = value),
          );
        }
      }
    },
  );
  await cases.run(
    'W2-C025',
    'M09,M05',
    'Restore needs exact backup identity and pinned plan; arbitrary paths denied',
    () {
      const backup =
          'ventio-postgresql-before-upgrade-20261116T000000000Z-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      validateHostOperation(w2Id(1), 'RESTORE', {
        'backupName': backup,
        'planOperationId': w2Id(2),
        'planSha256': 'a' * 64,
      });
      for (final body in [
        {'backupName': '../data'},
        {'backupName': backup, 'planOperationId': w2Id(2)},
        {
          'backupName': backup,
          'planOperationId': w2Id(2),
          'planSha256': 'a' * 64,
          'path': 'C:/data',
        },
      ]) {
        w2Contract(() => validateHostOperation(w2Id(1), 'RESTORE', body));
      }
      w2Contract(
        () => validateHostOperation(w2Id(1), 'BACKUP_NOW', {'command': 'run'}),
      );
    },
  );
  await cases.run(
    'W2-C026',
    'B02,J04',
    'Unknown contract versions, kinds and executable integration keys are refused',
    () {
      for (final kind in [
        'preferences',
        'configuration',
        'backup_policy',
        'saved_view',
      ]) {
        final body = switch (kind) {
          'preferences' => w2Preferences(),
          'configuration' => w2Settings(),
          'backup_policy' => w2Policy(),
          _ => w2View(),
        };
        w2Contract(
          () => validateWave2Definition(kind, {...body, 'contractVersion': 2}),
        );
        w2Contract(
          () => validateWave2Definition(kind, {
            ...body,
            'url': 'https://example.invalid/execute',
          }),
        );
      }
      w2Contract(
        () => validateWave2Definition('webhook', {'contractVersion': 1}),
        code: 'UNSUPPORTED_DEFINITION',
      );
    },
  );
  await cases.run(
    'W2-C027',
    'B02,K10',
    'Existing v1 record envelope round-trips and rejects unsupported command version',
    () {
      final command = w2Create(1);
      w2Equal(
        CommandEnvelope.fromJson(command.original).original,
        command.original,
        'Wire shape changed',
      );
      w2Contract(
        () => ExtensionRecordCommand.fromEnvelope(
          CommandEnvelope.fromJson({...command.original, 'typeVersion': 2}),
        ),
        code: 'UNSUPPORTED_VERSION',
      );
    },
  );
  await cases.run(
    'W2-C028',
    'A12,B02,J04',
    'Definitions enforce encoded byte ceiling and reject unknown overlay keys',
    () {
      w2Contract(
        () => validateWave2Definition('preferences', {
          ...w2Preferences(),
          'payload': 'é' * 16385,
        }),
        code: 'DEFINITION_TOO_LARGE',
      );
      w2Contract(
        () =>
            MetadataCustomization.fromJson({...w2Overlay(), 'sql': 'select 1'}),
        code: 'INVALID_WAVE2_CONTRACT',
      );
      w2Expect(
        utf8.encode(canonicalJson(w2Overlay())).length < 32768,
        'Fixture exceeds real bound',
      );
    },
  );
  await cases.run(
    'W2-C029',
    'J01,K10',
    'CSV date enum reference and child JSON preserve types with exact defaults and calculations',
    () {
      final row = _typedCsv().single;
      w2Expect(row.errors.isEmpty, 'Typed CSV rejected');
      w2Equal(row.values['due'], '2024-02-29', 'Date was inferred or changed');
      w2Equal(row.values['state'], 'open', 'Enum changed');
      final definition = _csvDefinition();
      final normalized = definition.applyDefaults(row.values);
      w2Expect(
        definition.validatePayload(normalized).isEmpty,
        'Defaults invalid',
      );
      final child = (normalized['lines'] as List).single as Map;
      w2Equal(child['quantity'], 1.25, 'Child default missing');
      w2Equal(child['unitPrice'], 2.0, 'Child price default missing');
      w2Equal(child['lineTotal'], 2.5, 'Exact child calculation differs');
      w2Equal(normalized['total'], 2.5, 'Parent sum differs');
      w2Equal(
        definition
            .referencesIn(normalized)
            .map((r) => r.recordId)
            .toSet()
            .toList()
          ..sort(),
        ['asset-child', 'asset-reference'],
        'Scoped reference candidates were lost',
      );
      // Preview identifies references; only Host can authorize their existence.
      w2Expect(
        !row.values.containsKey('total'),
        'Preview fabricated a persisted value',
      );
    },
  );
  await cases.run(
    'W2-C030',
    'J01',
    'CSV rejects invalid calendar enum reference and malformed forbidden or imprecise child rows',
    () {
      for (final row in [
        _typedCsv(due: '2023-02-29').single,
        _typedCsv(due: '2024-13-01').single,
        _typedCsv(due: '29/02/2024').single,
        _typedCsv(state: 'OPEN').single,
        _typedCsv(linked: '').single,
        _typedCsv(
          lines: [
            {'asset': 'asset-child', 'undeclared': 'hidden'},
          ],
        ).single,
        _typedCsv(
          lines: [
            {'asset': 12},
          ],
        ).single,
      ]) {
        w2Expect(row.errors.isNotEmpty, 'Invalid typed CSV admitted');
        w2Expect(row.rowNumber == 2, 'Invalid row correlation changed');
      }
      for (final lines in <Object>[
        '[broken',
        {'asset': 'asset-child'},
      ]) {
        // Invalid table parsing leaves no calculation input; the production
        // contract rejects the preview with INVALID_CALCULATION in this schema.
        w2Contract(() => _typedCsv(lines: lines), code: 'INVALID_CALCULATION');
      }
      // Exact calculation refuses implicit rounding rather than emitting a
      // successful preview. This ContractError is part of the actual contract.
      w2Contract(
        () => _typedCsv(
          lines: [
            {'asset': 'asset-child', 'quantity': 0.1, 'unitPrice': 0.15},
          ],
        ),
        code: 'INVALID_CALCULATION',
      );
    },
  );
  await cases.run(
    'W2-C031',
    'J01,D08,K10',
    'CSV cannot map a calculated output or read-only field even with writable-field labels',
    () {
      for (final field in ['total', 'locked']) {
        w2Contract(
          () => previewCsvImport(
            source: 'id,Value\nrow-a,999',
            definition: _csvDefinition(),
            mapping: {'Value': field},
            recordIdHeader: 'id',
            writableFields: {field},
          ),
          code: 'IMPORT_FIELD_DENIED',
        );
      }
    },
  );
}
