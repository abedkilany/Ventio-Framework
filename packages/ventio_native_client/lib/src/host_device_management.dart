import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ventio_core/ventio_core.dart';

import 'host_credentials.dart';
import 'host_extension_packages.dart' show HostSessionIdentity;

const int hostDeviceManagementApiVersion = 1;
const String manageHostDevicesPermission = 'identity.devices.manage';
const String manageHostPairingPermission = 'identity.pairing.manage';

enum HostManagedDeviceState { registered, revoked }

enum HostManagedCredentialState { active, expired, revoked, rotated, unknown }

class HostManagedCredential {
  const HostManagedCredential({
    required this.credentialId,
    required this.state,
    required this.expiresAtUtc,
    required this.revokedAtUtc,
  });

  final String credentialId;
  final HostManagedCredentialState state;
  final DateTime expiresAtUtc;
  final DateTime? revokedAtUtc;
}

class HostManagedDevice {
  HostManagedDevice({
    required this.deviceId,
    required this.actorId,
    required this.role,
    required this.state,
    required this.registeredAtUtc,
    required this.lastAuthenticatedAtUtc,
    required Iterable<HostManagedCredential> credentials,
  }) : credentials = List.unmodifiable(credentials);

  final String deviceId;
  final String actorId;
  final String role;
  final HostManagedDeviceState state;
  final DateTime registeredAtUtc;

  /// Null means Host activity telemetry is not available; it is not an
  /// online/offline state.
  final DateTime? lastAuthenticatedAtUtc;
  final List<HostManagedCredential> credentials;
}

class HostDeviceSnapshot {
  HostDeviceSnapshot({
    required this.tenantId,
    required this.companyId,
    required this.branchId,
    required Iterable<HostManagedDevice> devices,
  }) : devices = List.unmodifiable(devices);

  final String tenantId;
  final String companyId;
  final String branchId;
  final List<HostManagedDevice> devices;
}

/// A generated code is returned only in the create response and kept in page
/// state until the operator closes or clears it. Never log or persist this.
class HostPairingCredential {
  const HostPairingCredential({
    required this.pairingId,
    required this.actorId,
    required this.code,
    required this.expiresAtUtc,
    required this.correlationId,
  });

  final String pairingId;
  final String actorId;
  final String code;
  final DateTime expiresAtUtc;
  final String correlationId;
}

/// Returned only once after a Host-authorized device credential rotation.
/// Callers must keep it in memory and clear it after transfer to the Client.
class HostRotatedDeviceCredential {
  const HostRotatedDeviceCredential({
    required this.deviceId,
    required this.credentialId,
    required this.credential,
    required this.expiresAtUtc,
    required this.correlationId,
  });

  final String deviceId;
  final String credentialId;
  final String credential;
  final DateTime expiresAtUtc;
  final String correlationId;
}

class HostDeviceManagementException implements Exception {
  const HostDeviceManagementException(
    this.code, {
    this.statusCode,
    this.correlationId,
    this.retryable = false,
  });

  final String code;
  final int? statusCode;
  final String? correlationId;
  final bool retryable;

  @override
  String toString() =>
      'Host device-management error: $code${correlationId == null ? '' : ' [$correlationId]'}';
}

typedef HostDeviceManagementExchange =
    Future<HostDeviceManagementHttpResponse> Function({
      required Uri uri,
      required Map<String, String> headers,
      required String body,
      required Duration timeout,
      required int maxResponseBytes,
    });

class HostDeviceManagementHttpResponse {
  const HostDeviceManagementHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final Map<String, dynamic> body;
  final Map<String, String> headers;
}

/// Authenticated, exact-scope Host device operations. UI-side permission
/// checks are only a convenience; every operation is authorized again by Host.
class HostDeviceManagementClient {
  HostDeviceManagementClient({
    required Uri endpoint,
    required this.credentials,
    required this.verifiedIdentity,
    required this.companyId,
    required this.branchId,
    HttpClient Function()? clientFactory,
    this.exchange,
    this.timeout = const Duration(seconds: 15),
    this.maxResponseBytes = 1024 * 1024,
  }) : endpoint = HostCredentialVault.normalizeEndpoint(endpoint),
       _clientFactory = clientFactory ?? HttpClient.new {
    _validateScopeIdentifier(companyId);
    _validateScopeIdentifier(branchId);
    if (timeout <= Duration.zero || maxResponseBytes < 1) {
      throw ArgumentError('Host device-management limits must be positive.');
    }
  }

