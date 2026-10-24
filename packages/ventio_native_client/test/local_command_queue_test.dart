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
      await queue.close();
      final child = await Process.run(
        Platform.isWindows ? 'dart.exe' : 'dart',
        [
          'test/support/crash_after_attempt.dart',
          databasePath,
          jsonEncode(envelope.original),
        ],
        workingDirectory: Directory.current.path,
      );
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
}
