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
  static const _reissueStageKeyPrefix =
      'ventio.host.credential.reissue.stage.v1.';
  static const _reissueRequestKeyPrefix =
      'ventio.host.credential.reissue.request.v1.';
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

  /// Persists a replacement separately before acknowledgment. The currently
  /// active credential remains available until the Host confirms finalization.
  Future<void> stageCredentialReissue(
    Uri endpoint, {
    required String operationId,
    required String token,
    required String credentialId,
    required String tenantId,
    required String actorId,
    required String deviceId,
    required String companyId,
    required String branchId,
    required List<String> permissions,
    required DateTime expiresAtUtc,
  }) async {
    if (!_tokenPattern.hasMatch(token) ||
        !RegExp(r'^reissue_[0-9a-f]{32}$').hasMatch(operationId) ||
        !RegExp(r'^cred_[0-9a-f]{32}$').hasMatch(credentialId) ||
        [
          tenantId,
          actorId,
          deviceId,
          companyId,
          branchId,
        ].any((value) => value.trim().isEmpty || value.length > 256) ||
        permissions.isEmpty ||
        permissions.length > 128 ||
        permissions.toSet().length != permissions.length ||
        permissions.any(
          (value) => !RegExp(r'^[a-z][a-z0-9_.]{0,255}$').hasMatch(value),
        ) ||
        !expiresAtUtc.isUtc ||
        !expiresAtUtc.isAfter(DateTime.now().toUtc())) {
      throw ArgumentError('Host credential reissue data is invalid.');
    }
    await _backend.write(
      _reissueStageStorageKey(endpoint),
      jsonEncode({
        'operationId': operationId,
        'token': token,
        'credentialId': credentialId,
        'tenantId': tenantId,
        'actorId': actorId,
        'deviceId': deviceId,
        'companyId': companyId,
        'branchId': branchId,
        'permissions': permissions.toList()..sort(),
        'expiresAtUtc': expiresAtUtc.toIso8601String(),
      }),
    );
  }

  Future<StagedHostCredentialReissue?> readStagedCredentialReissue(
    Uri endpoint,
  ) async {
    final value = await _backend.read(_reissueStageStorageKey(endpoint));
    if (value == null) return null;
    try {
      final json = jsonDecode(value);
      if (json is! Map<String, dynamic> ||
          json.length != 10 ||
          json.keys.toSet().difference({
            'operationId',
            'token',
            'credentialId',
            'tenantId',
            'actorId',
            'deviceId',
            'companyId',
            'branchId',
            'permissions',
            'expiresAtUtc',
          }).isNotEmpty) {
        throw const FormatException('Staged Host credential is malformed.');
      }
      final expiry = json['expiresAtUtc'] is String
          ? DateTime.tryParse(json['expiresAtUtc'] as String)
          : null;
      final permissions = json['permissions'];
      final token = json['token'];
      final opId = json['operationId'];
      final credentialId = json['credentialId'];
      if (token is! String ||
          !_tokenPattern.hasMatch(token) ||
          opId is! String ||
          !RegExp(r'^reissue_[0-9a-f]{32}$').hasMatch(opId) ||
          credentialId is! String ||
          !RegExp(r'^cred_[0-9a-f]{32}$').hasMatch(credentialId) ||
          permissions is! List ||
          permissions.isEmpty ||
          permissions.length > 128 ||
          permissions.any(
            (item) =>
                item is! String ||
                !RegExp(r'^[a-z][a-z0-9_.]{0,255}$').hasMatch(item),
          ) ||
          expiry == null ||
          !expiry.isUtc) {
        throw const FormatException('Staged Host credential is invalid.');
      }
      final values = [
        json['tenantId'],
        json['actorId'],
        json['deviceId'],
        json['companyId'],
        json['branchId'],
      ];
      if (values.any(
        (item) => item is! String || item.trim().isEmpty || item.length > 256,
      )) {
        throw const FormatException('Staged Host credential scope is invalid.');
      }
      return StagedHostCredentialReissue(
        operationId: opId,
        token: token,
        credentialId: credentialId,
        tenantId: json['tenantId'] as String,
        actorId: json['actorId'] as String,
        deviceId: json['deviceId'] as String,
        companyId: json['companyId'] as String,
        branchId: json['branchId'] as String,
        permissions: List.unmodifiable(permissions.cast<String>()),
        expiresAtUtc: expiry,
      );
    } catch (_) {
      throw const FormatException('Staged Host credential is invalid.');
    }
  }

  Future<void> activateStagedCredentialReissue(
    Uri endpoint,
    String operationId,
  ) async {
    final staged = await readStagedCredentialReissue(endpoint);
    if (staged == null || staged.operationId != operationId) {
      throw StateError('Staged Host credential is unavailable.');
    }
    await _backend.write(_storageKey(endpoint), staged.token);
    await _backend.delete(_reissueStageStorageKey(endpoint));
  }

  Future<void> clearStagedCredentialReissue(Uri endpoint) =>
      _backend.delete(_reissueStageStorageKey(endpoint));

  /// Durable, secret-free reference used to reconcile an interrupted trusted
  /// operator request after the Windows UI or broker restarts.
  Future<void> savePendingCredentialReissueRequest(
    Uri endpoint, {
    required String operationId,
    required String tenantId,
    required String actorId,
    required String deviceId,
    required String sourceCredentialId,
    required String companyId,
    required String branchId,
    required List<String> permissions,
    required List<String> approvedRemovals,
  }) async {
    final allPermissions = [...permissions, ...approvedRemovals];
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(operationId) ||
        [
          tenantId,
          actorId,
          deviceId,
          sourceCredentialId,
          companyId,
          branchId,
        ].any((value) => value.trim().isEmpty || value.length > 256) ||
        permissions.isEmpty ||
        permissions.length > 128 ||
        approvedRemovals.length > 128 ||
        allPermissions.toSet().length != allPermissions.length ||
        allPermissions.any(
          (permission) =>
              !RegExp(r'^[a-z][a-z0-9_.]{0,255}$').hasMatch(permission),
        )) {
      throw ArgumentError('Credential reissue reference is invalid.');
    }
    await _backend.write(
      _reissueRequestStorageKey(endpoint, deviceId),
      jsonEncode({
        'operationId': operationId,
        'tenantId': tenantId,
        'actorId': actorId,
        'deviceId': deviceId,
        'sourceCredentialId': sourceCredentialId,
        'companyId': companyId,
        'branchId': branchId,
        'permissions': permissions.toList()..sort(),
        'approvedRemovals': approvedRemovals.toList()..sort(),
      }),
    );
  }

  Future<PendingHostCredentialReissue?> readPendingCredentialReissueRequest(
    Uri endpoint,
    String deviceId,
  ) async {
    final value = await _backend.read(
      _reissueRequestStorageKey(endpoint, deviceId),
    );
    if (value == null) return null;
    try {
      final json = jsonDecode(value);
      const keys = {
        'operationId',
        'tenantId',
        'actorId',
        'deviceId',
        'sourceCredentialId',
        'companyId',
        'branchId',
        'permissions',
        'approvedRemovals',
      };
      if (json is! Map<String, dynamic> ||
          json.length != keys.length ||
          json.keys.any((key) => !keys.contains(key)) ||
          json['operationId'] is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(json['operationId'] as String) ||
          json['deviceId'] != deviceId ||
          [
            json['tenantId'],
            json['actorId'],
            json['deviceId'],
            json['sourceCredentialId'],
            json['companyId'],
            json['branchId'],
          ].any(
            (item) =>
                item is! String || item.trim().isEmpty || item.length > 256,
          ) ||
          json['permissions'] is! List ||
          json['approvedRemovals'] is! List) {
        throw const FormatException(
          'Credential reissue reference is malformed.',
        );
      }
      List<String> parsePermissions(Object? raw, {required bool allowEmpty}) {
        final values = (raw as List).cast<String>();
        if ((!allowEmpty && values.isEmpty) ||
            values.length > 128 ||
            values.toSet().length != values.length ||
            values.any(
              (permission) =>
                  !RegExp(r'^[a-z][a-z0-9_.]{0,255}$').hasMatch(permission),
            )) {
          throw const FormatException(
            'Credential reissue permissions are malformed.',
          );
        }
        return List.unmodifiable(values);
      }

      return PendingHostCredentialReissue(
        operationId: json['operationId'] as String,
        tenantId: json['tenantId'] as String,
        actorId: json['actorId'] as String,
        deviceId: json['deviceId'] as String,
        sourceCredentialId: json['sourceCredentialId'] as String,
        companyId: json['companyId'] as String,
        branchId: json['branchId'] as String,
        permissions: parsePermissions(json['permissions'], allowEmpty: false),
        approvedRemovals: parsePermissions(
          json['approvedRemovals'],
          allowEmpty: true,
        ),
      );
    } catch (_) {
      throw const FormatException('Credential reissue reference is malformed.');
    }
  }

  Future<void> clearPendingCredentialReissueRequest(
    Uri endpoint,
    String deviceId,
  ) => _backend.delete(_reissueRequestStorageKey(endpoint, deviceId));

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
      final der = List<int>.unmodifiable(certificate.der);
      // The first handshake only obtains the certificate whose identity the
      // administrator supplied out of band. Reconnect with that exact leaf as
      // the trust anchor so the TLS stack still enforces validity and the
      // endpoint's DNS/IP name before any enrollment request is sent.
      final validationSocket = await SecureSocket.connect(
        normalized.host,
        normalized.port,
        timeout: timeout,
        context: pinnedCertificateContext(der),
      );
      await validationSocket.close();
      return der;
    } finally {
      await socket.close();
    }
  }

  /// Creates a trust store containing only the administrator-confirmed Host
  /// leaf. Standard TLS certificate time and endpoint-name validation remain
  /// enabled; callers must not install a bad-certificate callback.
  static SecurityContext pinnedCertificateContext(List<int> der) {
    if (der.isEmpty) throw const TlsException('Host certificate is empty.');
    final encoded = base64.encode(der);
    final lines = <String>[];
    for (var offset = 0; offset < encoded.length; offset += 64) {
      lines.add(
        encoded.substring(
          offset,
          offset + 64 > encoded.length ? encoded.length : offset + 64,
        ),
      );
    }
    final pem =
        '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n'
        '-----END CERTIFICATE-----\n';
    return SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(pem));
  }

  /// Creates an HttpClient constrained to the exact certificate previously
  /// confirmed by the user. The pinned leaf becomes the sole trust anchor;
  /// normal TLS validity and endpoint-name checks remain active. When no
  /// certificate is pinned, platform trust roots remain in effect.
  Future<HttpClient> createHttpClient(
    Uri endpoint, {
    required HttpClient Function() fallbackFactory,
  }) async {
    final trusted = await readTrustedCertificate(endpoint);
    if (trusted == null) return fallbackFactory();
    return HttpClient(context: pinnedCertificateContext(trusted.der));
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

  String _reissueStageStorageKey(Uri endpoint) {
    final origin = normalizeEndpoint(endpoint).origin;
    final digest = sha256.convert(utf8.encode(origin));
    return '$_reissueStageKeyPrefix$digest';
  }

  String _reissueRequestStorageKey(Uri endpoint, String deviceId) {
    final origin = normalizeEndpoint(endpoint).origin;
    final digest = sha256.convert(utf8.encode('$origin\n$deviceId'));
    return '$_reissueRequestKeyPrefix$digest';
  }
}

