import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';
import 'package:ventio_native_client/src/host_setup.dart';
import 'package:ventio_native_client/src/host_setup_page.dart';
import 'package:ventio_native_client/src/local_diagnostics.dart';

const _requestId = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';
const _token = 'BCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefgh';
const _actorId = 'usr_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';

class _MemoryHostCredentialBackend implements HostCredentialBackend {
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

Future<void> _submitMinimalHostSetup(WidgetTester tester) async {
  final list = find.byType(ListView);
  for (
    var attempt = 0;
    attempt < 8 && find.byType(TextField).evaluate().isEmpty;
    attempt++
  ) {
    await tester.drag(list, const Offset(0, -300));
    await tester.pumpAndSettle();
  }
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), 'tenant-lan-test');
  await tester.enterText(fields.at(1), 'company-lan-test');
  await tester.enterText(fields.at(2), 'branch-lan-test');
  tester.testTextInput.hide();
  for (
    var attempt = 0;
    attempt < 8 && find.text('Set up Host').evaluate().isEmpty;
    attempt++
  ) {
    await tester.drag(list, const Offset(0, -300));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('Set up Host'));
  await tester.pumpAndSettle();
}

void main() {
  group('HostSetupOperationStatus JSON', () {
    test('accepts the current camelCase status contract', () {
      final normalized = HostSetupOperationStatus.normalizeJson({
        'formatVersion': 1,
        'operationId': '0123456789abcdef0123456789abcdef',
        'state': 'failed',
        'phase': 'FIRST_ADMINISTRATOR_BOOTSTRAP',
        'failureCode': 'HOST_FIRST_ADMINISTRATOR_FAILED',
        'updatedAtUtc': '2026-10-31T09:00:00Z',
      });

      expect(normalized['state'], 'failed');
      expect(normalized['failureCode'], 'HOST_FIRST_ADMINISTRATOR_FAILED');
    });

    test('accepts legacy PascalCase status records', () {
      final normalized = HostSetupOperationStatus.normalizeJson({
        'FormatVersion': 1,
        'OperationId': '0123456789abcdef0123456789abcdef',
        'State': 'failed',
        'Phase': 'FIRST_ADMINISTRATOR_BOOTSTRAP',
        'FailureCode': 'HOST_FIRST_ADMINISTRATOR_FAILED',
        'UpdatedAtUtc': '2026-10-31T09:00:00Z',
      });

      expect(normalized['operationId'], '0123456789abcdef0123456789abcdef');
      expect(normalized['phase'], 'FIRST_ADMINISTRATOR_BOOTSTRAP');
    });

    test('rejects unknown or duplicate semantic status fields', () {
      expect(
        () => HostSetupOperationStatus.normalizeJson({
          'operationId': '0123456789abcdef0123456789abcdef',
          'OperationId': '0123456789abcdef0123456789abcdef',
        }),
        throwsFormatException,
      );
      expect(
        () => HostSetupOperationStatus.normalizeJson({'unexpected': true}),
        throwsFormatException,
      );
    });
  });

  group('Host session profile binding', () {
    const legacyProfile = HostConnectionProfile(
      endpoint: hostSetupEndpoint,
      tenantId: 'tenant-one',
      companyId: 'company-one',
      branchId: 'branch-one',
      actorId: _actorId,
    );

    test('uses the device identity returned by the authenticated Host', () {
      final profile = bindHostProfileToIdentity(
        profile: legacyProfile,
        identity: _adminIdentity(),
        requireHostAdministration: true,
      );

      expect(profile.actorId, _actorId);
      expect(profile.deviceId, 'device-one');
      expect(profile.tenantId, 'tenant-one');
      expect(profile.companyId, 'company-one');
      expect(profile.branchId, 'branch-one');
    });

    test('rejects a mismatched registered device identity', () {
      expect(
        () => bindHostProfileToIdentity(
          profile: HostConnectionProfile(
            endpoint: hostSetupEndpoint,
            tenantId: 'tenant-one',
            companyId: 'company-one',
            branchId: 'branch-one',
            actorId: _actorId,
            deviceId: 'another-device',
          ),
          identity: _adminIdentity(),
        ),
        throwsA(
          isA<HostSessionIdentityException>().having(
            (error) => error.code,
            'code',
            'HOST_SESSION_IDENTITY_MISMATCH',
          ),
        ),
      );
    });

    test('rejects a non-administrator session for Host setup', () {
      final identity = _adminIdentity(
        permissions: const {hostStatusReadPermission},
      );
      expect(
        () => bindHostProfileToIdentity(
          profile: legacyProfile,
          identity: identity,
          requireHostAdministration: true,
        ),
        throwsA(
          isA<HostSessionIdentityException>().having(
            (error) => error.code,
            'code',
            'HOST_FIRST_ADMINISTRATOR_PERMISSIONS_MISSING',
          ),
        ),
      );
    });

    test('rejects a session bound to another actor or tenant', () {
      expect(
        () => bindHostProfileToIdentity(
          profile: legacyProfile,
          identity: _adminIdentity(actorId: 'usr_other'),
        ),
        throwsA(isA<HostSessionIdentityException>()),
      );
      expect(
        () => bindHostProfileToIdentity(
          profile: legacyProfile,
          identity: _adminIdentity(tenantId: 'other-tenant'),
        ),
        throwsA(isA<HostSessionIdentityException>()),
      );
    });
  });

  group('Local Host setup credential verification', () {
    setUpAll(sqfliteFfiInit);

    test('preserves a safe Host authentication error code', () async {
      final store = await LocalExtensionStore.open(
        factory: databaseFactoryFfi,
        path: ':memory:',
      );
      addTearDown(store.close);
      final backend = _MemoryHostCredentialBackend();
      final vault = HostCredentialVault(backend);
      final endpoint = Uri.parse(hostSetupEndpoint);
      await vault.save(endpoint, _token);
      final profile = HostConnectionProfile(
        endpoint: hostSetupEndpoint,
        tenantId: 'tenant-one',
        companyId: 'company-one',
        branchId: 'branch-one',
        actorId: _actorId,
      );
      await store.saveHostProfile(profile);
      final credentials = LocalHostSetupCredentialStore(
        credentials: vault,
        store: store,
        sessionLoader: (_) async => throw const HostPackageTransportException(
          'HOST_CREDENTIAL_EXPIRED',
          statusCode: 401,
        ),
      );

      await expectLater(
        credentials.verifyAndBindExistingProfile(profile),
        throwsA(
          isA<HostSetupException>().having(
            (error) => error.code,
            'code',
            'HOST_CREDENTIAL_EXPIRED',
          ),
        ),
      );
    });
  });

  group('HostSetupCoordinator', () {
    late _FakePlatform platform;
    late _MemorySetupStore credentials;
    late HostSetupCoordinator coordinator;
    final scope = HostSetupScope(
      tenantId: 'tenant-one',
      companyId: 'company-one',
      branchId: 'branch-one',
    );

    setUp(() {
      platform = _FakePlatform();
      credentials = _MemorySetupStore(
        onSave: () => platform.events.add('save'),
      );
      coordinator = HostSetupCoordinator(
        platform: platform,
        credentials: credentials,
      );
    });

    test(
      'verifies the persistent administrator session before consuming handoff',
      () async {
        final profile = await coordinator.run(scope);

        expect(platform.startedServices, isEmpty);
        expect(
          platform.events.indexOf('save'),
          lessThan(platform.events.indexOf('clear-result')),
        );
        expect(
          platform.events.indexOf('ready'),
          lessThan(platform.events.indexOf('save')),
        );
        expect(
          platform.events.indexOf('clear-result'),
          lessThan(platform.events.indexOf('clear-pending')),
        );
        expect(platform.events, contains('elevate'));
        expect(platform.events, contains('read-result'));
        expect(profile.tenantId, scope.tenantId);
        expect(profile.companyId, scope.companyId);
        expect(profile.branchId, scope.branchId);
        expect(profile.actorId, _actorId);
        expect(profile.deviceId, 'device-one');
        expect(credentials.token, _token);
      },
    );

    test('does not continue when UAC is cancelled', () async {
      platform.elevationAccepted = false;

      await expectLater(
        coordinator.run(scope),
        throwsA(
          isA<HostSetupException>().having(
            (error) => error.code,
            'code',
            'HOST_SETUP_ELEVATION_CANCELLED',
          ),
        ),
      );

      expect(platform.startedServices, isEmpty);
      expect(platform.events, isNot(contains('read-result')));
      expect(platform.pending, isNull);
      expect(platform.events, contains('clear-pending'));
    });

    test(
      'does not relaunch an older pending operation without its status record',
      () async {
        platform.pending = HostSetupPendingOperation(
          operationId: '0123456789abcdef0123456789abcdef',
          requesterSid: platform.sid,
          scope: scope,
        );
        platform.states['VentioPostgres'] = HostWindowsServiceState.running;

        await expectLater(
          coordinator.run(scope),
          throwsA(
            isA<HostSetupException>().having(
              (error) => error.code,
              'code',
              'HOST_SETUP_INTERRUPTED_REQUIRES_RECOVERY',
            ),
          ),
        );

        expect(platform.events, isNot(contains('elevate')));
        expect(platform.events, isNot(contains('save-pending')));
        expect(platform.events, isNot(contains('clear-pending')));
        expect(platform.pending, isNotNull);
      },
    );

    test(
      'does not relaunch a pending operation with a different scope',
      () async {
        platform.pending = HostSetupPendingOperation(
          operationId: '0123456789abcdef0123456789abcdef',
          requesterSid: platform.sid,
          scope: HostSetupScope(
            tenantId: 'previous-tenant',
            companyId: 'company-one',
            branchId: 'branch-one',
          ),
        );

        await expectLater(
          coordinator.run(scope),
          throwsA(
            isA<HostSetupException>().having(
              (error) => error.code,
              'code',
              'HOST_SETUP_PENDING_OPERATION_MISMATCH',
            ),
          ),
        );

        expect(platform.events, isNot(contains('elevate')));
        expect(platform.events, isNot(contains('save-pending')));
        expect(platform.events, isNot(contains('clear-pending')));
        expect(platform.pending?.scope.tenantId, 'previous-tenant');
      },
    );

    test('refuses to provision when the Flutter app is elevated', () async {
      platform.processIsElevated = true;

      await expectLater(
        coordinator.run(scope),
        throwsA(
          isA<HostSetupException>().having(
            (error) => error.code,
            'code',
            'HOST_SETUP_APPLICATION_ELEVATED',
          ),
        ),
      );

      expect(platform.events, isEmpty);
      expect(platform.pending, isNull);
    });

    test(
      'stops waiting when the broker never publishes a start status',
      () async {
        platform.publishStatusOnElevation = false;
        coordinator = HostSetupCoordinator(
          platform: platform,
          credentials: credentials,
          brokerStatusStartTimeout: Duration.zero,
        );

        await expectLater(
          coordinator.run(scope),
          throwsA(
            isA<HostSetupException>().having(
              (error) => error.code,
              'code',
              'HOST_SETUP_BROKER_START_TIMEOUT',
            ),
          ),
        );

        expect(platform.events, contains('elevate'));
        expect(platform.events, isNot(contains('read-result')));
        expect(platform.pending, isNotNull);
      },
    );

    test(
      'preserves the protected result when secure persistence fails',
      () async {
        credentials.failSave = true;

        await expectLater(coordinator.run(scope), throwsA(isA<StateError>()));

        expect(platform.events, isNot(contains('clear-result')));
      },
    );

    test(
      'refuses an existing service instead of provisioning over it',
      () async {
        platform.states['VentioPostgres'] = HostWindowsServiceState.stopped;

        await expectLater(
          coordinator.run(scope),
          throwsA(
            isA<HostSetupException>().having(
              (error) => error.code,
              'code',
              'HOST_EXISTING_INSTALLATION_REQUIRES_RECOVERY',
            ),
          ),
        );

        expect(platform.startedServices, isEmpty);
        expect(platform.events, isNot(contains('elevate')));
      },
    );

    test(
      'does not relaunch stale provisioning after an interruption',
      () async {
        platform.status = HostSetupOperationStatus(
          state: HostSetupOperationState.running,
          phase: 'DATABASE_INITIALIZATION',
          updatedAtUtc: DateTime.now().toUtc().subtract(
            const Duration(minutes: 1),
          ),
        );

        await expectLater(
          coordinator.run(scope),
          throwsA(
            isA<HostSetupException>().having(
              (error) => error.code,
              'code',
              'HOST_SETUP_INTERRUPTED_REQUIRES_RECOVERY',
            ),
          ),
        );

        expect(platform.startedServices, isEmpty);
        expect(platform.events, isNot(contains('elevate')));
        expect(platform.pending, isNotNull);
      },
    );

    test(
      'resumes a completed helper operation without launching it again',
      () async {
        platform.pending = HostSetupPendingOperation(
          operationId: '0123456789abcdef0123456789abcdef',
          requesterSid: platform.sid,
          scope: scope,
        );
        platform.status = const HostSetupOperationStatus(
          state: HostSetupOperationState.complete,
        );
        final profile = await coordinator.run(scope);

        expect(profile.actorId, _actorId);
        expect(platform.events, isNot(contains('elevate')));
        expect(credentials.saved, isTrue);
        expect(profile.deviceId, 'device-one');
      },
    );

    test(
      'retries a confirmed PostgreSQL port collision with a new operation',
      () async {
        const failedOperation = '0123456789abcdef0123456789abcdef';
        platform.pending = HostSetupPendingOperation(
          operationId: failedOperation,
          requesterSid: platform.sid,
          scope: scope,
        );
        platform.statusByOperation[failedOperation] =
            const HostSetupOperationStatus(
              state: HostSetupOperationState.failed,
              failureCode: 'POSTGRES_PORT_IN_USE',
              phase: 'POSTGRES_SERVICE_PROVISIONING',
            );

        final profile = await coordinator.run(scope);

        expect(profile.actorId, _actorId);
        expect(
          platform.events,
          containsAllInOrder(['clear-pending', 'save-pending', 'elevate']),
        );
      },
    );

    test('binds a legacy saved profile to the verified Host device', () async {
      credentials
        ..token = _token
        ..profile = HostConnectionProfile(
          endpoint: hostSetupEndpoint,
          tenantId: scope.tenantId,
          companyId: scope.companyId,
          branchId: scope.branchId,
          actorId: _actorId,
        );

      final profile = await coordinator.run(scope);

      expect(platform.events, isNot(contains('elevate')));
      expect(credentials.profile?.deviceId, 'device-one');
      expect(profile.deviceId, 'device-one');
    });

    test('rejects a saved profile registered to a different device', () async {
      credentials
        ..token = _token
        ..profile = HostConnectionProfile(
          endpoint: hostSetupEndpoint,
          tenantId: scope.tenantId,
          companyId: scope.companyId,
          branchId: scope.branchId,
          actorId: _actorId,
          deviceId: 'revoked-or-other-device',
        );

      await expectLater(
        coordinator.run(scope),
        throwsA(
          isA<HostSetupException>().having(
            (error) => error.code,
            'code',
            'HOST_SESSION_IDENTITY_MISMATCH',
          ),
        ),
      );

      expect(platform.events, isNot(contains('elevate')));
      expect(credentials.profile?.deviceId, 'revoked-or-other-device');
    });

    test(
      'preserves the administrator handoff when Host readiness times out',
      () async {
        platform.ready = false;

        await expectLater(
          coordinator.run(scope),
          throwsA(
            isA<HostSetupException>().having(
              (error) => error.code,
              'code',
              'HOST_READINESS_TIMEOUT',
            ),
          ),
        );

        expect(credentials.token, isNull);
        expect(platform.events, isNot(contains('clear-result')));
        expect(platform.events, isNot(contains('clear-pending')));
        expect(platform.pending, isNotNull);
      },
    );
  });

  testWidgets('Host setup wizard persists the scope before completion', (
    tester,
  ) async {
    final platform = _FakePlatform();
    final credentials = _MemorySetupStore(
      onSave: () => platform.events.add('save'),
      identity: _adminIdentity(
        tenantId: 'tenant-ui',
        companyId: 'company-ui',
        branchId: 'branch-ui',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HostSetupPage(credentialStore: credentials, platform: platform),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    for (
      var attempt = 0;
      attempt < 8 && find.byType(TextField).evaluate().isEmpty;
      attempt++
    ) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'tenant-ui');
    await tester.enterText(fields.at(1), 'company-ui');
    await tester.enterText(fields.at(2), 'branch-ui');
    tester.testTextInput.hide();
    for (
      var attempt = 0;
      attempt < 8 && find.text('Set up Host').evaluate().isEmpty;
      attempt++
    ) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Set up Host'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Host is ready.'), findsOneWidget);
    expect(credentials.profile?.tenantId, 'tenant-ui');
    expect(
      platform.events.indexOf('save'),
      lessThan(platform.events.indexOf('clear-result')),
    );
  });

  testWidgets(
    'Host setup failure shows a reference and exports only safe diagnostics',
    (tester) async {
      final platform = _FakePlatform()
        ..status = const HostSetupOperationStatus(
          state: HostSetupOperationState.failed,
          phase: 'FIRST_ADMINISTRATOR_BOOTSTRAP',
          failureCode: 'HOST_FIRST_ADMIN_RECOVERY_AUTHORITY_FAILED',
        );
      final diagnosticSource = _MemorySetupDiagnosticSource();
      String? exported;

      await tester.pumpWidget(
        MaterialApp(
          home: HostSetupPage(
            credentialStore: _MemorySetupStore(),
            platform: platform,
            diagnosticEventSource: diagnosticSource,
            diagnosticExportHandler: (json) async => exported = json,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final list = find.byType(ListView);
      for (
        var attempt = 0;
        attempt < 8 && find.byType(TextField).evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(list, const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'tenant-ui');
      await tester.enterText(fields.at(1), 'company-ui');
      await tester.enterText(fields.at(2), 'branch-ui');
      tester.testTextInput.hide();
      for (
        var attempt = 0;
        attempt < 8 && find.text('Set up Host').evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(list, const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Set up Host'));
      await tester.pumpAndSettle();
      for (
        var attempt = 0;
        attempt < 8 &&
            find.textContaining('Diagnostic reference:').evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(list, const Offset(0, -300));
        await tester.pumpAndSettle();
      }

      expect(
        find.textContaining('protected Recovery Authority'),
        findsOneWidget,
      );
      expect(
        diagnosticSource.lastEvent!.correlationId,
        matches(RegExp(r'^cor_[a-f0-9]{32}$')),
      );
      expect(
        find.text(
          'Diagnostic reference: ${diagnosticSource.lastEvent!.correlationId}',
        ),
        findsOneWidget,
      );
      expect(
        diagnosticSource.lastInput?.component,
        'client.host_setup.first_administrator_bootstrap',
      );
      expect(
        diagnosticSource.lastInput?.category,
        ManagementDiagnosticCategory.recovery,
      );
      expect(
        diagnosticSource.lastInput?.protectedFailureType,
        'HostSetupException',
      );

      await tester.tap(find.text('Copy sanitized setup report'));
      await tester.pumpAndSettle();

      expect(exported, isNotNull);
      final report = jsonDecode(exported!) as Map<String, dynamic>;
      final events = (report['events'] as List).cast<Map<String, dynamic>>();
      expect(events, hasLength(1));
      expect(
        events.single['code'],
        'HOST_FIRST_ADMIN_RECOVERY_AUTHORITY_FAILED',
      );
      expect(
        events.single['correlationId'],
        diagnosticSource.lastEvent!.correlationId,
      );
      expect(events.single.keys, isNot(contains('protectedFailureType')));
      expect(events.single.keys, isNot(contains('protectedFailureSource')));
      expect(exported, isNot(contains('tenant-ui')));
      expect(exported, isNot(contains(_token)));
      expect(find.text('Sanitized Host setup report copied.'), findsOneWidget);
    },
  );

  testWidgets(
    'explains that LAN setup requires a trusted Windows network profile',
    (tester) async {
      final platform = _FakePlatform()
        ..status = const HostSetupOperationStatus(
          state: HostSetupOperationState.failed,
          phase: 'HOST_LAN_CONFIGURATION',
          failureCode: 'HOST_LAN_TRUSTED_NETWORK_REQUIRED',
        );
      final diagnostics = _MemorySetupDiagnosticSource();

      await tester.pumpWidget(
        MaterialApp(
          home: HostSetupPage(
            credentialStore: _MemorySetupStore(),
            platform: platform,
            diagnosticEventSource: diagnostics,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _submitMinimalHostSetup(tester);

      expect(
        find.textContaining('Private or authenticated Domain network'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Public networks stay closed'),
        findsOneWidget,
      );
      expect(diagnostics.lastEvent?.code, 'HOST_LAN_TRUSTED_NETWORK_REQUIRED');
    },
  );

  testWidgets(
    'exports a safe setup summary when local diagnostic storage is unavailable',
    (tester) async {
      final platform = _FakePlatform()
        ..status = const HostSetupOperationStatus(
          state: HostSetupOperationState.failed,
          phase: 'DATABASE_INITIALIZATION',
          failureCode: 'HOST_FIRST_ADMIN_DATABASE_CONNECTION_FAILED',
        );
      final diagnosticSource = _MemorySetupDiagnosticSource()
        ..failRecord = true;
      String? exported;

      await tester.pumpWidget(
        MaterialApp(
          home: HostSetupPage(
            credentialStore: _MemorySetupStore(),
            platform: platform,
            diagnosticEventSource: diagnosticSource,
            diagnosticExportHandler: (json) async => exported = json,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final list = find.byType(ListView);
      for (
        var attempt = 0;
        attempt < 8 && find.byType(TextField).evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(list, const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'tenant-ui');
      await tester.enterText(fields.at(1), 'company-ui');
      await tester.enterText(fields.at(2), 'branch-ui');
      tester.testTextInput.hide();
      for (
        var attempt = 0;
        attempt < 8 && find.text('Set up Host').evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(list, const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Set up Host'));
      await tester.pumpAndSettle();
      for (
        var attempt = 0;
        attempt < 8 &&
            find
                .textContaining('Copy sanitized setup report')
                .evaluate()
                .isEmpty;
        attempt++
      ) {
        await tester.drag(list, const Offset(0, -300));
        await tester.pumpAndSettle();
      }

      expect(
        find.textContaining('could not be saved on this device'),
        findsOneWidget,
      );
      await tester.tap(find.text('Copy sanitized setup report'));
      await tester.pumpAndSettle();

      expect(exported, isNotNull);
      expect(exported, contains('HOST_FIRST_ADMIN_DATABASE_CONNECTION_FAILED'));
      expect(exported, isNot(contains('password=store-test-secret')));
      expect(exported, isNot(contains(r'C:\Users\Alice')));
      expect(exported, isNot(contains('StateError')));
      final report = jsonDecode(exported!) as Map<String, dynamic>;
      final event = ((report['events'] as List).single as Map)
          .cast<String, dynamic>();
      expect(event['correlationId'], matches(RegExp(r'^cor_[a-f0-9]{32}$')));
      expect(event.keys, isNot(contains('protectedFailureType')));
    },
  );

  testWidgets('waits for pending scope restoration and locks its fields', (
    tester,
  ) async {
    final pending = HostSetupPendingOperation(
      operationId: '0123456789abcdef0123456789abcdef',
      requesterSid: 'S-1-5-21-1000-1000-1000-1001',
      scope: HostSetupScope(
        tenantId: 'saved-tenant',
        companyId: 'saved-company',
        branchId: 'saved-branch',
      ),
    );
    final platform = _FakePlatform()
      ..pending = pending
      ..pendingReadGate = Completer<HostSetupPendingOperation?>();
    final credentials = _MemorySetupStore();

    await tester.pumpWidget(
      MaterialApp(
        home: HostSetupPage(credentialStore: credentials, platform: platform),
      ),
    );
    await tester.pump();

    expect(find.byType(TextField), findsNothing);

    platform.pendingReadGate!.complete(pending);
    await tester.pumpAndSettle();

    final list = find.byType(ListView);
    for (
      var attempt = 0;
      attempt < 8 && find.byType(TextField).evaluate().isEmpty;
      attempt++
    ) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields, hasLength(3));
    expect(fields.every((field) => field.enabled == false), isTrue);
    expect(find.text('saved-tenant'), findsOneWidget);
    expect(find.text('saved-company'), findsOneWidget);
    expect(find.text('saved-branch'), findsOneWidget);
  });
}

class _FakePlatform implements HostSetupPlatform {
  final events = <String>[];
  final startedServices = <String>[];
  final states = <String, HostWindowsServiceState>{
    'VentioPostgres': HostWindowsServiceState.notInstalled,
    'VentioHost': HostWindowsServiceState.notInstalled,
  };
  final sid = 'S-1-5-21-1000-1000-1000-1001';
  bool elevationAccepted = true;
  bool processIsElevated = false;
  bool publishStatusOnElevation = true;
  bool ready = true;
  HostSetupPendingOperation? pending;
  Completer<HostSetupPendingOperation?>? pendingReadGate;
  HostSetupOperationStatus status = const HostSetupOperationStatus(
    state: HostSetupOperationState.pending,
  );
  final statusByOperation = <String, HostSetupOperationStatus>{};
  HostFirstAdministratorReply reply = HostFirstAdministratorReply(
    success: true,
    status: 'pending',
    requestId: _requestId,
    actorId: _actorId,
    token: _token,
    expiresAt: DateTime.now()
        .toUtc()
        .add(const Duration(days: 1))
        .toIso8601String(),
  );

  @override
  bool get supportsHostSetup => true;

  @override
  Future<bool> currentProcessIsElevated() async => processIsElevated;

  @override
  Future<String> currentUserSid() async => sid;

  @override
  Future<HostSetupPendingOperation?> readPendingOperation() async =>
      pendingReadGate == null ? pending : await pendingReadGate!.future;

  @override
  Future<void> savePendingOperation(HostSetupPendingOperation operation) async {
    pending = operation;
    events.add('save-pending');
  }

  @override
  Future<void> clearPendingOperation() async {
    events.add('clear-pending');
    pending = null;
  }

  @override
  Future<bool> requestAdministratorSetup(
    HostSetupPendingOperation operation,
  ) async {
    events.add('elevate');
    if (elevationAccepted && publishStatusOnElevation) {
      status = const HostSetupOperationStatus(
        state: HostSetupOperationState.complete,
        phase: 'HOST_READINESS',
      );
    }
    return elevationAccepted;
  }

  @override
  Future<HostSetupOperationStatus> setupOperationStatus(
    String operationId,
  ) async => statusByOperation[operationId] ?? status;

  @override
  Future<HostFirstAdministratorReply> readBootstrapResult(
    String operationId,
  ) async {
    events.add('read-result');
    return reply;
  }

  @override
  Future<void> clearBootstrapResult(String operationId) async {
    events.add('clear-result');
  }

  @override
  Future<HostWindowsServiceState> serviceState(String serviceName) async {
    events.add('status:$serviceName');
    return states[serviceName] ?? HostWindowsServiceState.notInstalled;
  }

  @override
  Future<bool> waitForHostReadiness() async {
    events.add('ready');
    return ready;
  }
}

class _MemorySetupDiagnosticSource implements DiagnosticEventSource {
  LocalDiagnosticInput? lastInput;
  ManagementDiagnosticEvent? lastEvent;
  bool failRecord = false;

  @override
  Future<ManagementDiagnosticEvent> record(LocalDiagnosticInput input) async {
    lastInput = input;
    if (failRecord) {
      throw StateError(
        r'password=store-test-secret C:\Users\Alice\diagnostics.sqlite3',
      );
    }
    return lastEvent = ManagementDiagnosticEvent(
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
      protectedTechnicalCode: input.protectedTechnicalCode,
      protectedFailureType: input.protectedFailureType,
      protectedFailureSource: input.protectedFailureSource,
    );
  }

  @override
  Future<List<ManagementDiagnosticEvent>> recent({int limit = 100}) async =>
      lastEvent == null ? const [] : [lastEvent!];

  @override
  Future<String> exportJson({int limit = 100}) async => jsonEncode({
    'events': [if (lastEvent != null) lastEvent!.toJson()],
  });
}

class _MemorySetupStore implements HostSetupCredentialStore {
  _MemorySetupStore({this.onSave, HostSessionIdentity? identity})
    : identity = identity ?? _adminIdentity();

  final void Function()? onSave;
  final HostSessionIdentity identity;
  String? token;
  HostConnectionProfile? profile;
  bool failSave = false;
  bool saved = false;

  @override
  Future<String?> readCredential(Uri endpoint) async => token;

  @override
  Future<HostConnectionProfile?> readProfile() async => profile;

  @override
  Future<HostConnectionProfile> verifyAndBindExistingProfile(
    HostConnectionProfile profile,
  ) async {
    final verified = _bind(profile);
    if (verified.deviceId != profile.deviceId) this.profile = verified;
    return verified;
  }

  @override
  Future<HostConnectionProfile> saveCredentialAndProfile({
    required Uri endpoint,
    required String token,
    required HostConnectionProfile profile,
  }) async {
    if (failSave) throw StateError('Test storage failure');
    this.token = token;
    final verified = _bind(profile);
    this.profile = verified;
    saved = true;
    onSave?.call();
    return verified;
  }

  HostConnectionProfile _bind(HostConnectionProfile profile) {
    try {
      return bindHostProfileToIdentity(
        profile: profile,
        identity: identity,
        requireHostAdministration: true,
      );
    } on HostSessionIdentityException catch (error) {
      throw HostSetupException(error.code);
    }
  }
}

HostSessionIdentity _adminIdentity({
  String tenantId = 'tenant-one',
  String companyId = 'company-one',
  String branchId = 'branch-one',
  String actorId = _actorId,
  Iterable<String> permissions = const {
    hostStatusReadPermission,
    hostDiagnosticsReadPermission,
    identityUsersManagePermission,
    identityDevicesManagePermission,
    identityPairingManagePermission,
    identityRolesManagePermission,
  },
}) => HostSessionIdentity(
  tenantId: tenantId,
  actorId: actorId,
  deviceId: 'device-one',
  persistent: true,
  roleAdministrationAvailable: true,
  scopes: [
    HostScopeGrant(
      companyId: companyId,
      branchId: branchId,
      permissions: permissions,
    ),
  ],
);