  final Uri endpoint;
  final HostCredentialVault credentials;
  final HostSessionIdentity verifiedIdentity;
  final String companyId;
  final String branchId;
  final HttpClient Function() _clientFactory;
  final HostDeviceManagementExchange? exchange;
  final Duration timeout;
  final int maxResponseBytes;

  bool get canManageDevices => _hasPermission(manageHostDevicesPermission);
  bool get canCreatePairings => _hasPermission(manageHostPairingPermission);

  bool _hasPermission(String permission) =>
      verifiedIdentity.persistent &&
      verifiedIdentity.tenantId.trim().isNotEmpty &&
      verifiedIdentity.scopes.any(
        (scope) =>
            scope.companyId == companyId &&
            scope.branchId == branchId &&
            scope.permissions.contains(permission),
      );

  Future<HostDeviceSnapshot> listDevices() async {
    final response = await _post('list', const {});
    if (response.statusCode != HttpStatus.ok) throw _error(response);
    const envelopeKeys = {
      'apiVersion',
      'managementApiVersion',
      'correlationId',
      'devices',
    };
    if (response.body.length != envelopeKeys.length ||
        response.body.keys.any((key) => !envelopeKeys.contains(key))) {
      throw _invalidResponse(response);
    }
    final raw = response.body['devices'];
    if (raw is! Map) throw _invalidResponse(response);
    final snapshot = Map<String, dynamic>.from(raw);
    const snapshotKeys = {'tenantId', 'companyId', 'branchId', 'items'};
    if (snapshot.length != snapshotKeys.length ||
        snapshot.keys.any((key) => !snapshotKeys.contains(key)) ||
        snapshot['tenantId'] != verifiedIdentity.tenantId ||
        snapshot['companyId'] != companyId ||
        snapshot['branchId'] != branchId ||
        snapshot['items'] is! List) {
      throw _invalidResponse(response);
    }
    final items = snapshot['items'] as List;
    if (items.length > 1000) throw _invalidResponse(response);
    final devices = items
        .map((rawDevice) {
          if (rawDevice is! Map) throw _invalidResponse(response);
          final item = Map<String, dynamic>.from(rawDevice);
          const keys = {
            'deviceId',
            'actorId',
            'role',
            'registrationState',
            'registeredAtUtc',
            'lastAuthenticatedAtUtc',
            'credentials',
          };
          if (item.length != keys.length ||
              item.keys.any((key) => !keys.contains(key)) ||
              !_safeDeviceManagementDeviceId(item['deviceId']) ||
              !_safeDeviceManagementActorId(item['actorId']) ||
              !const {'HOST', 'CLIENT', 'UNKNOWN'}.contains(item['role']) ||
              item['credentials'] is! List) {
            throw _invalidResponse(response);
          }
          final registeredAt = _utc(item['registeredAtUtc']);
          final lastAuthenticatedAt = _utc(
            item['lastAuthenticatedAtUtc'],
            nullable: true,
          );
          if (registeredAt == null ||
              (item['lastAuthenticatedAtUtc'] != null &&
                  lastAuthenticatedAt == null)) {
            throw _invalidResponse(response);
          }
          final rawCredentials = item['credentials'] as List;
          if (rawCredentials.length > 100) throw _invalidResponse(response);
          final credentials = rawCredentials
              .map((rawCredential) {
                if (rawCredential is! Map) throw _invalidResponse(response);
                final credential = Map<String, dynamic>.from(rawCredential);
                const credentialKeys = {
                  'credentialId',
                  'state',
                  'expiresAtUtc',
                  'revokedAtUtc',
                };
                if (credential.length != credentialKeys.length ||
                    credential.keys.any(
                      (key) => !credentialKeys.contains(key),
                    ) ||
                    !_safeDeviceManagementCredentialId(
                      credential['credentialId'],
                    )) {
                  throw _invalidResponse(response);
                }
                final expires = _utc(credential['expiresAtUtc']);
                final revoked = _utc(
                  credential['revokedAtUtc'],
                  nullable: true,
                );
                if (expires == null ||
                    (credential['revokedAtUtc'] != null && revoked == null)) {
                  throw _invalidResponse(response);
                }
                final state = switch (credential['state']) {
                  'ACTIVE' => HostManagedCredentialState.active,
                  'EXPIRED' => HostManagedCredentialState.expired,
                  'REVOKED' => HostManagedCredentialState.revoked,
                  'ROTATED' => HostManagedCredentialState.rotated,
                  'UNKNOWN' => HostManagedCredentialState.unknown,
                  _ => throw _invalidResponse(response),
                };
                return HostManagedCredential(
                  credentialId: credential['credentialId'] as String,
                  state: state,
                  expiresAtUtc: expires,
                  revokedAtUtc: revoked,
                );
              })
              .toList(growable: false);
          return HostManagedDevice(
            deviceId: item['deviceId'] as String,
            actorId: item['actorId'] as String,
            role: item['role'] as String,
            state: switch (item['registrationState']) {
              'REGISTERED' => HostManagedDeviceState.registered,
              'REVOKED' => HostManagedDeviceState.revoked,
              _ => throw _invalidResponse(response),
            },
            registeredAtUtc: registeredAt,
            lastAuthenticatedAtUtc: lastAuthenticatedAt,
            credentials: credentials,
          );
        })
        .toList(growable: false);
    if (devices.map((device) => device.deviceId).toSet().length !=
        devices.length) {
      throw _invalidResponse(response);
    }
    return HostDeviceSnapshot(
      tenantId: snapshot['tenantId'] as String,
      companyId: snapshot['companyId'] as String,
      branchId: snapshot['branchId'] as String,
      devices: devices,
    );
  }

