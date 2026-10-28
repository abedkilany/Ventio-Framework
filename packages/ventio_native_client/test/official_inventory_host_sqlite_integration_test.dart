import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/local_command_queue.dart';
import 'package:ventio_native_client/src/print_format_renderer.dart';
import 'package:ventio_native_client/src/queued_record_reconciliation.dart';
import 'package:ventio_native_client/src/transport_fixture.dart';
import 'package:ventio_postgres/ventio_postgres.dart'
    show PostgresMigrationRunner;

import '../../ventio_host_api/test/test_support.dart'
    show createPrivateTestDirectory, send;

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'Ventio Inventory Operations reconciles durable Windows SQLite commands with PostgreSQL Host receipts',
    () async {
      final databaseUrl = Platform.environment['VENTIO_TEST_DATABASE_URL'];
      final runtimeUrl =
          Platform.environment['VENTIO_TEST_RUNTIME_DATABASE_URL'];
      final adminUrl = Platform.environment['VENTIO_TEST_ADMIN_DATABASE_URL'];
      final allowed = Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'];
      if (databaseUrl == null ||
          runtimeUrl == null ||
          adminUrl == null ||
          allowed != 'yes') {
        throw StateError(
          'Set the guarded disposable ventio_host_test connection URLs and test opt-in.',
        );
      }
      final parsedUrls = [
        databaseUrl,
        runtimeUrl,
        adminUrl,
      ].map(Uri.parse).toList(growable: false);
      expect(
        parsedUrls.every(
          (url) =>
              url.host == '127.0.0.1' &&
              url.pathSegments.where((part) => part.isNotEmpty).lastOrNull ==
                  'ventio_host_test',
        ),
        isTrue,
        reason: 'This integration is restricted to loopback ventio_host_test.',
      );

      final observer = await pg.Connection.openFromUrl(databaseUrl);
      final runtime = await pg.Connection.openFromUrl(runtimeUrl);
      final admin = await pg.Connection.openFromUrl(adminUrl);
      final temporary = await createPrivateTestDirectory(
        'ventio-inventory-e2e-',
      );
      final authority = RecoveryAuthority('${temporary.path}/authority.json');
      final tenant =
          'inventory-${DateTime.now().toUtc().microsecondsSinceEpoch}';
      const company = 'company-inventory';
      const branch = 'branch-inventory';
      const actor = 'inventory-operator';
      const device = 'inventory-desktop';
      const moduleId = 'com.ventio.inventory_operations';
      final scope = RecordScope(
        organizationId: tenant,
        companyId: company,
        branchId: branch,
      );
      HostApi? api;
      LocalExtensionStore? store;
      LocalCommandQueue? queue;
      Directory? localDirectory;
      try {
        final unapplied = await PostgresMigrationRunner(
          observer,
          Directory('../../migrations/postgres'),
        ).apply();
        expect(
          unapplied,
          isEmpty,
          reason: 'All reviewed migrations are current.',
        );
        await authority.resetForReenrollment(admin, 'inventory-e2e-reset');

        final packageJson = Map<String, dynamic>.from(
          jsonDecode(
                await File(
                  '../../examples/ventio_inventory_operations/extension.json',
                ).readAsString(),
              )
              as Map,
        );
        final bundle = ExtensionBundle.fromJson(packageJson);
        final packageDigest = sha256
            .convert(utf8.encode(canonicalJson(bundle.toJson())))
            .toString();

        final permissions = <String>{
          'extension.package.read',
          'extension.package.submit',
        };
        for (final rawType in bundle.docTypeJson) {
          final typePermissions = rawType['permissions'] as Map;
          permissions.addAll(typePermissions.values.cast<String>());
          for (final rawField in rawType['fields'] as List) {
            final field = rawField as Map;
            if (field['readPermission'] case final String permission) {
              permissions.add(permission);
            }
            if (field['writePermission'] case final String permission) {
              permissions.add(permission);
            }
          }
          for (final rawOperation
              in rawType['businessOperations'] as List? ?? const []) {
            permissions.add((rawOperation as Map)['permission'] as String);
          }
        }
        final identityAdmin = IdentityAdministration(
          connection: admin,
          tenantId: tenant,
          operatorLabel: 'inventory-e2e-operator',
          authority: authority,
        );
        await identityAdmin.createUser(actor);
        await identityAdmin.registerBranch(company, branch);
        await identityAdmin.registerDevice(actor, device);
        for (final permission in permissions) {
          await identityAdmin.grant(actor, company, branch, permission);
        }
        final tokenPath = '${temporary.path}/inventory-credential.json';
        await identityAdmin.provisionToFile(
          actorId: actor,
          deviceId: device,
          credentialId: 'inventory-e2e-credential',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
          allowedScopes: [
            {
              'companyId': company,
              'branchId': branch,
              'permissions': permissions.toList()..sort(),
            },
          ],
          outputPath: tokenPath,
        );
        final credential =
            jsonDecode(await PrivateFiles.read(tokenPath))
                as Map<String, dynamic>;
        final token = credential['token'] as String;

        final prototype = bootstrapMaintenancePrototype('../../spec/v1.2');
        Future<HostApi> bindHost() => HostApi.bind(
          authenticator: PersistentTokenAuthenticator(
            connect: () => pg.Connection.openFromUrl(runtimeUrl),
            admission: authority,
          ),
          executor: PersistentCommandExecutor(
            connect: () => pg.Connection.openFromUrl(runtimeUrl),
            admission: authority,
            modules: prototype.modules,
            docTypes: prototype.docTypes,
            bindings: const [
              TrustedCommandBinding(
                'maintenance.create',
                1,
                'MaintenanceRequest',
              ),
            ],
          ),
          extensionPackages: PostgresExtensionPackageGateway(
            connect: () => pg.Connection.openFromUrl(runtimeUrl),
            admission: authority,
          ),
          extensionRecordQueries: PostgresExtensionRecordQueryGateway(
            connect: () => pg.Connection.openFromUrl(runtimeUrl),
            admission: authority,
          ),
          extensionReportQueries: PostgresExtensionReportQueryGateway(
            connect: () => pg.Connection.openFromUrl(runtimeUrl),
            admission: authority,
          ),
        );
        var activeApi = await bindHost();
        api = activeApi;

        final submission = await send(
          activeApi,
          token: token,
          path: '/api/v1/extensions/submit',
          body: {
            'companyId': company,
            'branchId': branch,
            'package': bundle.toJson(),
          },
        );
        expect(submission.status, 202);
        await ExtensionPackageAdministration(
          connection: admin,
          tenantId: tenant,
          operatorLabel: 'inventory-e2e-operator',
          authority: authority,
        ).approve(
          moduleId: moduleId,
          version: bundle.version,
          packageSha256: packageDigest,
        );

        localDirectory = await Directory.systemTemp.createTemp(
          'ventio-inventory-sqlite-',
        );
        final storePath = '${localDirectory.path}/extensions.sqlite3';
        final queuePath = '${localDirectory.path}/commands.sqlite3';
        Future<void> openClient() async {
          store = await LocalExtensionStore.open(
            factory: databaseFactoryFfiNoIsolate,
            path: storePath,
          );
          queue = await LocalCommandQueue.open(
            factory: databaseFactoryFfiNoIsolate,
            path: queuePath,
          );
        }

        await openClient();
        await store!.installBundle(bundle);
        await store!.activate(moduleId);
        const productId = 'inventory-product-1';
        const movementId = 'inventory-movement-1';
        const productCreateId = '85000000-0000-4000-8000-000000000001';
        const movementCreateId = '85000000-0000-4000-8000-000000000002';
        const submitId = '85000000-0000-4000-8000-000000000003';
        const cancelId = '85000000-0000-4000-8000-000000000004';
        const amendId = '85000000-0000-4000-8000-000000000005';
        const amendSubmitId = '85000000-0000-4000-8000-000000000006';
        const amendCancelId = '85000000-0000-4000-8000-000000000007';
        const movementUpdateId = '85000000-0000-4000-8000-000000000008';

        final localProduct = await store!.createRecord(
          moduleId: moduleId,
          docTypeName: 'Product',
          scope: scope,
          recordId: productId,
          values: const {'quantity': 90},
        );
        final localMovement = await store!.createRecord(
          moduleId: moduleId,
          docTypeName: 'Movement',
          scope: scope,
          recordId: movementId,
          values: const {
            'lines': [
              {'product': productId, 'amount': 2, 'unitPrice': 0.1},
              {'product': productId, 'amount': 3, 'unitPrice': 0.2},
            ],
          },
        );
        expect(localMovement.values['documentNumber'], 'LOCAL-$movementId');
        expect(localMovement.values['total'], 0.8);

        final productCommand = ExtensionRecordCommand.create(
          commandId: productCreateId,
          tenantId: tenant,
          companyId: company,
          branchId: branch,
          recordId: productId,
          actorId: actor,
          deviceId: device,
          moduleId: moduleId,
          moduleVersion: bundle.version,
          docType: 'Product',
          schemaVersion: 1,
          values: localProduct.values,
        );
        await queue!.enqueue(productCommand.envelope);
        await store!.markRecordPending(
          recordId: productId,
          scope: scope,
          commandId: productCreateId,
          operation: 'create',
        );
        final movementValues = Map<String, dynamic>.of(localMovement.values)
          ..remove('documentNumber');
        final movementCommand = ExtensionRecordCommand.create(
          commandId: movementCreateId,
          tenantId: tenant,
          companyId: company,
          branchId: branch,
          recordId: movementId,
          actorId: actor,
          deviceId: device,
          moduleId: moduleId,
          moduleVersion: bundle.version,
          docType: 'Movement',
          schemaVersion: 1,
          values: movementValues,
          dependsOn: const [productCreateId],
        );
        await queue!.enqueue(movementCommand.envelope);
        await store!.markRecordPending(
          recordId: movementId,
          scope: scope,
          commandId: movementCreateId,
          operation: 'create',
        );

        Future<CommandReceipt> sendQueued(
          String commandId, {
          bool retryIdentically = false,
          bool simulateLostFirstResponse = false,
        }) async {
          final entry = (await queue!.list(
            limit: 100,
          )).singleWhere((item) => item.envelope.commandId == commandId);
          await queue!.recordAttempt(commandId);
          late final CommandReceipt receipt;
          if (simulateLostFirstResponse) {
            // The Host commits, but the client process loses the response
            // before saving a Host receipt. The durable command remains
            // pending and must be replayed with the same ID.
            await send(activeApi, token: token, body: entry.envelope.original);
            final unresolved = await queue!.getById(commandId);
            expect(unresolved?.isPending, isTrue);
            expect(unresolved?.hostReceipt, isNull);
            final retry = await send(
              activeApi,
              token: token,
              body: entry.envelope.original,
            );
            expect(retry.status, anyOf(200, 202));
            receipt = CommandReceipt.fromJson(
              Map<String, dynamic>.from(retry.body['receipt'] as Map),
            );
            expect(
              receipt.accepted,
              isTrue,
              reason: '$commandId was rejected after lost-response recovery.',
            );
          } else {
            final first = await send(
              activeApi,
              token: token,
              body: entry.envelope.original,
            );
            expect(first.status, anyOf(200, 202));
            receipt = CommandReceipt.fromJson(
              Map<String, dynamic>.from(first.body['receipt'] as Map),
            );
            expect(
              receipt.accepted,
              isTrue,
              reason: '$commandId was rejected.',
            );
          }
          if (retryIdentically) {
            final retry = await send(
              activeApi,
              token: token,
              body: entry.envelope.original,
            );
            expect(retry.status, anyOf(200, 202));
            expect(
              canonicalJson(retry.body['receipt']),
              canonicalJson(receipt.toJson()),
            );
          }
          await queue!.recordHostReceipt(
            commandId,
            TransportResponse(
              apiVersion: hostApiVersion,
              source: TransportSource.host,
              receipt: receipt.toJson(),
            ),
          );
          await reconcileQueuedRecords(store!, queue!);
          return receipt;
        }

        final productReceipt = await sendQueued(productCreateId);
        expect(productReceipt.hostRevision, 1);
        final movementReceipt = await sendQueued(movementCreateId);
        expect(movementReceipt.hostRevision, 1);

        final offlineEdit = await store!.updateRecord(
          moduleId: moduleId,
          docTypeName: 'Movement',
          recordId: movementId,
          scope: scope,
          expectedRevision: 1,
          values: const {
            'lines': [
              {'product': productId, 'amount': 1, 'unitPrice': 0.1},
              {'product': productId, 'amount': 3, 'unitPrice': 0.2},
            ],
          },
        );
        expect(offlineEdit.values['total'], 0.7);
        final movementUpdate = ExtensionRecordCommand.update(
          commandId: movementUpdateId,
          tenantId: tenant,
          companyId: company,
          branchId: branch,
          recordId: movementId,
          expectedRevision: 1,
          actorId: actor,
          deviceId: device,
          moduleId: moduleId,
          moduleVersion: bundle.version,
          docType: 'Movement',
          schemaVersion: 1,
          values: {'lines': offlineEdit.values['lines']},
        );
        await queue!.enqueue(movementUpdate.envelope);
        await store!.markRecordPending(
          recordId: movementId,
          scope: scope,
          commandId: movementUpdateId,
        );
        final updateReceipt = await sendQueued(movementUpdateId);
        expect(updateReceipt.hostRevision, 2);
        var acceptedMovement = await store!.getRecord(
          moduleId: moduleId,
          docTypeName: 'Movement',
          recordId: movementId,
          scope: scope,
        );
        expect(acceptedMovement?.authorityState, 'HOST_ACCEPTED');
        expect(acceptedMovement?.hostRevision, 2);
        expect(acceptedMovement?.values['total'], 0.7);

        Future<Map<String, dynamic>> queryRecord(
          String docType,
          String recordId,
        ) async {
          final reply = await send(
            activeApi,
            token: token,
            path: '/api/v1/extensions/records/query',
            body: {
              'companyId': company,
              'branchId': branch,
              'moduleId': moduleId,
              'version': bundle.version,
              'docType': docType,
              'recordId': recordId,
              'search': '',
              'filters': <String, Object>{},
              'filterField': null,
              'filterContains': '',
              'sortField': docType == 'Product' ? 'quantity' : 'documentNumber',
              'descending': false,
              'offset': 0,
              'limit': 1,
            },
          );
          expect(reply.status, 200);
          final result = reply.body['recordResult'] as Map;
          expect(result['packageSha256'], packageDigest);
          final records = result['records'] as List;
          expect(records, hasLength(1));
          return Map<String, dynamic>.from(records.single as Map)
            ..['readableFields'] = result['readableFields']
            ..['writableFields'] = result['writableFields']
            ..['creatableFields'] = result['creatableFields'];
        }

        Future<void> applyHostRecord(String docType, String recordId) async {
          final record = await queryRecord(docType, recordId);
          await store!.applyHostRecord(
            moduleId: moduleId,
            docTypeName: docType,
            scope: scope,
            recordId: recordId,
            revision: record['revision'] as int,
            values: Map<String, dynamic>.from(record['values'] as Map),
            updatedAtUtc: DateTime.parse(record['updatedAtUtc'] as String),
            readableFields: (record['readableFields'] as List).cast<String>(),
            writableFields: (record['writableFields'] as List).cast<String>(),
            creatableFields: (record['creatableFields'] as List).cast<String>(),
          );
        }

        final movementAfterOfflineEdit = await queryRecord(
          'Movement',
          movementId,
        );
        expect(movementAfterOfflineEdit['revision'], 2);
        expect((movementAfterOfflineEdit['values'] as Map)['total'], 0.7);

        Future<CommandReceipt> executeOperation({
          required String commandId,
          required String recordId,
          required int expectedRevision,
          required String operationId,
          bool retryIdentically = false,
          bool simulateLostFirstResponse = false,
        }) async {
          final command = ExtensionBusinessOperationCommand.execute(
            commandId: commandId,
            tenantId: tenant,
            companyId: company,
            branchId: branch,
            recordId: recordId,
            expectedRevision: expectedRevision,
            actorId: actor,
            deviceId: device,
            moduleId: moduleId,
            moduleVersion: bundle.version,
            docType: 'Movement',
            schemaVersion: 1,
            operationId: operationId,
            operationVersion: 1,
            inputs: const {},
          );
          await queue!.enqueue(command.envelope);
          await reconcileQueuedRecords(store!, queue!);
          return sendQueued(
            commandId,
            retryIdentically: retryIdentically,
            simulateLostFirstResponse: simulateLostFirstResponse,
          );
        }

        final submitted = await executeOperation(
          commandId: submitId,
          recordId: movementId,
          expectedRevision: 2,
          operationId: 'inventory.submit',
          simulateLostFirstResponse: true,
        );
        expect(submitted.output?['number'], 'INV-000001');
        acceptedMovement = await store!.getRecord(
          moduleId: moduleId,
          docTypeName: 'Movement',
          recordId: movementId,
          scope: scope,
        );
        expect(acceptedMovement?.documentStatus, 1);
        expect(acceptedMovement?.hostRevision, 3);
        expect(acceptedMovement?.values['documentNumber'], 'INV-000001');
        expect(acceptedMovement?.authorityState, 'HOST_ACCEPTED');

        final hostProduct = await queryRecord('Product', productId);
        expect((hostProduct['values'] as Map)['quantity'], 94);
        await applyHostRecord('Product', productId);
        final localProductAfterSubmit = await store!.getRecord(
          moduleId: moduleId,
          docTypeName: 'Product',
          recordId: productId,
          scope: scope,
        );
        expect(localProductAfterSubmit?.values['quantity'], 94);

        final report = await send(
          activeApi,
          token: token,
          path: '/api/v1/extensions/reports/query',
          body: {
            'companyId': company,
            'branchId': branch,
            'moduleId': moduleId,
            'version': bundle.version,
            'docType': 'Movement',
            'reportId': 'movement_totals',
            'filters': <String, Object>{},
          },
        );
        final reportResult = report.body['reportResult'] as Map;
        expect(report.status, 200);
        expect(reportResult['rowCount'], 1);
        final aggregates =
            ((reportResult['groups'] as List).single as Map)['aggregates']
                as Map;
        expect(aggregates['row_count'], '1');
        expect(aggregates['sum_total'], '0.7');

        final hostMovement = await queryRecord('Movement', movementId);
        final rendered = await buildPrintFormatPdf(
          format: bundle.printFormats.single,
          docType: bundle.docTypes.singleWhere(
            (definition) => definition.name == 'Movement',
          ),
          englishCatalog: bundle.englishCatalog,
          record: Map<String, dynamic>.from(hostMovement['values'] as Map),
        );
        expect(String.fromCharCodes(rendered.take(5)), '%PDF-');
        expect(rendered.length, lessThan(5 * 1024 * 1024));

        final cancelled = await executeOperation(
          commandId: cancelId,
          recordId: movementId,
          expectedRevision: 3,
          operationId: 'inventory.cancel',
          retryIdentically: true,
        );
        expect(cancelled.accepted, isTrue);
        final productAfterCancel = await queryRecord('Product', productId);
        expect((productAfterCancel['values'] as Map)['quantity'], 90);
        acceptedMovement = await store!.getRecord(
          moduleId: moduleId,
          docTypeName: 'Movement',
          recordId: movementId,
          scope: scope,
        );
        expect(acceptedMovement?.documentStatus, 2);

        await store!.createAmendmentDraft(
          moduleId: moduleId,
          docTypeName: 'Movement',
          sourceRecordId: movementId,
          scope: scope,
          expectedSourceRevision: 4,
          commandId: amendId,
          linkField: 'amendedFrom',
        );
        final amended = await executeOperation(
          commandId: amendId,
          recordId: movementId,
          expectedRevision: 4,
          operationId: 'document.amend',
        );
        expect(amended.output?['amendedRecordId'], amendId);
        final localAmendment = await store!.getRecord(
          moduleId: moduleId,
          docTypeName: 'Movement',
          recordId: amendId,
          scope: scope,
        );
        expect(localAmendment?.values['amendedFrom'], movementId);
        expect(localAmendment?.documentStatus, 0);
        final productAfterAmend = await queryRecord('Product', productId);
        expect((productAfterAmend['values'] as Map)['quantity'], 90);

        final resubmitted = await executeOperation(
          commandId: amendSubmitId,
          recordId: amendId,
          expectedRevision: 1,
          operationId: 'inventory.submit',
          retryIdentically: true,
        );
        expect(resubmitted.output?['number'], 'INV-000002');
        final localResubmission = await store!.getRecord(
          moduleId: moduleId,
          docTypeName: 'Movement',
          recordId: amendId,
          scope: scope,
        );
        expect(localResubmission?.documentStatus, 1);
        expect(localResubmission?.values['documentNumber'], 'INV-000002');
        final productAfterResubmit = await queryRecord('Product', productId);
        expect((productAfterResubmit['values'] as Map)['quantity'], 94);

        await executeOperation(
          commandId: amendCancelId,
          recordId: amendId,
          expectedRevision: 2,
          operationId: 'inventory.cancel',
          retryIdentically: true,
        );
        final finalProduct = await queryRecord('Product', productId);
        expect((finalProduct['values'] as Map)['quantity'], 90);
        final sourceAfterAmend = await store!.getRecord(
          moduleId: moduleId,
          docTypeName: 'Movement',
          recordId: movementId,
          scope: scope,
        );
        final amendmentAfterCancel = await store!.getRecord(
          moduleId: moduleId,
          docTypeName: 'Movement',
          recordId: amendId,
          scope: scope,
        );
        expect(sourceAfterAmend?.values['documentNumber'], 'INV-000001');
        expect(sourceAfterAmend?.documentStatus, 2);
        expect(amendmentAfterCancel?.values['documentNumber'], 'INV-000002');
        expect(amendmentAfterCancel?.documentStatus, 2);

        await queue!.close();
        queue = null;
        await store!.close();
        store = null;
        await openClient();
        await reconcileQueuedRecords(store!, queue!);
        final restored = await store!.getRecord(
          moduleId: moduleId,
          docTypeName: 'Movement',
          recordId: amendId,
          scope: scope,
        );
        final recoveredCommands = await queue!.list(limit: 100);
        expect(
          (await store!.getExtension(moduleId))?.state,
          ExtensionState.active,
        );
        expect(restored?.authorityState, 'HOST_ACCEPTED');
        expect(restored?.hostRevision, greaterThanOrEqualTo(3));
        expect(restored?.documentStatus, 2);
        expect(restored?.values['documentNumber'], 'INV-000002');
        expect(recoveredCommands, hasLength(8));
        expect(
          recoveredCommands.every((entry) => entry.isHostConfirmed),
          isTrue,
        );

        await activeApi.close();
        activeApi = await bindHost();
        api = activeApi;
        final restartedMovement = await queryRecord('Movement', amendId);
        expect(
          (restartedMovement['values'] as Map)['documentNumber'],
          'INV-000002',
        );
        expect(restartedMovement['revision'], 3);
        final auditCount = await observer.execute(
          pg.Sql.named('''
            SELECT count(*) FROM ventio_audit_entries
            WHERE tenant_id=@tenant AND company_id=@company AND branch_id=@branch
          '''),
          parameters: {'tenant': tenant, 'company': company, 'branch': branch},
        );
        expect(auditCount.single[0], greaterThan(0));
      } finally {
        await api?.close();
        await queue?.close();
        await store?.close();
        await observer.close();
        await runtime.close();
        await admin.close();
        await temporary.delete(recursive: true);
        await localDirectory?.delete(recursive: true);
      }
    },
    skip: Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] == 'yes'
        ? false
        : 'Requires the explicitly enabled disposable loopback PostgreSQL test database.',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
