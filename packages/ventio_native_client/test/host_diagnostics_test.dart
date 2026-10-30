import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/host_diagnostics.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';
import 'package:ventio_native_client/src/host_readiness.dart';
import 'package:ventio_native_client/src/diagnostics_center_page.dart';
import 'package:ventio_native_client/src/local_diagnostics.dart';

const _correlationId = 'cor_0123456789abcdef0123456789abcdef';
const _token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';

class _Credentials implements HostCredentialBackend {
  @override
  Future<String?> read(String key) async => _token;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

void main() {
  final event = ManagementDiagnosticEvent(
    code: 'DATABASE_UNAVAILABLE',
    component: 'host.database',
    category: ManagementDiagnosticCategory.database,
    severity: ManagementDiagnosticSeverity.error,
    occurredAtUtc: DateTime.utc(2026, 10, 30),
    correlationId: _correlationId,
    retryable: true,
    messageKey: 'host.database.unavailable',
    safeExplanation: 'The Host database is unavailable.',
    recommendedAction: 'Ask an authorized operator to check Host health.',
    protectedTechnicalCode: '08006',
  );

  HostReadinessClient createClient({
    required Set<String> permissions,
    required Future<HostReadinessHttpResponse> Function(
      Uri uri,
      Map<String, String> headers,
      String body,
    )
    exchange,
  }) {
    return HostReadinessClient(
      endpoint: Uri.https('host.example'),
      credentials: HostCredentialVault(_Credentials()),
      verifiedIdentity: HostSessionIdentity(
        tenantId: 'tenant-1',
        actorId: 'actor-1',
        deviceId: 'device-1',
        persistent: true,
        roleAdministrationAvailable: false,
        scopes: [
          HostScopeGrant(
            companyId: 'company-1',
            branchId: 'branch-1',
            permissions: permissions,
          ),
        ],
      ),
      companyId: 'company-1',
      branchId: 'branch-1',
      exchange:
          ({
            required uri,
            required headers,
            required body,
            required timeout,
            required maxResponseBytes,
          }) => exchange(uri, headers, body),
    );
  }

  test('requests recent events through the exact scoped Host API', () async {
    Uri? requestedUri;
    Map<String, String>? requestedHeaders;
    Map<String, dynamic>? requestedBody;
    final transport = createClient(
      permissions: {hostDiagnosticsReadPermission},
      exchange: (uri, headers, body) async {
        requestedUri = uri;
        requestedHeaders = headers;
        requestedBody = jsonDecode(body) as Map<String, dynamic>;
        return HostReadinessHttpResponse(
          statusCode: 200,
          body: {
            'apiVersion': 1,
            'managementApiVersion': managementApiVersion,
            'correlationId': _correlationId,
            'events': [event.toJson()],
          },
        );
      },
    );

    final result = await HostDiagnosticsClient(transport).recent(limit: 7);

    expect(requestedUri!.path, HostManagementRoutes.diagnosticsRecent);
    expect(
      requestedHeaders![HttpHeaders.authorizationHeader],
      'Bearer $_token',
    );
    expect(requestedBody, {
      'managementApiVersion': managementApiVersion,
      'companyId': 'company-1',
      'branchId': 'branch-1',
      'limit': 7,
    });
    expect(result.correlationId, _correlationId);
    expect(result.events.single.code, 'DATABASE_UNAVAILABLE');
    expect(result.events.single.protectedTechnicalCode, isNull);
    expect(event.toJson(), isNot(contains('protectedTechnicalCode')));
  });

  test(
    'local permission gate rejects unauthorized users before networking',
    () async {
      var requests = 0;
      final transport = createClient(
        permissions: {'host.status.read'},
        exchange: (_, _, _) async {
          requests++;
          throw StateError('The request must not be sent.');
        },
      );
      final diagnostics = HostDiagnosticsClient(transport);

      expect(diagnostics.canReadDiagnostics, isFalse);
      await expectLater(
        diagnostics.recent(),
        throwsA(
          isA<HostReadinessException>().having(
            (error) => error.code,
            'code',
            'HOST_PERMISSION_DENIED',
          ),
        ),
      );
      expect(requests, 0);
    },
  );

  test('server failure retains only stable code and correlation', () async {
    final transport = createClient(
      permissions: {hostDiagnosticsReadPermission},
      exchange: (_, _, _) async => HostReadinessHttpResponse(
        statusCode: 503,
        body: {
          'apiVersion': 1,
          'correlationId': _correlationId,
          'error': {
            'code': 'HOST_UNAVAILABLE',
            'retryable': true,
            'message': 'postgres://admin:secret@host/db',
          },
        },
      ),
    );

    await expectLater(
      HostDiagnosticsClient(transport).recent(),
      throwsA(
        isA<HostReadinessException>()
            .having((error) => error.code, 'code', 'HOST_UNAVAILABLE')
            .having(
              (error) => error.correlationId,
              'correlationId',
              _correlationId,
            )
            .having((error) => error.retryable, 'retryable', isTrue)
            .having(
              (error) => error.toString(),
              'safe string',
              isNot(contains('secret')),
            ),
      ),
    );
  });

  test('rejects an unsafe or malformed Host event response', () async {
    final transport = createClient(
      permissions: {hostDiagnosticsReadPermission},
      exchange: (_, _, _) async => HostReadinessHttpResponse(
        statusCode: 200,
        body: {
          'apiVersion': 1,
          'managementApiVersion': managementApiVersion,
          'correlationId': _correlationId,
          'events': [
            {...event.toJson(), 'safeExplanation': 'password=cleartext'},
          ],
        },
      ),
    );

    await expectLater(
      HostDiagnosticsClient(transport).recent(),
      throwsA(
        isA<HostReadinessException>().having(
          (error) => error.code,
          'code',
          'HOST_INVALID_RESPONSE',
        ),
      ),
    );
  });

  testWidgets('Diagnostics Center displays authorized Host events', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = createClient(
      permissions: {hostDiagnosticsReadPermission},
      exchange: (_, _, _) async => HostReadinessHttpResponse(
        statusCode: 200,
        body: {
          'apiVersion': 1,
          'managementApiVersion': managementApiVersion,
          'correlationId': _correlationId,
          'events': [event.toJson()],
        },
      ),
    );
    String? exported;
    await tester.pumpWidget(
      MaterialApp(
        home: DiagnosticsCenterPage(
          store: _LocalEvents(event),
          hostClient: HostDiagnosticsClient(transport),
          exportHandler: (json) async => exported = json,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Device diagnostics'), findsOneWidget);
    expect(find.text('Host diagnostics'), findsOneWidget);
    expect(find.text('DATABASE_UNAVAILABLE'), findsNWidgets(2));
    expect(find.text('The Host database is unavailable.'), findsNWidgets(2));
    await tester.tap(find.text('Copy sanitized export'));
    await tester.pumpAndSettle();
    final decoded = jsonDecode(exported!) as Map<String, dynamic>;
    final exportedEvents = decoded['events'] as List;
    expect(exportedEvents, hasLength(2));
    expect(exportedEvents[0]['source'], 'device');
    expect(exportedEvents[1]['source'], 'host');
    final encoded = jsonEncode(decoded);
    expect(encoded, isNot(contains('protectedTechnicalCode')));
    expect(encoded, isNot(contains('08006')));
  });

  testWidgets('Host diagnostics failure shows and exports its correlation ID', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = createClient(
      permissions: {hostDiagnosticsReadPermission},
      exchange: (_, _, _) async => HostReadinessHttpResponse(
        statusCode: 503,
        body: {
          'apiVersion': 1,
          'correlationId': _correlationId,
          'error': {
            'code': 'HOST_UNAVAILABLE',
            'retryable': true,
            'message': 'password=must-not-be-exported',
          },
        },
      ),
    );
    String? exported;
    await tester.pumpWidget(
      MaterialApp(
        home: DiagnosticsCenterPage(
          store: _LocalEvents(event),
          hostClient: HostDiagnosticsClient(transport),
          exportHandler: (json) async => exported = json,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'The Host could not be reached. Check the connection and retry.',
      ),
      findsOneWidget,
    );
    expect(find.text('Reference: $_correlationId'), findsNWidgets(2));
    await tester.tap(find.text('Copy sanitized export'));
    await tester.pumpAndSettle();
    final decoded = jsonDecode(exported!) as Map<String, dynamic>;
    expect(decoded['hostDiagnosticsStatus'], 'HOST_UNAVAILABLE');
    expect(decoded['hostDiagnosticsCorrelationId'], _correlationId);
    expect(exported, isNot(contains('must-not-be-exported')));
  });
}

class _LocalEvents implements DiagnosticEventSource {
  const _LocalEvents(this.event);

  final ManagementDiagnosticEvent event;

  @override
  Future<ManagementDiagnosticEvent> record(LocalDiagnosticInput input) async =>
      event;

  @override
  Future<List<ManagementDiagnosticEvent>> recent({int limit = 100}) async => [
    event,
  ];

  @override
  Future<String> exportJson({int limit = 100}) async =>
      '{"events":[${jsonEncode(event.toJson())}]}';
}
