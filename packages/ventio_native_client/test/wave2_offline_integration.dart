// PREPARED / NOT EXECUTED. Explicit invocation only (not default *_test.dart).
// Two real SQLite stores and identities, real HTTP/SQL; not two physical PCs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/queued_record_reconciliation.dart';
import 'package:ventio_native_client/ventio_native_client.dart';

import '../../ventio_host_api/test/support/wave2_fixture.dart';
import 'support/wave2_commit_drop_proxy.dart';

// Ephemeral credential delivery fixture only. Authentication, authorization,
// transport, command execution and receipts are the production implementations.
// This suite makes no Windows Credential Manager / DPAPI acceptance claim.
class _EphemeralCredentials implements HostCredentialBackend {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  late W2Fixture f;
  late W2Identity peer;
  late Directory root;
  late LocalCommandQueue a;
  late LocalCommandQueue b;
  late String aPath;
  late String bPath;
  late Uri endpoint;
  final clock = DateTime.utc(2026, 11, 16);
  HostSyncIdentity identity(W2Identity user) => HostSyncIdentity(
    tenantId: user.tenant,
    companyId: W2Fixture.company,
    branchId: W2Fixture.branch,
    actorId: user.actor,
    deviceId: user.device,
  );
  Future<HostSyncService> service(
    LocalCommandQueue queue,
    W2Identity user, {
    Uri? via,
  }) async {
    final vault = HostCredentialVault(_EphemeralCredentials());
    await vault.save(via ?? endpoint, user.token);
    return HostSyncService(
      queue: queue,
      identity: identity(user),
      transport: HttpHostCommandTransport(
        endpoint: via ?? endpoint,
        credentials: vault,
        timeout: const Duration(seconds: 3),
      ),
    );
  }

  CommandEnvelope update(
    int id,
    W2Identity user,
    String record,
    int revision,
    Map<String, dynamic> values,
  ) => ExtensionRecordCommand.update(
    commandId: w2Id(id),
    tenantId: user.tenant,
    companyId: W2Fixture.company,
    branchId: W2Fixture.branch,
    recordId: record,
    expectedRevision: revision,
    actorId: user.actor,
    deviceId: user.device,
    moduleId: w2Module,
    moduleVersion: '1.0.0',
    docType: 'Asset',
    schemaVersion: 1,
    values: values,
  ).envelope;
  Future<void> reopen() async {
    await a.close();
    await b.close();
    a = await LocalCommandQueue.open(
      factory: databaseFactoryFfi,
      path: aPath,
      clock: () => clock,
    );
    b = await LocalCommandQueue.open(
      factory: databaseFactoryFfi,
      path: bPath,
      clock: () => clock,
    );
  }

