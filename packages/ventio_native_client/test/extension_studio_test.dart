import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/extension_studio_page.dart';
import 'package:ventio_native_client/src/local_command_queue.dart';

void main() {
  late Directory directory;
  late LocalExtensionStore store;
  late LocalCommandQueue queue;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ventio_studio_test_');
    store = await LocalExtensionStore.open(
      factory: databaseFactoryFfiNoIsolate,
      path: '${directory.path}${Platform.pathSeparator}extensions.sqlite3',
    );
    queue = await LocalCommandQueue.open(
      factory: databaseFactoryFfiNoIsolate,
      path: '${directory.path}${Platform.pathSeparator}commands.sqlite3',
    );
  });

  tearDown(() async {
    await queue.close();
    await store.close();
    await directory.delete(recursive: true);
  });

  testWidgets(
    'Builder creates, previews, activates and runs a generated DocType',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: ExtensionStudioPage(store: store, queue: queue),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create your first extension'));
      await tester.pumpAndSettle();
      var fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'com.example.asset_register');
      await tester.enterText(fields.at(1), 'Asset Register');
      await tester.enterText(fields.at(2), 'Track equipment by branch.');
      await tester.tap(find.text('Create draft'));
      await tester.pumpAndSettle();

      expect(find.text('Asset Register'), findsWidgets);
      await tester.tap(find.text('Add DocType'));
      await tester.pumpAndSettle();
      fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'Asset');
      await tester.enterText(fields.at(1), 'Asset');
      await tester.enterText(fields.at(2), 'An asset assigned to a branch.');
      await tester.tap(find.text('Add field'));
      await tester.pumpAndSettle();
      fields = find.byType(TextFormField);
      await tester.enterText(fields.at(3), 'name');
      await tester.enterText(fields.at(4), 'Name');
      await tester.ensureVisible(find.text('Save field'));
      await tester.tap(find.text('Save field'));
      await tester.pumpAndSettle();
      expect(find.text('Save field'), findsNothing);
      await tester.ensureVisible(find.text('Save DocType'));
      await tester.tap(find.text('Save DocType'));
      await tester.pumpAndSettle();

      expect(find.text('Asset · operational DocType'), findsOneWidget);
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.text('Generated list view'), findsOneWidget);
      await tester.tap(find.text('Open generated form'));
      await tester.pumpAndSettle();
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Preview only'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Activate on device'));
      await tester.pumpAndSettle();
      expect(find.text('ACTIVE_LOCAL'), findsOneWidget);
      await tester.tap(find.text('Open records'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New record'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'Laptop 42');
      await tester.tap(find.text('Save on device'));
      await tester.pumpAndSettle();

      expect(find.text('Laptop 42'), findsOneWidget);
      final records = await store.listRecords(
        moduleId: 'com.example.asset_register',
        docTypeName: 'Asset',
        scope: const RecordScope(
          organizationId: 'local-organization',
          companyId: 'local-company',
          branchId: 'local-branch',
        ),
      );
      expect(records, hasLength(1));
      expect(records.single.values['name'], 'Laptop 42');
      expect(records.single.syncState, 'LOCAL_ONLY');
    },
  );

  testWidgets('Builder saves an explicitly selected extension dependency', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await store.createExtension(
      moduleId: 'com.example.shared_catalog',
      displayName: 'Shared Catalog',
      description: 'A local dependency.',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionStudioPage(store: store, queue: queue),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('New extension'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'com.example.catalog_client');
    await tester.enterText(fields.at(1), 'Catalog Client');
    await tester.enterText(fields.at(2), 'Uses the shared catalog.');
    await tester.enterText(fields.at(3), '1.2.3');
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.tap(find.text('Create draft'));
    await tester.pumpAndSettle();

    final extension = (await store.getExtension('com.example.catalog_client'))!;
    expect(extension.version, '1.2.3');
    expect(extension.dependencies, {'com.example.shared_catalog': '0.1.0'});
  });

  testWidgets('Generated record list and form fit a phone-sized viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const moduleId = 'com.example.phone_preview';
    final metadata = <String, dynamic>{
      'name': 'Asset',
      'moduleId': moduleId,
      'schemaVersion': 1,
      'kind': 'operational',
      'fields': [
        {
          'name': 'name',
          'type': 'text',
          'required': true,
          'maxLength': 120,
          'label': 'Name',
          'labelKey': 'phone_preview.asset.name',
        },
      ],
      'permissions': {
        'read': 'extension.com_example_phone_preview.asset.read',
        'create': 'extension.com_example_phone_preview.asset.create',
        'update': 'extension.com_example_phone_preview.asset.update',
      },
      'ui': {
        'listColumns': ['name'],
        'formFields': ['name'],
      },
      'label': 'Asset',
      'labelKey': 'phone_preview.asset.label',
    };
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Phone Preview',
      description: '',
    );
    await store.saveDocType(metadata);
    await store.activate(moduleId);

    await tester.pumpWidget(
      MaterialApp(
        home: DynamicDocTypePage(
          store: store,
          moduleId: moduleId,
          metadata: metadata,
          scope: const RecordScope(
            organizationId: 'local-organization',
            companyId: 'local-company',
            branchId: 'local-branch',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('No matching records'), findsOneWidget);

    await tester.tap(find.text('New record'));
    await tester.pumpAndSettle();
    expect(find.text('New Asset'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
