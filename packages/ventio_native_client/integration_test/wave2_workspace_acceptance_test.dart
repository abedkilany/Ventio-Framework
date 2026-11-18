// PREPARED / NOT EXECUTED. Desktop integration runner only. A later invocation
// builds a test application; no build or invocation is authorized by preparation.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/workspace_page.dart';
import 'package:ventio_native_client/src/document_activity_page.dart';
import 'package:ventio_native_client/ventio_native_client.dart';

import '../../ventio_host_api/test/support/wave2_fixture.dart';

class _EphemeralCredentials implements HostCredentialBackend {
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late W2Fixture f;
  late Directory root;
  late LocalExtensionStore extensions;
  late LocalCommandQueue queue;
  late Uri endpoint;
  setUpAll(() async {
    final support = Platform.environment['VENTIO_APP_SUPPORT_DIRECTORY'];
    if ((!Platform.isWindows && !Platform.isLinux) ||
        support == null ||
        !Directory(support).isAbsolute ||
        !RegExp(r'ventio-wave2-ui-[A-Za-z0-9_-]+$').hasMatch(support)) {
      throw StateError(
        'Explicit unique desktop fixture app-support directory required; no default user data is used',
      );
    }
    if (await Directory(support).exists() &&
        !await Directory(support).list().isEmpty) {
      throw StateError('UI fixture support directory must initially be empty');
    }
    sqfliteFfiInit();
    f = await W2Fixture.open();
    endpoint = Uri.parse('http://127.0.0.1:${f.api.port}');
  });
  tearDownAll(() async {
    await f.close();
  });
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ventio-wave2-widget-data-');
    extensions = await LocalExtensionStore.open(
      factory: databaseFactoryFfi,
      path: '${root.path}/metadata.sqlite',
    );
    queue = await LocalCommandQueue.open(
      factory: databaseFactoryFfi,
      path: '${root.path}/queue.sqlite',
    );
    await extensions.installBundle(ExtensionBundle.fromJson(w2BundleJson()));
    await extensions.activate(w2Module);
  });
  tearDown(() async {
    await extensions.close();
    await queue.close();
    await root.delete(recursive: true);
  });
  Future<void> show(
    WidgetTester tester,
    W2Identity user, {
    double width = 1280,
    double scale = 1,
  }) async {
    final profile = HostConnectionProfile(
      endpoint: endpoint.toString(),
      tenantId: user.tenant,
      companyId: W2Fixture.company,
      branchId: W2Fixture.branch,
      actorId: user.actor,
      deviceId: user.device,
    );
    await extensions.saveHostProfile(profile);
    final vault = HostCredentialVault(_EphemeralCredentials());
    await vault.save(endpoint, user.token);
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: WorkspacePage(
          client: HostExtensionPackageClient(
            endpoint: endpoint,
            credentials: vault,
          ),
          profile: profile,
          extensions: extensions,
          queue: queue,
        ),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 20),
    );
    final banners = find.byType(MaterialBanner).evaluate();
    for (final banner in banners) {
      final content = (banner.widget as MaterialBanner).content;
      if (content is Text) debugPrint('WAVE2_UI_BANNER: ${content.data}');
    }
    if (banners.isNotEmpty) {
      debugPrint('WAVE2_HOST_DIAGNOSTICS: ${f.diagnostics.recent().map((e) => e.toJson()).toList()}');
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  void reportDiagnostics(WidgetTester tester) {
    for (final element in find.byType(MaterialBanner).evaluate()) {
      final content = (element.widget as MaterialBanner).content;
      if (content is Text) debugPrint('WAVE2_UI_BANNER: ${content.data}');
    }
    debugPrint('WAVE2_HOST_DIAGNOSTICS: ${f.diagnostics.recent().map((e) => e.toJson()).toList()}');
  }

  Future<void> awaitReport(WidgetTester tester) async {
    // pumpAndSettle only waits for scheduled frames. An actual HTTP/database
    // request can be pending with no animation, so wait for its visible outcome.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (find.byType(AlertDialog).evaluate().isEmpty &&
        find.byType(MaterialBanner).evaluate().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    if (find.byType(AlertDialog).evaluate().isEmpty) reportDiagnostics(tester);
  }

  testWidgets(
    'W2-G001 [C08,F05,B09] workspace exposes only current approved installed modules and native navigation',
    (tester) async {
      try {
        await show(tester, f.author);
        expect(find.text('Wave 2 fixture'), findsOneWidget);
        expect(find.text('Saved views'), findsWidgets);
        await tester.tap(find.text('Wave 2 fixture'));
        await tester.pumpAndSettle();
        expect(find.text('Asset'), findsWidgets);
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    },
  );
  testWidgets(
    'W2-G002 [C08,D09] locally installed metadata grants no navigation without current package authority',
    (tester) async {
      final limited = await f.provision(
        'ui-limited',
        permissions: ['platform.workspace.use'],
      );
      try {
        await show(tester, limited);
        expect(find.text('Wave 2 fixture'), findsNothing);
        expect(
          find.text(
            'No authorized, installed Host-approved modules are available.',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    },
  );
  testWidgets(
    'W2-G003 [C08,F05] a local package digest mismatch contributes no authorized workspace links',
    (tester) async {
      final tampered = w2BundleJson();
      (tampered['englishCatalog'] as Map)['$w2Label.name'] =
          'Changed local label';
      // A fresh local installation can contain an unapproved package. Existing
      // installed releases now correctly refuse same-version content changes.
      await extensions.close();
      extensions = await LocalExtensionStore.open(
        factory: databaseFactoryFfi, path: '${root.path}/unapproved.sqlite');
      await extensions.installBundle(ExtensionBundle.fromJson(tampered));
      await extensions.activate(w2Module);
      try {
        await show(tester, f.author);
        expect(find.text('Wave 2 fixture'), findsNothing);
        expect(
          find.text(
            'No authorized, installed Host-approved modules are available.',
          ),
          findsOneWidget,
        );
      } finally {
        await unmount(tester);
      }
    },
  );
  testWidgets(
    'W2-G004 [C08,C09,C12] narrow large-text workspace navigation has no overflow or uncaught rendering error',
    (tester) async {
      try {
        await show(tester, f.reader, width: 320, scale: 2);
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byIcon(Icons.dashboard_outlined));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byIcon(Icons.settings_outlined));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    },
  );
  testWidgets(
    'W2-G005 [A11,A12,K09] repeated Host customization labels refresh in the same app session',
    (tester) async {
      final bundle = ExtensionBundle.fromJson(w2BundleJson());
      Map<String, dynamic> overlay(String label) =>
          w2Overlay(hash: f.digest(bundle))
            ..['properties'] = {
              'label': label,
              'labelKey': '$w2Label.custom.asset_title',
            };
      await f.save(
        'customization',
        '$w2Module:1.0.0:Asset',
        overlay('First customized asset'),
        request: 500,
      );
      try {
        await show(tester, f.author);
        await tester.tap(find.text('Wave 2 fixture'));
        await tester.pumpAndSettle();
        expect(find.text('First customized asset'), findsWidgets);
        await f.save(
          'customization',
          '$w2Module:1.0.0:Asset',
          overlay('Second customized asset'),
          request: 501,
          expected: 1,
        );
        await tester.tap(find.byTooltip('Refresh authorization and data'));
        await tester.pumpAndSettle();
        if (find.text('Second customized asset').evaluate().isEmpty) {
          reportDiagnostics(tester);
        }
        expect(find.text('Second customized asset'), findsWidgets);
        expect(find.text('First customized asset'), findsNothing);
      } finally {
        await unmount(tester);
      }
    },
  );
  testWidgets(
    'W2-G006 [C12,F05] a saved dashboard card opens a real current-authorized Host report',
    (tester) async {
      await f.execute(f.command(600));
      await f.save('dashboard', 'live-assets', {
        'contractVersion': 1,
        'title': 'Live assets',
        'cards': [
          {
            'title': 'Current assets',
            'moduleId': w2Module,
            'moduleVersion': '1.0.0',
            'docType': 'Asset',
            'reportId': 'asset_count',
            'filters': <String, dynamic>{},
          },
        ],
      }, request: 600);
      try {
        await show(tester, f.author);
        await tester.tap(find.byIcon(Icons.dashboard_outlined));
        await tester.pumpAndSettle();
        expect(find.text('Current assets'), findsOneWidget);
        await tester.tap(find.text('Open current Host report'));
        await awaitReport(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('Count: 1'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    },
  );
  testWidgets(
    'W2-G007 [H04,D08] native document activity renders real command identity without protected values',
    (tester) async {
      final command = f.command(
        700,
        values: {'name': 'Activity', 'secret': 'ui-secret-sentinel'},
      );
      await f.execute(command);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: DocumentActivityPage(
              request: (action, body) => f.call(action, fields: body),
              binding: {
                'moduleId': w2Module,
                'moduleVersion': '1.0.0',
                'docType': 'Asset',
                'recordId': command.aggregateId,
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining(command.commandId), findsWidgets);
        expect(find.textContaining('ui-secret-sentinel'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    },
  );
}
