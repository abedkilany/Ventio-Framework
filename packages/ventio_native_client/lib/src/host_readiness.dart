import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ventio_core/ventio_core.dart';

import 'host_credentials.dart';
import 'host_extension_packages.dart' show HostSessionIdentity;
import 'transport_fixture.dart' show hostApiVersion;

class HostReadinessResult {
  const HostReadinessResult({
    required this.snapshot,
    required this.correlationId,
  });

  final HostReadinessSnapshot snapshot;
  final String correlationId;
}

class HostReadinessException implements Exception {
  const HostReadinessException(
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
      'Host readiness error: $code${correlationId == null ? '' : ' [$correlationId]'}';
}

typedef HostReadinessExchange =
    Future<HostReadinessHttpResponse> Function({
      required Uri uri,
      required Map<String, String> headers,
      required String body,
      required Duration timeout,
      required int maxResponseBytes,
    });

class HostReadinessHttpResponse {
  const HostReadinessHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final Map<String, dynamic> body;
  final Map<String, String> headers;
}

/// Authenticated exact-scope Host readiness client. Host authorization remains
/// authoritative; this local check is only a UI gate.
class HostReadinessClient {
  HostReadinessClient({
    required Uri endpoint,
    required this.credentials,
    required this.verifiedIdentity,
    required this.companyId,
    required this.branchId,
    HttpClient Function()? clientFactory,
    this.exchange,
    this.timeout = const Duration(seconds: 15),
    this.maxResponseBytes = 256 * 1024,
  }) : endpoint = HostCredentialVault.normalizeEndpoint(endpoint),
       _clientFactory = clientFactory ?? HttpClient.new {
    if (companyId.trim().isEmpty ||
        companyId.length > 256 ||
        branchId.trim().isEmpty ||
        branchId.length > 256 ||
        timeout <= Duration.zero ||
        maxResponseBytes < 1) {
      throw ArgumentError('Invalid Host readiness client settings.');
    }
  }

  final Uri endpoint;
  final HostCredentialVault credentials;
  final HostSessionIdentity verifiedIdentity;
  final String companyId;
  final String branchId;
  final HttpClient Function() _clientFactory;
  final HostReadinessExchange? exchange;
  final Duration timeout;
  final int maxResponseBytes;

  bool get canReadStatus =>
      verifiedIdentity.persistent &&
      verifiedIdentity.tenantId.trim().isNotEmpty &&
      verifiedIdentity.scopes.any(
        (scope) =>
            scope.companyId == companyId &&
            scope.branchId == branchId &&
            scope.permissions.contains(hostStatusReadPermission),
      );

  bool canReadManagementPermission(String permission) =>
      verifiedIdentity.persistent &&
      verifiedIdentity.tenantId.trim().isNotEmpty &&
      verifiedIdentity.scopes.any(
        (scope) =>
            scope.companyId == companyId &&
            scope.branchId == branchId &&
            scope.permissions.contains(permission),
      );

  /// Sends only supported, versioned management requests through the same
  /// certificate-validating transport used by readiness checks.
  Future<HostReadinessHttpResponse> postManagement({
    required String path,
    required String permission,
    required Map<String, Object?> payload,
  }) async {
    if (!{
      HostManagementRoutes.readiness,
      HostManagementRoutes.diagnosticsRecent,
    }.contains(path)) {
      throw const HostReadinessException('HOST_UNSUPPORTED_MANAGEMENT_ROUTE');
    }
    if (permission != hostStatusReadPermission &&
        permission != hostDiagnosticsReadPermission) {
      throw const HostReadinessException('HOST_UNSUPPORTED_PERMISSION');
    }
    if (!canReadManagementPermission(permission)) {
      throw const HostReadinessException('HOST_PERMISSION_DENIED');
    }
    final token = await credentials.read(endpoint);
    if (token == null) {
      throw const HostReadinessException('HOST_CREDENTIAL_MISSING');
    }
    final body = canonicalJson(payload);
    try {
      final response = await (exchange ?? _httpExchange)(
        uri: endpoint.replace(path: path),
        headers: {
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
          HttpHeaders.authorizationHeader: 'Bearer $token',
        },
        body: body,
        timeout: timeout,
        maxResponseBytes: maxResponseBytes,
      ).timeout(timeout);
      final correlationId = _validCorrelationId(
        response.body['correlationId'] ??
            response.headers['x-correlation-id'] ??
            response.headers['X-Correlation-ID'],
      );
      if (correlationId == null) {
        throw HostReadinessException(
          'HOST_INVALID_RESPONSE',
          statusCode: response.statusCode,
        );
      }
      if (response.body['apiVersion'] != hostApiVersion ||
          (response.statusCode == HttpStatus.ok &&
              response.body['managementApiVersion'] != managementApiVersion)) {
        throw HostReadinessException(
          'HOST_API_VERSION_MISMATCH',
          statusCode: response.statusCode,
          correlationId: correlationId,
        );
      }
      return HostReadinessHttpResponse(
        statusCode: response.statusCode,
        body: response.body,
        headers: {...response.headers, 'x-correlation-id': correlationId},
      );
    } on HostReadinessException {
      rethrow;
    } on TimeoutException {
      throw const HostReadinessException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    } on SocketException {
      throw const HostReadinessException('HOST_UNREACHABLE', retryable: true);
    } on TlsException {
      throw const HostReadinessException('HOST_TLS_VALIDATION_FAILED');
    } on HttpException {
      throw const HostReadinessException('HOST_INVALID_RESPONSE');
    } on FormatException {
      throw const HostReadinessException('HOST_INVALID_RESPONSE');
    } catch (_) {
      throw const HostReadinessException('HOST_UNAVAILABLE', retryable: true);
    }
  }

