import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ventio_core/ventio_core.dart';

import 'host_credentials.dart';
import 'transport_fixture.dart';

class HostScopeGrant {
  HostScopeGrant({
    required this.companyId,
    required this.branchId,
    required Iterable<String> permissions,
  }) : permissions = Set.unmodifiable(permissions);

  final String companyId;
  final String branchId;
  final Set<String> permissions;
}

class HostSessionIdentity {
  HostSessionIdentity({
    required this.tenantId,
    required this.actorId,
    required this.deviceId,
    required this.persistent,
    required Iterable<HostScopeGrant> scopes,
  }) : scopes = List.unmodifiable(scopes);

  final String tenantId;
  final String actorId;
  final String deviceId;
  final bool persistent;
  final List<HostScopeGrant> scopes;
}

typedef HostExtensionPackageClientFactory =
    HostExtensionPackageClient Function({
      required Uri endpoint,
      required HostCredentialVault credentials,
    });

enum HostPackageSubmissionStatus { submitted, alreadyApproved }

/// Authenticated transport for package review and approved-package reads.
/// It never treats a submitted candidate as an approved installation.
class HostExtensionPackageClient {
  HostExtensionPackageClient({
    required Uri endpoint,
    required this.credentials,
    HttpClient Function()? clientFactory,
    this.timeout = const Duration(seconds: 15),
    this.maxResponseBytes = 2 * 1024 * 1024,
  }) : endpoint = HostCredentialVault.normalizeEndpoint(endpoint),
       _clientFactory = clientFactory ?? HttpClient.new {
    if (timeout <= Duration.zero || maxResponseBytes < 1) {
      throw ArgumentError('Host package transport limits must be positive.');
    }
  }

  final Uri endpoint;
  final HostCredentialVault credentials;
  final HttpClient Function() _clientFactory;
  final Duration timeout;
  final int maxResponseBytes;

