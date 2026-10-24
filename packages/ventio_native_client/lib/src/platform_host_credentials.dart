import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'host_credentials.dart';

/// Uses platform-native secure storage, never the local SQLite database.
class PlatformHostCredentialBackend implements HostCredentialBackend {
  PlatformHostCredentialBackend({FlutterSecureStorage? storage})
    : _storage = storage ?? FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