  Future<void> revoke(String deviceId) async {
    if (!_safeDeviceManagementDeviceId(deviceId)) {
      throw const HostDeviceManagementException('INVALID_DEVICE_ID');
    }
    final response = await _post('revoke', {'deviceId': deviceId});
    if (response.statusCode != HttpStatus.ok) throw _error(response);
    const keys = {
      'apiVersion',
      'managementApiVersion',
      'correlationId',
      'deviceOperation',
    };
    if (response.body.length != keys.length ||
        response.body.keys.any((key) => !keys.contains(key))) {
      throw _invalidResponse(response);
    }
    final operation = response.body['deviceOperation'];
    if (operation is! Map ||
        operation.length != 2 ||
        operation['status'] != 'APPLIED' ||
        operation['deviceId'] != deviceId) {
      throw _invalidResponse(response);
    }
  }

  Future<HostRotatedDeviceCredential> rotateCredential({
    required String deviceId,
    required String credentialId,
  }) async {
    if (!_safeDeviceManagementDeviceId(deviceId) ||
        !_safeDeviceManagementCredentialId(credentialId)) {
      throw const HostDeviceManagementException('INVALID_DEVICE_ID');
    }
    final response = await _post('rotate-credential', {
      'deviceId': deviceId,
      'credentialId': credentialId,
    });
    if (response.statusCode != HttpStatus.ok) throw _error(response);
    const envelopeKeys = {
      'apiVersion',
      'managementApiVersion',
      'correlationId',
      'deviceCredential',
    };
    if (response.body.length != envelopeKeys.length ||
        response.body.keys.any((key) => !envelopeKeys.contains(key))) {
      throw _invalidResponse(response);
    }
    final raw = response.body['deviceCredential'];
    if (raw is! Map) throw _invalidResponse(response);
    final value = Map<String, dynamic>.from(raw);
    const keys = {
      'tenantId',
      'actorId',
      'deviceId',
      'credentialId',
      'companyId',
      'branchId',
      'expiresAtUtc',
      'credential',
    };
    final expiry = _utc(value['expiresAtUtc']);
    final token = value['credential'];
    if (value.length != keys.length ||
        value.keys.any((key) => !keys.contains(key)) ||
        value['tenantId'] != verifiedIdentity.tenantId ||
        !_safeDeviceManagementActorId(value['actorId']) ||
        value['deviceId'] != deviceId ||
        !_safeDeviceManagementCredentialId(value['credentialId']) ||
        value['companyId'] != companyId ||
        value['branchId'] != branchId ||
        expiry == null ||
        token is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(token)) {
      throw _invalidResponse(response);
    }
    return HostRotatedDeviceCredential(
      deviceId: deviceId,
      credentialId: value['credentialId'] as String,
      credential: token,
      expiresAtUtc: expiry,
      correlationId: response.correlationId,
    );
  }

