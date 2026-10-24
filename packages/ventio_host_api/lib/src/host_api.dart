import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ventio_core/ventio_core.dart';

import 'authentication.dart';

abstract interface class CommandExecutor {
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session,
  );
}

/// Executor whose accepted effects use the authoritative durable Host store.
abstract interface class AuthoritativeCommandExecutor
    implements CommandExecutor {}

/// Versioned HTTP routing, validation, and authenticated command dispatch.
/// Cleartext is limited to loopback. Any external listener requires TLS and
/// persistent Host identity resolution.
class HostApi {
  final HttpServer _server;
  final HostAuthenticator _authenticator;
  final CommandExecutor _executor;
  final int maxBodyBytes;
  final int maxConcurrentRequests;
  final Duration bodyTimeout;
  final Set<Future<void>> _active = {};
  bool _closing = false;
  Future<void>? _closeFuture;

  HostApi._(
    this._server,
    this._authenticator,
    this._executor,
    this.maxBodyBytes,
    this.maxConcurrentRequests,
    this.bodyTimeout,
  ) {
    _server.serverHeader = null;
    _server.idleTimeout = const Duration(seconds: 5);
    _server.listen((request) {
      // Register synchronously before yielding so shutdown sees every request.
      late final Future<void> pending;
      pending = _handleSafely(
        request,
      ).whenComplete(() => _active.remove(pending));
      _active.add(pending);
    });
  }

  static Future<HostApi> bind({
    required HostAuthenticator authenticator,
    required CommandExecutor executor,
    InternetAddress? listenAddress,
    SecurityContext? tlsContext,
    int port = 0,
    int maxBodyBytes = 65536,
    int maxConcurrentRequests = 16,
    Duration bodyTimeout = const Duration(seconds: 10),
  }) async {
    if (maxBodyBytes < 1 ||
        maxConcurrentRequests < 1 ||
        bodyTimeout <= Duration.zero) {
      throw ArgumentError('Resource limits must be positive');
    }
    final address = listenAddress ?? InternetAddress.loopbackIPv4;
    if (!address.isLoopback &&
        (tlsContext == null ||
            authenticator is! PersistentHostAuthenticator ||
            executor is! AuthoritativeCommandExecutor)) {
      throw ArgumentError(
        'External Host listeners require TLS and authoritative Host services.',
      );
    }
    final server = tlsContext == null
        ? await HttpServer.bind(address, port)
        : await HttpServer.bindSecure(address, port, tlsContext);
    return HostApi._(
      server,
      authenticator,
      executor,
      maxBodyBytes,
      maxConcurrentRequests,
      bodyTimeout,
    );
  }

  int get port => _server.port;

