import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Minimal secret-storage contract for deterministic tests and platform storage.
abstract interface class HostCredentialBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Device-bound storage for opaque Host credentials.
///
/// Remote endpoints must use HTTPS. Plain HTTP is accepted only for exact
/// loopback addresses used by a same-device development Host.
class HostCredentialVault {
  HostCredentialVault(this._backend);

  static const _keyPrefix = 'ventio.host.credential.v1.';
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43,128}$');

  final HostCredentialBackend _backend;

  Future<void> save(Uri endpoint, String token) async {
    if (!_tokenPattern.hasMatch(token)) {
      throw ArgumentError('Host credential has an invalid format.');
    }
    await _backend.write(_storageKey(endpoint), token);
  }

  Future<String?> read(Uri endpoint) => _backend.read(_storageKey(endpoint));

  Future<void> delete(Uri endpoint) => _backend.delete(_storageKey(endpoint));

  static Uri normalizeEndpoint(Uri endpoint) {
    final scheme = endpoint.scheme.toLowerCase();
    final host = endpoint.host.toLowerCase();
    final loopback = const {'localhost', '127.0.0.1', '::1'}.contains(host);
    final validTransport = scheme == 'https' || (scheme == 'http' && loopback);
    if (!endpoint.isAbsolute ||
        !validTransport ||
        host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.path.isNotEmpty && endpoint.path != '/') ||
        (endpoint.hasPort && endpoint.port == 0)) {
      throw ArgumentError(
        'Use an HTTPS Host origin; HTTP is allowed only for loopback development.',
      );
    }
    return Uri(
      scheme: scheme,
      host: host,
      port: endpoint.hasPort ? endpoint.port : null,
    );
  }

  String _storageKey(Uri endpoint) {
    final origin = normalizeEndpoint(endpoint).origin;
    final digest = sha256.convert(utf8.encode(origin));
    return '$_keyPrefix$digest';
  }
}
