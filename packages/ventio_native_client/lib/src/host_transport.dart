import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ventio_core/ventio_core.dart';

import 'host_credentials.dart';
import 'transport_fixture.dart';

/// Authenticated HTTPS transport for an approved Host endpoint.
///
/// TLS uses platform trust roots until the user explicitly pins a Host
/// certificate during Client enrollment. Pinned Hosts are constrained to that
/// exact certificate. This class never follows redirects or bypasses TLS.
class HttpHostCommandTransport implements CommandTransport {
  HttpHostCommandTransport({
    required Uri endpoint,
    required this.credentials,
    HttpClient Function()? clientFactory,
    this.timeout = const Duration(seconds: 15),
    this.maxResponseBytes = 65536,
  }) : endpoint = HostCredentialVault.normalizeEndpoint(endpoint),
       _clientFactory = clientFactory ?? HttpClient.new {
    if (timeout <= Duration.zero || maxResponseBytes < 1) {
      throw ArgumentError('Transport limits must be positive.');
    }
  }

  final Uri endpoint;
  final HostCredentialVault credentials;
  final HttpClient Function() _clientFactory;
  final Duration timeout;
  final int maxResponseBytes;

  @override
  int get apiVersion => hostApiVersion;

  @override
  Future<TransportResponse> send(CommandEnvelope envelope) async {
    final token = await credentials.read(endpoint);
    if (token == null) {
      throw const HostTransportException('HOST_CREDENTIAL_MISSING');
    }

    final uri = endpoint.replace(path: '/api/v1/commands');
    final watch = Stopwatch()..start();
    final client = await credentials.createHttpClient(
      endpoint,
      fallbackFactory: _clientFactory,
    );
    client.connectionTimeout = timeout;
    try {
      final request = await client.postUrl(uri).timeout(_remaining(watch));
      request.followRedirects = false;
      request.maxRedirects = 0;
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..contentType = ContentType.json;
      request.write(canonicalJson(envelope.original));
      final response = await request.close().timeout(_remaining(watch));
      if (response.headers.contentType?.mimeType.toLowerCase() !=
          'application/json') {
        throw const HostTransportException('HOST_INVALID_RESPONSE');
      }
      if (response.contentLength > maxResponseBytes) {
        throw const HostTransportException('HOST_RESPONSE_TOO_LARGE');
      }
      final body = await response
          .fold<List<int>>(<int>[], (bytes, chunk) {
            if (bytes.length + chunk.length > maxResponseBytes) {
              throw const HostTransportException('HOST_RESPONSE_TOO_LARGE');
            }
            bytes.addAll(chunk);
            return bytes;
          })
          .timeout(_remaining(watch));
      return _parseResponse(
        response.statusCode,
        body,
        envelope.commandId,
        correlationHeader: response.headers.value('X-Correlation-ID'),
      );
    } on HostTransportException {
      rethrow;
    } on TimeoutException {
      throw const HostTransportException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    } on SocketException {
      throw const HostTransportException('HOST_UNREACHABLE', retryable: true);
    } on TlsException {
      throw const HostTransportException('HOST_TLS_VALIDATION_FAILED');
    } on HttpException {
      throw const HostTransportException('HOST_INVALID_RESPONSE');
    } on FormatException {
      throw const HostTransportException('HOST_INVALID_RESPONSE');
    } finally {
      client.close(force: true);
    }
  }

  TransportResponse _parseResponse(
    int statusCode,
    List<int> bytes,
    String commandId, {
    String? correlationHeader,
  }) {
    final decoded = jsonDecode(utf8.decode(bytes));
    final response = requireMap(decoded, 'response');
    if (requireInt(response, 'apiVersion') != apiVersion) {
      throw const HostTransportException('HOST_API_VERSION_MISMATCH');
    }
    final rawReceipt = response['receipt'];
    if (rawReceipt is! Map) {
      final rawError = response['error'];
      final error = rawError is Map
          ? requireMap(rawError, 'error')
          : const <String, dynamic>{};
      final code = error['code'];
      final retryable = error['retryable'];
      final bodyCorrelation = response['correlationId'];
      final correlationId = _validatedCorrelationId(
        bodyCorrelation,
        correlationHeader,
      );
      throw HostTransportException(
        code is String && RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(code)
            ? code
            : 'HOST_HTTP_ERROR',
        statusCode: statusCode,
        retryable: retryable == true || statusCode >= 500,
        correlationId: correlationId,
      );
    }
    final receipt = CommandReceipt.fromJson(requireMap(rawReceipt, 'receipt'));
    if (receipt.commandId != commandId ||
        statusCode != _statusCodeFor(receipt)) {
      throw const HostTransportException('HOST_INVALID_RESPONSE');
    }
    return TransportResponse(
      apiVersion: apiVersion,
      source: TransportSource.host,
      receipt: receipt.toJson(),
    );
  }

  String? _validatedCorrelationId(Object? bodyValue, String? headerValue) {
    bool valid(String value) => RegExp(r'^cor_[a-f0-9]{32}$').hasMatch(value);

    if (bodyValue != null && (bodyValue is! String || !valid(bodyValue))) {
      throw const HostTransportException('HOST_INVALID_RESPONSE');
    }
    if (headerValue != null && !valid(headerValue)) {
      throw const HostTransportException('HOST_INVALID_RESPONSE');
    }
    if (bodyValue is String &&
        headerValue != null &&
        bodyValue != headerValue) {
      throw const HostTransportException('HOST_INVALID_RESPONSE');
    }
    return bodyValue is String ? bodyValue : headerValue;
  }

  int _statusCodeFor(CommandReceipt receipt) => switch (receipt.status) {
    'ACCEPTED' => HttpStatus.ok,
    'CONFLICT' || 'RETRY_LATER' => HttpStatus.conflict,
    'REJECTED' => switch (receipt.reasonCode) {
      'SCOPE_DENIED' || 'PERMISSION_DENIED' => HttpStatus.forbidden,
      'COMMAND_ID_REUSED' => HttpStatus.conflict,
      _ => HttpStatus.unprocessableEntity,
    },
    _ => throw const HostTransportException('HOST_INVALID_RESPONSE'),
  };

  Duration _remaining(Stopwatch watch) {
    final remaining = timeout - watch.elapsed;
    if (remaining <= Duration.zero) {
      throw const HostTransportException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    }
    return remaining;
  }
}

class HostTransportException implements Exception {
  const HostTransportException(
    this.code, {
    this.statusCode,
    this.retryable = false,
    this.correlationId,
  });

  final String code;
  final int? statusCode;
  final bool retryable;
  final String? correlationId;

  @override
  String toString() =>
      'Host transport error: $code${statusCode == null ? '' : ' ($statusCode)'}${correlationId == null ? '' : ' [$correlationId]'}';
}
