import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_native_client/src/extension_store.dart';

const _moduleId = 'com.example.asset_register';
const _scope = RecordScope(
  organizationId: 'org-one',
  companyId: 'company-one',
  branchId: 'branch-one',
);

Map<String, dynamic> _textField({
  String name = 'name',
  bool required = true,
  int maxLength = 120,
}) => {
  'name': name,
  'type': 'text',
  'required': required,
  'maxLength': maxLength,
  'label': name,
  'labelKey': 'asset_register.asset.${name.toLowerCase()}',
};

Map<String, dynamic> _docType({
  String name = 'Asset',
  int schemaVersion = 1,
  List<Map<String, dynamic>>? fields,
  String? referenceTo,
  String? createPermission,
}) {
  final selectedFields =
      fields ??
      [
        _textField(),
        if (referenceTo != null)
          {
            'name': 'parentAsset',
            'type': 'reference',
            'referenceTo': referenceTo,
            'required': false,
            'label': 'Parent asset',
            'labelKey': 'asset_register.asset.parent_asset',
          },
      ];
  final fieldNames = selectedFields.map((field) => field['name'] as String);
  return {
    'name': name,
    'moduleId': _moduleId,
    'schemaVersion': schemaVersion,
    'kind': 'operational',
    'fields': selectedFields,
    'permissions': {
      'read': 'extension.com_example_asset_register.${name.toLowerCase()}.read',
      'create':
          createPermission ??
          'extension.com_example_asset_register.${name.toLowerCase()}.create',
      'update':
          'extension.com_example_asset_register.${name.toLowerCase()}.update',
    },
    'ui': {
      'listColumns': fieldNames.take(2).toList(),
      'formFields': fieldNames.toList(),
    },
    'label': name,
    'labelKey': 'asset_register.${name.toLowerCase()}.name',
  };
}

