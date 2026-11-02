import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/client_pairing.dart';
import 'package:ventio_native_client/src/client_pairing_page.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/local_diagnostics.dart';
import 'package:ventio_native_client/src/transport_fixture.dart'
    show hostApiVersion;

const _correlationId = 'cor_0123456789abcdef0123456789abcdef';
const _deviceId = 'client_0123456789abcdef0123456789abcdef';
final _pairingCode = List<String>.filled(43, 'P').join();
final _deviceCredential = List<String>.filled(43, 'C').join();
final _endpoint = Uri.parse('https://host.example.test');
final _now = DateTime.utc(2026, 10, 30, 12);

class _MemoryCredentialBackend implements HostCredentialBackend {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _FakeExchange {
  _FakeExchange(this.response);

  ClientPairingHttpResponse Function(Map<String, Object?> request) response;
  final requests = <Map<String, Object?>>[];

  Future<ClientPairingHttpResponse> call({
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
    return response(request);
  }
}

class _MemoryDiagnostics implements DiagnosticEventSource {
  final recorded = <ManagementDiagnosticEvent>[];

  @override
  Future<ManagementDiagnosticEvent> record(LocalDiagnosticInput input) async {
    final event = ManagementDiagnosticEvent(
      code: input.code,
      component: input.component,
      category: input.category,
      severity: input.severity,
      occurredAtUtc: input.occurredAtUtc ?? _now,
      correlationId: input.correlationId ?? _correlationId,
      retryable: input.retryable,
      messageKey: input.messageKey,
      safeExplanation: input.safeExplanation,
      recommendedAction: input.recommendedAction,
    );
    recorded.add(event);
    return event;
  }

  @override
  Future<List<ManagementDiagnosticEvent>> recent({int limit = 100}) async =>
      recorded.take(limit).toList(growable: false);

