import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/ventio_native_client.dart';

void main() {
  late Directory directory;
  late String databasePath;
  late LocalCommandQueue queue;

  final fixedTime = DateTime.utc(2026, 10, 24, 1);

  Future<Map<String, dynamic>> readFixture(String path) async {
    return jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
  }

  Future<CommandEnvelope> maintenanceEnvelope() async {
    return CommandEnvelope.fromJson(
      await readFixture(
        '../../spec/v1.2/examples/create_maintenance_command.json',
      ),
    );
  }

  Future<void> reopenQueue() async {
    await queue.close();
    queue = await LocalCommandQueue.open(
      factory: databaseFactoryFfi,
      path: databasePath,
      clock: () => fixedTime,
    );
  }

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ventio_queue_test_');
    databasePath = '${directory.path}${Platform.pathSeparator}client.sqlite3';
    queue = await LocalCommandQueue.open(
      factory: databaseFactoryFfi,
      path: databasePath,
      clock: () => fixedTime,
    );
  });

  tearDown(() async {
    await queue.close();
    await directory.delete(recursive: true);
  });

  test(
    'Core command and Host receipt examples remain wire-compatible',
    () async {
      final envelopeJson = await readFixture(
        '../../spec/v1.2/examples/create_maintenance_command.json',
      );
      final envelope = CommandEnvelope.fromJson(envelopeJson);
      expect(envelope.type, 'maintenance.create');
      expect(canonicalJson(envelope.original), canonicalJson(envelopeJson));

      final acceptedJson = await readFixture(
        '../../spec/v1.2/examples/accepted_receipt.json',
      );
      final receipt = CommandReceipt.fromJson(acceptedJson);
      expect(receipt.accepted, isTrue);
      expect(canonicalJson(receipt.toJson()), canonicalJson(acceptedJson));
    },
  );

  test(
    'Original envelope, ID, and pending state survive close and reopen',
    () async {
      final envelope = await maintenanceEnvelope();
      await queue.enqueue(envelope);

      await reopenQueue();
      final restored = await queue.getById(envelope.commandId);

      expect(restored, isNotNull);
      expect(restored!.envelope.commandId, envelope.commandId);
      expect(
        canonicalJson(restored.envelope.original),
        canonicalJson(envelope.original),
      );
      expect(restored.hostStatus, HostCommandStatus.pending);
      expect(restored.isHostConfirmed, isFalse);
      expect(restored.hostReceipt, isNull);
    },
  );

  test(
    'Generic delete intent survives queue restart as a provisional command',
    () async {
      final command = ExtensionRecordCommand.delete(
        commandId: '00000000-0000-4000-8000-000000000036',
        tenantId: 'tenant-west',
        companyId: 'company-west',
        branchId: 'branch-7',
        recordId: 'inventory-move-1',
        expectedRevision: 7,
        actorId: 'operator-1',
        deviceId: 'desktop-1',
        moduleId: 'com.example.inventory',
        moduleVersion: '1.0.0',
        docType: 'InventoryMove',
        schemaVersion: 1,
      );
      await queue.enqueue(command.envelope);

      await reopenQueue();
      final restored = await queue.getById(command.envelope.commandId);

      expect(restored, isNotNull);
      expect(restored!.envelope.type, ExtensionRecordCommand.deleteType);
      expect(restored.envelope.expectedRevision, 7);
      expect(restored.hostStatus, HostCommandStatus.pending);
      expect(restored.isHostConfirmed, isFalse);
      expect(restored.hostReceipt, isNull);
    },
  );

  test(
    'Child rows stay inside the parent command after queue restart',
    () async {
      const lines = [
        {'itemCode': 'B-2', 'quantity': 3.0},
        {'itemCode': 'A-1', 'quantity': 2.5},
      ];
      final command = ExtensionRecordCommand.create(
        commandId: 'c03a0000-0000-4000-8000-000000000001',
        tenantId: 'tenant-west',
        companyId: 'company-west',
        branchId: 'branch-7',
        recordId: 'order-1',
        actorId: 'operator-1',
        deviceId: 'desktop-1',
        moduleId: 'com.example.orders',
        moduleVersion: '1.0.0',
        docType: 'Order',
        schemaVersion: 1,
        values: const {'lines': lines},
      );
      await queue.enqueue(command.envelope);

      await reopenQueue();
      final restored = await queue.getById(command.envelope.commandId);
      expect(restored, isNotNull);
      expect(restored!.hostStatus, HostCommandStatus.pending);
      expect(
        canonicalJson(
          (restored.envelope.payload['values']
              as Map<String, dynamic>)['lines'],
        ),
        canonicalJson(lines),
      );
    },
  );

  test('Duplicate command IDs cannot overwrite the original intent', () async {
    final original = await maintenanceEnvelope();
    await queue.enqueue(original);

    final conflictingJson = Map<String, dynamic>.from(original.original);
    conflictingJson['payload'] = {
      ...Map<String, dynamic>.from(original.payload),
      'problemDescription': 'Changed after the original ID was queued',
    };
    final conflicting = CommandEnvelope.fromJson(conflictingJson);
    await expectLater(
      queue.enqueue(conflicting),
      throwsA(isA<DuplicateCommandIdException>()),
    );

    final rows = await queue.list();
    expect(rows, hasLength(1));
    expect(
      rows.single.envelope.payload['problemDescription'],
      original.payload['problemDescription'],
    );
  });

  test('Unresolved extension commands block removal of their module', () async {
    final command = ExtensionRecordCommand.create(
      commandId: '00000000-0000-4000-8000-000000000001',
      tenantId: 'tenant-west',
      companyId: 'company-west',
      branchId: 'branch-7',
      recordId: 'inventory-move-1',
      actorId: 'operator-1',
      deviceId: 'desktop-1',
      moduleId: 'com.example.inventory',
      moduleVersion: '1.0.0',
      docType: 'InventoryMove',
      schemaVersion: 1,
      values: const {'reference': 'MOVE-0001'},
    );
    await queue.enqueue(command.envelope);

    expect(
      await queue.hasUnresolvedCommandsForModule('com.example.inventory'),
      isTrue,
    );
    expect(
      await queue.hasUnresolvedCommandsForModule('com.example.catalog'),
      isFalse,
    );
  });

  test('Restart after an interrupted send keeps the command pending', () async {
    final envelope = await maintenanceEnvelope();
    await queue.enqueue(envelope);
    await queue.recordAttempt(envelope.commandId);

    // Closing at this boundary models the app stopping after dispatch started,
    // before any response or receipt was persisted.
    await reopenQueue();
    final restored = (await queue.getById(envelope.commandId))!;
    expect(restored.attemptCount, 1);
    expect(restored.hostStatus, HostCommandStatus.pending);
    expect(restored.hostReceipt, isNull);
  });

  test(
    'Abrupt child-process exit preserves the pending command for recovery',
    () async {
      final envelope = await maintenanceEnvelope();
      await queue.enqueue(envelope);
      await queue.close();
      final child = await Process.run(_dartRuntimeExecutable(), [
        'run',
        'test/support/crash_after_attempt.dart',
        databasePath,
        envelope.commandId,
      ], workingDirectory: Directory.current.path);
      expect(child.exitCode, 73, reason: '${child.stdout}\n${child.stderr}');

      queue = await LocalCommandQueue.open(
        factory: databaseFactoryFfi,
        path: databasePath,
        clock: () => fixedTime,
      );
      final restored = (await queue.getById(envelope.commandId))!;
      expect(restored.attemptCount, 1);
      expect(restored.hostStatus, HostCommandStatus.pending);
      expect(restored.hostReceipt, isNull);
    },
  );

  test(
    'Fixture receipt persists separately and never confirms Host acceptance',
    () async {
      final envelope = await maintenanceEnvelope();
      await queue.enqueue(envelope);
      await queue.recordAttempt(envelope.commandId);
      final response = await const DeterministicTransportFixture().send(
        envelope,
      );
      expect(response.apiVersion, hostApiVersion);
      expect(response.source, TransportSource.fixture);
      await queue.recordFixtureReceipt(envelope.commandId, response);

      await reopenQueue();
      final restored = (await queue.getById(envelope.commandId))!;
      expect(restored.fixtureReceipt?.accepted, isTrue);
      expect(restored.hostStatus, HostCommandStatus.pending);
      expect(restored.hostReceipt, isNull);
      expect(restored.isHostConfirmed, isFalse);
    },
  );

  test('A fixture receipt for another command ID is rejected', () async {
    final envelope = await maintenanceEnvelope();
    await queue.enqueue(envelope);
    final validReceipt = await const DeterministicTransportFixture().send(
      envelope,
    );
    final alteredReceipt = Map<String, dynamic>.from(validReceipt.receipt)
      ..['commandId'] = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final receipt = TransportResponse(
      apiVersion: validReceipt.apiVersion,
      source: validReceipt.source,
      receipt: alteredReceipt,
    );

    await expectLater(
      queue.recordFixtureReceipt(envelope.commandId, receipt),
      throwsA(isA<FormatException>()),
    );
    final restored = (await queue.getById(envelope.commandId))!;
    expect(restored.fixtureReceipt, isNull);
    expect(restored.hostStatus, HostCommandStatus.pending);
  });

  test('Only a Host response can resolve queue status', () async {
    final envelope = await maintenanceEnvelope();
    await queue.enqueue(envelope);
    final service = HostSyncService(
      queue: queue,
      transport: const DeterministicTransportFixture(),
      identity: _syncIdentity(envelope),
    );

    await expectLater(service.syncPending(), throwsA(isA<FormatException>()));
    final stillPending = (await queue.getById(envelope.commandId))!;
    expect(stillPending.attemptCount, 1);
    expect(stillPending.hostStatus, HostCommandStatus.pending);
    expect(stillPending.hostReceipt, isNull);
    expect(stillPending.fixtureReceipt, isNull);
  });

  test('Host receipts resolve commands idempotently', () async {
    final envelope = await maintenanceEnvelope();
    await queue.enqueue(envelope);
    final receipt = _hostResponse(envelope, 'ACCEPTED');
    final service = HostSyncService(
      queue: queue,
      transport: _TestHostTransport((_) async => receipt),
      identity: _syncIdentity(envelope),
    );

    expect(await service.syncPending(), 1);
    final accepted = (await queue.getById(envelope.commandId))!;
    expect(accepted.hostStatus, HostCommandStatus.accepted);
    expect(accepted.isHostConfirmed, isTrue);
    expect(accepted.fixtureReceipt, isNull);

    await queue.recordHostReceipt(envelope.commandId, receipt);
    expect(
      (await queue.getById(envelope.commandId))!.hostStatus,
      HostCommandStatus.accepted,
    );
    await expectLater(
      queue.recordAttempt(envelope.commandId),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'RETRY_LATER receipts keep the same command eligible for retry',
    () async {
      final envelope = await maintenanceEnvelope();
      await queue.enqueue(envelope);
      var attempt = 0;
      final service = HostSyncService(
        queue: queue,
        identity: _syncIdentity(envelope),
        transport: _TestHostTransport((_) async {
          attempt++;
          return _hostResponse(
            envelope,
            attempt == 1 ? 'RETRY_LATER' : 'ACCEPTED',
          );
        }),
      );

      expect(await service.syncPending(), 1);
      final retryable = (await queue.getById(envelope.commandId))!;
      expect(retryable.hostStatus, HostCommandStatus.retryLater);
      expect(retryable.isPending, isTrue);

      expect(await service.syncPending(), 1);
      final accepted = (await queue.getById(envelope.commandId))!;
      expect(accepted.attemptCount, 2);
      expect(accepted.hostStatus, HostCommandStatus.accepted);
      expect(accepted.isHostConfirmed, isTrue);
    },
  );

  test(
    'A different Host identity or scope cannot attempt queued work',
    () async {
      final envelope = await maintenanceEnvelope();
      await queue.enqueue(envelope);
      var sends = 0;
      final mismatches = [
        HostSyncIdentity(
          tenantId: 'another-tenant',
          companyId: envelope.companyId,
          branchId: envelope.branchId,
          actorId: envelope.actorId,
          deviceId: envelope.deviceId,
        ),
        HostSyncIdentity(
          tenantId: envelope.tenantId,
          companyId: 'another-company',
          branchId: envelope.branchId,
          actorId: envelope.actorId,
          deviceId: envelope.deviceId,
        ),
        HostSyncIdentity(
          tenantId: envelope.tenantId,
          companyId: envelope.companyId,
          branchId: 'another-branch',
          actorId: envelope.actorId,
          deviceId: envelope.deviceId,
        ),
        HostSyncIdentity(
          tenantId: envelope.tenantId,
          companyId: envelope.companyId,
          branchId: envelope.branchId,
          actorId: 'another-user',
          deviceId: envelope.deviceId,
        ),
        HostSyncIdentity(
          tenantId: envelope.tenantId,
          companyId: envelope.companyId,
          branchId: envelope.branchId,
          actorId: envelope.actorId,
          deviceId: 'another-device',
        ),
      ];

      for (final identity in mismatches) {
        await expectLater(
          HostSyncService(
            queue: queue,
            identity: identity,
            transport: _TestHostTransport((_) async {
              sends++;
              return _hostResponse(envelope, 'ACCEPTED');
            }),
          ).syncPending(),
          throwsA(isA<HostSyncIdentityMismatchException>()),
        );
      }
      final pending = (await queue.getById(envelope.commandId))!;
      expect(sends, 0);
      expect(pending.attemptCount, 0);
      expect(pending.hostStatus, HostCommandStatus.pending);
      expect(pending.hostReceipt, isNull);
    },
  );
}

HostSyncIdentity _syncIdentity(CommandEnvelope envelope) => HostSyncIdentity(
  tenantId: envelope.tenantId,
  companyId: envelope.companyId,
  branchId: envelope.branchId,
  actorId: envelope.actorId,
  deviceId: envelope.deviceId,
);

TransportResponse _hostResponse(CommandEnvelope envelope, String status) {
  final accepted = status == 'ACCEPTED';
  return TransportResponse(
    apiVersion: hostApiVersion,
    source: TransportSource.host,
    receipt: CommandReceipt(
      commandId: envelope.commandId,
      status: status,
      serverTimestamp: _hostServerTime.toIso8601String(),
      reasonCode: accepted ? null : 'DEPENDENCY_PENDING',
      messageKey: accepted ? null : 'core.error.dependency_pending',
      hostRevision: accepted ? 1 : null,
      scopeCursor: accepted ? 'host-cursor-1' : null,
      output: accepted ? {'serverRecordId': envelope.aggregateId} : null,
    ).toJson(),
  );
}

class _TestHostTransport implements CommandTransport {
  const _TestHostTransport(this.handler);

  final Future<TransportResponse> Function(CommandEnvelope) handler;

  @override
  int get apiVersion => hostApiVersion;

  @override
  Future<TransportResponse> send(CommandEnvelope envelope) => handler(envelope);
}

final _hostServerTime = DateTime.utc(2026, 10, 24, 1);

String _dartRuntimeExecutable() {
  final resolved = Platform.resolvedExecutable;
  final executableName = resolved
      .split(Platform.pathSeparator)
      .last
      .toLowerCase();
  if (executableName == (Platform.isWindows ? 'dart.exe' : 'dart')) {
    return resolved;
  }

  final pathEntries = (Platform.environment['PATH'] ?? '').split(
    Platform.isWindows ? ';' : ':',
  );
  for (final entry in pathEntries) {
    final candidate = Platform.isWindows
        ? '$entry${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}dart.exe'
        : '$entry${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}dart';
    if (File(candidate).existsSync()) return candidate;
  }

  return Platform.isWindows ? 'dart.exe' : 'dart';
}
