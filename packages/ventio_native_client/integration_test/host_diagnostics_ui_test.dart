import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/diagnostics_center_page.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/host_diagnostics.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';
import 'package:ventio_native_client/src/host_readiness.dart';
import 'package:ventio_native_client/src/local_diagnostics.dart';

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
    'Diagnostics Center retrieves a protected Host failure and exports safely',
    (tester) async {
      final environment = Platform.environment;
      String requiredValue(String name) {
        final value = environment[name];
        if (value == null || value.isEmpty) {
          throw StateError('Required Host diagnostics value is missing: $name');
        }
        return value;
      }

      final endpoint = Uri.parse(requiredValue('VENTIO_DIAGNOSTICS_ENDPOINT'));
      final token = requiredValue('VENTIO_DIAGNOSTICS_TOKEN');
      final tenant = requiredValue('VENTIO_DIAGNOSTICS_TENANT');
      final company = requiredValue('VENTIO_DIAGNOSTICS_COMPANY');
      final branch = requiredValue('VENTIO_DIAGNOSTICS_BRANCH');
      final expectedCorrelation = requiredValue(
        'VENTIO_DIAGNOSTICS_EXPECTED_CORRELATION',
      );

      sqfliteFfiInit();
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final credentials = HostCredentialVault(_MemoryCredentialBackend());
      await credentials.save(endpoint, token);
      final identity = await HostExtensionPackageClient(
        endpoint: endpoint,
        credentials: credentials,
      ).session();
      expect(identity.tenantId, tenant);
      final selectedScope = identity.scopes.singleWhere(
        (scope) => scope.companyId == company && scope.branchId == branch,
      );
      expect(
        selectedScope.permissions,
        contains(hostDiagnosticsReadPermission),
      );

      final directory = await Directory.systemTemp.createTemp(
        'ventio-live-diagnostics-ui-',
      );
      final tempRoot = p.normalize(Directory.systemTemp.path);
      if (!p.isWithin(tempRoot, p.normalize(directory.path))) {
        throw StateError('Diagnostics test storage escaped the temp root.');
      }

      final localStore = await LocalDiagnosticsStore.open(
        factory: databaseFactoryFfi,
        path: p.join(directory.path, 'diagnostics.sqlite3'),
      );
      try {
        await localStore.record(
          const LocalDiagnosticInput(
            code: 'CLIENT_SETUP_FAILED',
            component: 'client.setup',
            category: ManagementDiagnosticCategory.hostLifecycle,
            severity: ManagementDiagnosticSeverity.error,
            retryable: true,
            messageKey: 'native.diagnostics.host_setup_failed',
            safeExplanation:
                r'Host setup failed at C:\Users\Alice; password=local-secret.',
            recommendedAction: 'Review the setup diagnostics and retry safely.',
            protectedFailureType: 'SetupException',
            protectedFailureSource: 'HostSetupCoordinator.run',
          ),
        );

        final hostClient = HostDiagnosticsClient(
          HostReadinessClient(
            endpoint: endpoint,
            credentials: credentials,
            verifiedIdentity: identity,
            companyId: company,
            branchId: branch,
          ),
        );
        String? exported;
        await tester.pumpWidget(
          MaterialApp(
            home: DiagnosticsCenterPage(
              store: localStore,
              hostClient: hostClient,
              exportHandler: (json) async => exported = json,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Host diagnostics'), findsOneWidget);
        expect(find.text('HOST_STARTUP_FAILED'), findsOneWidget);
        expect(
          find.text('The Host service could not complete its startup checks.'),
          findsOneWidget,
        );
        expect(find.textContaining(expectedCorrelation), findsOneWidget);
        expect(find.text('CLIENT_SETUP_FAILED'), findsOneWidget);
        expect(find.textContaining('local-secret'), findsNothing);
        expect(find.textContaining(r'C:\Users\Alice'), findsNothing);

        await tester.tap(find.text('Copy sanitized export'));
        await tester.pumpAndSettle();
        expect(exported, isNotNull);
        final decoded = jsonDecode(exported!) as Map<String, dynamic>;
        final events = (decoded['events'] as List).cast<Map<String, dynamic>>();
        expect(events, hasLength(2));
        expect(events.map((event) => event['source']), ['device', 'host']);
        final hostEvent = events.singleWhere(
          (event) => event['source'] == 'host',
        );
        expect(hostEvent['code'], 'HOST_STARTUP_FAILED');
        expect(hostEvent['correlationId'], expectedCorrelation);
        expect(decoded['hostDiagnosticsStatus'], 'available');
        for (final protectedValue in [
          'protectedFailureType',
          'protectedTechnicalCode',
          'ServerException',
          'invalid_runtime_test_only',
          'local-secret',
          r'C:\Users\Alice',
        ]) {
          expect(exported, isNot(contains(protectedValue)));
        }
        expect(tester.takeException(), isNull);
      } finally {
        await localStore.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
