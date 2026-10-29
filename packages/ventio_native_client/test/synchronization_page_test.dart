import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/app_localization.dart';
import 'package:ventio_native_client/src/host_sync_service.dart';
import 'package:ventio_native_client/src/local_command_queue.dart';
import 'package:ventio_native_client/src/synchronization_page.dart';
import 'package:ventio_native_client/src/transport_fixture.dart';

void main() {
  late Directory directory;
  late LocalCommandQueue queue;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ventio_sync_page_');
    queue = await LocalCommandQueue.open(
      factory: databaseFactoryFfiNoIsolate,
      path: '${directory.path}${Platform.pathSeparator}commands.sqlite3',
      clock: () => DateTime.utc(2026, 10, 29, 18),
    );
  });

  tearDown(() async {
    await queue.close();
    await directory.delete(recursive: true);
  });

  CommandEnvelope makeCommand() => CommandEnvelope.fromJson({
    'protocolVersion': 0,
    'commandId': '25b88df5-6332-41c2-9fb4-81bf7d70f20e',
    'type': 'extension.example.create',
    'typeVersion': 1,
    'tenantId': 'tenant-1',
    'companyId': 'company-1',
    'branchId': 'branch-1',
    'aggregateId': 'record-1',
    'expectedRevision': null,
    'dependsOn': <String>[],
    'payload': <String, Object?>{'name': 'Queued work'},
    'clientContext': <String, Object?>{
      'deviceId': 'device-1',
      'actorId': 'user-1',
      'moduleVersion': '0.1.0',
      'docTypeVersion': 1,
      'clientTimestamp': '2026-10-29T18:00:00Z',
    },
  });

  Widget app({Future<void> Function()? onRetryPending}) => MaterialApp(
    home: VentioLocalizationScope(
      controller: VentioLocalizationController(),
      child: SynchronizationPage(queue: queue, onRetryPending: onRetryPending),
    ),
  );

  testWidgets('Local fixture is never presented as Host confirmation', (
    tester,
  ) async {
    final command = makeCommand();
    await queue.enqueue(command);
    await queue.recordAttempt(command.commandId);
    await queue.recordFixtureReceipt(
      command.commandId,
      await const DeterministicTransportFixture().send(command),
    );

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Host confirmed: 0'), findsOneWidget);
    expect(find.text('Pending: 1'), findsOneWidget);
    expect(find.text('Pending on this device · 1 attempt(s)'), findsOneWidget);
    await tester.tap(find.text('extension.example.create'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not a Host confirmation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Only a stored Host receipt increments confirmed count', (
    tester,
  ) async {
    final command = makeCommand();
    await queue.enqueue(command);
    await queue.recordAttempt(command.commandId);
    await queue.recordHostReceipt(
      command.commandId,
      TransportResponse(
        apiVersion: hostApiVersion,
        source: TransportSource.host,
        receipt: CommandReceipt(
          commandId: command.commandId,
          status: 'ACCEPTED',
          serverTimestamp: '2026-10-29T18:00:00Z',
          hostRevision: 1,
          scopeCursor: 'branch-cursor-1',
          output: {'serverRecordId': command.aggregateId},
        ).toJson(),
      ),
    );

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Host confirmed: 1'), findsOneWidget);
    expect(find.text('Confirmed by Host · 1 attempt(s)'), findsOneWidget);
    expect(find.text('Pending: 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Retry failure shows safe code and correlation reference', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        onRetryPending: () async => throw HostSyncFailureException(
          code: 'HOST_UNAVAILABLE',
          correlationId: 'cor_0123456789abcdef0123456789abcdef',
          retryable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry pending'));
    await tester.pumpAndSettle();

    expect(find.text('Safe error code: HOST_UNAVAILABLE'), findsOneWidget);
    expect(
      find.text('Reference: cor_0123456789abcdef0123456789abcdef'),
      findsOneWidget,
    );
    expect(find.textContaining('remain saved locally'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
