import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/host_credentials.dart';

class MemoryBackend implements HostCredentialBackend {
  final values = <String, String>{};
  bool failDelete = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('Storage failure');
    values.remove(key);
  }
}

void main() {
  final endpoint = Uri.parse('https://host.example');
  final enrollment = 'a' * 43;
  final session = 'b' * 43;
  final secondSession = 'c' * 43;

  late MemoryBackend backend;
  late HostCredentialVault vault;

  setUp(() {
    backend = MemoryBackend();
    vault = HostCredentialVault(backend);
  });

  test('Session cleanup preserves enrollment and TLS certificate', () async {
    await vault.save(endpoint, enrollment);
    await vault.preserveEnrollment(endpoint);
    await vault.save(endpoint, session);
    await vault.saveTrustedCertificate(endpoint, [1, 2, 3]);
    await vault.writeOfflineAccount(endpoint, {'verifier': 'test'});

    await vault.clearAccountSession(endpoint);

    expect(await vault.read(endpoint), isNull);
    expect(await vault.readEnrollment(endpoint), enrollment);
    expect(await vault.readOfflineAccount(endpoint), isNull);
    expect(await vault.readTrustedCertificate(endpoint), isNotNull);
  });

  test('Pending revocations survive vault recreation', () async {
    await vault.queueSessionRevocation(endpoint, session);
    await vault.queueSessionRevocation(endpoint, session);

    final reopened = HostCredentialVault(backend);

    expect(await reopened.readPendingSessionRevocations(endpoint), [session]);
  });

  test('Concurrent queue changes preserve pending sessions', () async {
    await vault.queueSessionRevocation(endpoint, session);

    await Future.wait([
      vault.queueSessionRevocation(endpoint, secondSession),
      vault.removePendingSessionRevocation(endpoint, session),
      vault.queueSessionRevocation(endpoint, secondSession),
    ]);

    expect(await vault.readPendingSessionRevocations(endpoint), [
      secondSession,
    ]);
  });

  test('Logout pending marker survives vault recreation', () async {
    await vault.markLogoutPending(endpoint);

    final reopened = HostCredentialVault(backend);
    expect(await reopened.isLogoutPending(endpoint), isTrue);

    await reopened.clearLogoutPending(endpoint);
    expect(await vault.isLogoutPending(endpoint), isFalse);
  });

  test('Storage failure preserves logout pending marker', () async {
    await vault.markLogoutPending(endpoint);
    await vault.queueSessionRevocation(endpoint, session);

    backend.failDelete = true;

    await expectLater(vault.clearAccountSession(endpoint), throwsStateError);

    expect(await vault.isLogoutPending(endpoint), isTrue);
    expect(await vault.readPendingSessionRevocations(endpoint), [session]);
  });
}
