import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';
import 'package:ventio_native_client/src/host_overview_page.dart';
import 'package:ventio_native_client/src/host_readiness.dart';

const _token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';
const _correlationId = 'cor_0123456789abcdef0123456789abcdef';

class _FakeExchange {
  final requests = <Map<String, Object?>>[];
  HostReadinessHttpResponse Function(Map<String, Object?> request)? respond;

  Future<HostReadinessHttpResponse> call({
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
      'timeout': timeout,
      'maxResponseBytes': maxResponseBytes,
    };
    requests.add(request);
    return respond?.call(request) ?? _readyResponse();
  }
}

class _MemoryCredentials implements HostCredentialBackend {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

HostSessionIdentity _identity({
  bool persistent = true,
  String companyId = 'company-1',
  String branchId = 'branch-1',
  Iterable<String> permissions = const {'host.status.read'},
  bool roleAdministrationAvailable = false,
}) => HostSessionIdentity(
  tenantId: 'tenant-1',
  actorId: 'admin-1',
  deviceId: 'client-1',
  persistent: persistent,
  roleAdministrationAvailable: roleAdministrationAvailable,
  scopes: [
    HostScopeGrant(
      companyId: companyId,
      branchId: branchId,
      permissions: permissions,
    ),
  ],
);

Future<HostReadinessClient> _client(
  _FakeExchange exchange, {
  HostSessionIdentity? identity,
}) async {
  final endpoint = Uri.https('host.example');
  final credentials = HostCredentialVault(_MemoryCredentials());
  await credentials.save(endpoint, _token);
  return HostReadinessClient(
    endpoint: endpoint,
    credentials: credentials,
    verifiedIdentity: identity ?? _identity(),
    companyId: 'company-1',
    branchId: 'branch-1',
    exchange: exchange.call,
  );
}

HostReadinessSnapshot _snapshot({
  ManagementHealthState api = ManagementHealthState.ready,
  ManagementHealthState database = ManagementHealthState.ready,
  ManagementHealthState schema = ManagementHealthState.ready,
  ManagementHealthState recovery = ManagementHealthState.ready,
}) {
  final now = DateTime.utc(2026, 10, 29, 12, 30);
  final states = {
    ManagementComponent.api: api,
    ManagementComponent.database: database,
    ManagementComponent.schema: schema,
    ManagementComponent.recoveryAuthority: recovery,
  };
  return HostReadinessSnapshot(
    checkedAtUtc: now,
    hostVersion: '0.1.0',
    components: ManagementComponent.values.map(
      (component) => ManagementComponentHealth(
        component: component,
        state: states[component]!,
        checkedAtUtc: now,
        reasonCode: switch (component) {
          ManagementComponent.database
              when database != ManagementHealthState.ready =>
            'DATABASE_UNAVAILABLE',
          ManagementComponent.schema
              when schema != ManagementHealthState.ready =>
            'DATABASE_PROFILE_UNAVAILABLE',
          ManagementComponent.recoveryAuthority
              when recovery != ManagementHealthState.ready =>
            'RECOVERY_ADMISSION_BLOCKED',
          _ => null,
        },
      ),
    ),
  );
}

HostReadinessHttpResponse _readyResponse([HostReadinessSnapshot? snapshot]) =>
    HostReadinessHttpResponse(
      statusCode: 200,
      body: {
        'apiVersion': 1,
        'managementApiVersion': managementApiVersion,
        'correlationId': _correlationId,
        'readiness': (snapshot ?? _snapshot()).toJson(),
      },
    );

void main() {
  group('HostReadinessClient', () {
    test(
      'sends the authenticated exact-scope versioned readiness request',
      () async {
        final exchange = _FakeExchange();
        final client = await _client(exchange);
        final result = await client.checkReadiness();

        final request = exchange.requests.single;
        expect((request['uri'] as Uri).path, '/api/v1/management/readiness');
        expect(request['headers'], {
          'accept': 'application/json',
          'content-type': 'application/json; charset=utf-8',
          'authorization': 'Bearer $_token',
        });
        expect(request['body'], {
          'managementApiVersion': managementApiVersion,
          'companyId': 'company-1',
          'branchId': 'branch-1',
        });
        expect(result.snapshot.overallState, ManagementHealthState.ready);
        expect(result.snapshot.hostVersion, '0.1.0');
        expect(result.correlationId, _correlationId);
      },
    );

    test(
      'uses exact host.status.read scope, independent of device role',
      () async {
        final exchange = _FakeExchange();
        final clients = [
          await _client(
            exchange,
            identity: _identity(permissions: const {'maintenance.read'}),
          ),
          await _client(
            exchange,
            identity: _identity(branchId: 'other-branch'),
          ),
          await _client(exchange, identity: _identity(persistent: false)),
          await _client(
            exchange,
            identity: _identity(
              permissions: const {'host.status.read'},
              roleAdministrationAvailable: false,
            ),
          ),
        ];
        expect(clients.map((client) => client.canReadStatus), [
          false,
          false,
          false,
          true,
        ]);
        await expectLater(
          clients.first.checkReadiness(),
          throwsA(
            isA<HostReadinessException>().having(
              (error) => error.code,
              'code',
              'HOST_PERMISSION_DENIED',
            ),
          ),
        );
        expect(exchange.requests, isEmpty);
      },
    );

    test(
      'retains safe correlation on Host errors without showing raw details',
      () async {
        final exchange = _FakeExchange()
          ..respond = (_) => HostReadinessHttpResponse(
            statusCode: 503,
            body: {
              'apiVersion': 1,
              'managementApiVersion': managementApiVersion,
              'correlationId': _correlationId,
              'error': {
                'code': 'HOST_UNAVAILABLE',
                'retryable': true,
                'message': 'postgres://sensitive:password@host/db',
              },
            },
          );
        final client = await _client(exchange);
        await expectLater(
          client.checkReadiness(),
          throwsA(
            isA<HostReadinessException>()
                .having((error) => error.code, 'code', 'HOST_UNAVAILABLE')
                .having(
                  (error) => error.correlationId,
                  'correlationId',
                  _correlationId,
                )
                .having(
                  (error) => error.toString(),
                  'safe error text',
                  isNot(contains('sensitive')),
                ),
          ),
        );
      },
    );

    test('rejects a snapshot missing a required readiness component', () async {
      final valid = _snapshot().toJson();
      (valid['components'] as List).removeWhere(
        (value) => value['component'] == 'schema',
      );
      final exchange = _FakeExchange()
        ..respond = (_) => HostReadinessHttpResponse(
          statusCode: 200,
          body: {
            'apiVersion': 1,
            'managementApiVersion': managementApiVersion,
            'correlationId': _correlationId,
            'readiness': valid,
          },
        );
      final client = await _client(exchange);
      await expectLater(
        client.checkReadiness(),
        throwsA(
          isA<HostReadinessException>()
              .having((error) => error.code, 'code', 'HOST_INVALID_RESPONSE')
              .having(
                (error) => error.correlationId,
                'correlationId',
                _correlationId,
              ),
        ),
      );
    });
  });

  group('HostOverviewPage', () {
    testWidgets(
      'shows readiness states and explains where device inventory is managed',
      (tester) async {
        final client = _FakeReadinessClient(
          identity: _identity(),
          result: HostReadinessResult(
            snapshot: _snapshot(
              database: ManagementHealthState.unavailable,
              schema: ManagementHealthState.unknown,
              recovery: ManagementHealthState.blocked,
            ),
            correlationId: _correlationId,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(home: HostOverviewPage(client: client)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Authenticated Host API'), findsOneWidget);
        expect(find.text('READY'), findsOneWidget);
        expect(find.textContaining(_correlationId), findsOneWidget);

        final scrollable = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.text('PostgreSQL connection'),
          300,
          scrollable: scrollable,
        );
        expect(find.text('UNAVAILABLE'), findsOneWidget);
        expect(
          find.text(
            'The Host could not confirm the PostgreSQL connection. Check the Host database service and retry.',
          ),
          findsOneWidget,
        );

        await tester.scrollUntilVisible(
          find.text('Database schema and runtime profile'),
          300,
          scrollable: scrollable,
        );
        expect(find.text('UNKNOWN'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.text('Recovery Authority'),
          300,
          scrollable: scrollable,
        );
        expect(find.text('BLOCKED'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.text('Device inventory is not part of this readiness summary'),
          300,
          scrollable: scrollable,
        );
        expect(
          find.textContaining('Open Host devices & pairing'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'does not call readiness without exact-scope status permission',
      (tester) async {
        final client = _FakeReadinessClient(
          identity: _identity(permissions: const {'maintenance.read'}),
          result: HostReadinessResult(
            snapshot: _snapshot(),
            correlationId: _correlationId,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(home: HostOverviewPage(client: client)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Host status access required'), findsOneWidget);
        expect(client.calls, 0);
      },
    );

    testWidgets('shows a failed readiness correlation reference', (
      tester,
    ) async {
      final client = _FakeReadinessClient(
        identity: _identity(),
        result: HostReadinessResult(
          snapshot: _snapshot(),
          correlationId: _correlationId,
        ),
        error: const HostReadinessException(
          'DATABASE_UNAVAILABLE',
          correlationId: _correlationId,
          retryable: true,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: HostOverviewPage(client: client)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Could not check Host readiness'), findsOneWidget);
      expect(find.textContaining(_correlationId), findsOneWidget);
    });
  });
}

class _FakeReadinessClient extends HostReadinessClient {
  _FakeReadinessClient({
    required HostSessionIdentity identity,
    required this.result,
    this.error,
  }) : super(
         endpoint: Uri.https('host.example'),
         credentials: HostCredentialVault(_MemoryCredentials()),
         verifiedIdentity: identity,
         companyId: 'company-1',
         branchId: 'branch-1',
       );

  final HostReadinessResult result;
  final HostReadinessException? error;
  int calls = 0;

  @override
  Future<HostReadinessResult> checkReadiness() async {
    calls++;
    if (error != null) throw error!;
    return result;
  }
}
