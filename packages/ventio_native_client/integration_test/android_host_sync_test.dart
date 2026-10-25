import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/ventio_native_client.dart';

import 'package:ventio_native_client/src/command_id.dart';

const _endpointText = String.fromEnvironment('VENTIO_ANDROID_HOST_ENDPOINT');
const _writerToken = String.fromEnvironment('VENTIO_ANDROID_WRITER_TOKEN');
const _readerToken = String.fromEnvironment('VENTIO_ANDROID_READER_TOKEN');
const _tenantId = String.fromEnvironment('VENTIO_ANDROID_TENANT');
const _companyId = String.fromEnvironment('VENTIO_ANDROID_COMPANY');
const _branchId = String.fromEnvironment('VENTIO_ANDROID_BRANCH');
const _trustedCertificate = String.fromEnvironment(
  'VENTIO_ANDROID_HOST_CERTIFICATE_PEM_B64',
);

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
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android syncs offline work through the Windows Host network address',
    (tester) async {
      expect(_endpointText, isNotEmpty);
      expect(_writerToken, isNotEmpty);
      expect(_readerToken, isNotEmpty);
      expect(_tenantId, isNotEmpty);
      expect(_companyId, isNotEmpty);
      expect(_branchId, isNotEmpty);
      expect(_trustedCertificate, isNotEmpty);

      final endpoint = Uri.parse(_endpointText);
      final certificatePem = base64.decode(_trustedCertificate);
      HttpClient pinnedClient() => HttpClient(
        context: SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(certificatePem),
      );

      final writerVault = HostCredentialVault(_MemoryCredentialBackend());
      await writerVault.save(endpoint, _writerToken);
      await expectLater(
        HostExtensionPackageClient(
          endpoint: endpoint,
          credentials: writerVault,
        ).session(),
        throwsA(
          isA<HostPackageTransportException>().having(
            (error) => error.code,
            'code',
            'HOST_TLS_VALIDATION_FAILED',
          ),
        ),
      );

      final writer = HostExtensionPackageClient(
        endpoint: endpoint,
        credentials: writerVault,
        clientFactory: pinnedClient,
      );
      final writerSession = await writer.session();
      expect(writerSession.tenantId, _tenantId);
      expect(writerSession.scopes, hasLength(1));
      expect(writerSession.scopes.single.companyId, _companyId);
      expect(writerSession.scopes.single.branchId, _branchId);

      const moduleId = 'com.example.windows_records';
      const supersededVersion = '1.0.0';
      const currentVersion = '1.0.1';
      final approved = await writer.listApproved(
        companyId: _companyId,
        branchId: _branchId,
        limit: 10,
      );
      final summary = approved.packages.singleWhere(
        (package) =>
            package.moduleId == moduleId && package.version == currentVersion,
      );
      final bundle = await writer.readApproved(
        moduleId: moduleId,
        version: currentVersion,
        companyId: _companyId,
        branchId: _branchId,
        expectedPackageSha256: summary.packageSha256,
      );
      expect(bundle.docTypes, hasLength(1));
      expect(bundle.docTypes.single.schemaVersion, 2);

      final databasePath = p.join(
        await getDatabasesPath(),
        'ventio_android_host_${DateTime.now().microsecondsSinceEpoch}.sqlite3',
      );
      final readerQueuePath = '${databasePath}_reader_queue';
      final writerStorePath = '${databasePath}_writer_store';
      final readerStorePath = '${databasePath}_reader_store';
      LocalCommandQueue? queue;
      LocalCommandQueue? readerQueue;
      LocalExtensionStore? writerStore;
      LocalExtensionStore? readerStore;
      try {
        writerStore = await LocalExtensionStore.open(
          factory: databaseFactory,
          path: writerStorePath,
        );
        await writerStore.installBundle(bundle);
        await writerStore.activate(moduleId);
        queue = await LocalCommandQueue.open(
          factory: databaseFactory,
          path: databasePath,
        );
        final scope = RecordScope(
          organizationId: writerSession.tenantId,
          companyId: _companyId,
          branchId: _branchId,
        );
        final recordId =
            'android-${DateTime.now().microsecondsSinceEpoch.toString()}';
        final provisional = await writerStore.createRecord(
          moduleId: moduleId,
          docTypeName: 'Item',
          scope: scope,
          values: const {'title': 'Written from Android while offline'},
          recordId: recordId,
        );
        final command = ExtensionRecordCommand.create(
          commandId: createCommandId(),
          tenantId: writerSession.tenantId,
          companyId: _companyId,
          branchId: _branchId,
          recordId: recordId,
          actorId: writerSession.actorId,
          deviceId: writerSession.deviceId,
          moduleId: moduleId,
          moduleVersion: currentVersion,
          docType: 'Item',
          schemaVersion: bundle.docTypes.single.schemaVersion,
          values: provisional.values,
        );
        await queue.enqueue(command.envelope);
        await writerStore.markRecordPending(
          recordId: recordId,
          scope: scope,
          commandId: command.envelope.commandId,
        );

        final unavailableEndpoint = Uri.parse('https://127.0.0.1:1');
        final offlineVault = HostCredentialVault(_MemoryCredentialBackend());
        await offlineVault.save(unavailableEndpoint, _writerToken);
        await expectLater(
          HostSyncService(
            queue: queue,
            identity: HostSyncIdentity(
              tenantId: writerSession.tenantId,
              companyId: _companyId,
              branchId: _branchId,
              actorId: writerSession.actorId,
              deviceId: writerSession.deviceId,
            ),
            transport: HttpHostCommandTransport(
              endpoint: unavailableEndpoint,
              credentials: offlineVault,
              clientFactory: pinnedClient,
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
        final pending = (await queue.list()).single;
        expect(pending.envelope.commandId, command.envelope.commandId);
        expect(pending.isPending, isTrue);
        expect(pending.attemptCount, 1);

        expect(
          await HostSyncService(
            queue: queue,
            identity: HostSyncIdentity(
              tenantId: writerSession.tenantId,
              companyId: _companyId,
              branchId: _branchId,
              actorId: writerSession.actorId,
              deviceId: writerSession.deviceId,
            ),
            transport: HttpHostCommandTransport(
              endpoint: endpoint,
              credentials: writerVault,
              clientFactory: pinnedClient,
            ),
          ).syncPending(),
          1,
        );
        final accepted = await queue.getById(command.envelope.commandId);
        expect(accepted?.isHostConfirmed, isTrue);
        expect(accepted?.hostReceipt?.hostRevision, 1);
        await writerStore.applyHostReceipt(
          recordId: recordId,
          scope: scope,
          commandId: command.envelope.commandId,
          receipt: accepted!.hostReceipt!,
        );
        await queue.close();
        queue = null;

        queue = await LocalCommandQueue.open(
          factory: databaseFactory,
          path: databasePath,
        );
        final persisted = await queue.getById(command.envelope.commandId);
        expect(persisted?.isHostConfirmed, isTrue);
        expect(persisted?.attemptCount, 2);

        final readerVault = HostCredentialVault(_MemoryCredentialBackend());
        await readerVault.save(endpoint, _readerToken);
        final reader = HostExtensionPackageClient(
          endpoint: endpoint,
          credentials: readerVault,
          clientFactory: pinnedClient,
        );
        final readerSession = await reader.session();
        expect(readerSession.deviceId, isNot(writerSession.deviceId));
        readerStore = await LocalExtensionStore.open(
          factory: databaseFactory,
          path: readerStorePath,
        );
        await readerStore.installBundle(bundle);
        await readerStore.activate(moduleId);
        readerQueue = await LocalCommandQueue.open(
          factory: databaseFactory,
          path: readerQueuePath,
        );
        await expectLater(
          reader.queryRecords(
            companyId: _companyId,
            branchId: _branchId,
            moduleId: moduleId,
            version: supersededVersion,
            docType: 'Item',
            recordId: recordId,
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
        final sharedRecord = await reader.queryRecords(
          companyId: _companyId,
          branchId: _branchId,
          moduleId: moduleId,
          version: currentVersion,
          docType: 'Item',
          recordId: recordId,
          limit: 1,
        );
        expect(sharedRecord.records, hasLength(1));
        expect(
          sharedRecord.records.single.values['title'],
          'Written from Android while offline',
        );
        expect(sharedRecord.records.single.revision, 1);
        final hostCreatedRecord = sharedRecord.records.single;
        await writerStore.applyHostRecord(
          moduleId: moduleId,
          docTypeName: 'Item',
          scope: scope,
          recordId: hostCreatedRecord.recordId,
          revision: hostCreatedRecord.revision,
          values: hostCreatedRecord.values,
          updatedAtUtc: DateTime.parse(hostCreatedRecord.updatedAtUtc),
          readableFields: sharedRecord.readableFields,
          writableFields: sharedRecord.writableFields,
          creatableFields: sharedRecord.creatableFields,
        );
        await readerStore.applyHostRecord(
          moduleId: moduleId,
          docTypeName: 'Item',
          scope: scope,
          recordId: hostCreatedRecord.recordId,
          revision: hostCreatedRecord.revision,
          values: hostCreatedRecord.values,
          updatedAtUtc: DateTime.parse(hostCreatedRecord.updatedAtUtc),
          readableFields: sharedRecord.readableFields,
          writableFields: sharedRecord.writableFields,
          creatableFields: sharedRecord.creatableFields,
        );

        final firstEdit = await writerStore.updateRecord(
          moduleId: moduleId,
          docTypeName: 'Item',
          recordId: recordId,
          scope: scope,
          expectedRevision: 1,
          values: const {'title': 'First Android device update'},
        );
        final firstUpdate = ExtensionRecordCommand.update(
          commandId: createCommandId(),
          tenantId: writerSession.tenantId,
          companyId: _companyId,
          branchId: _branchId,
          recordId: recordId,
          expectedRevision: 1,
          actorId: writerSession.actorId,
          deviceId: writerSession.deviceId,
          moduleId: moduleId,
          moduleVersion: currentVersion,
          docType: 'Item',
          schemaVersion: bundle.docTypes.single.schemaVersion,
          values: firstEdit.values,
        );
        await queue.enqueue(firstUpdate.envelope);
        await writerStore.markRecordPending(
          recordId: recordId,
          scope: scope,
          commandId: firstUpdate.envelope.commandId,
        );
        expect(
          await HostSyncService(
            queue: queue,
            identity: HostSyncIdentity(
              tenantId: writerSession.tenantId,
              companyId: _companyId,
              branchId: _branchId,
              actorId: writerSession.actorId,
              deviceId: writerSession.deviceId,
            ),
            transport: HttpHostCommandTransport(
              endpoint: endpoint,
              credentials: writerVault,
              clientFactory: pinnedClient,
            ),
          ).syncPending(),
          1,
        );
        final firstReceipt = (await queue.getById(
          firstUpdate.envelope.commandId,
        ))!.hostReceipt!;
        expect(firstReceipt.status, 'ACCEPTED');
        expect(firstReceipt.hostRevision, 2);
        await writerStore.applyHostReceipt(
          recordId: recordId,
          scope: scope,
          commandId: firstUpdate.envelope.commandId,
          receipt: firstReceipt,
        );

        final staleEdit = await readerStore.updateRecord(
          moduleId: moduleId,
          docTypeName: 'Item',
          recordId: recordId,
          scope: scope,
          expectedRevision: 1,
          values: const {'title': 'Second Android device draft'},
        );
        final staleUpdate = ExtensionRecordCommand.update(
          commandId: createCommandId(),
          tenantId: readerSession.tenantId,
          companyId: _companyId,
          branchId: _branchId,
          recordId: recordId,
          expectedRevision: 1,
          actorId: readerSession.actorId,
          deviceId: readerSession.deviceId,
          moduleId: moduleId,
          moduleVersion: currentVersion,
          docType: 'Item',
          schemaVersion: bundle.docTypes.single.schemaVersion,
          values: staleEdit.values,
        );
        await readerQueue.enqueue(staleUpdate.envelope);
        await readerStore.markRecordPending(
          recordId: recordId,
          scope: scope,
          commandId: staleUpdate.envelope.commandId,
        );
        expect(
          await HostSyncService(
            queue: readerQueue,
            identity: HostSyncIdentity(
              tenantId: readerSession.tenantId,
              companyId: _companyId,
              branchId: _branchId,
              actorId: readerSession.actorId,
              deviceId: readerSession.deviceId,
            ),
            transport: HttpHostCommandTransport(
              endpoint: endpoint,
              credentials: readerVault,
              clientFactory: pinnedClient,
            ),
          ).syncPending(),
          1,
        );
        final staleReceipt = (await readerQueue.getById(
          staleUpdate.envelope.commandId,
        ))!.hostReceipt!;
        expect(staleReceipt.status, 'CONFLICT');
        expect(staleReceipt.currentRevision, 2);
        await readerStore.applyHostReceipt(
          recordId: recordId,
          scope: scope,
          commandId: staleUpdate.envelope.commandId,
          receipt: staleReceipt,
        );
        var conflicted = (await readerStore.getRecord(
          moduleId: moduleId,
          docTypeName: 'Item',
          recordId: recordId,
          scope: scope,
        ))!;
        expect(conflicted.authorityState, 'CONFLICT');
        expect(conflicted.values['title'], 'Second Android device draft');

        final latest = await reader.queryRecords(
          companyId: _companyId,
          branchId: _branchId,
          moduleId: moduleId,
          version: currentVersion,
          docType: 'Item',
          recordId: recordId,
          limit: 1,
        );
        final latestRecord = latest.records.single;
        await readerStore.applyHostRecord(
          moduleId: moduleId,
          docTypeName: 'Item',
          scope: scope,
          recordId: latestRecord.recordId,
          revision: latestRecord.revision,
          values: latestRecord.values,
          updatedAtUtc: DateTime.parse(latestRecord.updatedAtUtc),
          readableFields: latest.readableFields,
          writableFields: latest.writableFields,
          creatableFields: latest.creatableFields,
        );
        conflicted = (await readerStore.getRecord(
          moduleId: moduleId,
          docTypeName: 'Item',
          recordId: recordId,
          scope: scope,
        ))!;
        expect(conflicted.conflictRevision, 2);
        expect(
          conflicted.conflictValues?['title'],
          'First Android device update',
        );
        expect(conflicted.values['title'], 'Second Android device draft');

        final reviewed = await readerStore.updateRecord(
          moduleId: moduleId,
          docTypeName: 'Item',
          recordId: recordId,
          scope: scope,
          expectedRevision: conflicted.revision,
          values: const {'title': 'Reviewed Android device merge'},
        );
        final reviewedCommand = ExtensionRecordCommand.update(
          commandId: createCommandId(),
          tenantId: readerSession.tenantId,
          companyId: _companyId,
          branchId: _branchId,
          recordId: recordId,
          expectedRevision: conflicted.conflictRevision!,
          actorId: readerSession.actorId,
          deviceId: readerSession.deviceId,
          moduleId: moduleId,
          moduleVersion: currentVersion,
          docType: 'Item',
          schemaVersion: bundle.docTypes.single.schemaVersion,
          values: reviewed.values,
        );
        await readerQueue.enqueue(reviewedCommand.envelope);
        await readerStore.markRecordPending(
          recordId: recordId,
          scope: scope,
          commandId: reviewedCommand.envelope.commandId,
        );
        expect(
          await HostSyncService(
            queue: readerQueue,
            identity: HostSyncIdentity(
              tenantId: readerSession.tenantId,
              companyId: _companyId,
              branchId: _branchId,
              actorId: readerSession.actorId,
              deviceId: readerSession.deviceId,
            ),
            transport: HttpHostCommandTransport(
              endpoint: endpoint,
              credentials: readerVault,
              clientFactory: pinnedClient,
            ),
          ).syncPending(),
          1,
        );
        final reviewedReceipt = (await readerQueue.getById(
          reviewedCommand.envelope.commandId,
        ))!.hostReceipt!;
        expect(reviewedReceipt.status, 'ACCEPTED');
        expect(reviewedReceipt.hostRevision, 3);
        await readerStore.applyHostReceipt(
          recordId: recordId,
          scope: scope,
          commandId: reviewedCommand.envelope.commandId,
          receipt: reviewedReceipt,
        );

        final finalHostRecord = (await writer.queryRecords(
          companyId: _companyId,
          branchId: _branchId,
          moduleId: moduleId,
          version: currentVersion,
          docType: 'Item',
          recordId: recordId,
          limit: 1,
        )).records.single;
        expect(finalHostRecord.revision, 3);
        expect(
          finalHostRecord.values['title'],
          'Reviewed Android device merge',
        );
        await writerStore.applyHostRecord(
          moduleId: moduleId,
          docTypeName: 'Item',
          scope: scope,
          recordId: finalHostRecord.recordId,
          revision: finalHostRecord.revision,
          values: finalHostRecord.values,
          updatedAtUtc: DateTime.parse(finalHostRecord.updatedAtUtc),
        );

        await queue.close();
        queue = await LocalCommandQueue.open(
          factory: databaseFactory,
          path: databasePath,
        );
        await readerQueue.close();
        readerQueue = await LocalCommandQueue.open(
          factory: databaseFactory,
          path: readerQueuePath,
        );
        final persistedMerge = await readerQueue.getById(
          reviewedCommand.envelope.commandId,
        );
        expect(persistedMerge?.hostReceipt?.hostRevision, 3);
        await writerStore.close();
        writerStore = await LocalExtensionStore.open(
          factory: databaseFactory,
          path: writerStorePath,
        );
        await readerStore.close();
        readerStore = await LocalExtensionStore.open(
          factory: databaseFactory,
          path: readerStorePath,
        );
        final reopenedWriter = await writerStore.getRecord(
          moduleId: moduleId,
          docTypeName: 'Item',
          recordId: recordId,
          scope: scope,
        );
        final reopenedReader = await readerStore.getRecord(
          moduleId: moduleId,
          docTypeName: 'Item',
          recordId: recordId,
          scope: scope,
        );
        for (final record in [reopenedWriter, reopenedReader]) {
          expect(record?.values['title'], 'Reviewed Android device merge');
          expect(record?.authorityState, 'HOST_ACCEPTED');
          expect(record?.hostRevision, 3);
        }
      } finally {
        await queue?.close();
        await readerQueue?.close();
        await writerStore?.close();
        await readerStore?.close();
        await databaseFactory.deleteDatabase(databasePath);
        await databaseFactory.deleteDatabase(readerQueuePath);
        await databaseFactory.deleteDatabase(writerStorePath);
        await databaseFactory.deleteDatabase(readerStorePath);
      }
    },
  );
}
