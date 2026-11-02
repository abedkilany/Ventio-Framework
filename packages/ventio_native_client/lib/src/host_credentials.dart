import 'dart:convert';
import 'dart:io';

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
  static const _certificateKeyPrefix = 'ventio.host.tls-certificate.v1.';
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43,128}$');
  static final _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

  final HostCredentialBackend _backend;

  Future<void> save(Uri endpoint, String token) async {
    if (!_tokenPattern.hasMatch(token)) {
      throw ArgumentError('Host credential has an invalid format.');
    }
    await _backend.write(_storageKey(endpoint), token);
  }

  Future<String?> read(Uri endpoint) => _backend.read(_storageKey(endpoint));

  Future<void> delete(Uri endpoint) => _backend.delete(_storageKey(endpoint));

  Future<void> saveTrustedCertificate(Uri endpoint, List<int> der) async {
    if (der.isEmpty) throw ArgumentError('Host TLS certificate is empty.');
    final fingerprint = certificateFingerprint(der);
    final value = jsonEncode({
      'fingerprint': fingerprint,
      'certificateDerBase64': base64Encode(der),
    });
    await _backend.write(_certificateStorageKey(endpoint), value);
  }

  Future<HostTrustedCertificate?> readTrustedCertificate(Uri endpoint) async {
    final value = await _backend.read(_certificateStorageKey(endpoint));
    if (value == null) return null;
    try {
      final json = jsonDecode(value);
      if (json is! Map ||
          json['fingerprint'] is! String ||
          json['certificateDerBase64'] is! String) {
        throw const FormatException('Stored Host TLS trust data is malformed.');
      }
      final der = base64Decode(json['certificateDerBase64'] as String);
      if (der.isEmpty) {
        throw const FormatException('Stored Host TLS certificate is empty.');
      }
      final fingerprint = certificateFingerprint(der);
      if (json['fingerprint'] != fingerprint) {
        throw const FormatException('Stored Host TLS fingerprint is invalid.');
      }
      return HostTrustedCertificate(der: der, fingerprint: fingerprint);
    } catch (_) {
      // A corrupt pin must fail closed; treating it as absent would silently
      // downgrade this endpoint to the machine's general trust store.
      throw const TlsException('Stored Host TLS trust data is invalid.');
    }
  }

  Future<void> deleteTrustedCertificate(Uri endpoint) =>
      _backend.delete(_certificateStorageKey(endpoint));

  /// Reads the peer certificate without sending application data, and returns
  /// it only when its SHA-256 fingerprint matches the value supplied out of
  /// band by the Host administrator.
  Future<List<int>> verifyAndFetchCertificate(
    Uri endpoint,
    String expectedFingerprint, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final normalized = normalizeEndpoint(endpoint);
    final expected = normalizeFingerprint(expectedFingerprint);
    if (normalized.scheme != 'https' || expected == null) {
      throw const FormatException(
        'A valid HTTPS certificate fingerprint is required.',
      );
    }

    final socket = await SecureSocket.connect(
      normalized.host,
      normalized.port,
      timeout: timeout,
      onBadCertificate: (certificate) =>
          certificateFingerprint(certificate.der) == expected,
    );
    try {
      final certificate = socket.peerCertificate;
      if (certificate == null ||
          certificateFingerprint(certificate.der) != expected) {
        throw const TlsException('Host certificate fingerprint mismatch.');
      }
      return List<int>.unmodifiable(certificate.der);
    } finally {
      await socket.close();
    }
  }

  /// Creates an HttpClient constrained to the exact certificate previously
  /// confirmed by the user. A pinned connection uses an empty trust store and
  /// accepts only the matching leaf certificate through the exact fingerprint
  /// callback. When no certificate is pinned, platform trust roots remain in
  /// effect.
  Future<HttpClient> createHttpClient(
    Uri endpoint, {
    required HttpClient Function() fallbackFactory,
  }) async {
    final trusted = await readTrustedCertificate(endpoint);
    if (trusted == null) return fallbackFactory();
    final context = SecurityContext(withTrustedRoots: false);
    return HttpClient(context: context)
      ..badCertificateCallback = (certificate, _, _) =>
          certificateFingerprint(certificate.der) == trusted.fingerprint;
  }

  static String certificateFingerprint(List<int> der) =>
      sha256.convert(der).toString();

  static String? normalizeFingerprint(String value) {
    final normalized = value
        .replaceAll(':', '')
        .replaceAll(RegExp(r'\s+'), '')
        .toLowerCase();
    return _fingerprintPattern.hasMatch(normalized) ? normalized : null;
  }

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

  String _certificateStorageKey(Uri endpoint) {
    final origin = normalizeEndpoint(endpoint).origin;
    final digest = sha256.convert(utf8.encode(origin));
    return '$_certificateKeyPrefix$digest';
  }
}

class HostTrustedCertificate {
  const HostTrustedCertificate({required this.der, required this.fingerprint});

  final List<int> der;
  final String fingerprint;
}
