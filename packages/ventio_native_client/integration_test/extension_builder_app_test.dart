import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_native_client/main.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/local_command_queue.dart';

Future<void> _scrollTo(
  WidgetTester tester,
  Finder target, {
  double delta = 240,
}) async {
  final verticalScrollables = find.byWidgetPredicate(
    (widget) =>
        widget is Scrollable && widget.axisDirection == AxisDirection.down,
  );
  final targetCount = target.evaluate().length;
  if (targetCount == 1) {
    await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
    await tester.pumpAndSettle();
    return;
  }
  if (targetCount > 1) {
    throw TestFailure('Expected one matching widget, found $targetCount.');
  }
  final scrollable = verticalScrollables.first;
  final position = tester.state<ScrollableState>(scrollable).position;
  if (position.maxScrollExtent <= position.minScrollExtent) {
    throw TestFailure(
      'Could not find the target on the active screen, and it cannot scroll.',
    );
  }
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: scrollable,
    maxScrolls: 20,
  );
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pumpAndSettle();
}

Future<void> _finishTextEntry(WidgetTester tester) async {
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

Future<void> _waitForWidget(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 60; attempt++) {
    if (target.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(target, findsOneWidget);
}

Future<void> _scrollToTop(WidgetTester tester) async {
  final verticalScrollables = find.byWidgetPredicate(
    (widget) =>
        widget is Scrollable && widget.axisDirection == AxisDirection.down,
  );
  final position = tester
      .state<ScrollableState>(verticalScrollables.first)
      .position;
  if (position.pixels <= position.minScrollExtent) return;
  final animation = position.animateTo(
    position.minScrollExtent,
    duration: const Duration(milliseconds: 150),
    curve: Curves.easeOut,
  );
  await tester.pumpAndSettle();
  await animation;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory testDirectory;
  late String testRootPath;
  late LocalCommandQueue queue;
  late LocalExtensionStore store;

  Future<void> openClientData() async {
    final factory = switch (Platform.operatingSystem) {
      'windows' => () {
        sqfliteFfiInit();
        return databaseFactoryFfi;
      }(),
      'android' => sqflite.databaseFactory,
      _ => throw UnsupportedError(
        'The native Builder acceptance test supports Windows and Android.',
      ),
    };
    queue = await LocalCommandQueue.open(
      factory: factory,
      path: p.join(testDirectory.path, 'ventio_native_client.sqlite3'),
    );
    store = await LocalExtensionStore.open(
      factory: factory,
      path: p.join(testDirectory.path, 'ventio_extensions.sqlite3'),
    );
  }

  setUp(() async {
    final tempRoot = Platform.isAndroid
        ? await getTemporaryDirectory()
        : Directory.systemTemp;
    testRootPath = p.normalize(tempRoot.path);
    testDirectory = await tempRoot.createTemp('ventio_extension_builder_');
    await openClientData();
  });

  tearDown(() async {
    await queue.close();
    await store.close();
    final testRoot = p.normalize(testDirectory.path);
    if (!p.isWithin(testRootPath, testRoot)) {
      throw StateError(
        'Refusing to remove a test directory outside the platform temp root.',
      );
    }
    await testDirectory.delete(recursive: true);
  });

  testWidgets(
    'Native Builder creates, activates, runs and persists a dynamic extension',
    (tester) async {
      await tester.pumpWidget(
        VentioClientApp(queue: queue, extensionStore: store),
      );
      await tester.pumpAndSettle();

      await _scrollTo(tester, find.text('Create your first extension'));
      final createFirstExtension = find.text('Create your first extension');
      if (createFirstExtension.evaluate().isNotEmpty) {
        await tester.tap(createFirstExtension);
      } else {
        await tester.tap(find.text('New extension'));
      }
      await tester.pumpAndSettle();

      var fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'com.example.windows_acceptance');
      await tester.enterText(fields.at(1), 'Windows Acceptance');
      await tester.enterText(
        fields.at(2),
        'A native Windows Builder smoke test.',
      );
      await _finishTextEntry(tester);
      await tester.tap(find.text('Create draft'));
      await tester.pumpAndSettle();
      expect(
        await store.getExtension('com.example.windows_acceptance'),
        isNotNull,
      );

      await _waitForWidget(tester, find.text('Add DocType'));
      await _scrollTo(tester, find.text('Add DocType'));
      await tester.tap(find.text('Add DocType'));
      await tester.pumpAndSettle();
      fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'Asset');
      await tester.enterText(fields.at(1), 'Asset');
      await tester.enterText(
        fields.at(2),
        'An asset created through the Builder.',
      );
      await _finishTextEntry(tester);
      await tester.tap(find.text('Add field'));
      await tester.pumpAndSettle();
      fields = find.byType(TextFormField);
      await tester.enterText(fields.at(3), 'name');
      await tester.enterText(fields.at(4), 'Name');
      await _finishTextEntry(tester);
      await tester.ensureVisible(find.text('Save field'));
      await tester.tap(find.text('Save field'));
      await tester.pumpAndSettle();
      expect(find.text('Save field'), findsNothing);
      expect(tester.takeException(), isNull);
      await _scrollTo(tester, find.text('Save DocType'), delta: 300);
      await tester.tap(find.text('Save DocType'));
      await tester.pumpAndSettle();

      await _waitForWidget(tester, find.text('Asset · operational DocType'));
      await _scrollTo(tester, find.text('Preview'));
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.text('Generated list view'), findsOneWidget);
      await tester.tap(find.text('Open generated form'));
      await tester.pumpAndSettle();
      expect(find.text('Name'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      await _scrollTo(tester, find.text('Activate on device'));
      await tester.tap(find.text('Activate on device'));
      await tester.pumpAndSettle();
      expect(
        (await store.getExtension('com.example.windows_acceptance'))?.state,
        ExtensionState.active,
      );
      await _waitForWidget(tester, find.text('Disable on device'));
      await _scrollTo(tester, find.text('Open records'));
      await tester.tap(find.text('Open records'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('New record'));
      await tester.tap(find.text('New record'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'Windows device',
      );
      await _finishTextEntry(tester);
      await _scrollTo(tester, find.text('Save on device'));
      await tester.tap(find.text('Save on device'));
      await tester.pumpAndSettle();
      expect(find.text('Windows device'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await _scrollToTop(tester);
      await _scrollTo(tester, find.text('Disable on device'));
      await tester.tap(find.text('Disable on device'));
      await tester.pumpAndSettle();
      expect(
        (await store.getExtension('com.example.windows_acceptance'))?.state,
        ExtensionState.disabled,
      );
      await _waitForWidget(tester, find.text('Activate on device'));
      await tester.tap(find.text('Activate on device'));
      await tester.pumpAndSettle();
      expect(
        (await store.getExtension('com.example.windows_acceptance'))?.state,
        ExtensionState.active,
      );
      await _waitForWidget(tester, find.text('Disable on device'));

      await _scrollToTop(tester);
      await tester.tap(find.text('Edit extension details'));
      await tester.pumpAndSettle();
      fields = find.byType(TextFormField);
      await tester.enterText(fields.at(3), '0.1.1');
      await _finishTextEntry(tester);
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(
        (await store.getExtension('com.example.windows_acceptance'))?.version,
        '0.1.1',
      );
      final retainedFirstRecords = await store.listRecords(
        moduleId: 'com.example.windows_acceptance',
        docTypeName: 'Asset',
        scope: const RecordScope(
          organizationId: 'local-organization',
          companyId: 'local-company',
          branchId: 'local-branch',
        ),
      );
      expect(retainedFirstRecords.single.values['name'], 'Windows device');

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('New extension'));
      await tester.pumpAndSettle();
      fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'com.example.location_catalog');
      await tester.enterText(fields.at(1), 'Location Catalog');
      await tester.enterText(
        fields.at(2),
        'An independent location extension.',
      );
      await _finishTextEntry(tester);
      await tester.tap(find.text('Create draft'));
      await tester.pumpAndSettle();
      expect(
        await store.getExtension('com.example.location_catalog'),
        isNotNull,
      );

      await _waitForWidget(tester, find.text('Add DocType'));
      await _scrollTo(tester, find.text('Add DocType'));
      await tester.tap(find.text('Add DocType'));
      await tester.pumpAndSettle();
      fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'Site');
      await tester.enterText(fields.at(1), 'Site');
      await tester.enterText(
        fields.at(2),
        'A location maintained independently.',
      );
      await _finishTextEntry(tester);
      await tester.tap(find.text('Add field'));
      await tester.pumpAndSettle();
      fields = find.byType(TextFormField);
      await tester.enterText(fields.at(3), 'code');
      await tester.enterText(fields.at(4), 'Site code');
      await _finishTextEntry(tester);
      await tester.ensureVisible(find.text('Save field'));
      await tester.tap(find.text('Save field'));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Save DocType'), delta: 300);
      await tester.tap(find.text('Save DocType'));
      await tester.pumpAndSettle();
      await _waitForWidget(tester, find.text('Site · operational DocType'));
      await _scrollTo(tester, find.text('Activate on device'));
      await tester.tap(find.text('Activate on device'));
      await tester.pumpAndSettle();
      expect(
        (await store.getExtension('com.example.location_catalog'))?.state,
        ExtensionState.active,
      );
      await _waitForWidget(tester, find.text('Disable on device'));
      await _scrollTo(tester, find.text('Open records'));
      await tester.tap(find.text('Open records'));
      await tester.pumpAndSettle();
      await _waitForWidget(tester, find.text('New record'));
      await _scrollTo(tester, find.text('New record'));
      await tester.tap(find.text('New record'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'NORTH-01');
      await _finishTextEntry(tester);
      await _scrollTo(tester, find.text('Save on device'));
      await tester.tap(find.text('Save on device'));
      await tester.pumpAndSettle();
      expect(find.text('NORTH-01'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await queue.close();
      await store.close();

      await openClientData();
      final extension = await store.getExtension(
        'com.example.windows_acceptance',
      );
      expect(extension?.state.databaseValue, 'ACTIVE_LOCAL');
      expect(extension?.version, '0.1.1');
      expect(
        await store.listDocTypes('com.example.windows_acceptance'),
        hasLength(1),
      );
      final records = await store.listRecords(
        moduleId: 'com.example.windows_acceptance',
        docTypeName: 'Asset',
        scope: const RecordScope(
          organizationId: 'local-organization',
          companyId: 'local-company',
          branchId: 'local-branch',
        ),
      );
      expect(records, hasLength(1));
      expect(records.single.values['name'], 'Windows device');
      final secondExtension = await store.getExtension(
        'com.example.location_catalog',
      );
      expect(secondExtension?.state, ExtensionState.active);
      expect(
        await store.listDocTypes('com.example.location_catalog'),
        hasLength(1),
      );
      final secondRecords = await store.listRecords(
        moduleId: 'com.example.location_catalog',
        docTypeName: 'Site',
        scope: const RecordScope(
          organizationId: 'local-organization',
          companyId: 'local-company',
          branchId: 'local-branch',
        ),
      );
      expect(secondRecords.single.values['code'], 'NORTH-01');

      await tester.pumpWidget(
        VentioClientApp(queue: queue, extensionStore: store),
      );
      await tester.pumpAndSettle();
      await _waitForWidget(tester, find.text('Windows Acceptance'));
      await tester.tap(find.text('Windows Acceptance'));
      await tester.pumpAndSettle();
      await _waitForWidget(tester, find.text('ACTIVE_LOCAL'));
      expect(find.text('Asset · operational DocType'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await _waitForWidget(tester, find.text('Location Catalog'));
      await tester.tap(find.text('Location Catalog'));
      await tester.pumpAndSettle();
      await _waitForWidget(tester, find.text('ACTIVE_LOCAL'));
      expect(find.text('Site · operational DocType'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
