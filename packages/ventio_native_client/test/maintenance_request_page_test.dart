import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_native_client/src/maintenance_request_page.dart';
import 'package:ventio_native_client/ventio_native_client.dart';

void main() {
  late Directory directory;
  late LocalCommandQueue queue;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ventio_page_test_');
    queue = await LocalCommandQueue.open(
      factory: databaseFactoryFfi,
      path: '${directory.path}${Platform.pathSeparator}client.sqlite3',
    );
  });

  tearDown(() async {
    await queue.close();
    await directory.delete(recursive: true);
  });

  testWidgets('Maintenance form saves a visibly pending local request', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MaintenanceRequestPage(
          queue: queue,
          transport: const DeterministicTransportFixture(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Sample Customer');
    await tester.enterText(fields.at(1), 'Sample Laptop');
    await tester.enterText(fields.at(2), 'Battery does not charge');
    await tester.tap(find.text('Save locally'));
    await tester.pumpAndSettle();

    expect(find.text('Pending'), findsOneWidget);
    expect(find.textContaining('Host has not accepted'), findsOneWidget);
    final entries = await queue.list();
    expect(entries, hasLength(1));
    expect(entries.single.isPending, isTrue);
    expect(entries.single.isHostConfirmed, isFalse);
  });
}
