import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/diagnostics_center_page.dart';
import 'package:ventio_native_client/src/local_diagnostics.dart';

void main() {
  late Directory directory;
  late LocalDiagnosticsStore store;

  setUpAll(() => sqfliteFfiInit());

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'ventio-local-diagnostics-',
    );
    store = await LocalDiagnosticsStore.open(
      factory: databaseFactoryFfi,
      path: '${directory.path}${Platform.pathSeparator}diagnostics.sqlite3',
      clock: () => DateTime.utc(2026, 10, 29, 18),
    );
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test(
    'persists safe structured events across a local database reopen',
    () async {
      final recorded = await store.record(_input());
      expect(recorded.correlationId, matches(RegExp(r'^cor_[a-f0-9]{32}$')));

      final beforeClose = await store.recent();
      expect(beforeClose, hasLength(1));
      expect(beforeClose.single.code, 'HOST_UNREACHABLE');
      expect(
        beforeClose.single.category,
        ManagementDiagnosticCategory.networkTls,
      );
      expect(beforeClose.single.retryable, isTrue);

      await store.close();
      store = await LocalDiagnosticsStore.open(
        factory: databaseFactoryFfi,
        path: '${directory.path}${Platform.pathSeparator}diagnostics.sqlite3',
        clock: () => DateTime.utc(2026, 10, 29, 19),
      );
      expect(
        (await store.recent()).single.safeExplanation,
        contains('not reachable'),
      );
    },
  );

  test(
    'sanitizes credential formats and private paths in stored export',
    () async {
      await store.record(
        _input(
          safeExplanation:
              r'Host failed at C:\Users\Alice\Ventio\host.log; '
              'password=hunter2; bearer abcdefghijklmnopqrstuvwxyz0123456789; '
              'database postgresql://ventio:SuperSecret@localhost/ventio.',
          recommendedAction:
              r'Review C:\ProgramData\Ventio\logs and rotate '
              'api_key=api-secret-123456.',
        ),
      );

      final exported = await store.exportJson();
      final decoded = jsonDecode(exported) as Map<String, dynamic>;
      final event = (decoded['events'] as List).single as Map<String, dynamic>;
      final serializedEvent = jsonEncode(event);
      for (final secret in [
        'hunter2',
        'SuperSecret',
        'abcdefghijklmnopqrstuvwxyz0123456789',
        'api-secret-123456',
        r'C:\Users\Alice',
        r'C:\ProgramData\Ventio',
      ]) {
        expect(serializedEvent, isNot(contains(secret)));
      }
      expect(event.keys, containsAll(['code', 'category', 'correlationId']));
      expect(event.keys, isNot(contains('technicalDetails')));
      expect(serializedEvent, contains('[redacted]'));
      expect(serializedEvent, contains('[local path]'));
    },
  );

  test('persists and exports every stable diagnostic category', () async {
    final categories = ManagementDiagnosticCategory.values;
    for (final category in categories) {
      await store.record(
        LocalDiagnosticInput(
          code: 'DIAGNOSTIC_${category.name.toUpperCase()}',
          component: 'test.${category.wireValue}',
          category: category,
          severity: ManagementDiagnosticSeverity.error,
          retryable: false,
          messageKey: 'native.diagnostics.test_failure',
          safeExplanation: 'A representative ${category.wireValue} failure.',
          recommendedAction: 'Review the relevant diagnostics and retry.',
        ),
      );
    }

    final events = await store.recent(limit: categories.length);
    final restoredCategories = events.map((event) => event.category).toSet();
    expect(restoredCategories, hasLength(categories.length));
    expect(restoredCategories, containsAll(categories));

    final exported =
        jsonDecode(await store.exportJson(limit: categories.length))
            as Map<String, dynamic>;
    final exportedEvents = (exported['events'] as List).cast<Map>();
    final exportedCategories = exportedEvents
        .map((event) => event['category'])
        .toSet();
    expect(exportedCategories, hasLength(categories.length));
    expect(
      exportedCategories,
      containsAll(categories.map((value) => value.wireValue)),
    );
    expect(
      exportedEvents.every((event) => !event.containsKey('technicalDetails')),
      isTrue,
    );
  });

  testWidgets('diagnostics center loads and exports without Host credentials', (
    tester,
  ) async {
    final event = _event();
    final source = _MemoryDiagnosticSource(event);
    String? exported;
    await tester.pumpWidget(
      MaterialApp(
        home: DiagnosticsCenterPage(
          store: source,
          exportHandler: (json) async => exported = json,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('HOST_UNREACHABLE'), findsOneWidget);
    expect(
      find.text('Host is not reachable from this device.'),
      findsOneWidget,
    );
    expect(
      find.text('Reference: cor_0123456789abcdef0123456789abcdef'),
      findsOneWidget,
    );

    await tester.tap(find.text('Copy sanitized export'));
    await tester.pumpAndSettle();
    expect(exported, isNotNull);
    expect(exported, contains('HOST_UNREACHABLE'));
    expect(find.text('Sanitized diagnostics copied.'), findsOneWidget);
  });
}

class _MemoryDiagnosticSource implements DiagnosticEventSource {
  _MemoryDiagnosticSource(this.event);

  final ManagementDiagnosticEvent event;

  @override
  Future<ManagementDiagnosticEvent> record(LocalDiagnosticInput input) async =>
      ManagementDiagnosticEvent(
        code: input.code,
        component: input.component,
        category: input.category,
        severity: input.severity,
        occurredAtUtc: input.occurredAtUtc ?? DateTime.now().toUtc(),
        correlationId: input.correlationId ?? newLocalCorrelationId(),
        retryable: input.retryable,
        messageKey: input.messageKey,
        safeExplanation: input.safeExplanation,
        recommendedAction: input.recommendedAction,
      );

  @override
  Future<List<ManagementDiagnosticEvent>> recent({int limit = 100}) async => [
    event,
  ];

  @override
  Future<String> exportJson({int limit = 100}) async => jsonEncode({
    'events': [event.toJson()],
  });
}

ManagementDiagnosticEvent _event() => ManagementDiagnosticEvent(
  code: 'HOST_UNREACHABLE',
  component: 'host.connection',
  category: ManagementDiagnosticCategory.networkTls,
  severity: ManagementDiagnosticSeverity.error,
  occurredAtUtc: DateTime.utc(2026, 10, 29, 18),
  correlationId: 'cor_0123456789abcdef0123456789abcdef',
  retryable: true,
  messageKey: 'native.diagnostics.host_unreachable',
  safeExplanation: 'Host is not reachable from this device.',
  recommendedAction: 'Check the network address and retry.',
);

LocalDiagnosticInput _input({
  String safeExplanation = 'Host is not reachable from this device.',
  String recommendedAction = 'Check the network address and retry.',
}) => LocalDiagnosticInput(
  code: 'HOST_UNREACHABLE',
  component: 'host.connection',
  category: ManagementDiagnosticCategory.networkTls,
  severity: ManagementDiagnosticSeverity.error,
  occurredAtUtc: DateTime.utc(2026, 10, 29, 18),
  correlationId: 'cor_0123456789abcdef0123456789abcdef',
  retryable: true,
  messageKey: 'native.diagnostics.host_unreachable',
  safeExplanation: safeExplanation,
  recommendedAction: recommendedAction,
);