  /// Stop admission and drain in-flight work before the caller closes resources.
  /// Does not cancel a database transaction on an arbitrary HTTP timeout.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    final stopped = _server.close();
    while (_active.isNotEmpty) {
      await Future.wait(_active.toList());
    }
    await stopped;
  }

  Future<void> _handleSafely(HttpRequest request) async {
    // Subscribe immediately so dart:io does not implicitly drain an unbounded
    // unauthenticated body before sending an early error response.
    final iterator = StreamIterator<List<int>>(request);
    final firstChunk = iterator.moveNext();
    // Early rejection may never await the first chunk; consume its error too.
    unawaited(firstChunk.then<void>((_) {}, onError: (Object _) {}));
    try {
      await _handle(request, iterator, firstChunk);
    } on _ApiError catch (error) {
      await _error(
        request,
        error.status,
        error.code,
        retryable: error.retryable,
      );
    } on HttpException {
      await _error(request, 400, 'INVALID_REQUEST');
    } on FormatException {
      await _error(request, 400, 'INVALID_REQUEST');
    } on ContractError {
      await _error(request, 400, 'INVALID_COMMAND');
    } catch (_) {
      // Never return exception text, database details, tokens, or request bodies.
      // Any execution exception may have an ambiguous commit outcome.
      await _error(request, 503, 'HOST_UNAVAILABLE', retryable: true);
    } finally {
      try {
        await request.response.close();
      } catch (_) {
        /* Peer disconnected. */
      }
      // Flush the response before cancellation; early cancellation truncates
      // error responses for incomplete uploads on dart:io.
      unawaited(iterator.cancel().catchError((Object _) {}));
    }
  }

  Future<void> _handle(
    HttpRequest request,
    StreamIterator<List<int>> iterator,
    Future<bool> firstChunk,
  ) async {
    request.response.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    // Do not drain untrusted, possibly infinite request bodies on keep-alive.
    request.response.persistentConnection = false;
    if (_closing || _active.length >= maxConcurrentRequests) {
      throw const _ApiError(503, 'HOST_BUSY', retryable: true);
    }
    if (request.uri.hasQuery) throw const _ApiError(400, 'INVALID_REQUEST');
    if (request.uri.path == '/healthz') {
      if (request.method != 'GET') {
        request.response.headers.set(HttpHeaders.allowHeader, 'GET');
        throw const _ApiError(405, 'METHOD_NOT_ALLOWED');
      }
      _json(request, 200, {'apiVersion': 1, 'status': 'alive'});
      return;
    }
    if (request.uri.path != '/api/v1/commands') {
      throw const _ApiError(404, 'NOT_FOUND');
    }
    if (request.method != 'POST') {
      request.response.headers.set(HttpHeaders.allowHeader, 'POST');
      throw const _ApiError(405, 'METHOD_NOT_ALLOWED');
    }
    final headers = request.headers[HttpHeaders.authorizationHeader];
    if (headers == null ||
        headers.length != 1 ||
        !RegExp(
          r'^Bearer [A-Za-z0-9_-]{43,128}$',
          caseSensitive: false,
        ).hasMatch(headers.single)) {
      throw const _ApiError(401, 'UNAUTHENTICATED');
    }
    final session = await _authenticator.authenticate(
      headers.single.substring(7),
    );
    if (session == null) throw const _ApiError(401, 'UNAUTHENTICATED');
    final principal = session.principal;
    final contentType = request.headers.contentType;
    if (contentType?.mimeType.toLowerCase() != 'application/json' ||
        (contentType?.charset != null &&
            contentType!.charset!.toLowerCase() != 'utf-8') ||
        request.headers.value(HttpHeaders.contentEncodingHeader) != null) {
      throw const _ApiError(415, 'UNSUPPORTED_MEDIA_TYPE');
    }
    if (request.contentLength > maxBodyBytes) {
      throw const _ApiError(413, 'BODY_TOO_LARGE');
    }
    final bytes = BytesBuilder(copy: false);
    // Stream.timeout alone measures inactivity, not total upload time.
    final watch = Stopwatch()..start();
    var nextChunk = firstChunk;
    try {
      while (true) {
        final remaining = bodyTimeout - watch.elapsed;
        if (remaining <= Duration.zero)
          throw const _ApiError(408, 'BODY_TIMEOUT');
        if (!await nextChunk.timeout(remaining)) break;
        if (bytes.length + iterator.current.length > maxBodyBytes) {
          throw const _ApiError(413, 'BODY_TOO_LARGE');
        }
        bytes.add(iterator.current);
        nextChunk = iterator.moveNext();
      }
    } on TimeoutException {
      throw const _ApiError(408, 'BODY_TIMEOUT');
    }
    final text = utf8.decode(bytes.takeBytes());
    _validateNesting(text);
    final json = requireMap(jsonDecode(text), 'command');
    _validateWireShape(json);
    final command = CommandEnvelope.fromJson(json);
    // Persistent scope/permissions are resolved inside the execution transaction.
    // Only identity claims are checked against the authenticated snapshot here.
    if (session.credentialDigest != null &&
        (principal.tenantId != command.tenantId ||
            principal.actorId != command.actorId ||
            principal.deviceId != command.deviceId)) {
      throw const _ApiError(403, 'SCOPE_DENIED');
    }
    if (session.credentialDigest == null &&
        !principal.withinScope(
          tenantId: command.tenantId,
          companyId: command.companyId,
          branchId: command.branchId,
          actorId: command.actorId,
          deviceId: command.deviceId,
        )) {
      throw const _ApiError(403, 'SCOPE_DENIED');
    }
    final receipt = await _executor.execute(command, session);
    if (receipt['reasonCode'] == 'AUTHENTICATION_REQUIRED') {
      throw const _ApiError(401, 'UNAUTHENTICATED');
    }
    final status = switch (receipt['status']) {
      'ACCEPTED' => 200,
      'CONFLICT' => 409,
      'RETRY_LATER' => 409,
      _ => switch (receipt['reasonCode']) {
        'SCOPE_DENIED' || 'PERMISSION_DENIED' => 403,
        'COMMAND_ID_REUSED' => 409,
        _ => 422,
      },
    };
    _json(request, status, {'apiVersion': 1, 'receipt': receipt});
  }

  Future<void> _error(
    HttpRequest request,
    int status,
    String code, {
    bool retryable = false,
  }) async {
    try {
      if (status == 401)
        request.response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Bearer',
        );
      if (retryable)
        request.response.headers.set(HttpHeaders.retryAfterHeader, '1');
      _json(request, status, {
        'apiVersion': 1,
        'error': {
          'code': code,
          'messageKey': 'host_api.error.${code.toLowerCase()}',
          'message': switch (code) {
            'UNAUTHENTICATED' => 'Valid credentials are required.',
            'SCOPE_DENIED' => 'The requested identity or scope is not allowed.',
            'HOST_UNAVAILABLE' =>
              'Outcome may be unknown. Retry the identical command.',
            _ => 'The request could not be processed.',
          },
          'retryable': retryable,
        },
      });
    } catch (_) {
      /* Peer disconnected before error delivery. */
    }
  }

  void _json(HttpRequest request, int status, Map<String, dynamic> body) {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    final bytes = utf8.encode(jsonEncode(body));
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
  }
}

