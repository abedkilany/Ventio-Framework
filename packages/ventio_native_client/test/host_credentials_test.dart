import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/host_credentials.dart';

class _MemoryCredentialBackend implements HostCredentialBackend {
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
  const token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';
  late _MemoryCredentialBackend backend;
  late HostCredentialVault vault;

  setUp(() {
    backend = _MemoryCredentialBackend();
    vault = HostCredentialVault(backend);
  });

  test(
    'Credentials are keyed by normalized Host origin and can be removed',
    () async {
      await vault.save(Uri.parse('https://HOST.example:443/'), token);

      expect(await vault.read(Uri.parse('https://host.example')), token);
      expect(backend.values.keys, hasLength(1));
      expect(
        backend.values.keys.single,
        startsWith('ventio.host.credential.v1.'),
      );
      expect(backend.values.keys.single, isNot(contains('host.example')));
      expect(backend.values.values, [token]);

      await vault.delete(Uri.parse('https://host.example'));
      expect(backend.values, isEmpty);
    },
  );

  test('Plain HTTP is limited to exact loopback origins', () async {
    await vault.save(Uri.parse('http://127.0.0.1:8080'), token);
    await vault.save(Uri.parse('http://[::1]:8080'), token);
    await vault.save(Uri.parse('http://localhost:8080'), token);

    await expectLater(
      vault.save(Uri.parse('http://192.168.1.20:8080'), token),
      throwsArgumentError,
    );
    await expectLater(
      vault.save(Uri.parse('http://localhost.example:8080'), token),
      throwsArgumentError,
    );
  });

  test('Endpoint paths, user info and query strings are rejected', () async {
    for (final endpoint in [
      Uri.parse('https://host.example/api/v1'),
      Uri.parse('https://user@host.example'),
      Uri.parse('https://host.example?token=secret'),
      Uri.parse('https://host.example/#fragment'),
    ]) {
      await expectLater(vault.save(endpoint, token), throwsArgumentError);
    }
    expect(backend.values, isEmpty);
  });

  test('Only opaque token-shaped credentials are stored', () async {
    await expectLater(
      vault.save(Uri.parse('https://host.example'), 'short'),
      throwsArgumentError,
    );
    expect(backend.values, isEmpty);
  });
}
