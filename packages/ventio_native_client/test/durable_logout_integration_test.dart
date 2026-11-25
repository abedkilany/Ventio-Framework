import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/account_sign_in.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/host_credentials.dart';

class MemoryBackend implements HostCredentialBackend {
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
  final enrollment = 'a' * 43;
  final oldSession = 'b' * 43;
  final newSession = 'c' * 43;

  late HttpServer server;
  late Uri endpoint;
  late MemoryBackend backend;
  late HostCredentialVault vault;
  late HostConnectionProfile profile;
  late AccountSignIn signIn;
  late List<String> received;
  late int status;
  late bool confirmed;

  setUp(() async {
    received = [];
    status = 200;
    confirmed = true;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

    endpoint = Uri.parse('http://127.0.0.1:${server.port}');

    server.listen((request) async {
      received.add(
        request.headers.value(HttpHeaders.authorizationHeader) ?? '',
      );

      await request.drain<void>();

      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;

      request.response.write(
        jsonEncode({
          'apiVersion': 1,
          if (status == 200)
            'account': {'signedOut': confirmed}
          else
            'error': {'code': 'HOST_UNAVAILABLE'},
        }),
      );

      await request.response.close();
    });

    backend = MemoryBackend();
    vault = HostCredentialVault(backend);

    await vault.save(endpoint, enrollment);
    await vault.preserveEnrollment(endpoint);
    await vault.save(endpoint, oldSession);
    await vault.writeOfflineAccount(endpoint, {'verifier': 'test'});

    profile = HostConnectionProfile(
      endpoint: endpoint.toString(),
      tenantId: 'org-a',
      companyId: 'company',
      branchId: 'branch',
      actorId: 'actor',
      deviceId: 'device',
    );

    signIn = AccountSignIn(credentials: vault, profile: profile);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('Online logout revokes session and preserves enrollment', () async {
    await signIn.logout();

    expect(received, ['Bearer $oldSession']);
    expect(await vault.read(endpoint), isNull);
    expect(await vault.readEnrollment(endpoint), enrollment);
    expect(await vault.readOfflineAccount(endpoint), isNull);
    expect(await vault.isLogoutPending(endpoint), isFalse);
    expect(await vault.readPendingSessionRevocations(endpoint), isEmpty);
  });

  test('Offline logout retains revocation after restart', () async {
    await server.close(force: true);

    await signIn.logout();

    final reopened = HostCredentialVault(backend);

    expect(await reopened.read(endpoint), isNull);
    expect(await reopened.readEnrollment(endpoint), enrollment);
    expect(await reopened.readOfflineAccount(endpoint), isNull);
    expect(await reopened.readPendingSessionRevocations(endpoint), [
      oldSession,
    ]);
  });

  test('Retry revokes old session without touching new session', () async {
    status = 503;
    await signIn.logout();

    expect(await vault.readPendingSessionRevocations(endpoint), [oldSession]);

    await vault.save(endpoint, newSession);

    status = 200;
    received.clear();

    await signIn.flushPendingSessionRevocations();

    expect(received, ['Bearer $oldSession']);
    expect(await vault.read(endpoint), newSession);
    expect(await vault.readPendingSessionRevocations(endpoint), isEmpty);
  });

  test('Unconfirmed logout response retains pending revocation', () async {
    confirmed = false;
    await signIn.logout();

    expect(await vault.readPendingSessionRevocations(endpoint), [oldSession]);

    confirmed = true;
    await signIn.flushPendingSessionRevocations();

    expect(await vault.readPendingSessionRevocations(endpoint), isEmpty);
  });

  test('Interrupted logout resumes cleanup', () async {
    await vault.markLogoutPending(endpoint);
    await vault.queueSessionRevocation(endpoint, oldSession);

    final reopened = HostCredentialVault(backend);
    final recovered = AccountSignIn(credentials: reopened, profile: profile);

    await recovered.logout();

    expect(await reopened.isLogoutPending(endpoint), isFalse);
    expect(await reopened.read(endpoint), isNull);
    expect(await reopened.readEnrollment(endpoint), enrollment);
    expect(await reopened.readOfflineAccount(endpoint), isNull);
    expect(await reopened.readPendingSessionRevocations(endpoint), isEmpty);
    expect(received, ['Bearer $oldSession']);
  });

  test('Pending cleanup blocks online and offline sign-in', () async {
    await vault.markLogoutPending(endpoint);

    await expectLater(
      signIn.online('owner', 'test-password'),
      throwsA(predicate((dynamic e) => e.code == 'SESSION_CLEANUP_PENDING')),
    );

    await expectLater(
      signIn.offline('owner', 'test-password'),
      throwsA(predicate((dynamic e) => e.code == 'SESSION_CLEANUP_PENDING')),
    );

    expect(received, isEmpty);
    expect(await vault.read(endpoint), oldSession);
  });

  test('Concurrent revocation flush sends only one request', () async {
    await vault.queueSessionRevocation(endpoint, oldSession);

    final another = AccountSignIn(credentials: vault, profile: profile);

    await Future.wait([
      signIn.flushPendingSessionRevocations(),
      another.flushPendingSessionRevocations(),
      signIn.flushPendingSessionRevocations(),
    ]);

    expect(received, ['Bearer $oldSession']);
    expect(await vault.readPendingSessionRevocations(endpoint), isEmpty);
  });
}
