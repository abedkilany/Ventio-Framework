import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ventio_core/ventio_core.dart';

import 'extension_store.dart';
import 'host_credentials.dart';
import 'host_device_management.dart';

enum ClientCredentialReissueState { none, applied, staged, rejected }

class ClientCredentialReissueResult {
  const ClientCredentialReissueResult({
    required this.state,
    this.operationId,
    this.code,
  });

  final ClientCredentialReissueState state;
  final String? operationId;
  final String? code;
}

class ClientCredentialReissueException implements Exception {
  const ClientCredentialReissueException(
    this.code, {
    this.retryable = false,
    this.operationId,
  });

  final String code;
  final bool retryable;
  final String? operationId;

  @override
  String toString() =>
      'Client credential reissue error: $code${operationId == null ? '' : ' [$operationId]'}';
}

/// Applies a Host-approved credential update without changing Host profile,
/// device identity, or any SQLite state. New credentials are staged first and
/// acknowledged only after protected storage confirms the stage is durable.
class ClientCredentialReissueClient {
  ClientCredentialReissueClient({
    required this.profile,
    required this.credentials,
    this.exchange,
    HttpClient Function()? clientFactory,
    this.claimTimeout = const Duration(seconds: 25),
    this.acknowledgmentTimeout = const Duration(seconds: 60),
    this.maxResponseBytes = 128 * 1024,
  }) : endpoint = HostCredentialVault.normalizeEndpoint(
         Uri.parse(profile.endpoint),
       ),
       _clientFactory = clientFactory ?? HttpClient.new {
    if (claimTimeout <= Duration.zero ||
        acknowledgmentTimeout <= Duration.zero ||
        maxResponseBytes < 1) {
      throw ArgumentError(
        'Credential reissue transport limits must be positive.',
      );
    }
  }

  final HostConnectionProfile profile;
  final HostCredentialVault credentials;
  final Uri endpoint;
  final HostDeviceManagementExchange? exchange;
  final HttpClient Function() _clientFactory;
  final Duration claimTimeout;
  final Duration acknowledgmentTimeout;
  final int maxResponseBytes;

  /// Polls for a pending update bound to the currently active source
  /// credential. If this Client already has a durable stage, it resumes the
  /// acknowledgment first, including after a lost final response.
  Future<ClientCredentialReissueResult> checkAndApply() async {
    if (exchange == null &&
        await credentials.readTrustedCertificate(endpoint) == null) {
      throw const ClientCredentialReissueException('HOST_TLS_PIN_REQUIRED');
    }
    final staged = await credentials.readStagedCredentialReissue(endpoint);
    if (staged != null) return _finish(staged);
    final sourceToken = await credentials.read(endpoint);
    if (sourceToken == null) {
      throw const ClientCredentialReissueException('HOST_CREDENTIAL_MISSING');
    }
    final response = await _post(
      HostManagementRoutes.credentialReissueClaim,
      {'managementApiVersion': managementApiVersion},
      bearer: sourceToken,
      timeout: claimTimeout,
    );
    if (response.statusCode == HttpStatus.notFound) {
      return const ClientCredentialReissueResult(
        state: ClientCredentialReissueState.none,
      );
    }
    if (response.statusCode != HttpStatus.ok) throw _error(response);
    const outerKeys = {
      'apiVersion',
      'managementApiVersion',
      'correlationId',
      'credentialReissue',
    };
    if (response.body.length != outerKeys.length ||
        response.body.keys.any((key) => !outerKeys.contains(key)) ||
        response.body['apiVersion'] != 1 ||
        response.body['managementApiVersion'] != managementApiVersion) {
      throw const ClientCredentialReissueException('HOST_INVALID_RESPONSE');
    }
    final raw = response.body['credentialReissue'];
    if (raw is! Map) {
      throw const ClientCredentialReissueException('HOST_INVALID_RESPONSE');
    }
    final value = Map<String, dynamic>.from(raw);
    if (value.length == 1 && value['state'] == 'NONE') {
      return const ClientCredentialReissueResult(
        state: ClientCredentialReissueState.none,
      );
    }
    final newCredential = _parseReplacement(value);
    await credentials.stageCredentialReissue(
      endpoint,
      operationId: newCredential.operationId,
      token: newCredential.token,
      credentialId: newCredential.credentialId,
      tenantId: newCredential.tenantId,
      actorId: newCredential.actorId,
      deviceId: newCredential.deviceId,
      companyId: newCredential.companyId,
      branchId: newCredential.branchId,
      permissions: newCredential.permissions,
      expiresAtUtc: newCredential.expiresAtUtc,
    );
    return _finish(newCredential);
  }

