import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ventio_core/ventio_core.dart';

import 'extension_store.dart';
import 'host_credentials.dart';
import 'transport_fixture.dart' show hostApiVersion;

const clientPairingManagementApiVersion = managementApiVersion;

const _credentialPattern = r'^[A-Za-z0-9_-]{43,128}$';

/// A safe summary of successful enrollment. The returned bearer credential is
/// deliberately not part of this result or its string representation.
class ClientPairingResult {
  const ClientPairingResult({
    required this.profile,
    required this.credentialId,
    required this.expiresAtUtc,
    required this.correlationId,
  });

  final HostConnectionProfile profile;
  final String credentialId;
  final DateTime expiresAtUtc;
  final String correlationId;
}

class ClientPairingException implements Exception {
  const ClientPairingException(
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
      'Client pairing error: $code${correlationId == null ? '' : ' [$correlationId]'}';
}

typedef ClientPairingExchange =
    Future<ClientPairingHttpResponse> Function({
      required Uri uri,
      required Map<String, String> headers,
      required String body,
      required Duration timeout,
      required int maxResponseBytes,
    });

class ClientPairingHttpResponse {
  const ClientPairingHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final Map<String, dynamic> body;
  final Map<String, String> headers;
}

/// Redeems a single-use code over HTTPS and installs only the one exact scope
/// returned by the Host. Device role is validated as metadata; it grants no
/// user authorization.
class ClientPairingClient {
  ClientPairingClient({
    required Uri endpoint,
    required this.credentials,
    required this.store,
    String Function()? deviceIdFactory,
    DateTime Function()? clock,
    this.exchange,
    this.timeout = const Duration(seconds: 20),
    this.maxResponseBytes = 128 * 1024,
  }) : endpoint = _httpsEndpoint(endpoint),
       _deviceIdFactory = deviceIdFactory ?? createClientDeviceId,
       _clock = clock ?? DateTime.now {
    if (timeout <= Duration.zero || maxResponseBytes < 1) {
      throw ArgumentError('Client pairing transport limits must be positive.');
    }
  }

  final Uri endpoint;
  final HostCredentialVault credentials;
  final LocalExtensionStore store;
  final ClientPairingExchange? exchange;
  final Duration timeout;
  final int maxResponseBytes;
  final String Function() _deviceIdFactory;
  final DateTime Function() _clock;

  /// Uses cryptographically secure local randomness; the device ID is not a
  /// credential and does not carry permissions or role authority.
  static String createClientDeviceId() {
    final random = Random.secure();
    final hex = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return 'client_$hex';
  }

  Future<ClientPairingResult> redeemAndSave({required String code}) async {
    final pairingCode = code.trim();
    if (!RegExp(_credentialPattern).hasMatch(pairingCode)) {
      throw const ClientPairingException('PAIRING_CODE_INVALID_FORMAT');
    }
    final deviceId = _deviceIdFactory();
    if (!RegExp(r'^client_[0-9a-f]{32}$').hasMatch(deviceId)) {
      throw const ClientPairingException('CLIENT_DEVICE_ID_INVALID');
    }

    // Check local persistence before consuming the single-use Host code.
    final previousProfile = await _readExistingProfile();
    final previousCredential = await _readPreviousCredential();
    final response = await _post(pairingCode, deviceId);
    if (response.statusCode != HttpStatus.created) {
      throw _apiError(response);
    }
    late final _PairingEnrollment enrollment;
    try {
      enrollment = _parseSuccess(response, deviceId);
    } on ClientPairingException {
      rethrow;
    } catch (_) {
      throw _invalidResponse(response);
    }
    final profile = HostConnectionProfile(
      endpoint: endpoint.toString(),
      tenantId: enrollment.tenantId,
      companyId: enrollment.companyId,
      branchId: enrollment.branchId,
      actorId: enrollment.actorId,
      deviceId: enrollment.deviceId,
    );

    // A Host credential is replaced only after the complete Host response has
    // passed version, shape, role, scope, expiry, and token validation.
    try {
      await credentials.save(endpoint, enrollment.credential);
      await store.saveHostProfile(profile);
    } catch (_) {
      try {
        if (previousCredential == null) {
          await credentials.delete(endpoint);
        } else {
          await credentials.save(endpoint, previousCredential);
        }
      } catch (_) {
        // Do not expose platform-storage exceptions or credential material.
      }
      throw ClientPairingException(
        'CLIENT_ENROLLMENT_SAVE_FAILED',
        correlationId: response.correlationId,
      );
    }

    final oldEndpoint = previousProfile?.endpoint;
    if (oldEndpoint != null && oldEndpoint != endpoint.toString()) {
      try {
        await credentials.delete(Uri.parse(oldEndpoint));
      } catch (_) {
        // Profile and new credential are committed; stale-key cleanup is best effort.
      }
    }
    return ClientPairingResult(
      profile: profile,
      credentialId: enrollment.credentialId,
      expiresAtUtc: enrollment.expiresAtUtc,
      correlationId: response.correlationId,
    );
  }

