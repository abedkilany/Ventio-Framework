import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';
import 'package:ventio_native_client/src/host_settings_page.dart';

void main() {
  testWidgets('updates only the endpoint trust after fingerprint validation', (
    tester,
  ) async {
    String? receivedFingerprint;
    const profile = HostConnectionProfile(
      endpoint: 'https://host.example.test:8443',
      tenantId: 'tenant-1',
      companyId: 'company-1',
      branchId: 'branch-1',
      actorId: 'actor-1',
      deviceId: 'device-1',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HostSettingsPage(
          profile: profile,
          identity: null,
          onRefreshHostCertificate: (fingerprint) async {
            receivedFingerprint = fingerprint;
          },
          onConfigure: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final fingerprintField = find.byKey(
      const ValueKey('host-certificate-fingerprint'),
    );
    await tester.scrollUntilVisible(
      fingerprintField,
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      fingerprintField,
      'AA:'.replaceAll(':', '') + List.filled(31, '01').join(),
    );
    await tester.tap(
      find.byKey(const ValueKey('host-certificate-trust-update')),
    );
    await tester.pumpAndSettle();
    expect(receivedFingerprint, isNotNull);
    expect(receivedFingerprint, hasLength(64));
    expect(
      find.textContaining('Host certificate was verified'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps existing trust unchanged when certificate check fails', (
    tester,
  ) async {
    const profile = HostConnectionProfile(
      endpoint: 'https://host.example.test:8443',
      tenantId: 'tenant-1',
      companyId: 'company-1',
      branchId: 'branch-1',
      actorId: 'actor-1',
      deviceId: 'device-1',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HostSettingsPage(
          profile: profile,
          identity: null,
          onRefreshHostCertificate: (_) async => throw StateError('test'),
          onConfigure: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final fingerprintField = find.byKey(
      const ValueKey('host-certificate-fingerprint'),
    );
    await tester.scrollUntilVisible(
      fingerprintField,
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(fingerprintField, List.filled(32, 'ab').join());
    await tester.tap(
      find.byKey(const ValueKey('host-certificate-trust-update')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Host trust was not changed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows only permissions for the selected exact Host scope', (
    tester,
  ) async {
    var configureCalls = 0;
    const profile = HostConnectionProfile(
      endpoint: 'https://host.example.test',
      tenantId: 'tenant-1',
      companyId: 'company-1',
      branchId: 'branch-1',
      actorId: 'actor-1',
      deviceId: 'device-1',
    );
    final identity = HostSessionIdentity(
      tenantId: 'tenant-1',
      actorId: 'actor-1',
      deviceId: 'device-1',
      persistent: true,
      roleAdministrationAvailable: true,
      scopes: [
        HostScopeGrant(
          companyId: 'company-1',
          branchId: 'branch-1',
          permissions: const {'host.status.read', 'identity.users.manage'},
        ),
        HostScopeGrant(
          companyId: 'company-2',
          branchId: 'branch-2',
          permissions: const {'identity.roles.manage'},
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HostSettingsPage(
          profile: profile,
          identity: identity,
          onConfigure: () => configureCalls++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Host settings'), findsOneWidget);
    expect(find.text('https://host.example.test'), findsOneWidget);
    expect(find.text('tenant-1'), findsOneWidget);
    expect(find.text('company-1'), findsOneWidget);
    expect(find.text('branch-1'), findsOneWidget);
    expect(find.text('actor-1'), findsOneWidget);
    expect(find.text('device-1'), findsOneWidget);
    expect(find.text('host.status.read'), findsOneWidget);
    expect(find.text('identity.users.manage'), findsOneWidget);
    expect(find.text('identity.roles.manage'), findsNothing);

    final configureButton = find.byKey(
      const ValueKey('host-settings-configure-connection'),
    );
    await tester.scrollUntilVisible(
      configureButton,
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(configureButton);
    expect(configureCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offers local setup when no Host profile exists', (tester) async {
    var configureCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: HostSettingsPage(
          profile: null,
          identity: null,
          onConfigure: () => configureCalls++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No Host connection configured'), findsOneWidget);
    expect(find.text('Configure Host connection'), findsOneWidget);
    final configureButton = find.byKey(
      const ValueKey('host-settings-configure-connection'),
    );
    await tester.scrollUntilVisible(
      configureButton,
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(configureButton);
    expect(configureCalls, 1);
    expect(tester.takeException(), isNull);
  });
}
