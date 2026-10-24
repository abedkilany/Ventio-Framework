import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
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
  String moduleId = _moduleId,
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
  final permissionNamespace = moduleId.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]+'),
    '_',
  );
  return {
    'name': name,
    'moduleId': moduleId,
    'schemaVersion': schemaVersion,
    'kind': 'operational',
    'fields': selectedFields,
    'permissions': {
      'read': 'extension.$permissionNamespace.${name.toLowerCase()}.read',
      'create':
          createPermission ??
          'extension.$permissionNamespace.${name.toLowerCase()}.create',
      'update': 'extension.$permissionNamespace.${name.toLowerCase()}.update',
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

  test('A local extension exports a bounded declarative package', () async {
    await store.createExtension(
      moduleId: _moduleId,
      displayName: 'Asset Register',
      description: 'Track equipment by branch.',
    );
    final metadata = _docType();
    metadata['labelKey'] = 'extension.com_example_asset_register.asset.name';
    final fields = (metadata['fields'] as List).cast<Map<String, dynamic>>();
    fields.single['labelKey'] =
        'extension.com_example_asset_register.asset.name_value';
    fields.add({
      'name': 'status',
      'type': 'enum',
      'required': false,
      'label': 'Status',
      'labelKey': 'extension.com_example_asset_register.asset.status',
      'enumValues': ['active', 'retired'],
      'enumLabels': {
        'active': {
          'label': 'Active',
          'labelKey':
              'extension.com_example_asset_register.asset.status_active',
        },
        'retired': {
          'label': 'Retired',
          'labelKey':
              'extension.com_example_asset_register.asset.status_retired',
        },
      },
    });
    (metadata['ui'] as Map<String, dynamic>)['listColumns'] = [
      'name',
      'status',
    ];
    (metadata['ui'] as Map<String, dynamic>)['formFields'] = ['name', 'status'];
    await store.saveDocType(metadata);

    final bundle = await store.exportBundle(_moduleId);
    expect(bundle.moduleId, _moduleId);
    expect(bundle.docTypes.single.name, 'Asset');
    expect(bundle.manifest.commands, isEmpty);
    expect(bundle.manifest.requiredCapabilities, isEmpty);
    expect(
      bundle.englishCatalog['extension.com_example_asset_register.module.name'],
      'Asset Register',
    );
    expect(
      bundle
          .englishCatalog['extension.com_example_asset_register.asset.status_active'],
      'Active',
    );
    expect(
      () => (bundle.toJson()['docTypes'] as List).clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'A declarative package installs atomically and upgrades saved records',
    () async {
      await store.createExtension(
        moduleId: _moduleId,
        displayName: 'Asset Register',
        description: 'Track equipment by branch.',
      );
      final metadata = _docType();
      metadata['labelKey'] = 'extension.com_example_asset_register.asset.name';
      final fields = (metadata['fields'] as List).cast<Map<String, dynamic>>();
      fields.single['labelKey'] =
          'extension.com_example_asset_register.asset.name_value';
      await store.saveDocType(metadata);
      final bundle = await store.exportBundle(_moduleId);

      final target = await LocalExtensionStore.open(
        factory: databaseFactoryFfi,
        path: '${directory.path}${Platform.pathSeparator}installed.sqlite3',
      );
      try {
        await target.installBundle(bundle);
        expect(
          (await target.getExtension(_moduleId))!.state,
          ExtensionState.draft,
        );
        await target.activate(_moduleId);
        await target.createRecord(
          moduleId: _moduleId,
          docTypeName: 'Asset',
          scope: _scope,
          values: {'name': 'Workshop press'},
          recordId: 'asset-package-1',
        );

        final updateJson =
            jsonDecode(jsonEncode(bundle.toJson())) as Map<String, dynamic>;
        (updateJson['manifest'] as Map<String, dynamic>)['version'] = '0.2.0';
        final updatedType =
            (updateJson['docTypes'] as List).single as Map<String, dynamic>;
        updatedType['schemaVersion'] = 2;
        final updatedFields = (updatedType['fields'] as List)
            .cast<Map<String, dynamic>>();
        updatedFields.add({
          'name': 'serialNumber',
          'type': 'text',
          'required': false,
          'label': 'Serial number',
          'labelKey':
              'extension.com_example_asset_register.asset.serial_number',
          'maxLength': 80,
        });
        final ui = updatedType['ui'] as Map<String, dynamic>;
        ui['listColumns'] = ['name', 'serialNumber'];
        ui['formFields'] = ['name', 'serialNumber'];
        (updateJson['englishCatalog']
                as Map<
                  String,
                  dynamic
                >)['extension.com_example_asset_register.asset.serial_number'] =
            'Serial number';
        final upgrade = ExtensionBundle.fromJson(updateJson);

        await expectLater(
          target.installBundle(upgrade),
          throwsA(
            isA<ExtensionStoreException>().having(
              (error) => error.code,
              'code',
              'DISABLE_BEFORE_UPDATE',
            ),
          ),
        );
        await target.disable(_moduleId);
        await target.installBundle(upgrade);
        await target.activate(_moduleId);
        final preserved = await target.getRecord(
          moduleId: _moduleId,
          docTypeName: 'Asset',
          recordId: 'asset-package-1',
          scope: _scope,
        );
        expect(preserved!.values, {'name': 'Workshop press'});
        expect(preserved.schemaVersion, 2);
        expect((await target.getExtension(_moduleId))!.version, '0.2.0');
      } finally {
        await target.close();
      }
    },
  );

  test(
    'A package requiring a newer platform is rejected before install',
    () async {
      await store.createExtension(
        moduleId: _moduleId,
        displayName: 'Asset Register',
        description: 'Temporary package source.',
      );
      final metadata = _docType();
      metadata['labelKey'] = 'extension.com_example_asset_register.asset.name';
      (metadata['fields'] as List).single['labelKey'] =
          'extension.com_example_asset_register.asset.name_value';
      await store.saveDocType(metadata);
      final source =
          jsonDecode(jsonEncode((await store.exportBundle(_moduleId)).toJson()))
              as Map<String, dynamic>;
      await store.remove(_moduleId);
      (source['manifest'] as Map<String, dynamic>)['minPlatformApi'] = '0.2.0';
      final incompatible = ExtensionBundle.fromJson(source);

      await expectLater(
        store.installBundle(incompatible),
        throwsA(
          isA<ExtensionStoreException>().having(
            (error) => error.code,
            'code',
            'INCOMPATIBLE_PLATFORM',
          ),
        ),
      );
      expect(await store.getExtension(_moduleId), isNull);
    },
  );

  test(
    'Version-one local databases gain an empty dependency manifest',
    () async {
      final legacyPath =
          '${directory.path}${Platform.pathSeparator}legacy_extensions.sqlite3';
      final legacy = await databaseFactoryFfi.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (database, version) async {
            await database.execute('''
            CREATE TABLE local_extensions (
              module_id TEXT PRIMARY KEY NOT NULL,
              display_name TEXT NOT NULL,
              description TEXT NOT NULL,
              version TEXT NOT NULL,
              state TEXT NOT NULL,
              created_at_utc TEXT NOT NULL,
              updated_at_utc TEXT NOT NULL
            )
          ''');
            await database.insert('local_extensions', {
              'module_id': _moduleId,
              'display_name': 'Asset Register',
              'description': '',
              'version': '0.1.0',
              'state': 'DRAFT',
              'created_at_utc': '2026-10-24T00:00:00.000Z',
              'updated_at_utc': '2026-10-24T00:00:00.000Z',
            });
          },
        ),
      );
      await legacy.close();

      final migrated = await LocalExtensionStore.open(
        factory: databaseFactoryFfi,
        path: legacyPath,
      );
      try {
        expect((await migrated.getExtension(_moduleId))!.dependencies, isEmpty);
      } finally {
        await migrated.close();
      }
    },
  );

  test('Dependencies enforce install order and compatible versions', () async {
    const dependentId = 'com.example.asset_inspections';
    await store.createExtension(
      moduleId: _moduleId,
      displayName: 'Asset Register',
      description: '',
    );
    await store.saveDocType(_docType());
    await store.createExtension(
      moduleId: dependentId,
      displayName: 'Asset Inspections',
      description: '',
      dependencies: const {_moduleId: '0.1.0'},
    );
    await store.saveDocType(
      _docType(moduleId: dependentId, name: 'Inspection'),
    );

    await expectLater(
      store.activate(dependentId),
      throwsA(
        isA<ExtensionStoreException>().having(
          (error) => error.code,
          'code',
          'DEPENDENCY_NOT_ACTIVE',
        ),
      ),
    );
    await store.activate(_moduleId);
    await store.activate(dependentId);
    expect((await store.getExtension(dependentId))!.dependencies, {
      _moduleId: '0.1.0',
    });

    await expectLater(
      store.updateExtensionDetails(
        moduleId: _moduleId,
        displayName: 'Asset Register',
        description: '',
        version: '0.2.0',
      ),
      throwsA(
        isA<ExtensionStoreException>().having(
          (error) => error.code,
          'code',
          'BREAKING_DEPENDENCY_UPDATE',
        ),
      ),
    );
    await expectLater(
      store.updateExtensionDetails(
        moduleId: _moduleId,
        displayName: 'Asset Register',
        description: '',
        version: '1.0.0',
      ),
      throwsA(
        isA<ExtensionStoreException>().having(
          (error) => error.code,
          'code',
          'BREAKING_DEPENDENCY_UPDATE',
        ),
      ),
    );
    await store.updateExtensionDetails(
      moduleId: _moduleId,
      displayName: 'Asset Register',
      description: '',
      version: '0.1.1',
    );
    await expectLater(
      store.disable(_moduleId),
      throwsA(
        isA<ExtensionStoreException>().having(
          (error) => error.code,
          'code',
          'ACTIVE_DEPENDENTS',
        ),
      ),
    );
    await store.disable(dependentId);
    await store.disable(_moduleId);
    await expectLater(
      store.remove(_moduleId),
      throwsA(
        isA<ExtensionStoreException>().having(
          (error) => error.code,
          'code',
          'EXTENSION_IS_DEPENDENCY',
        ),
      ),
    );
  });

  test('Dependency cycles and missing versions are rejected', () async {
    const dependentId = 'com.example.asset_inspections';
    await store.createExtension(
      moduleId: _moduleId,
      displayName: 'Asset Register',
      description: '',
    );
    await store.createExtension(
      moduleId: dependentId,
      displayName: 'Asset Inspections',
      description: '',
      dependencies: const {_moduleId: '0.1.0'},
    );

    await expectLater(
      store.updateExtensionDetails(
        moduleId: _moduleId,
        displayName: 'Asset Register',
        description: '',
        version: '0.1.0',
        dependencies: const {dependentId: '0.1.0'},
      ),
      throwsA(
        isA<ExtensionStoreException>().having(
          (error) => error.code,
          'code',
          'DEPENDENCY_CYCLE',
        ),
      ),
    );
    await expectLater(
      store.createExtension(
        moduleId: 'com.example.missing_dependency',
        displayName: 'Missing dependency',
        description: '',
        dependencies: const {'com.example.not_installed': '1.0.0'},
      ),
      throwsA(
        isA<ExtensionStoreException>().having(
          (error) => error.code,
          'code',
          'MISSING_DEPENDENCY',
        ),
      ),
    );
  });

  test(
    'Two independent extensions use the same generated data engine',
    () async {
      const secondModuleId = 'com.example.site_registry';
      await createActiveExtension();
      await store.createExtension(
        moduleId: secondModuleId,
        displayName: 'Site Registry',
        description: 'Track operating locations.',
      );
      await store.saveDocType(_docType(moduleId: secondModuleId, name: 'Site'));
      await store.activate(secondModuleId);

      await store.createRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        values: {'name': 'Laptop 1'},
        recordId: 'asset-1',
      );
      await store.createRecord(
        moduleId: secondModuleId,
        docTypeName: 'Site',
        scope: _scope,
        values: {'name': 'Beirut Office'},
        recordId: 'site-1',
      );

      expect((await store.listDocTypes(_moduleId)).single['name'], 'Asset');
      expect((await store.listDocTypes(secondModuleId)).single['name'], 'Site');
      expect(
        (await store.listRecords(
          moduleId: secondModuleId,
          docTypeName: 'Site',
          scope: _scope,
        )).single.values,
        {'name': 'Beirut Office'},
      );
      expect(await store.countRecords(_moduleId), 1);
      expect(await store.countRecords(secondModuleId), 1);
    },
  );

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
        moduleId: _moduleId,
        docTypeName: 'Asset',
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
        moduleId: _moduleId,
        docTypeName: 'Asset',
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
      moduleId: _moduleId,
      docTypeName: 'Asset',
      recordId: 'asset-1',
      scope: _scope,
      expectedRevision: 1,
      values: {'name': 'Laptop 2'},
    );
    expect(updated.revision, 2);
    expect(updated.values['name'], 'Laptop 2');

    await expectLater(
      store.updateRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        recordId: 'asset-1',
        scope: _scope,
        expectedRevision: 1,
        values: {'name': 'stale'},
      ),
      throwsA(isA<ExtensionStoreException>()),
    );
    expect(
      (await store.getRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        recordId: 'asset-1',
        scope: _scope,
      ))!.values['name'],
      'Laptop 2',
    );
  });

  test(
    'Local record engine enforces each DocType operation declaration',
    () async {
      await createActiveExtension();
      await store.createRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        values: {'name': 'Laptop 1'},
        recordId: 'asset-operations',
      );

      final readOnly = _docType(schemaVersion: 2)
        ..['operations'] = ['read']
        ..['permissions'] = {
          'read': 'extension.com_example_asset_register.asset.read',
        };
      await store.saveDocType(readOnly);
      await expectLater(
        store.createRecord(
          moduleId: _moduleId,
          docTypeName: 'Asset',
          scope: _scope,
          values: {'name': 'Laptop 2'},
          recordId: 'asset-create-denied',
        ),
        throwsA(
          isA<ExtensionStoreException>().having(
            (error) => error.code,
            'code',
            'OPERATION_NOT_DECLARED',
          ),
        ),
      );
      await expectLater(
        store.updateRecord(
          moduleId: _moduleId,
          docTypeName: 'Asset',
          recordId: 'asset-operations',
          scope: _scope,
          expectedRevision: 1,
          values: {'name': 'Laptop changed'},
        ),
        throwsA(isA<ExtensionStoreException>()),
      );
      expect(
        (await store.listRecords(
          moduleId: _moduleId,
          docTypeName: 'Asset',
          scope: _scope,
        )).single.recordId,
        'asset-operations',
      );
      expect(
        (await store.getRecord(
          moduleId: _moduleId,
          docTypeName: 'Asset',
          recordId: 'asset-operations',
          scope: _scope,
        ))!.recordId,
        'asset-operations',
      );

      final createOnly = _docType(schemaVersion: 3)
        ..['operations'] = ['create']
        ..['permissions'] = {
          'create': 'extension.com_example_asset_register.asset.create',
        };
      await store.saveDocType(createOnly);
      await store.createRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        values: {'name': 'Laptop 2'},
        recordId: 'asset-create-only',
      );
      await expectLater(
        store.listRecords(
          moduleId: _moduleId,
          docTypeName: 'Asset',
          scope: _scope,
        ),
        throwsA(isA<ExtensionStoreException>()),
      );
      await expectLater(
        store.getRecord(
          moduleId: _moduleId,
          docTypeName: 'Asset',
          recordId: 'asset-create-only',
          scope: _scope,
        ),
        throwsA(isA<ExtensionStoreException>()),
      );
    },
  );

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
        moduleId: _moduleId,
        docTypeName: 'Asset',
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
