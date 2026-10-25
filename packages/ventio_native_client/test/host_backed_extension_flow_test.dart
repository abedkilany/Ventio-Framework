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
  final trustedCertificate =
      environment['VENTIO_CLIENT_HOST_TRUSTED_CERTIFICATE'];
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
      final secondQueuePath =
          '${secondDirectory.path}${Platform.pathSeparator}queue.sqlite3';

      LocalExtensionStore? firstStore;
      LocalExtensionStore? secondStore;
      LocalCommandQueue? firstQueue;
      LocalCommandQueue? secondQueue;
      try {
        final HttpClient Function()? trustedClientFactory =
            trustedCertificate == null
            ? null
            : () => HttpClient(
                context: SecurityContext(withTrustedRoots: false)
                  ..setTrustedCertificates(trustedCertificate),
              );

        final firstVault = HostCredentialVault(_MemoryCredentialBackend());
        await firstVault.save(endpoint, writerToken!);
        if (trustedCertificate != null) {
          await expectLater(
            HostExtensionPackageClient(
              endpoint: endpoint,
              credentials: firstVault,
            ).session(),
            throwsA(
              isA<HostPackageTransportException>().having(
                (error) => error.code,
                'code',
                'HOST_TLS_VALIDATION_FAILED',
              ),
            ),
          );
        }
        final firstPackageClient = HostExtensionPackageClient(
          endpoint: endpoint,
          credentials: firstVault,
          clientFactory: trustedClientFactory,
        );
        final firstSession = await firstPackageClient.session();
        expect(firstSession.tenantId, tenantId);
        expect(firstSession.persistent, isTrue);
        expect(firstSession.scopes, hasLength(1));
        expect(firstSession.scopes.single.companyId, companyId);
        expect(firstSession.scopes.single.branchId, branchId);

        final registryPage = await firstPackageClient.listApproved(
          companyId: companyId!,
          branchId: branchId!,
          limit: 10,
        );
        final listedRelease = registryPage.packages.singleWhere(
          (package) =>
              package.moduleId == moduleId && package.version == firstVersion,
        );
        expect(registryPage.hasMore, isFalse);
        expect(listedRelease.packageSha256, isNotEmpty);

        final initialBundle = await firstPackageClient.readApproved(
          moduleId: moduleId,
          version: firstVersion,
          companyId: companyId,
          branchId: branchId,
          expectedPackageSha256: listedRelease.packageSha256,
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
        final recordId =
            'native-client-${DateTime.now().microsecondsSinceEpoch}';
        final provisional = await firstStore.createRecord(
          moduleId: moduleId,
          docTypeName: docType,
          scope: scope,
          values: const {'title': 'Created while offline'},
          recordId: recordId,
        );
        final secondVault = HostCredentialVault(_MemoryCredentialBackend());
        await secondVault.save(endpoint, readerToken!);
        final secondPackageClient = HostExtensionPackageClient(
          endpoint: endpoint,
          credentials: secondVault,
          clientFactory: trustedClientFactory,
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
        secondQueue = await LocalCommandQueue.open(
          factory: databaseFactoryFfi,
          path: secondQueuePath,
        );
        await secondStore.installBundle(secondBundle);
        await secondStore.activate(moduleId);
        final upgradedBundle = await secondPackageClient.readApproved(
          moduleId: moduleId,
          version: upgradedVersion,
          companyId: companyId,
          branchId: branchId,
        );
        expect(upgradedBundle.docTypes.single.schemaVersion, 2);
        expect(
          upgradedBundle.docTypes.single.fields.map((field) => field.name),
          containsAll(['title', 'notes']),
        );
        await firstStore.disable(moduleId);
        await firstStore.installBundle(upgradedBundle);
        await firstStore.activate(moduleId);
        await secondStore.disable(moduleId);
        await secondStore.installBundle(upgradedBundle);
        await secondStore.activate(moduleId);

        await expectLater(
          secondPackageClient.queryRecords(
            companyId: companyId,
            branchId: branchId,
            moduleId: moduleId,
            version: firstVersion,
            docType: docType,
            recordId: 'host-item-1',
            limit: 1,
          ),
          throwsA(
            isA<HostPackageTransportException>().having(
              (error) => error.code,
              'code',
              'UPGRADE_REQUIRED',
            ),
          ),
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
          moduleVersion: upgradedVersion,
          docType: docType,
          schemaVersion: upgradedBundle.docTypes.single.schemaVersion,
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
            identity: HostSyncIdentity(
              tenantId: firstSession.tenantId,
              companyId: companyId,
              branchId: branchId,
              actorId: firstSession.actorId,
              deviceId: firstSession.deviceId,
            ),
            transport: HttpHostCommandTransport(
              endpoint: unavailableEndpoint,
              credentials: offlineVault,
              timeout: const Duration(seconds: 3),
              clientFactory: trustedClientFactory,
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
          identity: HostSyncIdentity(
            tenantId: firstSession.tenantId,
            companyId: companyId,
            branchId: branchId,
            actorId: firstSession.actorId,
            deviceId: firstSession.deviceId,
          ),
          transport: HttpHostCommandTransport(
            endpoint: endpoint,
            credentials: firstVault,
            clientFactory: trustedClientFactory,
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
        final hostRecord = upgradedHostPage.records.single;
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
        for (final store in [firstStore, secondStore]) {
          final record = await store.getRecord(
            moduleId: moduleId,
            docTypeName: docType,
            recordId: recordId,
            scope: scope,
          );
          expect(record?.values['title'], 'Created while offline');
          expect(record?.schemaVersion, 2);
          expect(record?.hostRevision, 1);
        }

        final firstDeviceEdit = await firstStore.updateRecord(
          moduleId: moduleId,
          docTypeName: docType,
          recordId: recordId,
          scope: scope,
          expectedRevision: 1,
          values: const {'title': 'First device update'},
        );
        final firstDeviceUpdateId = createCommandId();
        final firstDeviceUpdate = ExtensionRecordCommand.update(
          commandId: firstDeviceUpdateId,
          tenantId: firstSession.tenantId,
          companyId: companyId,
          branchId: branchId,
          recordId: recordId,
          expectedRevision: 1,
          actorId: firstSession.actorId,
          deviceId: firstSession.deviceId,
          moduleId: moduleId,
          moduleVersion: upgradedVersion,
          docType: docType,
          schemaVersion: upgradedBundle.docTypes.single.schemaVersion,
          values: firstDeviceEdit.values,
        );
        await firstQueue.enqueue(firstDeviceUpdate.envelope);
        await firstStore.markRecordPending(
          recordId: recordId,
          scope: scope,
          commandId: firstDeviceUpdateId,
        );
        final firstDeviceSync = await HostSyncService(
          queue: firstQueue,
          identity: HostSyncIdentity(
            tenantId: firstSession.tenantId,
            companyId: companyId,
            branchId: branchId,
            actorId: firstSession.actorId,
            deviceId: firstSession.deviceId,
          ),
          transport: HttpHostCommandTransport(
            endpoint: endpoint,
            credentials: firstVault,
            clientFactory: trustedClientFactory,
          ),
        ).syncPending();
        final firstDeviceReceipt = (await firstQueue.list())
            .singleWhere(
              (entry) => entry.envelope.commandId == firstDeviceUpdateId,
            )
            .hostReceipt!;
        expect(firstDeviceSync, 1);
        expect(firstDeviceReceipt.status, 'ACCEPTED');
        expect(firstDeviceReceipt.hostRevision, 2);
        await firstStore.applyHostReceipt(
          recordId: recordId,
          scope: scope,
          commandId: firstDeviceUpdateId,
          receipt: firstDeviceReceipt,
        );

        final secondDeviceEdit = await secondStore.updateRecord(
          moduleId: moduleId,
          docTypeName: docType,
          recordId: recordId,
          scope: scope,
          expectedRevision: 1,
          values: const {'title': 'Second device draft'},
        );
        final secondDeviceUpdateId = createCommandId();
        final secondDeviceUpdate = ExtensionRecordCommand.update(
          commandId: secondDeviceUpdateId,
          tenantId: secondSession.tenantId,
          companyId: companyId,
          branchId: branchId,
          recordId: recordId,
          expectedRevision: 1,
          actorId: secondSession.actorId,
          deviceId: secondSession.deviceId,
          moduleId: moduleId,
          moduleVersion: upgradedVersion,
          docType: docType,
          schemaVersion: upgradedBundle.docTypes.single.schemaVersion,
          values: secondDeviceEdit.values,
        );
        await secondQueue.enqueue(secondDeviceUpdate.envelope);
        await secondStore.markRecordPending(
          recordId: recordId,
          scope: scope,
          commandId: secondDeviceUpdateId,
        );
        final secondDeviceSync = await HostSyncService(
          queue: secondQueue,
          identity: HostSyncIdentity(
            tenantId: secondSession.tenantId,
            companyId: companyId,
            branchId: branchId,
            actorId: secondSession.actorId,
            deviceId: secondSession.deviceId,
          ),
          transport: HttpHostCommandTransport(
            endpoint: endpoint,
            credentials: secondVault,
            clientFactory: trustedClientFactory,
          ),
        ).syncPending();
        final secondDeviceReceipt =
            (await secondQueue.list()).single.hostReceipt!;
        expect(secondDeviceSync, 1);
        expect(secondDeviceReceipt.status, 'CONFLICT');
        expect(secondDeviceReceipt.currentRevision, 2);
        await secondStore.applyHostReceipt(
          recordId: recordId,
          scope: scope,
          commandId: secondDeviceUpdateId,
          receipt: secondDeviceReceipt,
        );
        var conflictedCopy = (await secondStore.getRecord(
          moduleId: moduleId,
          docTypeName: docType,
          recordId: recordId,
          scope: scope,
        ))!;
        expect(conflictedCopy.authorityState, 'CONFLICT');
        expect(conflictedCopy.values['title'], 'Second device draft');
        expect(conflictedCopy.hostRevision, 2);
        expect(conflictedCopy.conflictValues, isNull);

        final conflictSnapshot = await secondPackageClient.queryRecords(
          companyId: companyId,
          branchId: branchId,
          moduleId: moduleId,
          version: upgradedVersion,
          docType: docType,
          recordId: recordId,
          limit: 1,
        );
        final latestHostRecord = conflictSnapshot.records.single;
        await secondStore.applyHostRecord(
          moduleId: moduleId,
          docTypeName: docType,
          scope: scope,
          recordId: latestHostRecord.recordId,
          revision: latestHostRecord.revision,
          values: latestHostRecord.values,
          updatedAtUtc: DateTime.parse(latestHostRecord.updatedAtUtc),
          readableFields: conflictSnapshot.readableFields,
          writableFields: conflictSnapshot.writableFields,
          creatableFields: conflictSnapshot.creatableFields,
        );
        conflictedCopy = (await secondStore.getRecord(
          moduleId: moduleId,
          docTypeName: docType,
          recordId: recordId,
          scope: scope,
        ))!;
        expect(conflictedCopy.conflictRevision, 2);
        expect(conflictedCopy.conflictValues?['title'], 'First device update');
        expect(conflictedCopy.values['title'], 'Second device draft');

        final reviewedEdit = await secondStore.updateRecord(
          moduleId: moduleId,
          docTypeName: docType,
          recordId: recordId,
          scope: scope,
          expectedRevision: conflictedCopy.revision,
          values: const {'title': 'Reviewed second device merge'},
        );
        final reviewedCommandId = createCommandId();
        final reviewedCommand = ExtensionRecordCommand.update(
          commandId: reviewedCommandId,
          tenantId: secondSession.tenantId,
          companyId: companyId,
          branchId: branchId,
          recordId: recordId,
          expectedRevision: conflictedCopy.conflictRevision!,
          actorId: secondSession.actorId,
          deviceId: secondSession.deviceId,
          moduleId: moduleId,
          moduleVersion: upgradedVersion,
          docType: docType,
          schemaVersion: upgradedBundle.docTypes.single.schemaVersion,
          values: reviewedEdit.values,
        );
        await secondQueue.enqueue(reviewedCommand.envelope);
        await secondStore.markRecordPending(
          recordId: recordId,
          scope: scope,
          commandId: reviewedCommandId,
        );
        final reviewedSync = await HostSyncService(
          queue: secondQueue,
          identity: HostSyncIdentity(
            tenantId: secondSession.tenantId,
            companyId: companyId,
            branchId: branchId,
            actorId: secondSession.actorId,
            deviceId: secondSession.deviceId,
          ),
          transport: HttpHostCommandTransport(
            endpoint: endpoint,
            credentials: secondVault,
            clientFactory: trustedClientFactory,
          ),
        ).syncPending();
        final reviewedReceipt = (await secondQueue.list())
            .singleWhere(
              (entry) => entry.envelope.commandId == reviewedCommandId,
            )
            .hostReceipt!;
        expect(reviewedSync, 1);
        expect(
          reviewedReceipt.status,
          'ACCEPTED',
          reason:
              'Reviewed command expected Host revision ${conflictedCopy.conflictRevision}: ${reviewedReceipt.toJson()}',
        );
        expect(reviewedReceipt.hostRevision, 3);
        await secondStore.applyHostReceipt(
          recordId: recordId,
          scope: scope,
          commandId: reviewedCommandId,
          receipt: reviewedReceipt,
        );

        final finalHostPage = await firstPackageClient.queryRecords(
          companyId: companyId,
          branchId: branchId,
          moduleId: moduleId,
          version: upgradedVersion,
          docType: docType,
          recordId: recordId,
          limit: 1,
        );
        final finalHostRecord = finalHostPage.records.single;
        expect(finalHostRecord.revision, 3);
        expect(finalHostRecord.values['title'], 'Reviewed second device merge');
        final reviewedLocalCopy = await secondStore.getRecord(
          moduleId: moduleId,
          docTypeName: docType,
          recordId: recordId,
          scope: scope,
        );
        expect(reviewedLocalCopy?.authorityState, 'HOST_ACCEPTED');
        expect(reviewedLocalCopy?.hostRevision, 3);
        expect(
          reviewedLocalCopy?.values['title'],
          'Reviewed second device merge',
        );
        await firstStore.applyHostRecord(
          moduleId: moduleId,
          docTypeName: docType,
          scope: scope,
          recordId: finalHostRecord.recordId,
          revision: finalHostRecord.revision,
          values: finalHostRecord.values,
          updatedAtUtc: DateTime.parse(finalHostRecord.updatedAtUtc),
          readableFields: finalHostPage.readableFields,
          writableFields: finalHostPage.writableFields,
          creatableFields: finalHostPage.creatableFields,
        );

        await firstQueue.close();
        firstQueue = null;
        await secondQueue.close();
        secondQueue = null;
        await firstStore.close();
        firstStore = await LocalExtensionStore.open(
          factory: databaseFactoryFfi,
          path: firstDatabasePath,
        );
        await secondStore.close();
        secondStore = await LocalExtensionStore.open(
          factory: databaseFactoryFfi,
          path: secondDatabasePath,
        );
        final reopenedExtension = await firstStore.getExtension(moduleId);
        final reopenedRecord = await firstStore.getRecord(
          moduleId: moduleId,
          docTypeName: docType,
          recordId: recordId,
          scope: scope,
        );
        expect(reopenedExtension?.version, upgradedVersion);
        expect(reopenedRecord?.schemaVersion, 2);
        expect(reopenedRecord?.values['title'], 'Reviewed second device merge');
        expect(reopenedRecord?.authorityState, 'HOST_ACCEPTED');
        expect(reopenedRecord?.hostRevision, 3);
        final reopenedSecondDeviceRecord = await secondStore.getRecord(
          moduleId: moduleId,
          docTypeName: docType,
          recordId: recordId,
          scope: scope,
        );
        expect(reopenedSecondDeviceRecord?.schemaVersion, 2);
        expect(
          reopenedSecondDeviceRecord?.values['title'],
          'Reviewed second device merge',
        );
        expect(reopenedSecondDeviceRecord?.authorityState, 'HOST_ACCEPTED');
        expect(reopenedSecondDeviceRecord?.hostRevision, 3);
      } finally {
        await firstQueue?.close();
        await secondQueue?.close();
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
