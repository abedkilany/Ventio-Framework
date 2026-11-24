import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/main.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/local_command_queue.dart';

class _Backend implements HostCredentialBackend {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory directory;
  late LocalExtensionStore store;
  late LocalCommandQueue queue;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ventio-account-gate-');
    store = await LocalExtensionStore.open(
      factory: databaseFactoryFfiNoIsolate,
      path: '${directory.path}/extensions.sqlite3',
    );
    queue = await LocalCommandQueue.open(
      factory: databaseFactoryFfiNoIsolate,
      path: '${directory.path}/commands.sqlite3',
    );
  });
  tearDown(() async {
    await queue.close();
    await store.close();
    await directory.delete(recursive: true);
  });
  testWidgets(
    'A retained profile opens at sign-in and keeps queued SQLite work intact',
    (tester) async {
      await tester.runAsync(() async {
        await store.saveHostProfile(
          HostConnectionProfile(
            endpoint: 'https://host.example',
            tenantId: 'tenant-1',
            companyId: 'company-1',
            branchId: 'branch-1',
            actorId: 'user-1',
            deviceId: 'device-1',
          ),
        );
        await queue.enqueue(
          CommandEnvelope.fromJson({
            'protocolVersion': 0,
            'commandId': '00e0ca03-e259-4958-87fc-69fd40e23f11',
            'type': 'extension.example.create',
            'typeVersion': 1,
            'tenantId': 'tenant-1',
            'companyId': 'company-1',
            'branchId': 'branch-1',
            'aggregateId': 'pending-record',
            'expectedRevision': null,
            'dependsOn': <String>[],
            'payload': {'name': 'Retained pending work'},
            'clientContext': {
              'deviceId': 'device-1',
              'actorId': 'user-1',
              'moduleVersion': '0.1.0',
              'docTypeVersion': 1,
              'clientTimestamp': '2026-11-24T10:00:00Z',
            },
          }),
        );
      });
      await tester.pumpWidget(
        VentioClientApp(
          queue: queue,
          extensionStore: store,
          credentialVault: HostCredentialVault(_Backend()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Organization sign in'), findsOneWidget);
      expect(find.text('Ventio Extension Builder'), findsNothing);
      await tester.runAsync(() async {
        expect(
          (await queue.list()).single.hostStatus,
          HostCommandStatus.pending,
        );
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await queue.close();
        await store.close();
        store = await LocalExtensionStore.open(
          factory: databaseFactoryFfiNoIsolate,
          path: '${directory.path}/extensions.sqlite3',
        );
        queue = await LocalCommandQueue.open(
          factory: databaseFactoryFfiNoIsolate,
          path: '${directory.path}/commands.sqlite3',
        );
        expect((await store.getHostProfile())?.actorId, 'user-1');
        expect(
          (await queue.list()).single.envelope.payload['name'],
          'Retained pending work',
        );
      });
    },
  );
}
