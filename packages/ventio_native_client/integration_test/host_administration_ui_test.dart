import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_native_client/main.dart';
import 'package:ventio_native_client/src/device_management_page.dart';
import 'package:ventio_native_client/src/diagnostics_center_page.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/host_device_management.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';
import 'package:ventio_native_client/src/host_user_management.dart';
import 'package:ventio_native_client/src/host_overview_page.dart';
import 'package:ventio_native_client/src/host_settings_page.dart';
import 'package:ventio_native_client/src/local_command_queue.dart';
import 'package:ventio_native_client/src/local_diagnostics.dart';
import 'package:ventio_native_client/src/role_administration_page.dart';
import 'package:ventio_native_client/src/synchronization_page.dart';
import 'package:ventio_native_client/src/users_permissions_page.dart';

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

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 240; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
}

Future<void> _tapToolbarAction(
  WidgetTester tester, {
  required String label,
  required Finder page,
}) async {
  final action = find.widgetWithText(TextButton, label);
  expect(
    action,
    findsOneWidget,
    reason: 'Missing Windows toolbar action: $label',
  );
  await tester.tap(action);
  await _waitFor(tester, page);
  await tester.pumpAndSettle();
}

Future<void> _openAdministrationAction(
  WidgetTester tester, {
  required String label,
  required Finder page,
}) async {
  await tester.tap(find.byTooltip('Host administration'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await _waitFor(tester, page);
  await tester.pumpAndSettle();
}

Future<void> _returnToWorkspace(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  await _waitFor(tester, find.widgetWithText(TextButton, 'Host settings'));
}

String _safeVisibleTextSummary(WidgetTester tester) {
  final values = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final widget = element.widget as Text;
    final value = widget.data ?? widget.textSpan?.toPlainText() ?? '';
    if (value.isNotEmpty) values.add(value);
  }
  for (final element in find.byType(SelectableText).evaluate()) {
    final widget = element.widget as SelectableText;
    final value = widget.data;
    if (value != null && value.isNotEmpty) values.add(value);
  }
  final redacted = values
      .map(
        (value) =>
            value.replaceAll(RegExp(r'\b[A-Za-z0-9_-]{40,}\b'), '[REDACTED]'),
      )
      .take(30);
  return redacted.join(' | ');
}

Future<({int statusCode, Map<String, dynamic> body})> _postHostJson(
  Uri endpoint,
  String token,
  String route,
  Map<String, Object?> body,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.postUrl(endpoint.replace(path: route));
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8')
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.write(jsonEncode(body));
    final response = await request.close();
    final raw = await utf8.decoder.bind(response).join();
    return (
      statusCode: response.statusCode,
      body: jsonDecode(raw) as Map<String, dynamic>,
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows Host administration UI uses real Host APIs and exact-scope grants',
    (tester) async {
      final environment = Platform.environment;
      String requiredValue(String name) {
        final value = environment[name];
        if (value == null || value.isEmpty) {
          throw StateError(
            'Required Host UI integration value is missing: $name',
          );
        }
        return value;
      }

      final endpoint = Uri.parse(requiredValue('VENTIO_HOST_UI_ENDPOINT'));
      final writerToken = requiredValue('VENTIO_HOST_UI_WRITER_TOKEN');
      final readerToken = requiredValue('VENTIO_HOST_UI_READER_TOKEN');
      final tenant = requiredValue('VENTIO_HOST_UI_TENANT');
      final company = requiredValue('VENTIO_HOST_UI_COMPANY');
      final branch = requiredValue('VENTIO_HOST_UI_BRANCH');
      final actor = requiredValue('VENTIO_HOST_UI_ACTOR');
      final device = requiredValue('VENTIO_HOST_UI_DEVICE');

      sqfliteFfiInit();
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;

      final tempRoot = p.normalize(Directory.systemTemp.path);
      final directory = await Directory.systemTemp.createTemp(
        'ventio-host-admin-ui-',
      );
      final normalizedDirectory = p.normalize(directory.path);
      if (!p.isWithin(tempRoot, normalizedDirectory)) {
        throw StateError('Host UI integration storage escaped the temp root.');
      }

      final queue = await LocalCommandQueue.open(
        factory: databaseFactoryFfi,
        path: p.join(directory.path, 'client-queue.sqlite3'),
      );
      final store = await LocalExtensionStore.open(
        factory: databaseFactoryFfi,
        path: p.join(directory.path, 'client-profile.sqlite3'),
      );
      final diagnostics = await LocalDiagnosticsStore.open(
        factory: databaseFactoryFfi,
        path: p.join(directory.path, 'client-diagnostics.sqlite3'),
      );
      final credentials = HostCredentialVault(_MemoryCredentialBackend());

      Future<void> pumpApp(String key) async {
        await tester.pumpWidget(
          VentioClientApp(
            key: ValueKey(key),
            queue: queue,
            extensionStore: store,
            credentialVault: credentials,
            diagnosticEventSource: diagnostics,
          ),
        );
        await _waitFor(
          tester,
          find.widgetWithText(TextButton, 'Host settings'),
        );
      }

      try {
        await credentials.save(endpoint, readerToken);
        await store.saveHostProfile(
          HostConnectionProfile(
            endpoint: endpoint.toString(),
            tenantId: tenant,
            companyId: company,
            branchId: branch,
            actorId: 'host-reader',
            deviceId: 'windows-reader-device',
          ),
        );
        await pumpApp('reader');
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byTooltip('Host administration'), findsNothing);
        expect(
          find.widgetWithText(TextButton, 'Host overview'),
          findsNothing,
          reason: 'A reader without the status grant must not see Host status.',
        );

        await credentials.save(endpoint, writerToken);
        await store.saveHostProfile(
          HostConnectionProfile(
            endpoint: endpoint.toString(),
            tenantId: tenant,
            companyId: company,
            branchId: branch,
            actorId: actor,
            deviceId: device,
          ),
        );
        await pumpApp('administrator');
        await _waitFor(tester, find.byTooltip('Host administration'));
        expect(tester.takeException(), isNull);

        final hostIdentity = await HostExtensionPackageClient(
          endpoint: endpoint,
          credentials: credentials,
        ).session();
        final userManagementClient = HostUserManagementClient(
          endpoint: endpoint,
          credentials: credentials,
          verifiedIdentity: hostIdentity,
          companyId: company,
          branchId: branch,
        );
        final deviceInventory = await HostDeviceManagementClient(
          endpoint: endpoint,
          credentials: credentials,
          verifiedIdentity: hostIdentity,
          companyId: company,
          branchId: branch,
        ).listDevices();
        expect(
          deviceInventory.devices.map((item) => item.deviceId),
          contains(device),
        );

        await _tapToolbarAction(
          tester,
          label: 'Host overview',
          page: find.byType(HostOverviewPage),
        );
        await _waitFor(tester, find.byType(SelectableText));
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await _returnToWorkspace(tester);

        await _tapToolbarAction(
          tester,
          label: 'Host settings',
          page: find.byType(HostSettingsPage),
        );
        expect(find.text('Verified Host session'), findsOneWidget);
        expect(find.text(actor), findsOneWidget);
        expect(find.text(device), findsOneWidget);
        await _returnToWorkspace(tester);

        await _tapToolbarAction(
          tester,
          label: 'Local diagnostics',
          page: find.byType(DiagnosticsCenterPage),
        );
        await _waitFor(tester, find.text('Host diagnostics'));
        for (var attempt = 0; attempt < 120; attempt++) {
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('No recent Host diagnostic events'), findsOneWidget);
        await _returnToWorkspace(tester);

        await _tapToolbarAction(
          tester,
          label: 'Synchronization',
          page: find.byType(SynchronizationPage),
        );
        await _waitFor(tester, find.text('No queued operations'));
        await _returnToWorkspace(tester);

        await _openAdministrationAction(
          tester,
          label: 'Host devices & pairing',
          page: find.byType(DeviceManagementPage),
        );
        await _waitFor(tester, find.text(device));
        await _waitFor(
          tester,
          find.byKey(const ValueKey('pairing-target-user')),
        );
        await tester.tap(find.byKey(const ValueKey('generate-pairing-code')));
        await _waitFor(
          tester,
          find.byKey(const ValueKey('generated-pairing-code')),
        );
        expect(tester.takeException(), isNull);
        await _returnToWorkspace(tester);

        await _openAdministrationAction(
          tester,
          label: 'Manage roles & access',
          page: find.byType(RoleAdministrationPage),
        );
        final roleId = 'ui-smoke-${DateTime.now().millisecondsSinceEpoch}';
        await tester.tap(find.text('Create role'));
        await tester.pumpAndSettle();
        final roleFields = find.byType(TextFormField);
        await tester.enterText(roleFields.at(0), roleId);
        await tester.enterText(roleFields.at(1), 'UI Smoke Role');
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await _waitFor(tester, find.text('UI Smoke Role'));
        await _returnToWorkspace(tester);

        await _openAdministrationAction(
          tester,
          label: 'Users & permissions',
          page: find.byType(UsersPermissionsPage),
        );
        await _waitFor(tester, find.byKey(ValueKey('managed-user-$actor')));
        await tester.tap(find.text('Create user'));
        final generatedUserId = find.textContaining('Generated user ID:');
        for (
          var attempt = 0;
          attempt < 240 && generatedUserId.evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          generatedUserId,
          findsWidgets,
          reason: 'Host user-management UI: ${_safeVisibleTextSummary(tester)}',
        );
        final generatedUserText = tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((widget) => widget.data)
            .whereType<String>()
            .firstWhere(
              (value) => value.contains('Generated user ID:'),
              orElse: () => '',
            );
        if (generatedUserText.isEmpty) {
          throw StateError('Host did not render the generated user ID.');
        }
        final createdActorId = RegExp(
          r'usr_[0-9a-f]{32}',
        ).firstMatch(generatedUserText)?.group(0);
        if (createdActorId == null) {
          throw StateError('Host did not return a generated user ID.');
        }
        await _waitFor(tester, find.text('User created'));
        expect(
          find.text('Could not load recent administrative activity'),
          findsNothing,
          reason: 'Host audit UI: ${_safeVisibleTextSummary(tester)}',
        );
        final managedUserCard = find.byKey(
          ValueKey('managed-user-$createdActorId'),
        );
        await _waitFor(tester, managedUserCard);
        final createdUserRow = find.descendant(
          of: managedUserCard,
          matching: find.byType(ListTile),
        );
        await tester.ensureVisible(createdUserRow);
        await tester.tap(createdUserRow);
        await tester.pumpAndSettle();
        final grantPermissionAction = find.descendant(
          of: managedUserCard,
          matching: find.text('Grant permission'),
        );
        expect(
          grantPermissionAction,
          findsOneWidget,
          reason: 'Created user card: ${_safeVisibleTextSummary(tester)}',
        );
        await tester.tap(grantPermissionAction);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextFormField).last,
          'maintenance.read',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();
        expect(
          find.byType(AlertDialog),
          findsNothing,
          reason:
              'Permission dialog did not submit: ${_safeVisibleTextSummary(tester)}',
        );
        final cardPermissionAction = find.descendant(
          of: managedUserCard,
          matching: find.text('Grant permission'),
        );
        for (
          var attempt = 0;
          attempt < 240 &&
              find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final rawInventoryAfterGrant = await _postHostJson(
          endpoint,
          writerToken,
          '/api/v1/management/users/list',
          {'managementApiVersion': 1, 'companyId': company, 'branchId': branch},
        );
        final rawAuditAfterGrant = await _postHostJson(
          endpoint,
          writerToken,
          '/api/v1/management/users/audit',
          {'managementApiVersion': 1, 'companyId': company, 'branchId': branch},
        );
        final auditConfirmsTarget =
            ((rawAuditAfterGrant.body['audit'] as Map)['events'] as List)
                .cast<Map>()
                .any(
                  (event) =>
                      event['action'] == 'PERMISSION_GRANTED' &&
                      event['subjectId'] == createdActorId,
                );
        expect(
          auditConfirmsTarget,
          isTrue,
          reason:
              'Host audit did not confirm a grant for the newly created user: ${_safeVisibleTextSummary(tester)}',
        );
        final rawUserAfterGrant =
            ((rawInventoryAfterGrant.body['users'] as Map)['items'] as List)
                .cast<Map>()
                .singleWhere((user) => user['actorId'] == createdActorId);
        expect(
          (rawUserAfterGrant['directPermissions'] as List),
          contains('maintenance.read'),
          reason: 'Raw Host response after UI grant is empty.',
        );
        final userAfterGrant = (await userManagementClient.listUsers()).users
            .singleWhere((user) => user.actorId == createdActorId);
        expect(
          userAfterGrant.directPermissions,
          contains('maintenance.read'),
          reason: 'Host did not return the confirmed direct permission.',
        );
        if (cardPermissionAction.evaluate().isEmpty) {
          await tester.ensureVisible(createdUserRow);
          await tester.tap(createdUserRow);
          await tester.pumpAndSettle();
        }
        final grantedPermission = find.widgetWithText(
          InputChip,
          'maintenance.read',
        );
        for (
          var attempt = 0;
          attempt < 240 && grantedPermission.evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          grantedPermission,
          findsOneWidget,
          reason:
              'Host permission grant UI: ${_safeVisibleTextSummary(tester)}',
        );
        await tester.tap(find.byTooltip('Revoke permission').last);
        for (
          var attempt = 0;
          attempt < 240 && find.text('Permission revoked').evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          find.text('Permission revoked'),
          findsWidgets,
          reason:
              'Host permission revoke audit: ${_safeVisibleTextSummary(tester)}',
        );
        final userAfterRevoke = (await userManagementClient.listUsers()).users
            .singleWhere((user) => user.actorId == createdActorId);
        expect(
          userAfterRevoke.directPermissions,
          isNot(contains('maintenance.read')),
          reason: 'Host retained a direct permission after revoke.',
        );
        if (cardPermissionAction.evaluate().isEmpty) {
          await tester.ensureVisible(createdUserRow);
          await tester.tap(createdUserRow);
          await tester.pumpAndSettle();
        }
        expect(cardPermissionAction, findsOneWidget);
        expect(grantedPermission, findsNothing);
        expect(tester.takeException(), isNull);
        await _returnToWorkspace(tester);

        await store.saveHostProfile(
          HostConnectionProfile(
            endpoint: endpoint.toString(),
            tenantId: tenant,
            companyId: company,
            branchId: 'branch-outside-grant',
            actorId: actor,
            deviceId: device,
          ),
        );
        await pumpApp('cross-scope');
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byTooltip('Host administration'), findsNothing);

        final unavailableEndpoint = Uri.parse('http://127.0.0.1:1');
        await credentials.save(unavailableEndpoint, writerToken);
        await store.saveHostProfile(
          HostConnectionProfile(
            endpoint: unavailableEndpoint.toString(),
            tenantId: tenant,
            companyId: company,
            branchId: branch,
            actorId: actor,
            deviceId: device,
          ),
        );
        await pumpApp('disconnected');
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byTooltip('Host administration'), findsNothing);
        await _tapToolbarAction(
          tester,
          label: 'Host settings',
          page: find.byType(HostSettingsPage),
        );
        expect(find.text('Host session is not verified'), findsOneWidget);
        await _returnToWorkspace(tester);
        await _tapToolbarAction(
          tester,
          label: 'Local diagnostics',
          page: find.byType(DiagnosticsCenterPage),
        );
        expect(find.text('Local diagnostics'), findsOneWidget);
        await _returnToWorkspace(tester);
        await _tapToolbarAction(
          tester,
          label: 'Synchronization',
          page: find.byType(SynchronizationPage),
        );
        expect(find.byType(SynchronizationPage), findsOneWidget);

        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await queue.close();
        await store.close();
        await diagnostics.close();
        await directory.delete(recursive: true);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
