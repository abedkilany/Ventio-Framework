import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/account_sign_in.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';

class _ProtectedBackend implements HostCredentialBackend {
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
  const password = 'Offline password phrase 42!';
  late String verifier;
  setUpAll(() async {
    verifier = await AccountPassword.hash(password);
  });
  test(
    'Password verifier is salted, slow, versioned and rejects wrong password',
    () async {
      expect(AccountPassword.validVerifier(verifier), isTrue);
      expect(verifier, isNot(contains(password)));
      expect(await AccountPassword.verify(password, verifier), isTrue);
      expect(await AccountPassword.verify('wrong', verifier), isFalse);
      expect(await AccountPassword.verify(password, 'sha256:weak'), isFalse);
    },
  );
  test(
    'Offline sign-in binds tenant, actor, device, username, expiry and clock high-water',
    () async {
      final backend = _ProtectedBackend(),
          endpoint = Uri.parse('http://127.0.0.1:8080');
      final vault = HostCredentialVault(backend);
      var now = DateTime.utc(2026, 11, 24, 10);
      final profile = HostConnectionProfile(
        endpoint: endpoint.toString(),
        tenantId: 'org-a',
        companyId: 'company',
        branchId: 'branch',
        actorId: 'actor',
        deviceId: 'device',
      );
      final signIn = AccountSignIn(
        credentials: vault,
        profile: profile,
        clock: () => now,
      );
      final base = <String, dynamic>{
        'tenantId': 'org-a',
        'actorId': 'actor',
        'deviceId': 'device',
        'username': 'owner',
        'verifier': verifier,
        'expiresAt': now.add(const Duration(hours: 8)).toIso8601String(),
        'lastSeen': now.toIso8601String(),
        'failures': 0,
      };
      await vault.writeOfflineAccount(endpoint, base);
      expect(
        await signIn.offline('OWNER', password),
        now.add(const Duration(hours: 8)),
      );
      expect(backend.values.values.join(), isNot(contains(password)));
      for (final field in ['tenantId', 'actorId', 'deviceId', 'username']) {
        await vault.writeOfflineAccount(endpoint, {
          ...base,
          field: 'different',
        });
        await expectLater(
          signIn.offline('owner', password),
          throwsA(isA<HostPackageTransportException>()),
        );
      }
      await vault.writeOfflineAccount(endpoint, base);
      now = now.subtract(const Duration(minutes: 1));
      await expectLater(
        signIn.offline('owner', password),
        throwsA(isA<HostPackageTransportException>()),
      );
      now = DateTime.utc(2026, 11, 24, 18);
      await expectLater(
        signIn.offline('owner', password),
        throwsA(isA<HostPackageTransportException>()),
      );
      now = DateTime.utc(2026, 11, 24, 10);
      await vault.writeOfflineAccount(endpoint, {...base, 'failures': 5});
      await expectLater(
        signIn.offline('owner', password),
        throwsA(isA<HostPackageTransportException>()),
      );
    },
  );
  test('Unified sign-in falls back only when Host is unreachable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    await server.close(force: true);
    final vault = HostCredentialVault(_ProtectedBackend());
    final now = DateTime.utc(2026, 11, 24, 10);
    final expiry = now.add(const Duration(hours: 8));
    await vault.replaceEnrollment(endpoint, 'a' * 43);
    await vault.writeOfflineAccount(endpoint, {
      'tenantId': 'org-a',
      'actorId': 'actor',
      'deviceId': 'device',
      'username': 'owner',
      'verifier': verifier,
      'expiresAt': expiry.toIso8601String(),
      'lastSeen': now.toIso8601String(),
      'failures': 0,
    });
    final signIn = AccountSignIn(
      credentials: vault,
      profile: HostConnectionProfile(
        endpoint: endpoint.toString(),
        tenantId: 'org-a',
        companyId: 'company',
        branchId: 'branch',
        actorId: 'actor',
        deviceId: 'device',
      ),
      clock: () => now,
    );
    expect(await signIn.signIn('owner', password), expiry);
  });
  test(
    'Reachable Host denial clears offline authorization and retains enrolled device proof',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 401;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'apiVersion': 1,
            'error': {'code': 'SIGN_IN_DENIED'},
          }),
        );
        await request.response.close();
      });
      final backend = _ProtectedBackend();
      final vault = HostCredentialVault(backend);
      final root = 'a' * 43;
      await vault.save(endpoint, root);
      await vault.writeOfflineAccount(endpoint, {'verifier': verifier});
      final profile = HostConnectionProfile(
        endpoint: endpoint.toString(),
        tenantId: 'org-a',
        companyId: 'company',
        branchId: 'branch',
        actorId: 'actor',
        deviceId: 'device',
      );
      try {
        await expectLater(
          AccountSignIn(
            credentials: vault,
            profile: profile,
          ).signIn('owner', password),
          throwsA(isA<HostPackageTransportException>()),
        );
        expect(await vault.readOfflineAccount(endpoint), isNull);
        expect(await vault.readEnrollment(endpoint), root);
        await vault.delete(endpoint);
        expect(backend.values, isEmpty);
      } finally {
        await server.close(force: true);
      }
    },
  );
}