  Future<HostConnectionProfile?> _readExistingProfile() async {
    try {
      return await store.getHostProfile();
    } catch (_) {
      throw const ClientPairingException('CLIENT_PROFILE_READ_FAILED');
    }
  }

  Future<String?> _readPreviousCredential() async {
    try {
      return await credentials.read(endpoint);
    } catch (_) {
      throw const ClientPairingException('CLIENT_CREDENTIAL_STORAGE_FAILED');
    }
  }

  _PairingEnrollment _parseSuccess(
    _PairingResponse response,
    String requestedDeviceId,
  ) {
    const envelopeKeys = {
      'apiVersion',
      'managementApiVersion',
      'correlationId',
      'enrollment',
    };
    if (response.body.length != envelopeKeys.length ||
        response.body.keys.any((key) => !envelopeKeys.contains(key))) {
      throw _invalidResponse(response);
    }
    final raw = response.body['enrollment'];
    if (raw is! Map) throw _invalidResponse(response);
    final json = Map<String, dynamic>.from(raw);
    const enrollmentKeys = {
      'tenantId',
      'actorId',
      'deviceId',
      'deviceRole',
      'credentialId',
      'companyId',
      'branchId',
      'expiresAtUtc',
      'credential',
    };
    if (json.length != enrollmentKeys.length ||
        json.keys.any((key) => !enrollmentKeys.contains(key))) {
      throw _invalidResponse(response);
    }

    String identifier(String key) {
      final value = json[key];
      if (value is! String ||
          value.trim().isEmpty ||
          value.length > 256 ||
          value.trim() != value ||
          value.runes.any(
            (character) => character < 0x20 || character == 0x7f,
          )) {
        throw _invalidResponse(response);
      }
      return value;
    }

    final tenantId = identifier('tenantId');
    final actorId = identifier('actorId');
    final deviceId = identifier('deviceId');
    final companyId = identifier('companyId');
    final branchId = identifier('branchId');
    final credentialId = json['credentialId'];
    final credential = json['credential'];
    final expiresAtValue = json['expiresAtUtc'];
    final expiresAtUtc =
        expiresAtValue is String && expiresAtValue.endsWith('Z')
        ? DateTime.tryParse(expiresAtValue)
        : null;
    final now = _clock().toUtc();
    if (json['deviceRole'] != HostDeviceRole.client.wireValue ||
        deviceId != requestedDeviceId ||
        credentialId is! String ||
        !RegExp(r'^cred_[0-9a-f]{32}$').hasMatch(credentialId) ||
        credential is! String ||
        !RegExp(_credentialPattern).hasMatch(credential) ||
        expiresAtUtc == null ||
        !expiresAtUtc.isUtc ||
        !expiresAtUtc.isAfter(now) ||
        expiresAtUtc.isAfter(now.add(const Duration(days: 31)))) {
      throw _invalidResponse(response);
    }
    // Scope is exactly one company/branch pair in this contract. The strict
    // key set above rejects a broader permission or scope projection.
    return _PairingEnrollment(
      tenantId: tenantId,
      actorId: actorId,
      deviceId: deviceId,
      companyId: companyId,
      branchId: branchId,
      credentialId: credentialId,
      credential: credential,
      expiresAtUtc: expiresAtUtc,
    );
  }

  Future<_PairingResponse> _post(String code, String deviceId) async {
    try {
      final response = await (exchange ?? _httpExchange)(
        uri: endpoint.replace(path: HostManagementRoutes.pairingRedeem),
        headers: const {
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        },
        body: canonicalJson({
          'managementApiVersion': clientPairingManagementApiVersion,
          'code': code,
          'deviceId': deviceId,
        }),
        timeout: timeout,
        maxResponseBytes: maxResponseBytes,
      ).timeout(timeout);
      final correlationId = _validCorrelationId(
        response.body['correlationId'] ??
            response.headers['x-correlation-id'] ??
            response.headers['X-Correlation-ID'],
      );
      if (correlationId == null) {
        throw ClientPairingException(
          'HOST_INVALID_RESPONSE',
          statusCode: response.statusCode,
        );
      }
      if (response.body['apiVersion'] != hostApiVersion) {
        throw ClientPairingException(
          'HOST_API_VERSION_MISMATCH',
          statusCode: response.statusCode,
          correlationId: correlationId,
        );
      }
      if (response.statusCode == HttpStatus.created &&
          response.body['managementApiVersion'] !=
              clientPairingManagementApiVersion) {
        throw ClientPairingException(
          'HOST_API_VERSION_MISMATCH',
          statusCode: response.statusCode,
          correlationId: correlationId,
        );
      }
      return _PairingResponse(
        response.statusCode,
        response.body,
        correlationId,
      );
    } on ClientPairingException {
      rethrow;
    } on TimeoutException {
      throw const ClientPairingException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    } on SocketException {
      throw const ClientPairingException('HOST_UNREACHABLE', retryable: true);
    } on TlsException {
      throw const ClientPairingException('HOST_TLS_VALIDATION_FAILED');
    } on HttpException {
      throw const ClientPairingException('HOST_INVALID_RESPONSE');
    } on FormatException {
      throw const ClientPairingException('HOST_INVALID_RESPONSE');
    } catch (_) {
      throw const ClientPairingException('HOST_UNAVAILABLE', retryable: true);
    }
  }

