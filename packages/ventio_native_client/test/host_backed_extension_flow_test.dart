import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/ventio_native_client.dart';
import 'package:ventio_native_client/src/command_id.dart';

class _MemoryCredentialBackend implements HostCredentialBackend {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

void main() {
  final environment = Platform.environment;
  final endpointText = environment['VENTIO_CLIENT_HOST_ENDPOINT'];
  final writerToken = environment['VENTIO_CLIENT_HOST_WRITER_TOKEN'];
  final readerToken = environment['VENTIO_CLIENT_HOST_READER_TOKEN'];
  final tenantId = environment['VENTIO_CLIENT_HOST_TENANT'];
  final companyId = environment['VENTIO_CLIENT_HOST_COMPANY'];
  final branchId = environment['VENTIO_CLIENT_HOST_BRANCH'];
  const moduleId = 'com.example.windows_records';
  const docType = 'Item';
  const firstVersion = '1.0.0';
  const upgradedVersion = '1.0.1';

  setUpAll(sqfliteFfiInit);

  test(
    'real Host accepts offline client writes and serves the upgraded package to another device',
    () async {
      final endpoint = Uri.parse(endpointText!);
      final firstDirectory = await Directory.systemTemp.createTemp(
        'ventio-host-client-one-',
      );
      final secondDirectory = await Directory.systemTemp.createTemp(
        'ventio-host-client-two-',
      );
      final firstDatabasePath =
          '${firstDirectory.path}${Platform.pathSeparator}client.sqlite3';
      final firstQueuePath =
          '${firstDirectory.path}${Platform.pathSeparator}queue.sqlite3';
      final secondDatabasePath =
          '${secondDirectory.path}${Platform.pathSeparator}client.sqlite3';

      LocalExtensionStore? firstStore;
      LocalExtensionStore? secondStore;
      LocalCommandQueue? firstQueue;
      try {
        final firstVault = HostCredentialVault(_MemoryCredentialBackend());
        await firstVault.save(endpoint, writerToken!);
        final firstPackageClient = HostExtensionPackageClient(
          endpoint: endpoint,
          credentials: firstVault,
        );
        final firstSession = await firstPackageClient.session();
        expect(firstSession.tenantId, tenantId);
        expect(firstSession.persistent, isTrue);
        expect(firstSession.scopes, hasLength(1));
        expect(firstSession.scopes.single.companyId, companyId);
        expect(firstSession.scopes.single.branchId, branchId);

        final initialBundle = await firstPackageClient.readApproved(
          moduleId: moduleId,
          version: firstVersion,
          companyId: companyId!,
          branchId: branchId!,
        );
        firstStore = await LocalExtensionStore.open(
          factory: databaseFactoryFfi,
          path: firstDatabasePath,
        );
        firstQueue = await LocalCommandQueue.open(
          factory: databaseFactoryFfi,
          path: firstQueuePath,
        );
        await firstStore.installBundle(initialBundle);
        await firstStore.activate(moduleId);

        final scope = RecordScope(
          organizationId: tenantId!,
          companyId: companyId,
          branchId: branchId,
        );
        const recordId = 'native-client-offline-record';
        final provisional = await firstStore.createRecord(
          moduleId: moduleId,
          docTypeName: docType,
          scope: scope,
          values: const {'title': 'Created while offline'},
          recordId: recordId,
        );
        final commandId = createCommandId();
        final command = ExtensionRecordCommand.create(
          commandId: commandId,
          tenantId: firstSession.tenantId,
          companyId: companyId,
          branchId: branchId,
          recordId: recordId,
          actorId: firstSession.actorId,
          deviceId: firstSession.deviceId,
          moduleId: moduleId,
          moduleVersion: firstVersion,
          docType: docType,
          schemaVersion: initialBundle.docTypes.single.schemaVersion,
          values: provisional.values,
        );
        await firstQueue.enqueue(command.envelope);
        await firstStore.markRecordPending(
          recordId: recordId,
          scope: scope,
          commandId: commandId,
        );

        final unavailableEndpoint = Uri.parse('http://127.0.0.1:1');
        final offlineVault = HostCredentialVault(_MemoryCredentialBackend());
        await offlineVault.save(unavailableEndpoint, writerToken);
        await expectLater(
          HostSyncService(
            queue: firstQueue,
            transport: HttpHostCommandTransport(
              endpoint: unavailableEndpoint,
              credentials: offlineVault,
              timeout: const Duration(seconds: 3),
            ),
          ).syncPending(),
          throwsA(
            isA<HostTransportException>().having(
              (error) => error.retryable,
              'retryable',
              isTrue,
            ),
          ),
        );
        final stillPending = (await firstQueue.list()).single;
        expect(stillPending.envelope.commandId, commandId);
        expect(stillPending.isPending, isTrue);
        expect(stillPending.attemptCount, 1);

        final resolved = await HostSyncService(
          queue: firstQueue,
          transport: HttpHostCommandTransport(
            endpoint: endpoint,
            credentials: firstVault,
          ),
        ).syncPending();
        expect(resolved, 1);
        final receipt = (await firstQueue.list()).single.hostReceipt!;
        expect(receipt.status, 'ACCEPTED');
        expect(receipt.hostRevision, 1);
        await firstStore.applyHostReceipt(
          recordId: recordId,
          scope: scope,
          commandId: commandId,
          receipt: receipt,
        );
        final acceptedLocal = await firstStore.getRecord(
          moduleId: moduleId,
          docTypeName: docType,
          recordId: recordId,
          scope: scope,
        );
        expect(acceptedLocal?.authorityState, 'HOST_ACCEPTED');
        expect(acceptedLocal?.hostRevision, 1);

        final secondVault = HostCredentialVault(_MemoryCredentialBackend());
        await secondVault.save(endpoint, readerToken!);
        final secondPackageClient = HostExtensionPackageClient(
          endpoint: endpoint,
          credentials: secondVault,
        );
        final secondSession = await secondPackageClient.session();
        expect(secondSession.deviceId, isNot(firstSession.deviceId));
        final secondBundle = await secondPackageClient.readApproved(
          moduleId: moduleId,
          version: firstVersion,
          companyId: companyId,
          branchId: branchId,
        );
        secondStore = await LocalExtensionStore.open(
          factory: databaseFactoryFfi,
          path: secondDatabasePath,
        );
        await secondStore.installBundle(secondBundle);
        await secondStore.activate(moduleId);
        final hostPage = await secondPackageClient.queryRecords(
          companyId: companyId,
          branchId: branchId,
          moduleId: moduleId,
          version: firstVersion,
          docType: docType,
          recordId: recordId,
          limit: 1,
        );
        expect(hostPage.records, hasLength(1));
        expect(hostPage.records.single.revision, 1);
        expect(
          hostPage.records.single.values['title'],
          'Created while offline',
        );
        final hostRecord = hostPage.records.single;
        await secondStore.applyHostRecord(
          moduleId: moduleId,
          docTypeName: docType,
          scope: scope,
          recordId: hostRecord.recordId,
          revision: hostRecord.revision,
          values: hostRecord.values,
          updatedAtUtc: DateTime.parse(hostRecord.updatedAtUtc),
        );
        final secondDeviceCopy = await secondStore.getRecord(
          moduleId: moduleId,
          docTypeName: docType,
          recordId: recordId,
          scope: scope,
        );
        expect(secondDeviceCopy?.authorityState, 'HOST_ACCEPTED');
        expect(secondDeviceCopy?.hostRevision, 1);

        final upgradedBundle = await secondPackageClient.readApproved(
          moduleId: moduleId,
          version: upgradedVersion,
          companyId: companyId,
          branchId: branchId,
        );
        await firstStore.disable(moduleId);
        await firstStore.installBundle(upgradedBundle);
        await firstStore.activate(moduleId);
        await secondStore.disable(moduleId);
        await secondStore.installBundle(upgradedBundle);
        await secondStore.activate(moduleId);

        final upgradedHostPage = await secondPackageClient.queryRecords(
          companyId: companyId,
          branchId: branchId,
          moduleId: moduleId,
          version: upgradedVersion,
          docType: docType,
          recordId: recordId,
          limit: 1,
        );
        expect(upgradedHostPage.records.single.revision, 1);
        expect(
          upgradedHostPage.records.single.values['title'],
          'Created while offline',
        );
        for (final store in [firstStore, secondStore]) {
          final record = await store.getRecord(
            moduleId: moduleId,
            docTypeName: docType,
            recordId: recordId,
            scope: scope,
          );
          expect(record?.values['title'], 'Created while offline');
          expect(record?.hostRevision, 1);
        }

        await firstQueue.close();
        firstQueue = null;
        await firstStore.close();
        firstStore = await LocalExtensionStore.open(
          factory: databaseFactoryFfi,
          path: firstDatabasePath,
        );
        final reopenedExtension = await firstStore.getExtension(moduleId);
        final reopenedRecord = await firstStore.getRecord(
          moduleId: moduleId,
          docTypeName: docType,
          recordId: recordId,
          scope: scope,
        );
        expect(reopenedExtension?.version, upgradedVersion);
        expect(reopenedRecord?.values['title'], 'Created while offline');
        expect(reopenedRecord?.authorityState, 'HOST_ACCEPTED');
      } finally {
        await firstQueue?.close();
        await firstStore?.close();
        await secondStore?.close();
        await firstDirectory.delete(recursive: true);
        await secondDirectory.delete(recursive: true);
      }
    },
    skip:
        endpointText == null ||
            writerToken == null ||
            readerToken == null ||
            tenantId == null ||
            companyId == null ||
            branchId == null
        ? 'Requires the real Windows Host process integration runner.'
        : null,
  );
}