  @override
  Future<String> exportJson({int limit = 100}) async => jsonEncode({
    'events': [for (final event in await recent(limit: limit)) event.toJson()],
  });
}

void main() {
  late Directory directory;
  late LocalExtensionStore store;
  late _MemoryCredentialBackend backend;
  late HostCredentialVault vault;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ventio_pairing_test_');
    store = await LocalExtensionStore.open(
      factory: databaseFactoryFfiNoIsolate,
      path: '${directory.path}${Platform.pathSeparator}extensions.sqlite3',
    );
    backend = _MemoryCredentialBackend();
    vault = HostCredentialVault(backend);
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test(
    'redeems exact v1 route without bearer auth and saves one Host scope',
    () async {
      final exchange = _FakeExchange((_) => _success());
      final result = await _client(
        exchange,
        vault,
        store,
      ).redeemAndSave(code: _pairingCode);

      final request = exchange.requests.single;
      expect((request['uri'] as Uri).scheme, 'https');
      expect((request['uri'] as Uri).path, '/api/v1/pairing/redeem');
      expect(request['headers'], const {
        'accept': 'application/json',
        'content-type': 'application/json; charset=utf-8',
      });
      expect(request['body'], {
        'managementApiVersion': managementApiVersion,
        'code': _pairingCode,
        'deviceId': _deviceId,
      });
      expect(result.profile.endpoint, _endpoint.toString());
      expect(result.profile.tenantId, 'tenant-001');
      expect(result.profile.actorId, 'user-001');
      expect(result.profile.deviceId, _deviceId);
      expect(result.profile.companyId, 'company-001');
      expect(result.profile.branchId, 'branch-001');
      expect(result.credentialId, 'cred_0123456789abcdef0123456789abcdef');
      expect(result.expiresAtUtc, DateTime.utc(2026, 11, 29, 12));
      expect(result.correlationId, _correlationId);
      expect(result.toString(), isNot(contains(_deviceCredential)));
      expect(await vault.read(_endpoint), _deviceCredential);
      final savedProfile = await store.getHostProfile();
      expect(savedProfile?.tenantId, result.profile.tenantId);
      expect(savedProfile?.companyId, result.profile.companyId);
      expect(savedProfile?.branchId, result.profile.branchId);
      expect(savedProfile?.deviceId, result.profile.deviceId);
    },
  );

  test('rejects HTTP even for loopback endpoints', () async {
    expect(
      () => ClientPairingClient(
        endpoint: Uri.parse('http://127.0.0.1:8443'),
        credentials: vault,
        store: store,
      ),
      throwsArgumentError,
    );
  });

  test(
    'invalid or expired pairing code exposes safe code and correlation only',
    () async {
      final leakedMessage =
          'Rejected $_pairingCode; device credential $_deviceCredential';
      final exchange = _FakeExchange(
        (_) => ClientPairingHttpResponse(
          statusCode: HttpStatus.gone,
          body: {
            'apiVersion': hostApiVersion,
            'correlationId': _correlationId,
            'error': {
              'code': 'PAIRING_INVALID_OR_EXPIRED',
              'messageKey': 'host_api.error.pairing_invalid_or_expired',
              'message': leakedMessage,
              'retryable': false,
            },
          },
        ),
      );
      final client = _client(exchange, vault, store);

      await expectLater(
        client.redeemAndSave(code: _pairingCode),
        throwsA(
          isA<ClientPairingException>()
              .having(
                (error) => error.code,
                'code',
                'PAIRING_INVALID_OR_EXPIRED',
              )
              .having((error) => error.statusCode, 'statusCode', 410)
              .having(
                (error) => error.correlationId,
                'correlationId',
                _correlationId,
              )
              .having(
                (error) => error.toString(),
                'safe string',
                isNot(contains(_pairingCode)),
              )
              .having(
                (error) => error.toString(),
                'safe string',
                isNot(contains(_deviceCredential)),
              ),
        ),
      );
      expect(await store.getHostProfile(), isNull);
      expect(await vault.read(_endpoint), isNull);
    },
  );

  test(
    'validates version, CLIENT role, exact-scope shape, and credential before saving',
    () async {
      final malformedResponses = [
        _success(apiVersion: hostApiVersion + 1),
        _success(apiContractVersion: managementApiVersion + 1),
        _success(deviceRole: 'HOST'),
        _success(deviceId: 'client_ffffffffffffffffffffffffffffffff'),
        _success(credential: 'short'),
        _success(
          enrollmentExtra: const {
            'permissions': ['admin'],
          },
        ),
        _success(expiresAtUtc: '2026-10-30T11:59:59Z'),
      ];

      for (final response in malformedResponses) {
        final exchange = _FakeExchange((_) => response);
        await expectLater(
          _client(exchange, vault, store).redeemAndSave(code: _pairingCode),
          throwsA(isA<ClientPairingException>()),
        );
        expect(await store.getHostProfile(), isNull);
        expect(await vault.read(_endpoint), isNull);
      }
    },
  );

  testWidgets(
    'success UI never displays or exports pairing code or credential',
    (tester) async {
      final exchange = _FakeExchange((_) => _success());
      final diagnostics = _MemoryDiagnostics();
      await tester.pumpWidget(
        MaterialApp(
          home: ClientPairingPage(
            store: store,
            credentials: vault,
            diagnosticEventSource: diagnostics,
            initialEndpoint: _endpoint.toString(),
            clientFactory: (endpoint) => ClientPairingClient(
              endpoint: endpoint,
              credentials: vault,
              store: store,
              deviceIdFactory: () => _deviceId,
              clock: () => _now,
              exchange: exchange.call,
            ),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('client-pairing-code')),
        _pairingCode,
      );
      final codeInput = find.descendant(
        of: find.byKey(const ValueKey('client-pairing-code')),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(codeInput).obscureText, isTrue);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('client-pairing-submit')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('client-pairing-submit')));
      await tester.pumpAndSettle();

      expect(find.text('Client enrolled'), findsOneWidget);
      expect(find.textContaining('company-001'), findsOneWidget);
      expect(find.textContaining('branch-001'), findsOneWidget);
      expect(find.textContaining(_correlationId), findsOneWidget);
      expect(find.textContaining(_pairingCode), findsNothing);
      expect(find.textContaining(_deviceCredential), findsNothing);
      final diagnosticExport = await diagnostics.exportJson();
      expect(diagnosticExport, isNot(contains(_pairingCode)));
      expect(diagnosticExport, isNot(contains(_deviceCredential)));
    },
  );