  Future<HostSessionIdentity> session() async {
    final response = await _request('GET', '/api/v1/session');
    if (response.statusCode != HttpStatus.ok) {
      throw _responseError(response);
    }
    final raw = response.body['identity'];
    if (raw is! Map) {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    }
    final identity = Map<String, dynamic>.from(raw);
    if (identity.keys.toSet().difference(const {
          'tenantId',
          'actorId',
          'deviceId',
          'persistent',
          'scopes',
        }).isNotEmpty ||
        identity.keys.length != 5 ||
        identity['persistent'] is! bool ||
        identity['scopes'] is! List) {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    }
    final scopes = (identity['scopes'] as List).map((rawScope) {
      if (rawScope is! Map) {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      final scope = Map<String, dynamic>.from(rawScope);
      if (scope.keys.toSet().difference(const {
            'companyId',
            'branchId',
            'permissions',
          }).isNotEmpty ||
          scope.keys.length != 3 ||
          scope['permissions'] is! List ||
          (scope['permissions'] as List).any((value) => value is! String)) {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      final permissions = (scope['permissions'] as List).cast<String>();
      if (permissions.toSet().length != permissions.length) {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      return HostScopeGrant(
        companyId: _requiredIdentifier(scope['companyId']),
        branchId: _requiredIdentifier(scope['branchId']),
        permissions: permissions,
      );
    }).toList();
    return HostSessionIdentity(
      tenantId: _requiredIdentifier(identity['tenantId']),
      actorId: _requiredIdentifier(identity['actorId']),
      deviceId: _requiredIdentifier(identity['deviceId']),
      persistent: identity['persistent'] as bool,
      scopes: scopes,
    );
  }

  Future<HostPackageSubmissionStatus> submit({
    required ExtensionBundle bundle,
    required String companyId,
    required String branchId,
  }) async {
    final response = await _request('POST', '/api/v1/extensions/submit', {
      'companyId': companyId,
      'branchId': branchId,
      'package': bundle.toJson(),
    });
    final result = _packageResult(response);
    return switch (result['status']) {
      'SUBMITTED' => HostPackageSubmissionStatus.submitted,
      'APPROVED' => HostPackageSubmissionStatus.alreadyApproved,
      _ => throw _packageError(response, result),
    };
  }

  Future<ExtensionBundle> readApproved({
    required String moduleId,
    required String version,
    required String companyId,
    required String branchId,
  }) async {
    final response = await _request('POST', '/api/v1/extensions/read', {
      'companyId': companyId,
      'branchId': branchId,
      'moduleId': moduleId,
      'version': version,
    });
    final result = _packageResult(response);
    if (response.statusCode != HttpStatus.ok ||
        result['status'] != 'APPROVED') {
      throw _packageError(response, result);
    }
    final rawPackage = result['package'];
    if (rawPackage is! Map) {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    }
    final bundle = ExtensionBundle.fromJson(
      Map<String, dynamic>.from(rawPackage),
    );
    final canonical = canonicalJson(bundle.toJson());
    if (utf8.encode(canonical).length > ExtensionBundle.maxEncodedBytes ||
        bundle.moduleId != moduleId ||
        bundle.version != version ||
        result['packageSha256'] !=
            sha256.convert(utf8.encode(canonical)).toString()) {
      throw const HostPackageTransportException(
        'HOST_PACKAGE_INTEGRITY_FAILED',
      );
    }
    return bundle;
  }

  Future<_HostResponse> _request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final token = await credentials.read(endpoint);
    if (token == null) {
      throw const HostPackageTransportException('HOST_CREDENTIAL_MISSING');
    }
    final watch = Stopwatch()..start();
    final client = _clientFactory()..connectionTimeout = timeout;
    try {
      final uri = endpoint.replace(path: path);
      final request = await client
          .openUrl(method, uri)
          .timeout(_remaining(watch));
      request
        ..followRedirects = false
        ..maxRedirects = 0;
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(canonicalJson(body));
      }
      final response = await request.close().timeout(_remaining(watch));
      if (response.headers.contentType?.mimeType.toLowerCase() !=
          'application/json') {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      if (response.contentLength > maxResponseBytes) {
        throw const HostPackageTransportException('HOST_RESPONSE_TOO_LARGE');
      }
      final bytes = await response
          .fold<List<int>>(<int>[], (buffer, chunk) {
            if (buffer.length + chunk.length > maxResponseBytes) {
              throw const HostPackageTransportException(
                'HOST_RESPONSE_TOO_LARGE',
              );
            }
            buffer.addAll(chunk);
            return buffer;
          })
          .timeout(_remaining(watch));
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      final envelope = Map<String, dynamic>.from(decoded);
      if (envelope['apiVersion'] != hostApiVersion) {
        throw const HostPackageTransportException('HOST_API_VERSION_MISMATCH');
      }
      return _HostResponse(response.statusCode, envelope);
    } on HostPackageTransportException {
      rethrow;
    } on TimeoutException {
      throw const HostPackageTransportException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    } on SocketException {
      throw const HostPackageTransportException(
        'HOST_UNREACHABLE',
        retryable: true,
      );
    } on TlsException {
      throw const HostPackageTransportException('HOST_TLS_VALIDATION_FAILED');
    } on HttpException {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    } on FormatException {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    } finally {
      client.close(force: true);
    }
  }

  Duration _remaining(Stopwatch watch) {
    final remaining = timeout - watch.elapsed;
    if (remaining <= Duration.zero) {
      throw const HostPackageTransportException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    }
    return remaining;
  }
}

class _HostResponse {
  const _HostResponse(this.statusCode, this.body);

  final int statusCode;
  final Map<String, dynamic> body;
}

Map<String, dynamic> _packageResult(_HostResponse response) {
  final raw = response.body['packageResult'];
  if (raw is Map) return Map<String, dynamic>.from(raw);
  throw _responseError(response);
}

HostPackageTransportException _packageError(
  _HostResponse response,
  Map<String, dynamic> result,
) {
  final reason = result['reasonCode'];
  if (reason is String && RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(reason)) {
    return HostPackageTransportException(
      reason,
      statusCode: response.statusCode,
      retryable: response.statusCode >= 500,
    );
  }
  return _responseError(response);
}

HostPackageTransportException _responseError(_HostResponse response) {
  final raw = response.body['error'];
  final error = raw is Map ? Map<String, dynamic>.from(raw) : const {};
  final code = error['code'];
  final retryable = error['retryable'];
  return HostPackageTransportException(
    code is String && RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(code)
        ? code
        : 'HOST_HTTP_ERROR',
    statusCode: response.statusCode,
    retryable: retryable == true || response.statusCode >= 500,
  );
}

String _requiredIdentifier(Object? value) {
  if (value is! String || value.trim().isEmpty || value.length > 256) {
    throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
  }
  return value;
}

class HostPackageTransportException implements Exception {
  const HostPackageTransportException(
    this.code, {
    this.statusCode,
    this.retryable = false,
  });

  final String code;
  final int? statusCode;
  final bool retryable;

  @override
  String toString() =>
      'Host package transport error: $code${statusCode == null ? '' : ' ($statusCode)'}';
}