  Future<ClientCredentialReissueResult> _finish(
    StagedHostCredentialReissue staged,
  ) async {
    _validateSameIdentity(staged);
    final response = await _post(
      HostManagementRoutes.credentialReissueAcknowledge,
      {
        'managementApiVersion': managementApiVersion,
        'operationId': staged.operationId,
      },
      bearer: staged.token,
      timeout: acknowledgmentTimeout,
    );
    if (response.statusCode == HttpStatus.conflict) {
      final code = _errorCode(response);
      if (code == 'REISSUE_EXPIRED' || code == 'REISSUE_REJECTED') {
        await credentials.clearStagedCredentialReissue(endpoint);
        return ClientCredentialReissueResult(
          state: ClientCredentialReissueState.rejected,
          operationId: staged.operationId,
          code: code,
        );
      }
      throw ClientCredentialReissueException(
        code,
        retryable: true,
        operationId: staged.operationId,
      );
    }
    if (response.statusCode != HttpStatus.ok) {
      final error = _error(response);
      throw ClientCredentialReissueException(
        error.code,
        retryable: error.retryable,
        operationId: staged.operationId,
      );
    }
    final result = response.body['credentialReissue'];
    if (response.body['apiVersion'] != 1 ||
        response.body['managementApiVersion'] != managementApiVersion ||
        result is! Map ||
        result['operationId'] != staged.operationId) {
      throw ClientCredentialReissueException(
        'HOST_INVALID_RESPONSE',
        retryable: true,
        operationId: staged.operationId,
      );
    }
    if (result['state'] == 'EXPIRED' || result['state'] == 'REJECTED') {
      await credentials.clearStagedCredentialReissue(endpoint);
      return ClientCredentialReissueResult(
        state: ClientCredentialReissueState.rejected,
        operationId: staged.operationId,
        code: result['state'] as String,
      );
    }
    if (result['state'] != 'FINALIZED' ||
        result['deviceId'] != profile.deviceId ||
        result['credentialId'] != staged.credentialId) {
      throw ClientCredentialReissueException(
        'HOST_INVALID_RESPONSE',
        retryable: true,
        operationId: staged.operationId,
      );
    }
    try {
      await credentials.activateStagedCredentialReissue(
        endpoint,
        staged.operationId,
      );
    } catch (_) {
      // The durable stage remains available for the next restart/retry.
      throw ClientCredentialReissueException(
        'CLIENT_SECURE_STORAGE_ACTIVATION_FAILED',
        retryable: true,
        operationId: staged.operationId,
      );
    }
    return ClientCredentialReissueResult(
      state: ClientCredentialReissueState.applied,
      operationId: staged.operationId,
    );
  }

  StagedHostCredentialReissue _parseReplacement(Map<String, dynamic> value) {
    const keys = {
      'operationId',
      'state',
      'tenantId',
      'actorId',
      'deviceId',
      'companyId',
      'branchId',
      'credentialId',
      'permissions',
      'expiresAtUtc',
      'credential',
    };
    final permissions = value['permissions'];
    final expiryValue = value['expiresAtUtc'];
    final expiresAt = expiryValue is String
        ? DateTime.tryParse(expiryValue)
        : null;
    final token = value['credential'];
    if (value.length != keys.length ||
        value.keys.any((key) => !keys.contains(key)) ||
        value['state'] != 'PREPARED' ||
        value['operationId'] is! String ||
        !RegExp(
          r'^reissue_[0-9a-f]{32}$',
        ).hasMatch(value['operationId'] as String) ||
        value['credentialId'] is! String ||
        !RegExp(
          r'^cred_[0-9a-f]{32}$',
        ).hasMatch(value['credentialId'] as String) ||
        token is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(token) ||
        permissions is! List ||
        permissions.isEmpty ||
        permissions.length > 128 ||
        permissions.any(
          (item) =>
              item is! String ||
              !RegExp(r'^[a-z][a-z0-9_.]{0,255}$').hasMatch(item),
        ) ||
        expiresAt == null ||
        !expiresAt.isUtc ||
        !expiresAt.isAfter(DateTime.now().toUtc())) {
      throw const ClientCredentialReissueException('HOST_INVALID_RESPONSE');
    }
    final result = StagedHostCredentialReissue(
      operationId: value['operationId'] as String,
      token: token,
      credentialId: value['credentialId'] as String,
      tenantId: _identifier(value, 'tenantId'),
      actorId: _identifier(value, 'actorId'),
      deviceId: _identifier(value, 'deviceId'),
      companyId: _identifier(value, 'companyId'),
      branchId: _identifier(value, 'branchId'),
      permissions: List.unmodifiable((permissions.cast<String>()..sort())),
      expiresAtUtc: expiresAt,
    );
    _validateSameIdentity(result);
    return result;
  }

