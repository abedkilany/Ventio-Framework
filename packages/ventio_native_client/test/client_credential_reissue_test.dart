import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/client_credential_reissue.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/host_device_management.dart';
import 'package:ventio_native_client/src/local_command_queue.dart';

const _oldToken = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';
const _newToken = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghi';
const _operationId = 'reissue_0123456789abcdef0123456789abcdef';

class _Backend implements HostCredentialBackend {
  final values = <String, String>{};
  bool failActiveWrite = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failActiveWrite && key.startsWith('ventio.host.credential.v1.')) {
      failActiveWrite = false;
      throw StateError('injected protected-store failure');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _HostExchange {
  final requests = <Map<String, Object?>>[];
  bool failFirstAcknowledgment = true;
  String acknowledgmentState = 'FINALIZED';
  String deviceId = 'existing-device';

  Future<HostDeviceManagementHttpResponse> call({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    final json = jsonDecode(body) as Map<String, dynamic>;
    requests.add({'path': uri.path, 'headers': headers, 'body': json});
    if (uri.path == HostManagementRoutes.credentialReissueClaim) {
      return HostDeviceManagementHttpResponse(
        statusCode: 200,
        headers: const {},
        body: {
          'apiVersion': 1,
          'managementApiVersion': managementApiVersion,
          'correlationId': 'cor_0123456789abcdef0123456789abcdef',
          'credentialReissue': {
            'operationId': _operationId,
            'state': 'PREPARED',
            'tenantId': 'tenant-a',
            'actorId': 'actor-a',
            'deviceId': deviceId,
            'companyId': 'company-a',
            'branchId': 'branch-a',
            'credentialId': 'cred_0123456789abcdef0123456789abcdef',
            'permissions': [
              'extension.package.read',
              'extension.package.submit',
            ],
            'expiresAtUtc': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 10))
                .toIso8601String(),
            'credential': _newToken,
          },
        },
      );
    }
    if (uri.path == HostManagementRoutes.credentialReissueAcknowledge) {
      if (failFirstAcknowledgment) {
        failFirstAcknowledgment = false;
        return const HostDeviceManagementHttpResponse(
          statusCode: 503,
          headers: {},
          body: {
            'error': {'code': 'RECOVERY_AUTHORITY_BUSY', 'retryable': true},
          },
        );
      }
      return HostDeviceManagementHttpResponse(
        statusCode: 200,
        headers: const {},
        body: {
          'apiVersion': 1,
          'managementApiVersion': managementApiVersion,
          'correlationId': 'cor_0123456789abcdef0123456789abcdef',
          'credentialReissue': {
            'operationId': _operationId,
            'state': acknowledgmentState,
            if (acknowledgmentState == 'FINALIZED') ...{
              'deviceId': deviceId,
              'credentialId': 'cred_0123456789abcdef0123456789abcdef',
            },
          },
        },
      );
    }
    throw StateError('Unexpected request path: ${uri.path}');
  }
}