class StagedHostCredentialReissue {
  const StagedHostCredentialReissue({
    required this.operationId,
    required this.token,
    required this.credentialId,
    required this.tenantId,
    required this.actorId,
    required this.deviceId,
    required this.companyId,
    required this.branchId,
    required this.permissions,
    required this.expiresAtUtc,
  });

  final String operationId;
  final String token;
  final String credentialId;
  final String tenantId;
  final String actorId;
  final String deviceId;
  final String companyId;
  final String branchId;
  final List<String> permissions;
  final DateTime expiresAtUtc;

  @override
  String toString() => 'StagedHostCredentialReissue($operationId, $deviceId)';
}

class PendingHostCredentialReissue {
  const PendingHostCredentialReissue({
    required this.operationId,
    required this.tenantId,
    required this.actorId,
    required this.deviceId,
    required this.sourceCredentialId,
    required this.companyId,
    required this.branchId,
    required this.permissions,
    required this.approvedRemovals,
  });

  final String operationId;
  final String tenantId;
  final String actorId;
  final String deviceId;
  final String sourceCredentialId;
  final String companyId;
  final String branchId;
  final List<String> permissions;
  final List<String> approvedRemovals;

  @override
  String toString() => 'PendingHostCredentialReissue($operationId, $deviceId)';
}

class HostTrustedCertificate {
  const HostTrustedCertificate({required this.der, required this.fingerprint});

  final List<int> der;
  final String fingerprint;
}