  Future<ClientPairingHttpResponse> _httpExchange({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    final stopwatch = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.openUrl('POST', uri).timeout(timeout);
      request
        ..followRedirects = false
        ..maxRedirects = 0;
      headers.forEach(request.headers.set);
      request.write(body);
      final response = await request.close().timeout(_remaining(stopwatch));
      if (response.headers.contentType?.mimeType.toLowerCase() !=
          'application/json') {
        throw const ClientPairingException('HOST_INVALID_RESPONSE');
      }
      if (response.contentLength > maxResponseBytes) {
        throw const ClientPairingException('HOST_RESPONSE_TOO_LARGE');
      }
      final bytes = await response
          .fold<List<int>>(<int>[], (buffer, chunk) {
            if (buffer.length + chunk.length > maxResponseBytes) {
              throw const ClientPairingException('HOST_RESPONSE_TOO_LARGE');
            }
            buffer.addAll(chunk);
            return buffer;
          })
          .timeout(_remaining(stopwatch));
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const ClientPairingException('HOST_INVALID_RESPONSE');
      }
      final correlationHeader = response.headers.value('x-correlation-id');
      return ClientPairingHttpResponse(
        statusCode: response.statusCode,
        body: Map<String, dynamic>.from(decoded),
        headers: {'x-correlation-id': ?correlationHeader},
      );
    } finally {
      client.close(force: true);
    }
  }

  ClientPairingException _apiError(_PairingResponse response) {
    try {
      const envelopeKeys = {'apiVersion', 'correlationId', 'error'};
      if (response.body.length != envelopeKeys.length ||
          response.body.keys.any((key) => !envelopeKeys.contains(key))) {
        return _invalidResponse(response);
      }
      final rawError = response.body['error'];
      if (rawError is! Map) return _invalidResponse(response);
      final error = Map<String, dynamic>.from(rawError);
      const errorKeys = {'code', 'messageKey', 'message', 'retryable'};
      if (error.length != errorKeys.length ||
          error.keys.any((key) => !errorKeys.contains(key)) ||
          error['messageKey'] is! String ||
          error['message'] is! String ||
          error['retryable'] is! bool) {
        return _invalidResponse(response);
      }
      final rawCode = error['code'];
      const knownCodes = {
        'PAIRING_INVALID_OR_EXPIRED',
        'PAIRING_RATE_LIMITED',
        'DEVICE_ALREADY_REGISTERED',
        'INVALID_REQUEST',
        'HOST_UNAVAILABLE',
      };
      final safeCode = rawCode is String && knownCodes.contains(rawCode)
          ? rawCode
          : 'HOST_HTTP_ERROR';
      return ClientPairingException(
        safeCode,
        statusCode: response.statusCode,
        correlationId: response.correlationId,
        retryable: error['retryable'] == true || response.statusCode >= 500,
      );
    } on ClientPairingException {
      rethrow;
    } catch (_) {
      return _invalidResponse(response);
    }
  }

  ClientPairingException _invalidResponse(_PairingResponse response) =>
      ClientPairingException(
        'HOST_INVALID_RESPONSE',
        statusCode: response.statusCode,
        correlationId: response.correlationId,
      );

  Duration _remaining(Stopwatch stopwatch) {
    final remaining = timeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) {
      throw const ClientPairingException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    }
    return remaining;
  }
}

Uri _httpsEndpoint(Uri endpoint) {
  final normalized = HostCredentialVault.normalizeEndpoint(endpoint);
  if (normalized.scheme != 'https') {
    throw ArgumentError('Client pairing requires an HTTPS Host address.');
  }
  return normalized;
}

String? _validCorrelationId(Object? value) =>
    value is String && RegExp(r'^cor_[0-9a-f]{32}$').hasMatch(value)
    ? value
    : null;

class _PairingResponse {
  const _PairingResponse(this.statusCode, this.body, this.correlationId);

  final int statusCode;
  final Map<String, dynamic> body;
  final String correlationId;
}

class _PairingEnrollment {
  const _PairingEnrollment({
    required this.tenantId,
    required this.actorId,
    required this.deviceId,
    required this.companyId,
    required this.branchId,
    required this.credentialId,
    required this.credential,
    required this.expiresAtUtc,
  });

  final String tenantId;
  final String actorId;
  final String deviceId;
  final String companyId;
  final String branchId;
  final String credentialId;
  final String credential;
  final DateTime expiresAtUtc;
}
