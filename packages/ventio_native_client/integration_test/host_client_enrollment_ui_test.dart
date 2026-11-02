import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_native_client/src/client_pairing_page.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/host_credentials.dart';

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
    'Client pairing UI enrolls against a live Host over pinned HTTPS',
    (tester) async {
      final environment = Platform.environment;
      String requiredValue(String name) {
        final value = environment[name];
        if (value == null || value.isEmpty) {
          throw StateError(
            'Required Client enrollment value is missing: $name',
          );
        }
        return value;
      }

      final endpoint = Uri.parse(
        requiredValue('VENTIO_CLIENT_PAIRING_ENDPOINT'),
      );
      final pairingCode = requiredValue('VENTIO_CLIENT_PAIRING_CODE');
      final fingerprint = requiredValue('VENTIO_CLIENT_PAIRING_FINGERPRINT');
      final certificatePath = requiredValue(
        'VENTIO_CLIENT_PAIRING_CERTIFICATE',
      );
      final expectedTenant = requiredValue('VENTIO_CLIENT_PAIRING_TENANT');
      final expectedActor = requiredValue('VENTIO_CLIENT_PAIRING_ACTOR');
      final expectedCompany = requiredValue('VENTIO_CLIENT_PAIRING_COMPANY');
      final expectedBranch = requiredValue('VENTIO_CLIENT_PAIRING_BRANCH');

      sqfliteFfiInit();
      tester.view.physicalSize = const Size(1200, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final tempRoot = p.normalize(Directory.systemTemp.path);
      final directory = await Directory.systemTemp.createTemp(
        'ventio-client-enrollment-ui-',
      );
      if (!p.isWithin(tempRoot, p.normalize(directory.path))) {
        throw StateError('Client enrollment storage escaped the temp root.');
      }
      final store = await LocalExtensionStore.open(
        factory: databaseFactoryFfi,
        path: p.join(directory.path, 'client-profile.sqlite3'),
      );
      final credentials = HostCredentialVault(_MemoryCredentialBackend());
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ClientPairingPage(
              store: store,
              credentials: credentials,
              initialEndpoint: endpoint.toString(),
            ),
          ),
        );
        await tester.enterText(
          find.byKey(const ValueKey('client-pairing-fingerprint')),
          fingerprint,
        );
        await tester.enterText(
          find.byKey(const ValueKey('client-pairing-code')),
          pairingCode,
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
        expect(find.textContaining(expectedCompany), findsOneWidget);
        expect(find.textContaining(expectedBranch), findsOneWidget);
        expect(find.textContaining(pairingCode), findsNothing);

        final profile = await store.getHostProfile();
        expect(profile, isNotNull);
        expect(profile!.endpoint, endpoint.toString());
        expect(profile.tenantId, expectedTenant);
        expect(profile.actorId, expectedActor);
        expect(profile.companyId, expectedCompany);
        expect(profile.branchId, expectedBranch);
        expect(profile.deviceId, matches(RegExp(r'^client_[0-9a-f]{32}$')));

        final credential = await credentials.read(endpoint);
        expect(credential, isNotNull);
        expect(credential, matches(RegExp(r'^[A-Za-z0-9_-]{43,128}$')));

        final trustedContext = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(certificatePath);
        final client = HttpClient(context: trustedContext)
          ..connectionTimeout = const Duration(seconds: 5);
        try {
          final request = await client.getUrl(
            endpoint.replace(path: '/api/v1/session'),
          );
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer $credential',
          );
          final response = await request.close();
          final body =
              jsonDecode(await utf8.decoder.bind(response).join())
                  as Map<String, dynamic>;
          final identity = body['identity'] as Map<String, dynamic>;
          final scopes = identity['scopes'] as List;
          expect(response.statusCode, HttpStatus.ok);
          expect(identity['tenantId'], expectedTenant);
          expect(identity['actorId'], expectedActor);
          expect(identity['deviceId'], profile.deviceId);
          expect(scopes, hasLength(1));
          expect((scopes.single as Map)['companyId'], expectedCompany);
          expect((scopes.single as Map)['branchId'], expectedBranch);
        } finally {
          client.close(force: true);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