void _validateWireShape(Map<String, dynamic> json) {
  const allowed = {
    'protocolVersion',
    'commandId',
    'type',
    'typeVersion',
    'tenantId',
    'companyId',
    'branchId',
    'aggregateId',
    'expectedRevision',
    'dependsOn',
    'payload',
    'clientContext',
  };
  final context = requireMap(json['clientContext'], 'clientContext');
  if (json.keys.any((key) => !allowed.contains(key)) ||
      context.keys.any(
        (key) => !{
          'deviceId',
          'actorId',
          'moduleVersion',
          'docTypeVersion',
          'clientTimestamp',
        }.contains(key),
      ) ||
      !RegExp(r'^[a-z][a-z0-9_.]+$').hasMatch(requireString(json, 'type'))) {
    throw const _ApiError(400, 'INVALID_COMMAND');
  }
  if (context.containsKey('clientTimestamp') &&
      (context['clientTimestamp'] is! String ||
          !RegExp(
            r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$',
          ).hasMatch(context['clientTimestamp'] as String) ||
          DateTime.tryParse(context['clientTimestamp'] as String) == null)) {
    throw const _ApiError(400, 'INVALID_COMMAND');
  }
  for (final key in [
    'tenantId',
    'companyId',
    'branchId',
    'aggregateId',
    'type',
  ]) {
    if (requireString(json, key).length > 256)
      throw const _ApiError(400, 'INVALID_COMMAND');
  }
  for (final key in ['actorId', 'deviceId']) {
    if (requireString(context, key).length > 256)
      throw const _ApiError(400, 'INVALID_COMMAND');
  }
  if (json['dependsOn'] is List && (json['dependsOn'] as List).length > 128) {
    throw const _ApiError(400, 'INVALID_COMMAND');
  }
}

/// Bound parser recursion before decoding adversarial nested JSON.
void _validateNesting(String text) {
  var depth = 0;
  var quoted = false;
  var escaped = false;
  for (final unit in text.codeUnits) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (unit == 92) {
        escaped = true;
      } else if (unit == 34) {
        quoted = false;
      }
    } else if (unit == 34) {
      quoted = true;
    } else if (unit == 123 || unit == 91) {
      if (++depth > 32) throw const _ApiError(400, 'INVALID_REQUEST');
    } else if (unit == 125 || unit == 93) {
      depth--;
    }
  }
}

class _ApiError implements Exception {
  final int status;
  final String code;
  final bool retryable;
  const _ApiError(this.status, this.code, {this.retryable = false});
}