  testWidgets(
    'expired token error is useful and records redacted local diagnostics',
    (tester) async {
      final exchange = _FakeExchange(
        (_) => ClientPairingHttpResponse(
          statusCode: HttpStatus.gone,
          body: {
            'apiVersion': hostApiVersion,
            'correlationId': _correlationId,
            'error': {
              'code': 'PAIRING_INVALID_OR_EXPIRED',
              'messageKey': 'host_api.error.pairing_invalid_or_expired',
              'message': 'Do not show $_pairingCode or $_deviceCredential',
              'retryable': false,
            },
          },
        ),
      );
      final diagnostics = _MemoryDiagnostics();
      await tester.pumpWidget(
        MaterialApp(
          home: ClientPairingPage(
            store: store,
            credentials: vault,
            diagnosticEventSource: diagnostics,
            initialEndpoint: _endpoint.toString(),
            clientFactory: (endpoint) => ClientPairingClient(
              endpoint: endpoint,
              credentials: vault,
              store: store,
              deviceIdFactory: () => _deviceId,
              clock: () => _now,
              exchange: exchange.call,
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('client-pairing-code')),
        _pairingCode,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('client-pairing-submit')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('client-pairing-submit')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('invalid, expired, or already used'),
        findsOneWidget,
      );
      expect(find.textContaining(_correlationId), findsOneWidget);
      expect(find.textContaining(_pairingCode), findsNothing);
      expect(find.textContaining(_deviceCredential), findsNothing);
      expect(diagnostics.recorded, hasLength(1));
      expect(diagnostics.recorded.single.code, 'PAIRING_INVALID_OR_EXPIRED');
      expect(diagnostics.recorded.single.correlationId, _correlationId);
      final diagnosticExport = await diagnostics.exportJson();
      expect(diagnosticExport, isNot(contains(_pairingCode)));
      expect(diagnosticExport, isNot(contains(_deviceCredential)));
      expect(await store.getHostProfile(), isNull);
    },
  );
}

ClientPairingClient _client(
  _FakeExchange exchange,
  HostCredentialVault vault,
  LocalExtensionStore store,
) => ClientPairingClient(
  endpoint: _endpoint,
  credentials: vault,
  store: store,
  deviceIdFactory: () => _deviceId,
  clock: () => _now,
  exchange: exchange.call,
);

ClientPairingHttpResponse _success({
  int apiVersion = hostApiVersion,
  int apiContractVersion = managementApiVersion,
  String deviceRole = 'CLIENT',
  String deviceId = _deviceId,
  String? credential,
  String expiresAtUtc = '2026-11-29T12:00:00.000Z',
  Map<String, Object?> enrollmentExtra = const {},
}) {
  final enrollment = <String, Object?>{
    'tenantId': 'tenant-001',
    'actorId': 'user-001',
    'deviceId': deviceId,
    'deviceRole': deviceRole,
    'credentialId': 'cred_0123456789abcdef0123456789abcdef',
    'companyId': 'company-001',
    'branchId': 'branch-001',
    'expiresAtUtc': expiresAtUtc,
    'credential': credential ?? _deviceCredential,
    ...enrollmentExtra,
  };
  return ClientPairingHttpResponse(
    statusCode: HttpStatus.created,
    body: {
      'apiVersion': apiVersion,
      'managementApiVersion': apiContractVersion,
      'correlationId': _correlationId,
      'enrollment': enrollment,
    },
  );
}
