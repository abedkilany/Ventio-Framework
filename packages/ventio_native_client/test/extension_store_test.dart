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

  test('Host scope profile persists across a database reopen', () async {
    const profile = HostConnectionProfile(
      endpoint: 'https://host.example.test:8443',
      tenantId: 'tenant-west',
      companyId: 'company-west',
      branchId: 'branch-7',
      actorId: 'user-west',
      deviceId: 'desktop-west',
    );
    await store.saveHostProfile(profile);
    await store.close();
    await openStore();

    final restored = await store.getHostProfile();
    expect(restored?.endpoint, profile.endpoint);
    expect(restored?.tenantId, profile.tenantId);
    expect(restored?.companyId, profile.companyId);
    expect(restored?.branchId, profile.branchId);
    expect(restored?.actorId, profile.actorId);
    expect(restored?.deviceId, profile.deviceId);
    await store.clearHostProfile();
    expect(await store.getHostProfile(), isNull);
  });

  test('Version-five stores migrate scoped Host record denial state', () async {
    final legacyPath =
        '${directory.path}${Platform.pathSeparator}legacy_v5.sqlite3';
    final legacy = await databaseFactoryFfi.openDatabase(
      legacyPath,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE local_extensions (
              module_id TEXT PRIMARY KEY NOT NULL,
              display_name TEXT NOT NULL,
              description TEXT NOT NULL,
              version TEXT NOT NULL,
              dependencies_json TEXT NOT NULL DEFAULT '{}',
              state TEXT NOT NULL,
              created_at_utc TEXT NOT NULL,
              updated_at_utc TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    await legacy.close();

    const profile = HostConnectionProfile(
      endpoint: 'https://host.example.test',
      tenantId: 'tenant-west',
      companyId: 'company-west',
      branchId: 'branch-7',
      actorId: 'user-west',
      deviceId: 'desktop-west',
    );
    var migrated = await LocalExtensionStore.open(
      factory: databaseFactoryFfi,
      path: legacyPath,
    );
    await migrated.createExtension(
      moduleId: _moduleId,
      displayName: 'Asset Register',
      description: '',
    );
    await migrated.markHostRecordReadDenied(
      profile: profile,
      moduleId: _moduleId,
      reasonCode: 'PERMISSION_DENIED',
    );
    expect(
      await migrated.hasHostRecordReadDenial(
        profile: profile,
        moduleId: _moduleId,
      ),
      isTrue,
    );
    await migrated.close();

    migrated = await LocalExtensionStore.open(
      factory: databaseFactoryFfi,
      path: legacyPath,
    );
    try {
      expect(
        await migrated.hasHostRecordReadDenial(
          profile: profile,
          moduleId: _moduleId,
        ),
        isTrue,
      );
      expect(
        await migrated.hasHostRecordReadDenial(
          profile: const HostConnectionProfile(
            endpoint: 'https://host.example.test',
            tenantId: 'tenant-west',
            companyId: 'company-west',
            branchId: 'branch-7',
            actorId: 'another-user',
            deviceId: 'desktop-west',
          ),
          moduleId: _moduleId,
        ),
        isFalse,
      );
      await migrated.clearHostRecordReadDenial(
        profile: profile,
        moduleId: _moduleId,
      );
      expect(
        await migrated.hasHostRecordReadDenial(
          profile: profile,
          moduleId: _moduleId,
        ),
        isFalse,
      );
    } finally {
      await migrated.close();
    }
  });

  test(
    'Host receipts and refreshes preserve provisional offline edits',
    () async {
      await createActiveExtension();
      final created = await store.createRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        values: const {'name': 'Host accepted'},
        recordId: 'host-record-1',
      );
      await store.markRecordPending(
        recordId: created.recordId,
        scope: _scope,
        commandId: 'create-command',
      );
      await store.applyHostReceipt(
        recordId: created.recordId,
        scope: _scope,
        commandId: 'create-command',
        receipt: CommandReceipt(
          commandId: 'create-command',
          status: 'ACCEPTED',
          hostRevision: 1,
        ),
      );
      final accepted = (await store.getRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        recordId: created.recordId,
        scope: _scope,
      ))!;
      expect(accepted.authorityState, 'HOST_ACCEPTED');
      expect(accepted.hostRevision, 1);

      final edited = await store.updateRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        recordId: created.recordId,
        scope: _scope,
        expectedRevision: 1,
        values: const {'name': 'Offline edit'},
      );
      expect(edited.authorityState, 'LOCAL_ONLY');
      expect(edited.hostRevision, 1);
      await store.applyHostRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        recordId: created.recordId,
        revision: 1,
        values: const {'name': 'Host accepted'},
        updatedAtUtc: DateTime.utc(2026, 10, 24, 1),
      );
      final preserved = (await store.getRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        recordId: created.recordId,
        scope: _scope,
      ))!;
      expect(preserved.values['name'], 'Offline edit');
      expect(preserved.hostRevision, 1);

      await store.markRecordPending(
        recordId: created.recordId,
        scope: _scope,
        commandId: 'update-command',
      );
      await store.applyHostReceipt(
        recordId: created.recordId,
        scope: _scope,
        commandId: 'update-command',
        receipt: CommandReceipt(
          commandId: 'update-command',
          status: 'ACCEPTED',
          hostRevision: 2,
        ),
      );
      final resolved = (await store.getRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        recordId: created.recordId,
        scope: _scope,
      ))!;
      expect(resolved.authorityState, 'HOST_ACCEPTED');
      expect(resolved.pendingCommandId, isNull);
      expect(resolved.hostRevision, 2);
    },
  );

  test('Conflict and rejection receipts preserve the local draft', () async {
    await createActiveExtension();
    final created = await store.createRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: _scope,
      values: const {'name': 'Host value'},
      recordId: 'conflicted-record',
    );
    await store.markRecordPending(
      recordId: created.recordId,
      scope: _scope,
      commandId: 'create-command',
    );
    await store.applyHostReceipt(
      recordId: created.recordId,
      scope: _scope,
      commandId: 'create-command',
      receipt: CommandReceipt(
        commandId: 'create-command',
        status: 'ACCEPTED',
        hostRevision: 1,
      ),
    );
    final localEdit = await store.updateRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      recordId: created.recordId,
      scope: _scope,
      expectedRevision: 1,
      values: const {'name': 'Local edit'},
    );
    await store.markRecordPending(
      recordId: localEdit.recordId,
      scope: _scope,
      commandId: 'update-command',
    );
    await store.applyHostReceipt(
      recordId: created.recordId,
      scope: _scope,
      commandId: 'update-command',
      receipt: CommandReceipt(
        commandId: 'update-command',
        status: 'CONFLICT',
        reasonCode: 'REVISION_CONFLICT',
        currentRevision: 2,
      ),
    );
    await expectLater(
      store.updateRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        recordId: created.recordId,
        scope: _scope,
        expectedRevision: localEdit.revision,
        values: const {'name': 'Unsafe automatic rebase'},
      ),
      throwsA(
        isA<ExtensionStoreException>().having(
          (error) => error.code,
          'code',
          'CONFLICT_SNAPSHOT_REQUIRED',
        ),
      ),
    );
    await store.applyHostRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: _scope,
      recordId: created.recordId,
      revision: 1,
      values: const {'name': 'Stale Host value'},
      updatedAtUtc: DateTime.utc(2026, 10, 23),
    );
    var conflicted = (await store.getRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      recordId: created.recordId,
      scope: _scope,
    ))!;
    expect(conflicted.conflictValues, isNull);
    await store.applyHostRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: _scope,
      recordId: created.recordId,
      revision: 2,
      values: const {'name': 'Concurrent Host value'},
      updatedAtUtc: DateTime.utc(2026, 10, 24),
    );
    conflicted = (await store.getRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      recordId: created.recordId,
      scope: _scope,
    ))!;
    expect(conflicted.authorityState, 'CONFLICT');
    expect(conflicted.hostRevision, 2);
    expect(conflicted.values['name'], 'Local edit');
    expect(conflicted.conflictRevision, 2);
    expect(conflicted.conflictValues?['name'], 'Concurrent Host value');

    final rebased = await store.updateRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      recordId: created.recordId,
      scope: _scope,
      expectedRevision: conflicted.revision,
      values: const {'name': 'Reviewed local draft'},
    );
    expect(rebased.hostRevision, 2);
    expect(rebased.authorityState, 'LOCAL_ONLY');
    await store.markRecordPending(
      recordId: rebased.recordId,
      scope: _scope,
      commandId: 'rebased-command',
    );
    await store.applyHostReceipt(
      recordId: rebased.recordId,
      scope: _scope,
      commandId: 'rebased-command',
      receipt: CommandReceipt(
        commandId: 'rebased-command',
        status: 'REJECTED',
        reasonCode: 'PERMISSION_DENIED',
      ),
    );
    conflicted = (await store.getRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      recordId: created.recordId,
      scope: _scope,
    ))!;
    expect(conflicted.authorityState, 'REJECTED');
    expect(conflicted.pendingCommandId, isNull);
    expect(conflicted.hostRevision, 2);
    expect(conflicted.values['name'], 'Reviewed local draft');
  });

  test('Conflict can explicitly adopt the latest Host snapshot', () async {
    await createActiveExtension();
    final record = await store.createRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: _scope,
      values: const {'name': 'Local draft'},
      recordId: 'host-adoption-record',
    );
    await store.markRecordPending(
      recordId: record.recordId,
      scope: _scope,
      commandId: 'host-adoption-command',
    );
    await store.applyHostReceipt(
      recordId: record.recordId,
      scope: _scope,
      commandId: 'host-adoption-command',
      receipt: CommandReceipt(
        commandId: 'host-adoption-command',
        status: 'CONFLICT',
        reasonCode: 'REVISION_CONFLICT',
        currentRevision: 4,
      ),
    );
    await store.applyHostRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: _scope,
      recordId: record.recordId,
      revision: 4,
      values: const {'name': 'Authoritative Host value'},
      updatedAtUtc: DateTime.utc(2026, 10, 24),
    );

    final accepted = await store.resolveConflictWithHostSnapshot(
      recordId: record.recordId,
      scope: _scope,
    );
    expect(accepted.authorityState, 'HOST_ACCEPTED');
    expect(accepted.revision, 4);
    expect(accepted.hostRevision, 4);
    expect(accepted.values['name'], 'Authoritative Host value');
    expect(accepted.conflictValues, isNull);
  });

  test('Host record imports remain isolated by exact branch scope', () async {
    await createActiveExtension();
    const otherBranch = RecordScope(
      organizationId: 'org-one',
      companyId: 'company-one',
      branchId: 'branch-two',
    );
    await store.applyHostRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: otherBranch,
      recordId: 'remote-branch-two',
      revision: 4,
      values: const {'name': 'Branch two'},
      updatedAtUtc: DateTime.utc(2026, 10, 24),
    );
    expect(
      await store.listRecords(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
      ),
      isEmpty,
    );
    final imported = await store.listRecords(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: otherBranch,
    );
    expect(imported.single.values['name'], 'Branch two');
    expect(imported.single.authorityState, 'HOST_ACCEPTED');
    expect(imported.single.hostRevision, 4);
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
        'extension.com_example_asset_register.asset.name';
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
    final exportedType = bundle.docTypeJson.single;
    final exportedField = (exportedType['fields'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((field) => field['name'] == 'name');
    expect(
      exportedField['labelKey'],
      'extension.com_example_asset_register.asset.field.name.label',
    );
    expect(
      bundle.englishCatalog['extension.com_example_asset_register.asset.name'],
      'Asset',
    );
    expect(bundle.englishCatalog[exportedField['labelKey']], 'name');
    final persistedType = await store.getDocType(_moduleId, 'Asset');
    expect(
      (persistedType!['fields'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((field) => field['name'] == 'name')['labelKey'],
      'extension.com_example_asset_register.asset.name',
    );
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
        final nameField = updatedFields.singleWhere(
          (field) => field['name'] == 'name',
        );
        updatedFields[updatedFields.indexOf(nameField)] = {
          ...nameField,
          'name': 'title',
          'label': 'Title',
          'labelKey': 'extension.com_example_asset_register.asset.title',
        };
        updatedFields.add({
          'name': 'serialNumber',
          'type': 'text',
          'required': false,
          'label': 'Serial number',
          'labelKey':
              'extension.com_example_asset_register.asset.serial_number',
          'maxLength': 80,
        });
        updatedType['migrations'] = [
          {
            'fromVersion': 1,
            'toVersion': 2,
            'steps': [
              {'op': 'renameField', 'from': 'name', 'to': 'title'},
            ],
          },
        ];
        final ui = updatedType['ui'] as Map<String, dynamic>;
        ui['listColumns'] = ['title', 'serialNumber'];
        ui['formFields'] = ['title', 'serialNumber'];
        (updateJson['englishCatalog']
                as Map<
                  String,
                  dynamic
                >)['extension.com_example_asset_register.asset.title'] =
            'Title';
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
        expect(preserved!.values, {'title': 'Workshop press'});
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
      expect(
        ((source['manifest'] as Map<String, dynamic>)['minPlatformApi']),
        currentPlatformApiVersion,
      );
      await store.remove(_moduleId);
      final newRelease = ExtensionBundle.fromJson(source);
      final oldPlatformStore = await LocalExtensionStore.open(
        factory: databaseFactoryFfiNoIsolate,
        path: '${directory.path}${Platform.pathSeparator}old_platform.sqlite3',
        platformApiVersion: '0.1.0',
      );
      try {
        await expectLater(
          oldPlatformStore.installBundle(newRelease),
          throwsA(
            isA<ExtensionStoreException>().having(
              (error) => error.code,
              'code',
              'INCOMPATIBLE_PLATFORM',
            ),
          ),
        );
        expect(await oldPlatformStore.getExtension(_moduleId), isNull);
      } finally {
        await oldPlatformStore.close();
      }

      (source['manifest'] as Map<String, dynamic>)['minPlatformApi'] = '0.3.0';
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
        expect(await migrated.getHostProfile(), isNull);
      } finally {
        await migrated.close();
      }
    },
  );

  test(
    'Version-four record data survives the conflict snapshot migration',
    () async {
      final legacyPath =
          '${directory.path}${Platform.pathSeparator}legacy_v4.sqlite3';
      final legacy = await databaseFactoryFfi.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (database, version) async {
            await database.execute('''
            CREATE TABLE local_extension_records (
              record_id TEXT PRIMARY KEY NOT NULL,
              module_id TEXT NOT NULL,
              doctype_name TEXT NOT NULL,
              organization_id TEXT NOT NULL,
              company_id TEXT NOT NULL,
              branch_id TEXT NOT NULL,
              data_json TEXT NOT NULL,
              schema_version INTEGER NOT NULL,
              revision INTEGER NOT NULL,
              sync_state TEXT NOT NULL DEFAULT 'LOCAL_ONLY',
              host_revision INTEGER,
              pending_command_id TEXT,
              authority_state TEXT NOT NULL DEFAULT 'LOCAL_ONLY',
              created_at_utc TEXT NOT NULL,
              updated_at_utc TEXT NOT NULL
            )
          ''');
            await database.insert('local_extension_records', {
              'record_id': 'preserved-record',
              'module_id': _moduleId,
              'doctype_name': 'Asset',
              'organization_id': _scope.organizationId,
              'company_id': _scope.companyId,
              'branch_id': _scope.branchId,
              'data_json': jsonEncode({'name': 'Keep this record'}),
              'schema_version': 1,
              'revision': 3,
              'host_revision': 2,
              'pending_command_id': null,
              'authority_state': 'CONFLICT',
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
      await migrated.close();
      final current = await databaseFactoryFfi.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(version: 6),
      );
      try {
        final columns = await current.rawQuery(
          'PRAGMA table_info(local_extension_records)',
        );
        final row = (await current.query(
          'local_extension_records',
          where: 'record_id = ?',
          whereArgs: ['preserved-record'],
        )).single;
        expect(
          columns.map((column) => column['name']),
          containsAll(['conflict_revision', 'conflict_data_json']),
        );
        expect(row['data_json'], jsonEncode({'name': 'Keep this record'}));
        expect(row['host_revision'], 2);
        expect(row['conflict_revision'], isNull);
        expect(row['conflict_data_json'], isNull);
      } finally {
        await current.close();
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
    'Search filters before paging when a DocType exceeds one thousand rows',
    () async {
      await createActiveExtension();
      await store.createRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        values: {'name': 'needle-oldest-record'},
        recordId: 'asset-oldest',
      );
      for (var index = 0; index < 1000; index++) {
        await store.createRecord(
          moduleId: _moduleId,
          docTypeName: 'Asset',
          scope: _scope,
          values: {'name': 'ordinary-record-$index'},
          recordId: 'asset-$index',
        );
      }

      final results = await store.listRecords(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        search: 'needle-oldest',
      );
      expect(results.map((record) => record.recordId), ['asset-oldest']);
    },
  );

  test(
    'Record filters and ordering run in SQLite using declared fields',
    () async {
      await createActiveExtension();
      for (final (id, name) in [
        ('asset-z', 'Zebra'),
        ('asset-a2', 'Alpine'),
        ('asset-a1', 'Atlas'),
        ('asset-other', 'Desk'),
      ]) {
        await store.createRecord(
          moduleId: _moduleId,
          docTypeName: 'Asset',
          scope: _scope,
          values: {'name': name},
          recordId: id,
        );
      }

      final results = await store.listRecords(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        filterField: 'name',
        filterContains: 'a',
        sortField: 'name',
      );
      expect(results.map((record) => record.values['name']), [
        'Alpine',
        'Atlas',
        'Zebra',
      ]);
      await expectLater(
        store.listRecords(
          moduleId: _moduleId,
          docTypeName: 'Asset',
          scope: _scope,
          sortField: 'name; DROP TABLE local_extension_records',
        ),
        throwsArgumentError,
      );
    },
  );

  test('Search treats user wildcards as literal text', () async {
    await createActiveExtension();
    await store.createRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: _scope,
      values: {'name': 'A%_B'},
      recordId: 'asset-special',
    );
    await store.createRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: _scope,
      values: {'name': 'AXYZB'},
      recordId: 'asset-ordinary',
    );

    final results = await store.listRecords(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: _scope,
      search: 'a%_',
    );
    expect(results.map((record) => record.recordId), ['asset-special']);
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
    'Reviewed rename and default migrations transform saved records',
    () async {
      await createActiveExtension(docType: _docType());
      await store.createRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        values: {'name': 'Workshop press'},
        recordId: 'asset-migrated',
      );
      await store.applyHostRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        recordId: 'asset-host-migrated',
        revision: 5,
        values: const {'name': 'Host press'},
        updatedAtUtc: DateTime.utc(2026, 10, 24),
      );

      final next =
          _docType(
              schemaVersion: 2,
              fields: [
                _textField(name: 'title'),
                _textField(name: 'category'),
              ],
            )
            ..['migrations'] = [
              {
                'fromVersion': 1,
                'toVersion': 2,
                'steps': [
                  {'op': 'renameField', 'from': 'name', 'to': 'title'},
                  {'op': 'setDefault', 'field': 'category', 'value': 'General'},
                ],
              },
            ];

      await store.saveDocType(next);
      final saved = (await store.getRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        recordId: 'asset-migrated',
        scope: _scope,
      ))!;
      expect(saved.values, {'title': 'Workshop press', 'category': 'General'});
      expect(saved.schemaVersion, 2);
      expect(saved.revision, 2);
      final hostCopy = (await store.getRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        recordId: 'asset-host-migrated',
        scope: _scope,
      ))!;
      expect(hostCopy.values, {'title': 'Host press', 'category': 'General'});
      expect(hostCopy.authorityState, 'CONFLICT');
      expect(hostCopy.hostRevision, 5);
      expect(hostCopy.conflictValues, isNull);
    },
  );

  test('Data migrations wait for unresolved Host commands', () async {
    await createActiveExtension(docType: _docType());
    final record = await store.createRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: _scope,
      values: {'name': 'Workshop press'},
      recordId: 'asset-pending-migration',
    );
    await store.markRecordPending(
      recordId: record.recordId,
      scope: _scope,
      commandId: 'cmd-pending-migration',
    );
    final next = _docType(schemaVersion: 2, fields: [_textField(name: 'title')])
      ..['migrations'] = [
        {
          'fromVersion': 1,
          'toVersion': 2,
          'steps': [
            {'op': 'renameField', 'from': 'name', 'to': 'title'},
          ],
        },
      ];

    await expectLater(
      store.saveDocType(next),
      throwsA(
        isA<ExtensionStoreException>().having(
          (error) => error.code,
          'code',
          'MIGRATION_PENDING_COMMANDS',
        ),
      ),
    );
    final unchanged = (await store.getRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      recordId: record.recordId,
      scope: _scope,
    ))!;
    expect(unchanged.values, {'name': 'Workshop press'});
    expect(unchanged.schemaVersion, 1);
  });

  test(
    'Numeric validation and schema upgrades preserve saved records',
    () async {
      Map<String, dynamic> quantityField({
        int? minimum = 0,
        int? maximum = 100,
      }) {
        final field = <String, dynamic>{
          'name': 'quantity',
          'type': 'integer',
          'required': false,
          'label': 'Quantity',
          'labelKey': 'asset_register.asset.quantity',
        };
        if (minimum != null) field['minValue'] = minimum;
        if (maximum != null) field['maxValue'] = maximum;
        return field;
      }

      Map<String, dynamic> definition({
        required int schemaVersion,
        int? minimum = 0,
        int? maximum = 100,
      }) => _docType(
        schemaVersion: schemaVersion,
        fields: [
          _textField(),
          quantityField(minimum: minimum, maximum: maximum),
        ],
      );

      await createActiveExtension(docType: definition(schemaVersion: 1));
      await store.createRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        values: {'name': 'Laptop', 'quantity': 50},
        recordId: 'asset-bounded',
      );
      await expectLater(
        store.createRecord(
          moduleId: _moduleId,
          docTypeName: 'Asset',
          scope: _scope,
          values: {'name': 'Out of range', 'quantity': 101},
          recordId: 'asset-invalid',
        ),
        throwsA(
          isA<ExtensionStoreException>().having(
            (error) => error.code,
            'code',
            'INVALID_RECORD',
          ),
        ),
      );

      await store.saveDocType(
        definition(schemaVersion: 2, minimum: -10, maximum: 200),
      );
      final migrated = (await store.getRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        recordId: 'asset-bounded',
        scope: _scope,
      ))!;
      expect(migrated.values['quantity'], 50);
      expect(migrated.schemaVersion, 2);

      for (final narrowed in [
        definition(schemaVersion: 3, minimum: -10, maximum: 40),
        definition(schemaVersion: 3, minimum: 60, maximum: 200),
      ]) {
        await expectLater(
          store.saveDocType(narrowed),
          throwsA(
            isA<ExtensionStoreException>().having(
              (error) => error.code,
              'code',
              'DESTRUCTIVE_SCHEMA_CHANGE',
            ),
          ),
        );
      }
      expect(await store.countRecords(_moduleId), 1);
      expect((await store.getExtension(_moduleId))!.version, '0.1.1');
    },
  );

  test('Text length validation blocks destructive schema tightening', () async {
    Map<String, dynamic> titleField({int? minimum = 2, int? maximum = 10}) {
      final field = <String, dynamic>{
        'name': 'title',
        'type': 'text',
        'required': true,
        'label': 'Title',
        'labelKey': 'asset_register.asset.title',
      };
      if (minimum != null) field['minLength'] = minimum;
      if (maximum != null) field['maxLength'] = maximum;
      return field;
    }

    Map<String, dynamic> definition({
      required int schemaVersion,
      int? minimum = 2,
      int? maximum = 10,
    }) => _docType(
      schemaVersion: schemaVersion,
      fields: [titleField(minimum: minimum, maximum: maximum)],
    );

    await createActiveExtension(docType: definition(schemaVersion: 1));
    await store.createRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      scope: _scope,
      values: {'title': 'Laptop'},
      recordId: 'asset-title',
    );
    await expectLater(
      store.createRecord(
        moduleId: _moduleId,
        docTypeName: 'Asset',
        scope: _scope,
        values: {'title': 'A'},
        recordId: 'asset-short-title',
      ),
      throwsA(
        isA<ExtensionStoreException>().having(
          (error) => error.code,
          'code',
          'INVALID_RECORD',
        ),
      ),
    );

    await store.saveDocType(
      definition(schemaVersion: 2, minimum: 1, maximum: 20),
    );
    for (final narrowed in [
      definition(schemaVersion: 3, minimum: 7, maximum: 20),
      definition(schemaVersion: 3, minimum: 1, maximum: 4),
    ]) {
      await expectLater(
        store.saveDocType(narrowed),
        throwsA(
          isA<ExtensionStoreException>().having(
            (error) => error.code,
            'code',
            'DESTRUCTIVE_SCHEMA_CHANGE',
          ),
        ),
      );
    }
    final saved = (await store.getRecord(
      moduleId: _moduleId,
      docTypeName: 'Asset',
      recordId: 'asset-title',
      scope: _scope,
    ))!;
    expect(saved.values['title'], 'Laptop');
    expect(saved.schemaVersion, 2);
    expect((await store.getExtension(_moduleId))!.version, '0.1.1');
  });

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
