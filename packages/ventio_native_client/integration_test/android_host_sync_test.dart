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
      const initialVersion = '1.0.0';
      final approved = await writer.listApproved(
        companyId: _companyId,
        branchId: _branchId,
        limit: 10,
      );
      final summary = approved.packages.singleWhere(
        (package) =>
            package.moduleId == moduleId && package.version == initialVersion,
      );
      final bundle = await writer.readApproved(
        moduleId: moduleId,
        version: initialVersion,
        companyId: _companyId,
        branchId: _branchId,
        expectedPackageSha256: summary.packageSha256,
      );
      expect(bundle.docTypes, hasLength(1));

      final databasePath = p.join(
        await getDatabasesPath(),
        'ventio_android_host_${DateTime.now().microsecondsSinceEpoch}.sqlite3',
      );
      LocalCommandQueue? queue;
      try {
        queue = await LocalCommandQueue.open(
          factory: databaseFactory,
          path: databasePath,
        );
        final recordId =
            'android-${DateTime.now().microsecondsSinceEpoch.toString()}';
        final command = ExtensionRecordCommand.create(
          commandId: createCommandId(),
          tenantId: writerSession.tenantId,
          companyId: _companyId,
          branchId: _branchId,
          recordId: recordId,
          actorId: writerSession.actorId,
          deviceId: writerSession.deviceId,
          moduleId: moduleId,
          moduleVersion: initialVersion,
          docType: 'Item',
          schemaVersion: bundle.docTypes.single.schemaVersion,
          values: const {'title': 'Written from Android while offline'},
        );
        await queue.enqueue(command.envelope);

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
        final sharedRecord = await reader.queryRecords(
          companyId: _companyId,
          branchId: _branchId,
          moduleId: moduleId,
          version: initialVersion,
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
      } finally {
        await queue?.close();
        await databaseFactory.deleteDatabase(databasePath);
      }
    },
  );
}
