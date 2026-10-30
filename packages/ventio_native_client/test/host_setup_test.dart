import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/host_setup.dart';
import 'package:ventio_native_client/src/host_setup_page.dart';

const _requestId = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';
const _token = 'BCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefgh';
const _actorId = 'usr_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';

void main() {
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
      'starts only Ventio services and saves before acknowledging',
      () async {
        final profile = await coordinator.run(scope);

        expect(platform.startedServices, ['VentioPostgres', 'VentioHost']);
        expect(
          platform.events.indexOf('save'),
          lessThan(platform.events.indexOf('ack')),
        );
        expect(
          platform.events.indexOf('ack'),
          lessThan(platform.events.indexOf('ready')),
        );
        expect(platform.events, contains('bootstrap'));
        expect(profile.tenantId, scope.tenantId);
        expect(profile.companyId, scope.companyId);
        expect(profile.branchId, scope.branchId);
        expect(profile.actorId, _actorId);
        expect(credentials.token, _token);
      },
    );

    test(
      'does not access services or broker without administrator access',
      () async {
        platform.administrator = false;

        await expectLater(
          coordinator.run(scope),
          throwsA(
            isA<HostSetupException>().having(
              (error) => error.code,
              'code',
              'HOST_SETUP_REQUIRES_ADMINISTRATOR',
            ),
          ),
        );

        expect(platform.startedServices, isEmpty);
        expect(platform.events, isNot(contains('bootstrap')));
        expect(platform.events, isNot(contains('ack')));
      },
    );

    test('does not acknowledge when secure persistence fails', () async {
      credentials.failSave = true;

      await expectLater(coordinator.run(scope), throwsA(isA<StateError>()));

      expect(platform.events, isNot(contains('ack')));
      expect(platform.events, isNot(contains('ready')));
    });

    test('rejects a missing service before requesting bootstrap', () async {
      platform.states['VentioPostgres'] = HostWindowsServiceState.notInstalled;

      await expectLater(
        coordinator.run(scope),
        throwsA(
          isA<HostSetupException>().having(
            (error) => error.code,
            'code',
            'HOST_SERVICE_NOT_INSTALLED',
          ),
        ),
      );

      expect(platform.startedServices, isEmpty);
      expect(platform.events, isNot(contains('bootstrap')));
    });

    test(
      'resumes an acknowledged bootstrap only with its saved scope',
      () async {
        platform.reply = const HostFirstAdministratorReply(
          success: true,
          status: 'acknowledged',
          requestId: _requestId,
        );
        credentials.token = _token;
        credentials.profile = HostConnectionProfile(
          endpoint: hostSetupEndpoint,
          tenantId: scope.tenantId,
          companyId: scope.companyId,
          branchId: scope.branchId,
          actorId: _actorId,
        );

        final profile = await coordinator.run(scope);

        expect(profile.actorId, _actorId);
        expect(platform.events, isNot(contains('ack')));
        expect(credentials.saved, isFalse);
      },
    );

    test(
      'does not claim readiness when the Host API check times out',
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

        expect(credentials.token, _token);
        expect(platform.events, contains('ack'));
      },
    );
  });

  testWidgets('Host setup wizard persists the scope before completion', (
    tester,
  ) async {
    final platform = _FakePlatform();
    final credentials = _MemorySetupStore(
      onSave: () => platform.events.add('save'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HostSetupPage(credentialStore: credentials, platform: platform),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    for (var attempt = 0;
        attempt < 8 && find.byType(TextField).evaluate().isEmpty;
        attempt++) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'tenant-ui');
    await tester.enterText(fields.at(1), 'company-ui');
    await tester.enterText(fields.at(2), 'branch-ui');
    tester.testTextInput.hide();
    for (var attempt = 0;
        attempt < 8 && find.text('Set up Host').evaluate().isEmpty;
        attempt++) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Set up Host'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Host is ready.'), findsOneWidget);
    expect(credentials.profile?.tenantId, 'tenant-ui');
    expect(
      platform.events.indexOf('save'),
      lessThan(platform.events.indexOf('ack')),
    );
  });
}

class _FakePlatform implements HostSetupPlatform {
  final events = <String>[];
  final startedServices = <String>[];
  final states = <String, HostWindowsServiceState>{
    'VentioPostgres': HostWindowsServiceState.stopped,
    'VentioHost': HostWindowsServiceState.stopped,
  };
  bool administrator = true;
  bool ready = true;
  HostFirstAdministratorReply reply = const HostFirstAdministratorReply(
    success: true,
    status: 'pending',
    requestId: _requestId,
    actorId: _actorId,
    token: _token,
    expiresAt: '2026-10-31T00:00:00Z',
  );

  @override
  bool get supportsHostSetup => true;

  @override
  Future<bool> isAdministrator() async {
    events.add('administrator');
    return administrator;
  }

  @override
  Future<bool> requestAdministratorSetup() async => true;

  @override
  Future<HostWindowsServiceState> serviceState(String serviceName) async {
    events.add('status:$serviceName');
    return states[serviceName] ?? HostWindowsServiceState.notInstalled;
  }

  @override
  Future<void> startService(String serviceName) async {
    events.add('start:$serviceName');
    startedServices.add(serviceName);
    states[serviceName] = HostWindowsServiceState.running;
  }

  @override
  Future<HostFirstAdministratorReply> bootstrapFirstAdministrator(
    HostSetupScope scope,
  ) async {
    events.add('bootstrap');
    return reply;
  }

  @override
  Future<void> acknowledgeFirstAdministrator(String requestId) async {
    events.add('ack');
  }

  @override
  Future<bool> waitForHostReadiness() async {
    events.add('ready');
    return ready;
  }
}

class _MemorySetupStore implements HostSetupCredentialStore {
  _MemorySetupStore({this.onSave});

  final void Function()? onSave;
  String? token;
  HostConnectionProfile? profile;
  bool failSave = false;
  bool saved = false;

  @override
  Future<String?> readCredential(Uri endpoint) async => token;

  @override
  Future<HostConnectionProfile?> readProfile() async => profile;

  @override
  Future<void> saveCredentialAndProfile({
    required Uri endpoint,
    required String token,
    required HostConnectionProfile profile,
  }) async {
    if (failSave) throw StateError('Test storage failure');
    this.token = token;
    this.profile = profile;
    saved = true;
    onSave?.call();
  }
}