  Future<HostReadinessResult> checkReadiness() async {
    final response = await _post();
    if (response.statusCode != HttpStatus.ok) throw _error(response);
    const envelopeKeys = {
      'apiVersion',
      'managementApiVersion',
      'correlationId',
      'readiness',
    };
    if (response.body.length != envelopeKeys.length ||
        response.body.keys.any((key) => !envelopeKeys.contains(key))) {
      throw _invalidResponse(response);
    }
    try {
      final snapshot = HostReadinessSnapshot.fromJson(
        response.body['readiness'],
      );
      final actualComponents = snapshot.components
          .map((component) => component.component)
          .toSet();
      if (actualComponents.length != ManagementComponent.values.length ||
          !actualComponents.containsAll(ManagementComponent.values)) {
        throw _invalidResponse(response);
      }
      return HostReadinessResult(
        snapshot: snapshot,
        correlationId: response.correlationId,
      );
    } on HostReadinessException {
      rethrow;
    } on FormatException {
      throw _invalidResponse(response);
    } on ArgumentError {
      throw _invalidResponse(response);
    }
  }

  Future<_ReadinessResponse> _post() async {
    if (!canReadStatus) {
      throw const HostReadinessException('HOST_PERMISSION_DENIED');
    }
    final token = await credentials.read(endpoint);
    if (token == null) {
      throw const HostReadinessException('HOST_CREDENTIAL_MISSING');
    }
    final body = canonicalJson({
      'managementApiVersion': managementApiVersion,
      'companyId': companyId,
      'branchId': branchId,
    });
    try {
      final response = await (exchange ?? _httpExchange)(
        uri: endpoint.replace(path: HostManagementRoutes.readiness),
        headers: {
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
          HttpHeaders.authorizationHeader: 'Bearer $token',
        },
        body: body,
        timeout: timeout,
        maxResponseBytes: maxResponseBytes,
      ).timeout(timeout);
      final correlationId = _validCorrelationId(
        response.body['correlationId'] ??
            response.headers['x-correlation-id'] ??
            response.headers['X-Correlation-ID'],
      );
      if (correlationId == null) {
        throw HostReadinessException(
          'HOST_INVALID_RESPONSE',
          statusCode: response.statusCode,
        );
      }
      if (response.body['apiVersion'] != hostApiVersion ||
          response.body['managementApiVersion'] != managementApiVersion) {
        throw HostReadinessException(
          'HOST_API_VERSION_MISMATCH',
          statusCode: response.statusCode,
          correlationId: correlationId,
        );
      }
      return _ReadinessResponse(
        response.statusCode,
        response.body,
        correlationId,
      );
    } on HostReadinessException {
      rethrow;
    } on TimeoutException {
      throw const HostReadinessException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    } on SocketException {
      throw const HostReadinessException('HOST_UNREACHABLE', retryable: true);
    } on TlsException {
      throw const HostReadinessException('HOST_TLS_VALIDATION_FAILED');
    } on HttpException {
      throw const HostReadinessException('HOST_INVALID_RESPONSE');
    } on FormatException {
      throw const HostReadinessException('HOST_INVALID_RESPONSE');
    } catch (_) {
      throw const HostReadinessException('HOST_UNAVAILABLE', retryable: true);
    }
  }

  Future<HostReadinessHttpResponse> _httpExchange({
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
        throw const HostReadinessException('HOST_INVALID_RESPONSE');
      }
      if (response.contentLength > maxResponseBytes) {
        throw const HostReadinessException('HOST_RESPONSE_TOO_LARGE');
      }
      final bytes = await response
          .fold<List<int>>(<int>[], (buffer, chunk) {
            if (buffer.length + chunk.length > maxResponseBytes) {
              throw const HostReadinessException('HOST_RESPONSE_TOO_LARGE');
            }
            buffer.addAll(chunk);
            return buffer;
          })
          .timeout(_remaining(watch));
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const HostReadinessException('HOST_INVALID_RESPONSE');
      }
      final correlationHeader = response.headers.value('x-correlation-id');
      return HostReadinessHttpResponse(
        statusCode: response.statusCode,
        body: Map<String, dynamic>.from(decoded),
        headers: {'x-correlation-id': ?correlationHeader},
      );
    } finally {
      client.close(force: true);
    }
  }

  Duration _remaining(Stopwatch watch) {
    final remaining = timeout - watch.elapsed;
    if (remaining <= Duration.zero) {
      throw const HostReadinessException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    }
    return remaining;
  }

  HostReadinessException _error(_ReadinessResponse response) {
    final rawError = response.body['error'];
    final error = rawError is Map
        ? Map<String, dynamic>.from(rawError)
        : const <String, dynamic>{};
    final rawCode = error['code'];
    final code =
        rawCode is String && RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(rawCode)
        ? rawCode
        : 'HOST_HTTP_ERROR';
    return HostReadinessException(
      code,
      statusCode: response.statusCode,
      correlationId: response.correlationId,
      retryable: error['retryable'] == true || response.statusCode >= 500,
    );
  }

  HostReadinessException _invalidResponse(_ReadinessResponse response) =>
      HostReadinessException(
        'HOST_INVALID_RESPONSE',
        statusCode: response.statusCode,
        correlationId: response.correlationId,
      );
}

class _ReadinessResponse {
  const _ReadinessResponse(this.statusCode, this.body, this.correlationId);

  final int statusCode;
  final Map<String, dynamic> body;
  final String correlationId;
}

String? _validCorrelationId(Object? value) =>
    value is String && RegExp(r'^cor_[a-f0-9]{32}$').hasMatch(value)
    ? value
    : null;
