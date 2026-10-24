import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
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
    'Builder exports, reviews and installs a declarative package locally',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const moduleId = 'com.example.package_source';
      const permissionPrefix = 'extension.com_example_package_source.item';
      await store.createExtension(
        moduleId: moduleId,
        displayName: 'Package Source',
        description: 'Portable declarative example.',
      );
      await store.saveDocType({
        'name': 'Item',
        'moduleId': moduleId,
        'schemaVersion': 1,
        'kind': 'operational',
        'fields': [
          {
            'name': 'label',
            'type': 'text',
            'required': true,
            'label': 'Label',
            'labelKey': '$permissionPrefix.label',
            'maxLength': 80,
          },
        ],
        'operations': ['read', 'create', 'update'],
        'permissions': {
          'read': '$permissionPrefix.read',
          'create': '$permissionPrefix.create',
          'update': '$permissionPrefix.update',
        },
        'ui': {
          'listColumns': ['label'],
          'formFields': ['label'],
        },
        'label': 'Item',
        'labelKey': '$permissionPrefix.name',
        'description': 'A portable item definition.',
        'descriptionKey': '$permissionPrefix.description',
      });
      final package = jsonEncode((await store.exportBundle(moduleId)).toJson());
      await store.remove(moduleId);

      await tester.pumpWidget(
        MaterialApp(
          home: ExtensionStudioPage(store: store, queue: queue),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install package'));
      await tester.pumpAndSettle();
      expect(find.text('Install extension package'), findsOneWidget);
      await tester.enterText(find.byType(TextField), package);
      await tester.tap(find.text('Validate package'));
      await tester.pumpAndSettle();

      expect(find.text('Review extension package'), findsOneWidget);
      expect(find.textContaining(moduleId), findsOneWidget);
      expect(find.textContaining('Item'), findsWidgets);
      await tester.tap(find.text('Install on this device'));
      await tester.pumpAndSettle();

      final installed = await store.getExtension(moduleId);
      expect(installed?.state, ExtensionState.draft);
      expect(find.text('Package Source'), findsWidgets);
      expect(find.text('LOCAL ONLY'), findsWidgets);

      await tester.tap(find.byTooltip('Export declarative package'));
      await tester.pumpAndSettle();
      expect(find.text('Declarative extension package'), findsOneWidget);
      expect(find.textContaining(moduleId), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
      await tester.tap(find.text('Add field'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a valid DocType ID before adding fields.'),
        findsOneWidget,
      );
      expect(find.text('Save field'), findsNothing);
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

  testWidgets('Builder saves configured list columns and form order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
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
    await tester.enterText(fields.at(0), 'com.example.configured_layout');
    await tester.enterText(fields.at(1), 'Configured Layout');
    await tester.enterText(fields.at(2), 'A configurable generated layout.');
    await tester.tap(find.text('Create draft'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add DocType'));
    await tester.pumpAndSettle();
    fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'LayoutRecord');
    await tester.enterText(fields.at(1), 'Layout Record');
    await tester.enterText(fields.at(2), 'Test form and list layout.');
    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();
    final fieldDialog = find.byType(AlertDialog);
    fields = find.descendant(
      of: fieldDialog,
      matching: find.byType(TextFormField),
    );
    await tester.enterText(fields.at(0), 'name');
    await tester.enterText(fields.at(1), 'Name');
    await tester.tap(
      find.descendant(of: fieldDialog, matching: find.byType(SwitchListTile)),
    );
    await tester.tap(find.text('Save field'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();
    final noteDialog = find.byType(AlertDialog);
    fields = find.descendant(
      of: noteDialog,
      matching: find.byType(TextFormField),
    );
    await tester.enterText(fields.at(0), 'note');
    await tester.enterText(fields.at(1), 'Note');
    await tester.tap(find.text('Save field'));
    await tester.pumpAndSettle();

    final nameColumn = find.widgetWithText(CheckboxListTile, 'Name').first;
    await tester.ensureVisible(nameColumn);
    await tester.tap(nameColumn);
    await tester.pumpAndSettle();

    for (final operation in ['create', 'update']) {
      final operationToggle = find.widgetWithText(CheckboxListTile, operation);
      await tester.ensureVisible(operationToggle);
      await tester.tap(operationToggle);
      await tester.pumpAndSettle();
    }

    final moveNoteUp = find.byTooltip('Move Note up').last;
    await tester.ensureVisible(moveNoteUp);
    await tester.tap(moveNoteUp);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save DocType'));
    await tester.tap(find.text('Save DocType'));
    await tester.pumpAndSettle();

    final definition = (await store.listDocTypes(
      'com.example.configured_layout',
    )).single;
    final ui = definition['ui'] as Map;
    expect(ui['listColumns'], ['note']);
    expect(ui['formFields'], ['note', 'name']);
    expect(definition['operations'], ['read']);
    expect((definition['permissions'] as Map).keys, ['read']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('The full builder setup flow fits a phone-sized viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionStudioPage(store: store, queue: queue),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Create your first extension'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create your first extension'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    var fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'com.example.phone_extension');
    await tester.enterText(fields.at(1), 'Phone Extension');
    await tester.enterText(fields.at(2), 'Created on a phone-sized screen.');
    await tester.tap(find.text('Create draft'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.text('Add DocType'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Add DocType'));
    await tester.pumpAndSettle();
    fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'PhoneNote');
    await tester.enterText(fields.at(1), 'Phone Note');
    await tester.enterText(fields.at(2), 'A note created from a compact view.');
    await tester.scrollUntilVisible(
      find.text('Add field'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), 'title');
    await tester.enterText(fields.at(2), 'Title');
    tester.binding.focusManager.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save field'));
    await tester.tap(find.text('Save field'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Save DocType'),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Save DocType'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      await store.listDocTypes('com.example.phone_extension'),
      hasLength(1),
    );
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

  testWidgets(
    'Generated forms follow configured order and preserve hidden values',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const moduleId = 'com.example.layout_preview';
      const scope = RecordScope(
        organizationId: 'local-organization',
        companyId: 'local-company',
        branchId: 'local-branch',
      );
      final metadata = <String, dynamic>{
        'name': 'LayoutItem',
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
            'labelKey': 'layout_preview.item.name',
          },
          {
            'name': 'internalNote',
            'type': 'text',
            'required': false,
            'maxLength': 240,
            'label': 'Internal note',
            'labelKey': 'layout_preview.item.internal_note',
          },
          {
            'name': 'flagged',
            'type': 'boolean',
            'required': false,
            'label': 'Flagged',
            'labelKey': 'layout_preview.item.flagged',
          },
        ],
        'permissions': {
          'read': 'extension.com_example_layout_preview.layout_item.read',
          'create': 'extension.com_example_layout_preview.layout_item.create',
          'update': 'extension.com_example_layout_preview.layout_item.update',
        },
        'ui': {
          'listColumns': ['name'],
          'formFields': ['internalNote', 'name'],
        },
        'label': 'Layout item',
        'labelKey': 'layout_preview.item.label',
      };
      await store.createExtension(
        moduleId: moduleId,
        displayName: 'Layout Preview',
        description: '',
      );
      await store.saveDocType(metadata);
      await store.activate(moduleId);
      await store.createRecord(
        moduleId: moduleId,
        docTypeName: 'LayoutItem',
        scope: scope,
        values: {
          'name': 'Before',
          'internalNote': 'Retain this',
          'flagged': true,
        },
        recordId: 'layout-record-1',
      );
      final record = (await store.listRecords(
        moduleId: moduleId,
        docTypeName: 'LayoutItem',
        scope: scope,
      )).single;

      await tester.pumpWidget(
        MaterialApp(
          home: DynamicRecordFormPage(
            store: store,
            moduleId: moduleId,
            definition: DocTypeDefinition.fromJson(metadata),
            scope: scope,
            record: record,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Internal note'), findsOneWidget);
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Flagged'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Internal note')).dy,
        lessThan(tester.getTopLeft(find.text('Name')).dy),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'After',
      );
      await tester.ensureVisible(find.text('Save changes'));
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();

      final updated = (await store.listRecords(
        moduleId: moduleId,
        docTypeName: 'LayoutItem',
        scope: scope,
      )).single;
      expect(updated.values['name'], 'After');
      expect(updated.values['internalNote'], 'Retain this');
      expect(updated.values['flagged'], true);
    },
  );
}