void main() {
  late _Backend backend;
  late HostCredentialVault vault;
  late HostConnectionProfile profile;
  late _HostExchange exchange;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    backend = _Backend();
    vault = HostCredentialVault(backend);
    profile = const HostConnectionProfile(
      endpoint: 'https://host.example',
      tenantId: 'tenant-a',
      actorId: 'actor-a',
      deviceId: 'existing-device',
      companyId: 'company-a',
      branchId: 'branch-a',
    );
    exchange = _HostExchange();
    await vault.save(Uri.parse(profile.endpoint), _oldToken);
  });

  test(
    'stages first, retries acknowledgment, and preserves device identity',
    () async {
      final reissuer = ClientCredentialReissueClient(
        profile: profile,
        credentials: vault,
        exchange: exchange.call,
      );

      await expectLater(
        reissuer.checkAndApply(),
        throwsA(
          isA<ClientCredentialReissueException>().having(
            (error) => error.code,
            'code',
            'RECOVERY_AUTHORITY_BUSY',
          ),
        ),
      );
      expect(await vault.read(Uri.parse(profile.endpoint)), _oldToken);
      final staged = await vault.readStagedCredentialReissue(
        Uri.parse(profile.endpoint),
      );
      expect(staged?.token, _newToken);
      expect(profile.deviceId, 'existing-device');

      final result = await ClientCredentialReissueClient(
        profile: profile,
        credentials: vault,
        exchange: exchange.call,
      ).checkAndApply();

      expect(result.state, ClientCredentialReissueState.applied);
      expect(await vault.read(Uri.parse(profile.endpoint)), _newToken);
      expect(
        await vault.readStagedCredentialReissue(Uri.parse(profile.endpoint)),
        isNull,
      );
      expect(profile.deviceId, 'existing-device');
      expect(exchange.requests, hasLength(3));
      expect(
        exchange.requests[0]['headers'],
        containsPair('authorization', 'Bearer $_oldToken'),
      );
      expect(
        exchange.requests[1]['headers'],
        containsPair('authorization', 'Bearer $_newToken'),
      );
      expect(
        exchange.requests[2]['headers'],
        containsPair('authorization', 'Bearer $_newToken'),
      );
    },
  );

  test(
    'does not stage a replacement for a different device identity',
    () async {
      exchange.deviceId = 'different-device';
      final reissuer = ClientCredentialReissueClient(
        profile: profile,
        credentials: vault,
        exchange: exchange.call,
      );

      await expectLater(
        reissuer.checkAndApply(),
        throwsA(isA<ClientCredentialReissueException>()),
      );
      expect(await vault.read(Uri.parse(profile.endpoint)), _oldToken);
      expect(
        await vault.readStagedCredentialReissue(Uri.parse(profile.endpoint)),
        isNull,
      );
    },
  );

  test('a Host rejection clears only the staged credential', () async {
    exchange.failFirstAcknowledgment = false;
    exchange.acknowledgmentState = 'REJECTED';
    final result = await ClientCredentialReissueClient(
      profile: profile,
      credentials: vault,
      exchange: exchange.call,
    ).checkAndApply();

    expect(result.state, ClientCredentialReissueState.rejected);
    expect(result.code, 'REJECTED');
    expect(await vault.read(Uri.parse(profile.endpoint)), _oldToken);
    expect(
      await vault.readStagedCredentialReissue(Uri.parse(profile.endpoint)),
      isNull,
    );
  });

  test(
    'retains staged token and old token when secure activation fails',
    () async {
      exchange.failFirstAcknowledgment = false;
      backend.failActiveWrite = true;
      final firstAttempt = ClientCredentialReissueClient(
        profile: profile,
        credentials: vault,
        exchange: exchange.call,
      );
      await expectLater(
        firstAttempt.checkAndApply(),
        throwsA(
          isA<ClientCredentialReissueException>().having(
            (error) => error.code,
            'code',
            'CLIENT_SECURE_STORAGE_ACTIVATION_FAILED',
          ),
        ),
      );
      expect(await vault.read(Uri.parse(profile.endpoint)), _oldToken);
      expect(
        (await vault.readStagedCredentialReissue(
          Uri.parse(profile.endpoint),
        ))?.token,
        _newToken,
      );

      final retry = await ClientCredentialReissueClient(
        profile: profile,
        credentials: vault,
        exchange: exchange.call,
      ).checkAndApply();
      expect(retry.state, ClientCredentialReissueState.applied);
      expect(await vault.read(Uri.parse(profile.endpoint)), _newToken);
    },
  );

  test(
    'Client restarts across reissue preserve the original pending SQLite command',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ventio-reissue-offline-',
      );
      final databasePath =
          '${directory.path}${Platform.pathSeparator}client.sqlite3';
      var queue = await LocalCommandQueue.open(
        factory: databaseFactoryFfi,
        path: databasePath,
      );
      try {
        final commandJson =
            jsonDecode(
                  await File(
                    '../../spec/v1.2/examples/create_maintenance_command.json',
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        commandJson
          ..['commandId'] = '1e1440d9-72aa-4b84-8c53-bb5856c675a6'
          ..['tenantId'] = profile.tenantId
          ..['companyId'] = profile.companyId
          ..['branchId'] = profile.branchId
          ..['aggregateId'] = 'offline-record-before-reissue';
        (commandJson['clientContext'] as Map<String, dynamic>)
          ..['actorId'] = profile.actorId
          ..['deviceId'] = profile.deviceId;
        final command = CommandEnvelope.fromJson(commandJson);
        await queue.enqueue(command);

        await expectLater(
          ClientCredentialReissueClient(
            profile: profile,
            credentials: vault,
            exchange: exchange.call,
          ).checkAndApply(),
          throwsA(isA<ClientCredentialReissueException>()),
        );
        expect(await vault.read(Uri.parse(profile.endpoint)), _oldToken);
        await queue.close();
        queue = await LocalCommandQueue.open(
          factory: databaseFactoryFfi,
          path: databasePath,
        );

        final applied = await ClientCredentialReissueClient(
          profile: profile,
          credentials: vault,
          exchange: exchange.call,
        ).checkAndApply();
        expect(applied.state, ClientCredentialReissueState.applied);
        expect(await vault.read(Uri.parse(profile.endpoint)), _newToken);
        expect(profile.deviceId, 'existing-device');
        await queue.close();
        queue = await LocalCommandQueue.open(
          factory: databaseFactoryFfi,
          path: databasePath,
        );

        final restored = await queue.getById(command.commandId);
        expect(restored, isNotNull);
        expect(restored!.envelope.commandId, command.commandId);
        expect(restored.envelope.tenantId, profile.tenantId);
        expect(restored.envelope.companyId, profile.companyId);
        expect(restored.envelope.branchId, profile.branchId);
        expect(restored.envelope.actorId, profile.actorId);
        expect(restored.envelope.deviceId, profile.deviceId);
        expect(restored.hostStatus, HostCommandStatus.pending);
        expect(restored.hostReceipt, isNull);
      } finally {
        await queue.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
