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
    final store = _LocalEvents(event);
    await tester.pumpWidget(
      MaterialApp(
        home: DiagnosticsCenterPage(
          store: store,
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

  testWidgets(
    'manual diagnostics refresh recovers in the same Flutter session',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var hostAvailable = false;
      final requestedPaths = <String>[];
      final checkedAt = DateTime.utc(2026, 10, 30, 12);
      final readiness = HostReadinessSnapshot(
        checkedAtUtc: checkedAt,
        hostVersion: '0.1.0',
        components: [
          for (final component in ManagementComponent.values)
            ManagementComponentHealth(
              component: component,
              state: ManagementHealthState.ready,
              checkedAtUtc: checkedAt,
            ),
        ],
      );
      final transport = createClient(
        permissions: {hostDiagnosticsReadPermission, hostStatusReadPermission},
        exchange: (uri, _, _) async {
          requestedPaths.add(uri.path);
          if (uri.path == HostManagementRoutes.readiness) {
            return HostReadinessHttpResponse(
              statusCode: HttpStatus.ok,
              body: {
                'apiVersion': 1,
                'managementApiVersion': managementApiVersion,
                'correlationId': _correlationId,
                'readiness': readiness.toJson(),
              },
            );
          }
          if (!hostAvailable) {
            return HostReadinessHttpResponse(
              statusCode: HttpStatus.serviceUnavailable,
              body: {
                'apiVersion': 1,
                'correlationId': _correlationId,
                'error': {'code': 'HOST_UNAVAILABLE', 'retryable': true},
              },
            );
          }
          return HostReadinessHttpResponse(
            statusCode: HttpStatus.ok,
            body: {
              'apiVersion': 1,
              'managementApiVersion': managementApiVersion,
              'correlationId': _correlationId,
              'events': [event.toJson()],
            },
          );
        },
      );
      final store = _LocalEvents(event);

      await tester.pumpWidget(
        MaterialApp(
          home: DiagnosticsCenterPage(
            store: store,
            hostClient: HostDiagnosticsClient(transport),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(requestedPaths, [HostManagementRoutes.diagnosticsRecent]);
      expect(
        find.text(
          'The Host could not be reached. Check the connection and retry.',
        ),
        findsOneWidget,
      );
      expect(find.text('DATABASE_UNAVAILABLE'), findsOneWidget);

      // Simulate the Host service returning after a disconnect. The page and
      // its authenticated client remain alive; the app-bar action re-reads
      // both event feeds without restarting Flutter.
      hostAvailable = true;
      await tester.tap(find.byTooltip('Refresh diagnostics'));
      await tester.pumpAndSettle();

      expect(requestedPaths, [
        HostManagementRoutes.diagnosticsRecent,
        HostManagementRoutes.diagnosticsRecent,
      ]);
      expect(store.recentCalls, 2);
      expect(find.text('DATABASE_UNAVAILABLE'), findsNWidgets(2));

      // Host-only refresh does not reload device history, and readiness is a
      // separate scoped status request rather than a diagnostic-event fetch.
      hostAvailable = false;
      await tester.tap(find.byTooltip('Refresh Host diagnostics'));
      await tester.pumpAndSettle();
      expect(store.recentCalls, 2);
      expect(find.text('DATABASE_UNAVAILABLE'), findsOneWidget);

      hostAvailable = true;
      await tester.tap(find.byTooltip('Refresh Host diagnostics'));
      await tester.pumpAndSettle();
      expect(store.recentCalls, 2);
      expect(find.text('DATABASE_UNAVAILABLE'), findsNWidgets(2));

      await tester.tap(find.text('Run Host readiness check'));
      await tester.pumpAndSettle();
      expect(requestedPaths.last, HostManagementRoutes.readiness);
      expect(
        requestedPaths.where(
          (path) => path == HostManagementRoutes.diagnosticsRecent,
        ),
        hasLength(4),
      );
      expect(find.text('READY'), findsNWidgets(4));
      expect(find.text('DATABASE_UNAVAILABLE'), findsNWidgets(2));
    },
  );

  testWidgets('Diagnostics Center runs the scoped Host readiness check', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final checkedAt = DateTime.utc(2026, 10, 30, 12);
    final snapshot = HostReadinessSnapshot(
      checkedAtUtc: checkedAt,
      hostVersion: '0.1.0',
      components: [
        for (final component in ManagementComponent.values)
          ManagementComponentHealth(
            component: component,
            state: component == ManagementComponent.database
                ? ManagementHealthState.unavailable
                : ManagementHealthState.ready,
            checkedAtUtc: checkedAt,
            reasonCode: component == ManagementComponent.database
                ? 'DATABASE_UNAVAILABLE'
                : null,
          ),
      ],
    );
    final requestedPaths = <String>[];
    final transport = createClient(
      permissions: {hostDiagnosticsReadPermission, hostStatusReadPermission},
      exchange: (uri, _, _) async {
        requestedPaths.add(uri.path);
        if (uri.path == HostManagementRoutes.readiness) {
          return HostReadinessHttpResponse(
            statusCode: HttpStatus.ok,
            body: {
              'apiVersion': 1,
              'managementApiVersion': managementApiVersion,
              'correlationId': _correlationId,
              'readiness': snapshot.toJson(),
            },
          );
        }
        return HostReadinessHttpResponse(
          statusCode: HttpStatus.ok,
          body: {
            'apiVersion': 1,
            'managementApiVersion': managementApiVersion,
            'correlationId': _correlationId,
            'events': <Object?>[],
          },
        );
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DiagnosticsCenterPage(
          store: _LocalEvents(event),
          hostClient: HostDiagnosticsClient(transport),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run Host readiness check'));
    await tester.pumpAndSettle();

    expect(requestedPaths, contains(HostManagementRoutes.readiness));
    expect(find.text('database'), findsNWidgets(2));
    expect(find.text('UNAVAILABLE · DATABASE_UNAVAILABLE'), findsOneWidget);
    expect(find.text('api'), findsOneWidget);
    expect(find.text('READY'), findsNWidgets(3));
    expect(find.text('Reference: $_correlationId'), findsNWidgets(2));
  });

  testWidgets('readiness action is unavailable without scoped status grant', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requestedPaths = <String>[];
    final transport = createClient(
      permissions: {hostDiagnosticsReadPermission},
      exchange: (uri, _, _) async {
        requestedPaths.add(uri.path);
        return HostReadinessHttpResponse(
          statusCode: HttpStatus.ok,
          body: {
            'apiVersion': 1,
            'managementApiVersion': managementApiVersion,
            'correlationId': _correlationId,
            'events': <Object?>[],
          },
        );
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DiagnosticsCenterPage(
          store: _LocalEvents(event),
          hostClient: HostDiagnosticsClient(transport),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final action = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Run Host readiness check'),
    );
    expect(action.onPressed, isNull);
    expect(
      find.text(
        'The Host account needs host.status.read in this scope to run readiness checks.',
      ),
      findsOneWidget,
    );
    expect(requestedPaths, isNot(contains(HostManagementRoutes.readiness)));
  });

  testWidgets('readiness failure keeps a safe explanation and reference', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = createClient(
      permissions: {hostDiagnosticsReadPermission, hostStatusReadPermission},
      exchange: (uri, _, _) async => HostReadinessHttpResponse(
        statusCode: uri.path == HostManagementRoutes.readiness
            ? HttpStatus.serviceUnavailable
            : HttpStatus.ok,
        body: uri.path == HostManagementRoutes.readiness
            ? {
                'apiVersion': 1,
                'managementApiVersion': managementApiVersion,
                'correlationId': _correlationId,
                'error': {
                  'code': 'HOST_UNAVAILABLE',
                  'retryable': true,
                  'message': 'password=must-not-be-shown-or-exported',
                },
              }
            : {
                'apiVersion': 1,
                'managementApiVersion': managementApiVersion,
                'correlationId': _correlationId,
                'events': <Object?>[],
              },
      ),
    );
    String? exported;
    final store = _LocalEvents(event);
    await tester.pumpWidget(
      MaterialApp(
        home: DiagnosticsCenterPage(
          store: store,
          hostClient: HostDiagnosticsClient(transport),
          exportHandler: (json) async => exported = json,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run Host readiness check'));
    await tester.pumpAndSettle();

    expect(find.text('Host readiness check failed'), findsOneWidget);
    expect(
      find.text(
        'The Host could not be reached. Check the connection and retry.',
      ),
      findsOneWidget,
    );
    expect(find.text('Reference: $_correlationId'), findsNWidgets(3));
    await tester.tap(find.text('Copy sanitized export'));
    await tester.pumpAndSettle();
    final decoded = jsonDecode(exported!) as Map<String, dynamic>;
    expect(decoded['hostReadinessStatus'], 'HOST_UNAVAILABLE');
    expect(decoded['hostReadinessCorrelationId'], _correlationId);
    expect(exported, isNot(contains('must-not-be-shown-or-exported')));
    expect(store.recorded.single.code, 'HOST_UNAVAILABLE');
    expect(
      store.recorded.single.category,
      ManagementDiagnosticCategory.apiExecution,
    );
    expect(store.recorded.single.safeExplanation, isNot(contains('password')));
    expect(
      store.recorded.single.recommendedAction,
      contains('Retry the readiness check'),
    );
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
  _LocalEvents(this.event);

  final ManagementDiagnosticEvent event;
  final recorded = <LocalDiagnosticInput>[];
  int recentCalls = 0;

  @override
  Future<ManagementDiagnosticEvent> record(LocalDiagnosticInput input) async {
    recorded.add(input);
    return event;
  }

  @override
  Future<List<ManagementDiagnosticEvent>> recent({int limit = 100}) async {
    recentCalls++;
    return [event];
  }

  @override
  Future<String> exportJson({int limit = 100}) async =>
      '{"events":[${jsonEncode(event.toJson())}]}';
}
