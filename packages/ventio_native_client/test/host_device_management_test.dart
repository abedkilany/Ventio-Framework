import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/device_management_page.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/host_device_management.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';
import 'package:ventio_native_client/src/host_user_management.dart';

const _token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';
const _correlationId = 'cor_0123456789abcdef0123456789abcdef';
const _pairingCode =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

class _MemoryCredentials implements HostCredentialBackend {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Exchange {
  final requests = <Map<String, Object?>>[];
  HostDeviceManagementHttpResponse Function(Map<String, Object?> request)?
  respond;

  Future<HostDeviceManagementHttpResponse> call({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    final request = <String, Object?>{
      'uri': uri,
      'headers': headers,
      'body': jsonDecode(body),
    };
    requests.add(request);
    return respond?.call(request) ?? _success(request);
  }
}

HostDeviceManagementHttpResponse _success(
  Map<String, Object?> request, {
  int? status,
  Map<String, Object?> fields = const {},
}) {
  final path = (request['uri'] as Uri).path;
  final defaults = switch (path) {
    '/api/v1/management/devices/list' => {
      'devices': {
        'tenantId': 'tenant-1',
        'companyId': 'company-1',
        'branchId': 'branch-1',
        'items': [_device()],
      },
    },
    '/api/v1/management/devices/revoke' => {
      'deviceOperation': {
        'status': 'APPLIED',
        'deviceId': (request['body'] as Map)['deviceId'],
      },
    },
    '/api/v1/management/pairing/create' => {
      'pairing': {
        'pairingId': 'pair_0123456789abcdef0123456789abcdef',
        'actorId': (request['body'] as Map)['actorId'],
        'deviceRole': 'CLIENT',
        'code': _pairingCode,
        'companyId': 'company-1',
        'branchId': 'branch-1',
        'expiresAtUtc': '2026-10-30T13:00:00.000Z',
      },
    },
    _ => const <String, Object?>{},
  };
  final resolvedStatus =
      status ?? (path == '/api/v1/management/pairing/create' ? 201 : 200);
  return HostDeviceManagementHttpResponse(
    statusCode: resolvedStatus,
    body: {
      'apiVersion': 1,
      'managementApiVersion': 1,
      'correlationId': _correlationId,
      ...defaults,
      ...fields,
    },
  );
}

Map<String, Object?> _device({String deviceId = 'client-device-001'}) => {
  'deviceId': deviceId,
  'actorId': 'usr_0123456789abcdef0123456789abcdef',
  'role': 'CLIENT',
  'registrationState': 'REGISTERED',
  'registeredAtUtc': '2026-10-29T12:30:00.000Z',
  'lastAuthenticatedAtUtc': null,
  'credentials': [
    {
      'credentialId': 'cred_0123456789abcdef0123456789abcdef',
      'state': 'ACTIVE',
      'expiresAtUtc': '2026-11-29T12:30:00.000Z',
      'revokedAtUtc': null,
    },
  ],
};

HostSessionIdentity _identity({
  bool persistent = true,
  Iterable<String> permissions = const {
    manageHostDevicesPermission,
    manageHostPairingPermission,
  },
}) => HostSessionIdentity(
  tenantId: 'tenant-1',
  actorId: 'admin-1',
  deviceId: 'client-1',
  persistent: persistent,
  roleAdministrationAvailable: false,
  scopes: [
    HostScopeGrant(
      companyId: 'company-1',
      branchId: 'branch-1',
      permissions: permissions,
    ),
  ],
);

Future<HostDeviceManagementClient> _client(
  _Exchange exchange, {
  HostSessionIdentity? identity,
}) async {
  final endpoint = Uri.https('host.example');
  final vault = HostCredentialVault(_MemoryCredentials());
  await vault.save(endpoint, _token);
  return HostDeviceManagementClient(
    endpoint: endpoint,
    credentials: vault,
    verifiedIdentity: identity ?? _identity(),
    companyId: 'company-1',
    branchId: 'branch-1',
    exchange: exchange.call,
  );
}

void main() {
  group('HostDeviceManagementClient', () {
    test(
      'loads scoped inventory and reports unknown activity as null',
      () async {
        final exchange = _Exchange();
        final client = await _client(exchange);

        final snapshot = await client.listDevices();

        expect(snapshot.tenantId, 'tenant-1');
        expect(snapshot.devices.single.deviceId, 'client-device-001');
        expect(snapshot.devices.single.lastAuthenticatedAtUtc, isNull);
        expect(
          snapshot.devices.single.credentials.single.state,
          HostManagedCredentialState.active,
        );
        final request = exchange.requests.single;
        expect((request['uri'] as Uri).path, '/api/v1/management/devices/list');
        expect((request['headers'] as Map)['authorization'], 'Bearer $_token');
        expect((request['body'] as Map)['companyId'], 'company-1');
        expect((request['body'] as Map)['branchId'], 'branch-1');
      },
    );

    test('preserves rotated credential state from Host inventory', () async {
      final exchange = _Exchange()
        ..respond = (request) => _success(
          request,
          fields: {
            'devices': {
              'tenantId': 'tenant-1',
              'companyId': 'company-1',
              'branchId': 'branch-1',
              'items': [
                {
                  ..._device(),
                  'credentials': [
                    {
                      'credentialId': 'cred_old',
                      'state': 'ROTATED',
                      'expiresAtUtc': '2026-11-29T12:30:00.000Z',
                      'revokedAtUtc': null,
                    },
                  ],
                },
              ],
            },
          },
        );
      final client = await _client(exchange);

      final snapshot = await client.listDevices();

      expect(
        snapshot.devices.single.credentials.single.state,
        HostManagedCredentialState.rotated,
      );
    });

    test(
      'creates a one-time Client code and revokes through Host routes',
      () async {
        final exchange = _Exchange();
        final client = await _client(exchange);

        final pairing = await client.createPairing(
          'usr_0123456789abcdef0123456789abcdef',
        );
        await client.revoke('client-device-001');

        expect(pairing.code, _pairingCode);
        expect(pairing.actorId, 'usr_0123456789abcdef0123456789abcdef');
        expect(pairing.correlationId, _correlationId);
        expect(
          exchange.requests.map((request) => (request['uri'] as Uri).path),
          [
            '/api/v1/management/pairing/create',
            '/api/v1/management/devices/revoke',
          ],
        );
        expect(
          jsonEncode(
            exchange.requests.map((request) => request['body']).toList(),
          ).contains(_pairingCode),
          isFalse,
          reason:
              'the code is response-only and is never sent back in a request',
        );
      },
    );

    test('denies by exact user permission before network access', () async {
      final exchange = _Exchange();
      final client = await _client(
        exchange,
        identity: _identity(permissions: const {'host.status.read'}),
      );

      await expectLater(
        client.listDevices(),
        throwsA(
          isA<HostDeviceManagementException>().having(
            (error) => error.code,
            'code',
            'HOST_PERMISSION_DENIED',
          ),
        ),
      );
      expect(exchange.requests, isEmpty);
    });

    test(
      'does not accept inventory fields that could expose secret material',
      () async {
        final exchange = _Exchange()
          ..respond = (request) => _success(
            request,
            fields: {
              'devices': {
                'tenantId': 'tenant-1',
                'companyId': 'company-1',
                'branchId': 'branch-1',
                'items': [
                  {..._device(), 'tokenDigest': 'private'},
                ],
              },
            },
          );
        final client = await _client(exchange);

        await expectLater(
          client.listDevices(),
          throwsA(
            isA<HostDeviceManagementException>().having(
              (error) => error.code,
              'code',
              'HOST_INVALID_RESPONSE',
            ),
          ),
        );
      },
    );

    test(
      'preserves the Host correlation ID on errors without exposing details',
      () async {
        final exchange = _Exchange()
          ..respond = (request) => HostDeviceManagementHttpResponse(
            statusCode: 403,
            body: {
              'apiVersion': 1,
              'correlationId': _correlationId,
              'error': {
                'code': 'PERMISSION_DENIED',
                'message': 'postgres://private:secret@host/database',
              },
            },
          );
        final client = await _client(exchange);

        await expectLater(
          client.listDevices(),
          throwsA(
            isA<HostDeviceManagementException>()
                .having((error) => error.code, 'code', 'PERMISSION_DENIED')
                .having(
                  (error) => error.correlationId,
                  'correlation ID',
                  _correlationId,
                )
                .having(
                  (error) => error.toString(),
                  'safe string',
                  isNot(contains('secret')),
                ),
          ),
        );
      },
    );
  });

  testWidgets('device page displays inventory and one-time pairing code', (
    tester,
  ) async {
    final exchange = _Exchange();
    final client = await _client(exchange);
    await tester.pumpWidget(
      MaterialApp(home: DeviceManagementPage(client: client)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Registered devices'), findsOneWidget);
    expect(find.text('client-device-001'), findsOneWidget);
    expect(find.textContaining('connection state is unknown'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('pairing-target-actor')),
      'usr_0123456789abcdef0123456789abcdef',
    );
    await tester.tap(find.byKey(const ValueKey('generate-pairing-code')));
    await tester.pumpAndSettle();

    expect(find.text(_pairingCode), findsOneWidget);
    expect(
      find.text(
        'Show this single-use code to the Client operator. It is visible only in this screen and expires soon.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('pairing can target an active Host user from its scoped list', (
    tester,
  ) async {
    final identity = _identity(
      permissions: const {
        manageHostDevicesPermission,
        manageHostPairingPermission,
        'identity.users.manage',
      },
    );
    final exchange = _Exchange();
    final deviceClient = await _client(exchange, identity: identity);
    final userDirectory = HostUserManagementClient(
      endpoint: Uri.https('host.example'),
      credentials: deviceClient.credentials,
      verifiedIdentity: identity,
      companyId: 'company-1',
      branchId: 'branch-1',
      exchange:
          ({
            required uri,
            required headers,
            required body,
            required timeout,
            required maxResponseBytes,
          }) async => HostUserManagementHttpResponse(
            statusCode: 200,
            body: {
              'apiVersion': 1,
              'managementApiVersion': 1,
              'correlationId': _correlationId,
              'users': {
                'tenantId': 'tenant-1',
                'companyId': 'company-1',
                'branchId': 'branch-1',
                'items': [
                  {
                    'actorId': 'usr_0123456789abcdef0123456789abcdef',
                    'state': 'ACTIVE',
                    'directPermissions': ['maintenance.read'],
                    'roles': [],
                  },
                ],
              },
            },
          ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceManagementPage(
          client: deviceClient,
          userDirectory: userDirectory,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pairing-target-user')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('generate-pairing-code')));
    await tester.pumpAndSettle();
    expect(
      ((exchange.requests.last['body'] as Map)['actorId']),
      'usr_0123456789abcdef0123456789abcdef',
    );
    expect(find.text(_pairingCode), findsOneWidget);
  });
}