  setUpAll(() async {
    sqfliteFfiInit();
    f = await W2Fixture.open();
    peer = await f.provision('peer', permissions: W2Fixture.permissions);
    endpoint = Uri.parse('http://127.0.0.1:${f.api.port}');
  });
  tearDownAll(() async {
    await f.close();
  });
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ventio-wave2-offline-');
    aPath = '${root.path}/a.sqlite';
    bPath = '${root.path}/b.sqlite';
    a = await LocalCommandQueue.open(
      factory: databaseFactoryFfi,
      path: aPath,
      clock: () => clock,
    );
    b = await LocalCommandQueue.open(
      factory: databaseFactoryFfi,
      path: bPath,
      clock: () => clock,
    );
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await root.delete(recursive: true);
  });

  test(
    'W2-E001 [K09,C09,J03] offline queued intent survives reopen and reconnect gets a real Host receipt',
    () async {
      final command = f.command(1001);
      await a.enqueue(command, projectToLocalRecords: false);
      final port = f.api.port;
      await f.api.close();
      try {
        await expectLater(
          (await service(a, f.author)).syncPending(),
          throwsA(isA<HostTransportException>()),
        );
      } finally {
        await f.bind(port: port);
      }
      await reopen();
      expect((await a.getById(command.commandId))!.isPending, isTrue);
      expect(
        (await a.getById(command.commandId))!.envelope.original,
        command.original,
      );
      expect(await (await service(a, f.author)).syncPending(), 1);
      expect((await a.getById(command.commandId))!.isHostConfirmed, isTrue);
      expect(await b.list(), isEmpty);
    },
  );
  test(
    'W2-E002 [J03,K09,L01] real lost response after commit is recovered without duplicate effects',
    () async {
      final proxy = await W2CommitDropProxy.start(endpoint);
      final command = f.command(2001);
      await a.enqueue(command, projectToLocalRecords: false);
      try {
        await expectLater(
          (await service(a, f.author, via: proxy.endpoint)).syncPending(),
          throwsA(isA<HostTransportException>()),
        );
        expect(proxy.committedResponsesDropped, 1);
        await reopen();
        expect((await a.getById(command.commandId))!.isPending, isTrue);
        await (await service(a, f.author, via: proxy.endpoint)).syncPending();
        final receipt = (await a.getById(
          command.commandId,
        ))!.hostReceipt!.toJson();
        expect(receipt, await f.execute(command));
        for (final table in [
          'ventio_command_journal',
          'ventio_audit_entries',
          'ventio_outbox',
        ]) {
          final rows = await f.observer.execute(
            pg.Sql.named(
              'SELECT count(*) FROM public.$table WHERE tenant_id=@tenant AND command_id=@id',
            ),
            parameters: {'tenant': W2Fixture.tenant, 'id': command.commandId},
          );
          expect(rows.single[0], 1);
        }
      } finally {
        await proxy.close();
      }
    },
  );
  test(
    'W2-E003 [K09,J03,D08] two identities conflict and explicitly reconcile while old receipts remain immutable',
    () async {
      await f.execute(f.command(3000));
      final first = update(3001, f.author, 'asset-3000', 1, {
        'name': 'A change',
      });
      final competing = update(3002, peer, 'asset-3000', 1, {
        'name': 'B change',
      });
      await a.enqueue(first, projectToLocalRecords: false);
      await b.enqueue(competing, projectToLocalRecords: false);
      await (await service(a, f.author)).syncPending();
      await (await service(b, peer)).syncPending();
      expect(
        (await a.getById(first.commandId))!.hostStatus,
        HostCommandStatus.accepted,
      );
      final conflict = (await b.getById(
        competing.commandId,
      ))!.hostReceipt!.toJson();
      expect(conflict['status'], 'CONFLICT');
      expect(conflict['currentRevision'], 2);
      final replacement = update(3003, peer, 'asset-3000', 2, {
        'name': 'Explicit resolution',
      });
      await b.enqueue(
        replacement,
        projectToLocalRecords: false,
        reconcilesCommandId: competing.commandId,
      );
      await reopen();
      await (await service(b, peer)).syncPending();
      expect((await b.getById(replacement.commandId))!.isHostConfirmed, isTrue);
      expect(
        (await b.getById(competing.commandId))!.hostReceipt!.toJson(),
        conflict,
      );
      expect(
        (await b.getById(replacement.commandId))!.reconcilesCommandId,
        competing.commandId,
      );
      await expectLater(
        b.enqueue(
          update(3004, peer, 'asset-3000', 3, {
            'name': 'Duplicate replacement',
          }),
          projectToLocalRecords: false,
          reconcilesCommandId: competing.commandId,
        ),
        throwsA(isA<DatabaseException>()),
      );
    },
  );
  test(
    'W2-E004 [K09,D09] reconciliation cannot redirect a terminal draft to another owner scope record or device',
    () async {
      await f.execute(f.command(4000));
      final stale = update(4001, f.author, 'asset-4000', 1, {'name': 'Stale'});
      await f.execute(
        update(4002, peer, 'asset-4000', 1, {'name': 'Peer'}),
        as: peer,
      );
      await a.enqueue(stale, projectToLocalRecords: false);
      await (await service(a, f.author)).syncPending();
      final good = update(4003, f.author, 'asset-4000', 2, {
        'name': 'Resolution',
      }).original;
      final context = requireMap(good['clientContext'], 'context');
      for (final raw in [
        {...good, 'tenantId': 'other'},
        {...good, 'companyId': 'other'},
        {...good, 'branchId': 'other'},
        {...good, 'aggregateId': 'other'},
        {
          ...good,
          'clientContext': {...context, 'actorId': 'other'},
        },
        {
          ...good,
          'clientContext': {...context, 'deviceId': 'other'},
        },
      ]) {
        await expectLater(
          a.enqueue(
            CommandEnvelope.fromJson(raw),
            projectToLocalRecords: false,
            reconcilesCommandId: stale.commandId,
          ),
          throwsStateError,
        );
      }
      expect(await a.list(), hasLength(1));
    },
  );
  test(
    'W2-E005 [A12,K09] effective-schema queue receipts never project into the immutable base-package cache',
    () async {
      final store = await LocalExtensionStore.open(
        factory: databaseFactoryFfi,
        path: '${root.path}/records.sqlite',
      );
      try {
        await store.installBundle(ExtensionBundle.fromJson(w2BundleJson()));
        await store.activate(w2Module);
        const scope = RecordScope(
          organizationId: W2Fixture.tenant,
          companyId: W2Fixture.company,
          branchId: W2Fixture.branch,
        );
        await store.createRecord(
          moduleId: w2Module,
          docTypeName: 'Asset',
          scope: scope,
          values: {'name': 'Base cache'},
          recordId: 'asset-5000',
        );
        final command = f.command(5000, values: {'name': 'Host value'});
        await a.enqueue(command, projectToLocalRecords: false);
        await (await service(a, f.author)).syncPending();
        await reconcileQueuedRecords(store, a);
        final cached = await store.getRecord(
          moduleId: w2Module,
          docTypeName: 'Asset',
          recordId: 'asset-5000',
          scope: scope,
        );
        expect(cached!.values['name'], 'Base cache');
      } finally {
        await store.close();
      }
    },
  );
  test(
    'W2-E006 [D08,D09,K09] revocation prevents queued offline work from becoming Host-confirmed',
    () async {
      final user = await f.provision(
        'offline-revoked',
        permissions: W2Fixture.permissions,
      );
      final command = f.command(6000, as: user);
      await a.enqueue(command, projectToLocalRecords: false);
      await user.admin.revokeCredential(user.credential);
      await expectLater(
        (await service(a, user)).syncPending(),
        throwsA(
          isA<HostTransportException>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      expect((await a.getById(command.commandId))!.isPending, isTrue);
      expect((await a.getById(command.commandId))!.hostReceipt, isNull);
    },
  );
}
