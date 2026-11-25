import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/account_sign_in.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';

class FaultBackend implements HostCredentialBackend {
  final values = <String, String>{};
  bool Function(String, String)? failWrite;
  bool Function(String)? failDelete;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrite?.call(key, value) ?? false) throw StateError('write fault');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete?.call(key) ?? false) throw StateError('delete fault');
    values.remove(key);
  }
}

void main() {
  final root = 'a' * 43, old = 'b' * 43, issued = 'c' * 43;
  final now = DateTime.utc(2026, 11, 25, 12);
  final expiry = now.add(const Duration(hours: 8));
  const password = 'Offline password phrase 42!';
  late HttpServer server;
  late Uri endpoint;
  late FaultBackend backend;
  late HostCredentialVault vault;
  late HostConnectionProfile profile;
  late AccountSignIn signIn;
  late Completer<void> arrived;
  late Completer<void> release;
  late String? hold;
  late List<String> revoked;
  late List<String> loginProofs;
  AccountSignIn make(HostCredentialVault v) =>
      AccountSignIn(credentials: v, profile: profile, clock: () => now);
  Map<String, dynamic> cache() => {
    'tenantId': 'org-a',
    'actorId': 'actor',
    'deviceId': 'device',
    'username': 'owner',
    'verifier': 'fixture',
    'expiresAt': expiry.toIso8601String(),
    'lastSeen': now.toIso8601String(),
    'identity': <String, dynamic>{},
    'failures': 0,
  };
  setUp(() async {
    arrived = Completer<void>();
    release = Completer<void>();
    hold = null;
    revoked = [];
    loginProofs = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final login = request.uri.path.endsWith('/login');
      final action = login ? 'login' : body['action'];
      final proof =
          request.headers.value(HttpHeaders.authorizationHeader) ?? '';
      if (login) loginProofs.add(proof);
      if (action == 'LOGOUT_SESSION') revoked.add(proof);
      if (action == hold) {
        arrived.complete();
        await release.future;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'apiVersion': 1,
          'account': action == 'LOGOUT_SESSION'
              ? {'signedOut': true}
              : {
                  'tenantId': 'org-a',
                  'actorId': 'actor',
                  'deviceId': 'device',
                  'expiresAt': expiry.toIso8601String(),
                  'identity': <String, dynamic>{},
                  if (login) 'token': issued,
                },
        }),
      );
      await request.response.close();
    });
    backend = FaultBackend();
    vault = HostCredentialVault(backend);
    await vault.save(endpoint, root);
    await vault.preserveEnrollment(endpoint);
    await vault.save(endpoint, old);
    await vault.writeOfflineAccount(endpoint, cache());
    profile = HostConnectionProfile(
      endpoint: endpoint.toString(),
      tenantId: 'org-a',
      companyId: 'company',
      branchId: 'branch',
      actorId: 'actor',
      deviceId: 'device',
    );
    signIn = make(vault);
  });
  tearDown(() async {
    if (!release.isCompleted) release.complete();
    await server.close(force: true);
  });
  Future<void> assertClean(HostCredentialVault v) async {
    expect(await v.read(endpoint), isNull);
    expect(await v.readOfflineAccount(endpoint), isNull);
    expect(await v.readEnrollment(endpoint), root);
    expect(await v.isLogoutPending(endpoint), isFalse);
  }

  for (final target in ['token', 'offline']) {
    test('Login $target write failure clears partial session', () async {
      backend.failWrite = (key, value) => target == 'token'
          ? value == issued
          : key.startsWith('ventio.account.v1.offline.');
      await expectLater(
        signIn.online('owner', password),
        throwsA(isA<StateError>()),
      );
      backend.failWrite = null;
      await assertClean(vault);
      expect(
        await vault.readPendingSessionRevocations(endpoint),
        unorderedEquals([old, issued]),
      );
      expect(loginProofs, ['Bearer $root']);
    });
  }
  test(
    'Failed cleanup leaves durable marker and reopened vault recovers',
    () async {
      backend.failWrite = (key, value) =>
          key.startsWith('ventio.account.v1.offline.');
      backend.failDelete = (key) =>
          key.startsWith('ventio.account.v1.offline.');
      await expectLater(
        signIn.online('owner', password),
        throwsA(isA<StateError>()),
      );
      final reopened = HostCredentialVault(backend);
      expect(await reopened.isLogoutPending(endpoint), isTrue);
      await expectLater(
        make(reopened).online('owner', password),
        throwsA(isA<HostPackageTransportException>()),
      );
      await expectLater(
        make(reopened).offline('owner', password),
        throwsA(isA<HostPackageTransportException>()),
      );
      backend.failWrite = null;
      backend.failDelete = null;
      await make(reopened).logout();
      await assertClean(reopened);
      expect(revoked, unorderedEquals(['Bearer $old', 'Bearer $issued']));
    },
  );
  test('Late login cannot restore logged-out session', () async {
    hold = 'login';
    final result = expectLater(
      signIn.online('owner', password),
      throwsA(
        isA<HostPackageTransportException>().having(
          (e) => e.code,
          'code',
          'SESSION_UNAVAILABLE',
        ),
      ),
    );
    await arrived.future.timeout(const Duration(seconds: 5));
    await signIn.logout();
    release.complete();
    await result;
    await assertClean(vault);
    expect(await vault.readPendingSessionRevocations(endpoint), [issued]);
    await signIn.flushPendingSessionRevocations();
    expect(revoked, ['Bearer $old', 'Bearer $issued']);
  });
  test('Late refresh cannot restore logged-out authorization', () async {
    hold = 'REFRESH_SESSION';
    final result = expectLater(
      signIn.refreshSession(),
      throwsA(
        isA<HostPackageTransportException>().having(
          (e) => e.code,
          'code',
          'SESSION_UNAVAILABLE',
        ),
      ),
    );
    await arrived.future.timeout(const Duration(seconds: 5));
    await signIn.logout();
    release.complete();
    await result;
    await assertClean(vault);
    expect(revoked, ['Bearer $old']);
  });
  test('Account invalidation blocks an in-flight refresh', () async {
    hold = 'REFRESH_SESSION';
    final result = expectLater(
      signIn.refreshSession(),
      throwsA(
        isA<HostPackageTransportException>().having(
          (e) => e.code,
          'code',
          'SESSION_UNAVAILABLE',
        ),
      ),
    );
    await arrived.future.timeout(const Duration(seconds: 5));
    final notifications = accountSessionInvalidated.value;
    await invalidateLocalAccountSession(vault, endpoint);
    expect(accountSessionInvalidated.value, notifications + 1);
    expect(await vault.isLogoutPending(endpoint), isTrue);
    release.complete();
    await result;
    expect(await vault.readOfflineAccount(endpoint), isNull);
    await signIn.logout();
    await assertClean(vault);
  });
  test(
    'Account invalidation notifies UI even if secure storage fails',
    () async {
      final notifications = accountSessionInvalidated.value;
      backend.failDelete = (key) =>
          key.startsWith('ventio.account.v1.offline.');
      await expectLater(
        invalidateLocalAccountSession(vault, endpoint),
        throwsA(isA<StateError>()),
      );
      expect(accountSessionInvalidated.value, notifications + 1);
      expect(await vault.isLogoutPending(endpoint), isTrue);
      backend.failDelete = null;
      await signIn.logout();
      await assertClean(vault);
    },
  );
  test('Valid refresh updates expiry without replacing token', () async {
    await vault.writeOfflineAccount(endpoint, {
      ...cache(),
      'expiresAt': now.add(const Duration(hours: 1)).toIso8601String(),
    });
    expect(await signIn.refreshSession(), expiry);
    expect(await vault.read(endpoint), old);
    expect(
      (await vault.readOfflineAccount(endpoint))?['expiresAt'],
      expiry.toIso8601String(),
    );
  });
}