  void _validateSameIdentity(StagedHostCredentialReissue value) {
    if (value.tenantId != profile.tenantId ||
        value.actorId != profile.actorId ||
        value.deviceId != profile.deviceId ||
        value.companyId != profile.companyId ||
        value.branchId != profile.branchId) {
      throw ClientCredentialReissueException(
        'REISSUE_IDENTITY_MISMATCH',
        operationId: value.operationId,
      );
    }
  }

  String _identifier(Map<String, dynamic> value, String key) {
    final item = value[key];
    if (item is! String ||
        item.trim().isEmpty ||
        item.length > 256 ||
        item.trim() != item ||
        item.runes.any((code) => code < 0x20 || code == 0x7f)) {
      throw const ClientCredentialReissueException('HOST_INVALID_RESPONSE');
    }
    return item;
  }

  Future<HostDeviceManagementHttpResponse> _post(
    String path,
    Map<String, Object?> body, {
    required String bearer,
    required Duration timeout,
  }) async {
    final uri = endpoint.replace(path: path);
    final headers = <String, String>{
      HttpHeaders.acceptHeader: 'application/json',
      HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
      HttpHeaders.authorizationHeader: 'Bearer $bearer',
    };
    final encoded = canonicalJson(body);
    try {
      final response = exchange != null
          ? await exchange!(
              uri: uri,
              headers: headers,
              body: encoded,
              timeout: timeout,
              maxResponseBytes: maxResponseBytes,
            ).timeout(timeout)
          : await _httpExchange(
              uri: uri,
              headers: headers,
              body: encoded,
              timeout: timeout,
            );
      if (response.body.length > 256) {
        throw const ClientCredentialReissueException('HOST_INVALID_RESPONSE');
      }
      return response;
    } on ClientCredentialReissueException {
      rethrow;
    } on TimeoutException {
      throw const ClientCredentialReissueException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    } on SocketException {
      throw const ClientCredentialReissueException(
        'HOST_UNREACHABLE',
        retryable: true,
      );
    } on TlsException {
      throw const ClientCredentialReissueException(
        'HOST_TLS_VALIDATION_FAILED',
      );
    } on FormatException {
      throw const ClientCredentialReissueException('HOST_INVALID_RESPONSE');
    } catch (_) {
      throw const ClientCredentialReissueException(
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
  }) async {
    final watch = Stopwatch()..start();
    final client = await credentials.createHttpClient(
      endpoint,
      fallbackFactory: _clientFactory,
    );
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.openUrl('POST', uri).timeout(timeout);
      request
        ..followRedirects = false
        ..maxRedirects = 0;
      headers.forEach(request.headers.set);
      request.write(body);
      final response = await request.close().timeout(timeout - watch.elapsed);
      if (response.headers.contentType?.mimeType.toLowerCase() !=
              'application/json' ||
          response.contentLength > maxResponseBytes) {
        throw const ClientCredentialReissueException('HOST_INVALID_RESPONSE');
      }
      final bytes = await response
          .fold<List<int>>(<int>[], (output, chunk) {
            if (output.length + chunk.length > maxResponseBytes) {
              throw const ClientCredentialReissueException(
                'HOST_RESPONSE_TOO_LARGE',
              );
            }
            output.addAll(chunk);
            return output;
          })
          .timeout(timeout - watch.elapsed);
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map) {
        throw const ClientCredentialReissueException('HOST_INVALID_RESPONSE');
      }
      return HostDeviceManagementHttpResponse(
        statusCode: response.statusCode,
        body: Map<String, dynamic>.from(json),
        headers: {
          'x-correlation-id': ?response.headers.value('x-correlation-id'),
        },
      );
    } on ClientCredentialReissueException {
      rethrow;
    } on TimeoutException {
      throw const ClientCredentialReissueException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    } on SocketException {
      throw const ClientCredentialReissueException(
        'HOST_UNREACHABLE',
        retryable: true,
      );
    } on HttpException {
      throw const ClientCredentialReissueException(
        'HOST_INVALID_RESPONSE',
        retryable: true,
      );
    } finally {
      client.close(force: true);
    }
  }

  ClientCredentialReissueException _error(
    HostDeviceManagementHttpResponse response,
  ) {
    final error = response.body['error'];
    final code = error is Map && error['code'] is String
        ? error['code'] as String
        : 'HOST_REQUEST_FAILED';
    final retryable = error is Map && error['retryable'] == true;
    return ClientCredentialReissueException(code, retryable: retryable);
  }

  String _errorCode(HostDeviceManagementHttpResponse response) {
    final error = response.body['error'];
    return error is Map && error['code'] is String
        ? error['code'] as String
        : 'HOST_REQUEST_FAILED';
  }
}