void main() {
  late Directory directory;
  late LocalExtensionStore store;
  var sequence = 0;

  setUpAll(sqfliteFfiInit);

  Future<void> openStore() async {
    store = await LocalExtensionStore.open(
      factory: databaseFactoryFfi,
      path: '${directory.path}${Platform.pathSeparator}extensions.sqlite3',
      clock: () => DateTime.utc(2026, 10, 24, 2, sequence++),
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ventio_extensions_');
    sequence = 0;
    await openStore();
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  Future<void> createActiveExtension({
    String moduleId = _moduleId,
    Map<String, dynamic>? docType,
  }) async {
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Asset Register',
      description: 'Track equipment assigned to each branch.',
    );
    await store.saveDocType(docType ?? _docType());
    await store.activate(moduleId);
  }

  test('Extension metadata and lifecycle survive database reopen', () async {
    await createActiveExtension();
    final beforeClose = (await store.getExtension(_moduleId))!;
    expect(beforeClose.state, ExtensionState.active);
    expect(beforeClose.authorityState, 'LOCAL_ONLY');

    await store.close();
    await openStore();

    final restored = (await store.getExtension(_moduleId))!;
    expect(restored.displayName, 'Asset Register');
    expect(restored.version, '0.1.0');
    expect(restored.state, ExtensionState.active);
    expect((await store.listDocTypes(_moduleId)).single['name'], 'Asset');
  });

  test(
    'An extension cannot declare permissions outside its namespace',
    () async {
      await store.createExtension(
        moduleId: _moduleId,
        displayName: 'Asset Register',
        description: '',
      );

      await expectLater(
        store.saveDocType(_docType(createPermission: 'system.identity.admin')),
        throwsA(
          isA<ExtensionStoreException>().having(
            (error) => error.code,
            'code',
            'PERMISSION_NAMESPACE',
          ),
        ),
      );
      expect(await store.listDocTypes(_moduleId), isEmpty);
    },
  );

  test('Records are scoped by organization, company and branch', () async {
    await createActiveExtension();
    final created = await store.createRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: _scope,
      values: {'name': 'Laptop 1'},
      recordId: 'asset-1',
    );

    expect(created.syncState, 'LOCAL_ONLY');
    expect(created.revision, 1);
    expect(
      (await store.listRecords(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        search: 'laptop',
      )).map((record) => record.recordId),
      ['asset-1'],
    );

    expect(
      await store.getRecord(
        recordId: 'asset-1',
        scope: const RecordScope(
          organizationId: 'org-one',
          companyId: 'company-one',
          branchId: 'branch-two',
        ),
      ),
      isNull,
    );
    expect(
      await store.getRecord(
        recordId: 'asset-1',
        scope: const RecordScope(
          organizationId: 'org-two',
          companyId: 'company-one',
          branchId: 'branch-one',
        ),
      ),
      isNull,
    );
  });

  test('Record updates use optimistic revisions and preserve scope', () async {
    await createActiveExtension();
    await store.createRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: _scope,
      values: {'name': 'Laptop 1'},
      recordId: 'asset-1',
    );

    final updated = await store.updateRecord(
      recordId: 'asset-1',
      scope: _scope,
      expectedRevision: 1,
      values: {'name': 'Laptop 2'},
    );
    expect(updated.revision, 2);
    expect(updated.values['name'], 'Laptop 2');

    await expectLater(
      store.updateRecord(
        recordId: 'asset-1',
        scope: _scope,
        expectedRevision: 1,
        values: {'name': 'stale'},
      ),
      throwsA(isA<ExtensionStoreException>()),
    );
    expect(
      (await store.getRecord(
        recordId: 'asset-1',
        scope: _scope,
      ))!.values['name'],
      'Laptop 2',
    );
  });

  test(
    'Relationships cannot cross organization, company or branch scope',
    () async {
      await store.createExtension(
        moduleId: _moduleId,
        displayName: 'Asset Register',
        description: '',
      );
      await store.saveDocType(_docType(name: 'ParentAsset'));
      await store.saveDocType(
        _docType(name: 'ChildAsset', referenceTo: 'ParentAsset'),
      );
      await store.activate(_moduleId);
      await store.createRecord(
        moduleId: _moduleId,
        docTypeName: 'ParentAsset',
        scope: _scope,
        values: {'name': 'Head office'},
        recordId: 'parent-1',
      );

      await expectLater(
        store.createRecord(
          moduleId: _moduleId,
          docTypeName: 'ChildAsset',
          scope: const RecordScope(
            organizationId: 'org-one',
            companyId: 'company-one',
            branchId: 'branch-two',
          ),
          values: {'name': 'Child', 'parentAsset': 'parent-1'},
          recordId: 'child-1',
        ),
        throwsA(
          isA<ExtensionStoreException>().having(
            (error) => error.code,
            'code',
            'INVALID_REFERENCE',
          ),
        ),
      );

      final child = await store.createRecord(
        moduleId: _moduleId,
        docTypeName: 'ChildAsset',
        scope: _scope,
        values: {'name': 'Child', 'parentAsset': 'parent-1'},
        recordId: 'child-1',
      );
      expect(child.values['parentAsset'], 'parent-1');
    },
  );

  test(
    'Schema upgrades preserve records and reject destructive changes',
    () async {
      await createActiveExtension();
      await store.createRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        values: {'name': 'Laptop 1'},
        recordId: 'asset-1',
      );

      await store.saveDocType(
        _docType(
          schemaVersion: 2,
          fields: [
            _textField(),
            _textField(name: 'serialNumber', required: false),
          ],
        ),
      );
      final extension = (await store.getExtension(_moduleId))!;
      expect(extension.version, '0.1.1');
      final migrated = (await store.getRecord(
        recordId: 'asset-1',
        scope: _scope,
      ))!;
      expect(migrated.values['name'], 'Laptop 1');
      expect(migrated.schemaVersion, 2);

      await expectLater(
        store.saveDocType(
          _docType(
            schemaVersion: 3,
            fields: [_textField(name: 'serialNumber')],
          ),
        ),
        throwsA(
          isA<ExtensionStoreException>().having(
            (error) => error.code,
            'code',
            'DESTRUCTIVE_SCHEMA_CHANGE',
          ),
        ),
      );
      expect(await store.countRecords(_moduleId), 1);
    },
  );

  test(
    'Removal refuses to destroy data; disable keeps it readable offline',
    () async {
      await createActiveExtension();
      await store.createRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        values: {'name': 'Laptop 1'},
        recordId: 'asset-1',
      );

      await store.disable(_moduleId);
      expect(
        (await store.getExtension(_moduleId))!.state,
        ExtensionState.disabled,
      );
      await expectLater(
        store.remove(_moduleId),
        throwsA(isA<ExtensionStoreException>()),
      );
      expect(await store.countRecords(_moduleId), 1);
    },
  );
}