  Future<HostPairingCredential> createPairing(String actorId) async {
    if (!_safeDeviceManagementActorId(actorId)) {
      throw const HostDeviceManagementException('INVALID_ACTOR_ID');
    }
    final response = await _postPairing(actorId);
    if (response.statusCode != HttpStatus.created) throw _error(response);
    const envelopeKeys = {
      'apiVersion',
      'managementApiVersion',
      'correlationId',
      'pairing',
    };
    if (response.body.length != envelopeKeys.length ||
        response.body.keys.any((key) => !envelopeKeys.contains(key))) {
      throw _invalidResponse(response);
    }
    const keys = {
      'pairingId',
      'actorId',
      'deviceRole',
      'code',
      'companyId',
      'branchId',
      'expiresAtUtc',
    };
    final raw = response.body['pairing'];
    if (raw is! Map) throw _invalidResponse(response);
    final pairing = Map<String, dynamic>.from(raw);
    final expiry = _utc(pairing['expiresAtUtc']);
    final code = pairing['code'];
    if (pairing.length != keys.length ||
        pairing.keys.any((key) => !keys.contains(key)) ||
        !_safeIdentifier(pairing['pairingId']) ||
        pairing['actorId'] != actorId ||
        pairing['deviceRole'] != 'CLIENT' ||
        pairing['companyId'] != companyId ||
        pairing['branchId'] != branchId ||
        code is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(code) ||
        expiry == null) {
      throw _invalidResponse(response);
    }
    return HostPairingCredential(
      pairingId: pairing['pairingId'] as String,
      actorId: actorId,
      code: code,
      expiresAtUtc: expiry,
      correlationId: response.correlationId,
    );
  }

  Future<_DeviceResponse> _post(String action, Map<String, Object?> fields) =>
      _request(
        '/api/v1/management/devices/$action',
        fields,
        permission: manageHostDevicesPermission,
      );

  Future<_DeviceResponse> _postPairing(String actorId) => _request(
    HostManagementRoutes.pairingCreate,
    {'actorId': actorId},
    permission: manageHostPairingPermission,
  );

  Future<_DeviceResponse> _request(
    String path,
    Map<String, Object?> fields, {
    required String permission,
  }) async {
    _requirePermission(permission);
    final token = await credentials.read(endpoint);
    if (token == null) {
      throw const HostDeviceManagementException('HOST_CREDENTIAL_MISSING');
    }
    try {
      final response = await (exchange ?? _httpExchange)(
        uri: endpoint.replace(path: path),
        headers: {
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
          HttpHeaders.authorizationHeader: 'Bearer $token',
        },
        body: canonicalJson({
          'managementApiVersion': hostDeviceManagementApiVersion,
          'companyId': companyId,
          'branchId': branchId,
          ...fields,
        }),
        timeout: timeout,
        maxResponseBytes: maxResponseBytes,
      ).timeout(timeout);
      final id = _correlationId(
        response.body['correlationId'] ??
            response.headers['x-correlation-id'] ??
            response.headers['X-Correlation-ID'],
      );
      if (id == null) {
        throw HostDeviceManagementException(
          'HOST_INVALID_RESPONSE',
          statusCode: response.statusCode,
        );
      }
      if (response.body['apiVersion'] != managementApiVersion ||
          (response.statusCode >= 200 &&
              response.statusCode < 300 &&
              response.body['managementApiVersion'] !=
                  hostDeviceManagementApiVersion)) {
        throw HostDeviceManagementException(
          'HOST_API_VERSION_MISMATCH',
          statusCode: response.statusCode,
          correlationId: id,
        );
      }
      return _DeviceResponse(response.statusCode, response.body, id);
    } on HostDeviceManagementException {
      rethrow;
    } on TimeoutException {
      throw const HostDeviceManagementException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    } on SocketException {
      throw const HostDeviceManagementException(
        'HOST_UNREACHABLE',
        retryable: true,
      );
    } on TlsException {
      throw const HostDeviceManagementException('HOST_TLS_VALIDATION_FAILED');
    } on HttpException {
      throw const HostDeviceManagementException('HOST_INVALID_RESPONSE');
    } on FormatException {
      throw const HostDeviceManagementException('HOST_INVALID_RESPONSE');
    } catch (_) {
      throw const HostDeviceManagementException(
        'HOST_UNAVAILABLE',
        retryable: true,
      );
    }
  }

  Future<HostDeviceManagementHttpResponse> _httpExchange({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    final watch = Stopwatch()..start();
    final client = await credentials.createHttpClient(
      endpoint,
      fallbackFactory: _clientFactory,
    );
    client.connectionTimeout = timeout;
    try {
      final request = await client.openUrl('POST', uri).timeout(timeout);
      request
        ..followRedirects = false
        ..maxRedirects = 0;
      headers.forEach(request.headers.set);
      request.write(body);
      final response = await request.close().timeout(_remaining(watch));
      if (response.headers.contentType?.mimeType.toLowerCase() !=
          'application/json') {
        throw const HostDeviceManagementException('HOST_INVALID_RESPONSE');
      }
      if (response.contentLength > maxResponseBytes) {
        throw const HostDeviceManagementException('HOST_RESPONSE_TOO_LARGE');
      }
      final bytes = await response
          .fold<List<int>>(<int>[], (buffer, chunk) {
            if (buffer.length + chunk.length > maxResponseBytes) {
              throw const HostDeviceManagementException(
                'HOST_RESPONSE_TOO_LARGE',
              );
            }
            buffer.addAll(chunk);
            return buffer;
          })
          .timeout(_remaining(watch));
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const HostDeviceManagementException('HOST_INVALID_RESPONSE');
      }
      return HostDeviceManagementHttpResponse(
        statusCode: response.statusCode,
        body: Map<String, dynamic>.from(decoded),
        headers: {
          'x-correlation-id': ?response.headers.value('x-correlation-id'),
        },
      );
    } finally {
      client.close(force: true);
    }
  }

  void _requirePermission(String permission) {
    if (!_hasPermission(permission)) {
      throw const HostDeviceManagementException('HOST_PERMISSION_DENIED');
    }
  }

  Duration _remaining(Stopwatch watch) {
    final remaining = timeout - watch.elapsed;
    if (remaining <= Duration.zero) {
      throw const HostDeviceManagementException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    }
    return remaining;
  }

  HostDeviceManagementException _error(_DeviceResponse response) {
    final raw = response.body['error'];
    final error = raw is Map ? Map<String, dynamic>.from(raw) : const {};
    final value = error['code'];
    final code =
        value is String && RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(value)
        ? value
        : 'HOST_HTTP_ERROR';
    return HostDeviceManagementException(
      code,
      statusCode: response.statusCode,
      correlationId: response.correlationId,
      retryable: error['retryable'] == true || response.statusCode >= 500,
    );
  }

  HostDeviceManagementException _invalidResponse(_DeviceResponse response) =>
      HostDeviceManagementException(
        'HOST_INVALID_RESPONSE',
        statusCode: response.statusCode,
        correlationId: response.correlationId,
      );
}

class _DeviceResponse {
  const _DeviceResponse(this.statusCode, this.body, this.correlationId);

  final int statusCode;
  final Map<String, dynamic> body;
  final String correlationId;
}

String? _correlationId(Object? value) =>
    value is String && RegExp(r'^cor_[a-f0-9]{32}$').hasMatch(value)
    ? value
    : null;

DateTime? _utc(Object? value, {bool nullable = false}) {
  if (value == null) return nullable ? null : null;
  if (value is! String || !value.endsWith('Z')) return null;
  final parsed = DateTime.tryParse(value);
  return parsed != null && parsed.isUtc ? parsed : null;
}

bool _safeIdentifier(Object? value) =>
    value is String &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$').hasMatch(value) &&
    !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(value) &&
    !RegExp(
      r'(bearer|password|token|secret|postgres(?:ql)?|credential)',
      caseSensitive: false,
    ).hasMatch(value);

bool _isTypedOpaqueManagementId(Object? value, String prefix) =>
    value is String &&
    value.startsWith(prefix) &&
    RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value.substring(prefix.length));

bool _safeDeviceManagementDeviceId(Object? value) =>
    _isTypedOpaqueManagementId(value, 'dev_') || _safeIdentifier(value);

bool _safeDeviceManagementActorId(Object? value) =>
    _isTypedOpaqueManagementId(value, 'usr_') || _safeIdentifier(value);

bool _safeDeviceManagementCredentialId(Object? value) =>
    _isTypedOpaqueManagementId(value, 'cred_') || _safeIdentifier(value);

void _validateScopeIdentifier(String value) {
  if (value.trim().isEmpty || value.length > 256) {
    throw const HostDeviceManagementException('INVALID_SCOPE');
  }
}
