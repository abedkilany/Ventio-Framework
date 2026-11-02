import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ventio_core/ventio_core.dart';

import 'authentication.dart';
import 'device_administration.dart';
import 'extension_packages.dart';
import 'extension_records.dart';
import 'management.dart';
import 'pairing_administration.dart';
import 'role_administration.dart';
import 'user_administration.dart';

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
  final ExtensionPackageGateway? _extensionPackages;
  final ExtensionRecordQueryGateway? _extensionRecordQueries;
  final ExtensionReportQueryGateway? _extensionReportQueries;
  final IdentityRoleAdministrationGateway? _identityRoleAdministration;
  final IdentityUserAdministrationGateway? _identityUserAdministration;
  final IdentityPairingGateway? _identityPairing;
  final IdentityDeviceAdministrationGateway? _identityDeviceAdministration;
  final HostReadinessProvider? _readinessProvider;
  final ManagementDiagnosticSink _diagnostics;
  final int maxBodyBytes;
  final int maxConcurrentRequests;
  final Duration bodyTimeout;
  final Set<Future<void>> _active = {};
  final _PairingRedeemRateLimiter _pairingRedeemRateLimiter =
      _PairingRedeemRateLimiter();
  bool _closing = false;
  Future<void>? _closeFuture;

  HostApi._(
    this._server,
    this._authenticator,
    this._executor,
    this._extensionPackages,
    this._extensionRecordQueries,
    this._extensionReportQueries,
    this._identityRoleAdministration,
    this._identityUserAdministration,
    this._identityPairing,
    this._identityDeviceAdministration,
    this._readinessProvider,
    this._diagnostics,
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
    ExtensionPackageGateway? extensionPackages,
    ExtensionRecordQueryGateway? extensionRecordQueries,
    ExtensionReportQueryGateway? extensionReportQueries,
    IdentityRoleAdministrationGateway? identityRoleAdministration,
    IdentityUserAdministrationGateway? identityUserAdministration,
    IdentityPairingGateway? identityPairing,
    IdentityDeviceAdministrationGateway? identityDeviceAdministration,
    HostReadinessProvider? readinessProvider,
    ManagementDiagnosticSink? diagnostics,
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
            executor is! AuthoritativeCommandExecutor ||
            (extensionPackages != null &&
                extensionPackages is! AuthoritativeExtensionPackageGateway) ||
            (extensionRecordQueries != null &&
                extensionRecordQueries
                    is! AuthoritativeExtensionRecordQueryGateway) ||
            (extensionReportQueries != null &&
                extensionReportQueries
                    is! AuthoritativeExtensionReportQueryGateway) ||
            (identityRoleAdministration != null &&
                identityRoleAdministration
                    is! AuthoritativeIdentityRoleAdministrationGateway) ||
            (identityUserAdministration != null &&
                identityUserAdministration
                    is! AuthoritativeIdentityUserAdministrationGateway) ||
            (identityPairing != null &&
                identityPairing is! AuthoritativeIdentityPairingGateway) ||
            (identityDeviceAdministration != null &&
                identityDeviceAdministration
                    is! AuthoritativeIdentityDeviceAdministrationGateway) ||
            (readinessProvider != null &&
                readinessProvider is! AuthoritativeHostReadinessProvider))) {
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
      extensionPackages,
      extensionRecordQueries,
      extensionReportQueries,
      identityRoleAdministration,
      identityUserAdministration,
      identityPairing,
      identityDeviceAdministration,
      readinessProvider,
      diagnostics ?? ManagementDiagnosticBuffer(),
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
    final correlationId = _newCorrelationId();
    request.response.headers.set('X-Correlation-ID', correlationId);
    // Subscribe immediately so dart:io does not implicitly drain an unbounded
    // unauthenticated body before sending an early error response.
    final iterator = StreamIterator<List<int>>(request);
    final firstChunk = iterator.moveNext();
    // Early rejection may never await the first chunk; consume its error too.
    unawaited(firstChunk.then<void>((_) {}, onError: (Object _) {}));
    try {
      await _handle(request, iterator, firstChunk, correlationId);
    } on _ApiError catch (error) {
      await _error(
        request,
        error.status,
        error.code,
        correlationId: correlationId,
        retryable: error.retryable,
        retryAfterSeconds: error.retryAfterSeconds,
      );
    } on HttpException {
      await _error(
        request,
        400,
        'INVALID_REQUEST',
        correlationId: correlationId,
      );
    } on FormatException {
      await _error(
        request,
        400,
        'INVALID_REQUEST',
        correlationId: correlationId,
      );
    } on ContractError {
      await _error(
        request,
        400,
        'INVALID_COMMAND',
        correlationId: correlationId,
      );
    } on IdentityRoleAdministrationException catch (error) {
      await _error(
        request,
        error.statusCode,
        error.code,
        correlationId: correlationId,
      );
    } on IdentityUserAdministrationException catch (error) {
      await _error(
        request,
        error.statusCode,
        error.code,
        correlationId: correlationId,
      );
    } on IdentityPairingException catch (error) {
      await _recordDiagnostic(
        ManagementDiagnosticEvent(
          code: error.code,
          component: 'identity.pairing',
          category: ManagementDiagnosticCategory.pairing,
          severity: error.statusCode >= 500
              ? ManagementDiagnosticSeverity.error
              : ManagementDiagnosticSeverity.warning,
          occurredAtUtc: DateTime.now().toUtc(),
          correlationId: correlationId,
          retryable: error.retryable,
          messageKey: 'host_api.error.${error.code.toLowerCase()}',
          safeExplanation: 'The device pairing request could not be completed.',
          recommendedAction:
              'Check the pairing state and request a new code if it expired.',
          protectedTechnicalCode: error.protectedTechnicalCode,
        ),
      );
      await _error(
        request,
        error.statusCode,
        error.code,
        correlationId: correlationId,
        retryable: error.retryable,
        retryAfterSeconds: error.retryAfterSeconds,
      );
    } on IdentityDeviceAdministrationException catch (error) {
      await _recordDiagnostic(
        ManagementDiagnosticEvent(
          code: error.code,
          component: 'identity.devices',
          category: ManagementDiagnosticCategory.authorization,
          severity: error.statusCode >= 500
              ? ManagementDiagnosticSeverity.error
              : ManagementDiagnosticSeverity.warning,
          occurredAtUtc: DateTime.now().toUtc(),
          correlationId: correlationId,
          retryable: false,
          messageKey: 'host_api.error.${error.code.toLowerCase()}',
          safeExplanation: 'The device administration request was denied.',
          recommendedAction:
              'Check the signed-in user permissions and exact branch scope.',
        ),
      );
      await _error(
        request,
        error.statusCode,
        error.code,
        correlationId: correlationId,
      );
    } catch (error, stackTrace) {
      // Never return exception text, database details, tokens, or request bodies.
      // Any execution exception may have an ambiguous commit outcome.
      await _recordInternalFailure(
        correlationId,
        protectedFailureType: error.runtimeType.toString(),
        protectedFailureSource: _protectedFailureSource(stackTrace),
      );
      await _error(
        request,
        503,
        'HOST_UNAVAILABLE',
        correlationId: correlationId,
        retryable: true,
      );
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
    String correlationId,
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
    final pairingRedeemRoute =
        request.uri.path == HostManagementRoutes.pairingRedeem;
    if (pairingRedeemRoute) {
      if (request.method != 'POST') {
        request.response.headers.set(HttpHeaders.allowHeader, 'POST');
        throw const _ApiError(405, 'METHOD_NOT_ALLOWED');
      }
      if (_identityPairing == null) throw const _ApiError(404, 'NOT_FOUND');
      final remote = request.connectionInfo?.remoteAddress.address ?? 'unknown';
      if (!_pairingRedeemRateLimiter.allow(remote)) {
        throw const _ApiError(
          429,
          'PAIRING_RATE_LIMITED',
          retryable: true,
          retryAfterSeconds: 60,
        );
      }
      final json = await _readJsonBody(request, iterator, firstChunk);
      await _handlePairingRedeem(request, json, correlationId);
      return;
    }
    final packageRoute = switch (request.uri.path) {
      '/api/v1/extensions/submit' => 'submit',
      '/api/v1/extensions/read' => 'read',
      '/api/v1/extensions/approved' => 'list',
      _ => null,
    };
    final recordQueryRoute =
        request.uri.path == '/api/v1/extensions/records/query';
    final reportQueryRoute =
        request.uri.path == '/api/v1/extensions/reports/query';
    final identityRoleRoute = _identityRoleAction(request.uri.path);
    final identityUserRoute = _identityUserAction(request.uri.path);
    final pairingCreateRoute =
        request.uri.path == HostManagementRoutes.pairingCreate;
    final identityDeviceAction = _identityDeviceAction(request.uri.path);
    final sessionRoute = request.uri.path == '/api/v1/session';
    final readinessRoute = request.uri.path == HostManagementRoutes.readiness;
    final diagnosticsRoute =
        request.uri.path == HostManagementRoutes.diagnosticsRecent;
    if (request.uri.path != '/api/v1/commands' &&
        packageRoute == null &&
        !recordQueryRoute &&
        !reportQueryRoute &&
        identityRoleRoute == null &&
        identityUserRoute == null &&
        identityDeviceAction == null &&
        !pairingCreateRoute &&
        !sessionRoute &&
        !readinessRoute &&
        !diagnosticsRoute) {
      throw const _ApiError(404, 'NOT_FOUND');
    }
    final requiredMethod = sessionRoute ? 'GET' : 'POST';
    if (request.method != requiredMethod) {
      request.response.headers.set(HttpHeaders.allowHeader, requiredMethod);
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
    if (sessionRoute) {
      if (request.contentLength > 0 ||
          request.headers.value(HttpHeaders.transferEncodingHeader) != null) {
        throw const _ApiError(400, 'INVALID_REQUEST');
      }
      final scopes =
          principal.scopeGrants
              .map(
                (scope) => {
                  'companyId': scope.companyId,
                  'branchId': scope.branchId,
                  'permissions': scope.permissions.toList()..sort(),
                },
              )
              .toList()
            ..sort((left, right) {
              final company = (left['companyId'] as String).compareTo(
                right['companyId'] as String,
              );
              return company != 0
                  ? company
                  : (left['branchId'] as String).compareTo(
                      right['branchId'] as String,
                    );
            });
      _json(request, 200, {
        'apiVersion': 1,
        'identity': {
          'tenantId': principal.tenantId,
          'actorId': principal.actorId,
          'deviceId': principal.deviceId,
          'persistent': session.credentialDigest != null,
          'roleAdministrationAvailable': _identityRoleAdministration != null,
          'scopes': scopes,
        },
      });
      return;
    }
    if (packageRoute != null && _extensionPackages == null) {
      throw const _ApiError(404, 'NOT_FOUND');
    }
    if (recordQueryRoute && _extensionRecordQueries == null) {
      throw const _ApiError(404, 'NOT_FOUND');
    }
    if ((packageRoute != null ||
            recordQueryRoute ||
            identityRoleRoute != null ||
            identityUserRoute != null ||
            identityDeviceAction != null ||
            pairingCreateRoute ||
            readinessRoute ||
            diagnosticsRoute) &&
        session.credentialDigest == null) {
      throw const _ApiError(403, 'PERSISTENT_IDENTITY_REQUIRED');
    }
    if (identityRoleRoute != null && _identityRoleAdministration == null) {
      throw const _ApiError(404, 'NOT_FOUND');
    }
    if (identityUserRoute != null && _identityUserAdministration == null) {
      throw const _ApiError(404, 'NOT_FOUND');
    }
    if (identityDeviceAction != null && _identityDeviceAdministration == null) {
      throw const _ApiError(404, 'NOT_FOUND');
    }
    if (readinessRoute && _readinessProvider == null) {
      throw const _ApiError(503, 'HOST_STATUS_UNAVAILABLE', retryable: true);
    }
    if (diagnosticsRoute && _diagnostics is! ManagementDiagnosticReader) {
      throw const _ApiError(
        503,
        'HOST_DIAGNOSTICS_UNAVAILABLE',
        retryable: true,
      );
    }
    if (pairingCreateRoute && _identityPairing == null) {
      throw const _ApiError(404, 'NOT_FOUND');
    }
    final contentType = request.headers.contentType;
    if (contentType?.mimeType.toLowerCase() != 'application/json' ||
        (contentType?.charset != null &&
            contentType!.charset!.toLowerCase() != 'utf-8') ||
        request.headers.value(HttpHeaders.contentEncodingHeader) != null) {
      throw const _ApiError(415, 'UNSUPPORTED_MEDIA_TYPE');
    }
    final bodyLimit = packageRoute == 'submit'
        ? ExtensionBundle.maxEncodedBytes + 8192
        : maxBodyBytes;
    if (request.contentLength > bodyLimit) {
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
        if (bytes.length + iterator.current.length > bodyLimit) {
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
    if (readinessRoute) {
      await _handleReadiness(request, json, session, correlationId);
      return;
    }
    if (diagnosticsRoute) {
      _handleDiagnostics(request, json, session, correlationId);
      return;
    }
    if (pairingCreateRoute) {
      await _handlePairingCreate(request, json, session, correlationId);
      return;
    }
    if (identityRoleRoute != null) {
      await _handleIdentityRoleAdministration(
        request,
        identityRoleRoute,
        json,
        session,
      );
      return;
    }
    if (identityUserRoute != null) {
      await _handleIdentityUserAdministration(
        request,
        identityUserRoute,
        json,
        session,
        correlationId,
      );
      return;
    }
    if (identityDeviceAction != null) {
      await _handleIdentityDeviceAdministration(
        request,
        identityDeviceAction,
        json,
        session,
        correlationId,
      );
      return;
    }
    if (packageRoute != null) {
      await _handleExtensionPackage(request, packageRoute, json, session);
      return;
    }
    if (recordQueryRoute) {
      await _handleExtensionRecordQuery(request, json, session);
      return;
    }
    if (reportQueryRoute) {
      await _handleExtensionReportQuery(request, json, session);
      return;
    }
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

  Future<Map<String, dynamic>> _readJsonBody(
    HttpRequest request,
    StreamIterator<List<int>> iterator,
    Future<bool> firstChunk,
  ) async {
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
    final watch = Stopwatch()..start();
    var nextChunk = firstChunk;
    try {
      while (true) {
        final remaining = bodyTimeout - watch.elapsed;
        if (remaining <= Duration.zero) {
          throw const _ApiError(408, 'BODY_TIMEOUT');
        }
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
    return requireMap(jsonDecode(text), 'pairing request');
  }

  Future<void> _handlePairingCreate(
    HttpRequest request,
    Map<String, dynamic> json,
    AuthenticatedSession session,
    String correlationId,
  ) async {
    const keys = {'managementApiVersion', 'companyId', 'branchId', 'actorId'};
    if (json.keys.toSet().length != keys.length ||
        !json.keys.toSet().containsAll(keys) ||
        json['managementApiVersion'] != managementApiVersion) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final companyId = _boundedIdentifier(json, 'companyId');
    final branchId = _boundedIdentifier(json, 'branchId');
    final actorId = _boundedIdentifier(json, 'actorId');
    if (!session.principal.allowsInScope(
      identityPairingManagePermission,
      companyId,
      branchId,
    )) {
      throw const IdentityPairingException(
        'PERMISSION_DENIED',
        statusCode: 403,
      );
    }
    final pairing = await _identityPairing!.create(
      session: session,
      companyId: companyId,
      branchId: branchId,
      actorId: actorId,
    );
    _json(request, 201, {
      'apiVersion': 1,
      'managementApiVersion': managementApiVersion,
      'correlationId': correlationId,
      'pairing': pairing,
    });
  }

  Future<void> _handlePairingRedeem(
    HttpRequest request,
    Map<String, dynamic> json,
    String correlationId,
  ) async {
    const keys = {'managementApiVersion', 'code', 'deviceId'};
    if (json.keys.toSet().length != keys.length ||
        !json.keys.toSet().containsAll(keys) ||
        json['managementApiVersion'] != managementApiVersion) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final code = json['code'];
    final deviceId = _boundedIdentifier(json, 'deviceId');
    if (code is! String ||
        !OpaqueToken.isValid(code) ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(deviceId) ||
        RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(deviceId)) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final enrollment = await _identityPairing!.redeem(
      code: code,
      deviceId: deviceId,
    );
    _json(request, 201, {
      'apiVersion': 1,
      'managementApiVersion': managementApiVersion,
      'correlationId': correlationId,
      'enrollment': enrollment,
    });
  }

  Future<void> _handleExtensionPackage(
    HttpRequest request,
    String operation,
    Map<String, dynamic> json,
    AuthenticatedSession session,
  ) async {
    final gateway = _extensionPackages!;
    final requiredKeys = switch (operation) {
      'submit' => const {'companyId', 'branchId', 'package'},
      'read' => const {'companyId', 'branchId', 'moduleId', 'version'},
      _ => const {'companyId', 'branchId', 'limit'},
    };
    final optionalKeys = operation == 'list'
        ? const {'afterModuleId', 'afterVersion'}
        : const <String>{};
    if (json.keys.any(
          (key) => !requiredKeys.contains(key) && !optionalKeys.contains(key),
        ) ||
        !requiredKeys.every(json.containsKey) ||
        (json.containsKey('afterModuleId') !=
            json.containsKey('afterVersion'))) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final companyId = _boundedIdentifier(json, 'companyId');
    final branchId = _boundedIdentifier(json, 'branchId');
    final requiredPermission = operation == 'submit'
        ? 'extension.package.submit'
        : 'extension.package.read';
    if (!session.principal.allowsInScope(
      requiredPermission,
      companyId,
      branchId,
    )) {
      throw const _ApiError(403, 'PERMISSION_DENIED');
    }
    final Map<String, dynamic> result;
    if (operation == 'submit') {
      final raw = json['package'];
      if (raw is! Map) throw const _ApiError(400, 'INVALID_REQUEST');
      final bundle = ExtensionBundle.fromJson(Map<String, dynamic>.from(raw));
      result = await gateway.submit(
        session: session,
        companyId: companyId,
        branchId: branchId,
        bundle: bundle,
      );
    } else if (operation == 'read') {
      final moduleId = _boundedIdentifier(json, 'moduleId');
      if (!RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$').hasMatch(moduleId) ||
          moduleId.length > 128) {
        throw const _ApiError(400, 'INVALID_REQUEST');
      }
      result = await gateway.readApproved(
        session: session,
        companyId: companyId,
        branchId: branchId,
        moduleId: moduleId,
        version: _boundedIdentifier(json, 'version'),
      );
    } else {
      final limit = json['limit'];
      if (limit is! int || limit < 1 || limit > 50) {
        throw const _ApiError(400, 'INVALID_REQUEST');
      }
      final afterModuleId = json['afterModuleId'];
      final afterVersion = json['afterVersion'];
      if ((afterModuleId != null && afterModuleId is! String) ||
          (afterVersion != null && afterVersion is! String)) {
        throw const _ApiError(400, 'INVALID_REQUEST');
      }
      result = await gateway.listApproved(
        session: session,
        companyId: companyId,
        branchId: branchId,
        limit: limit,
        afterModuleId: afterModuleId as String?,
        afterVersion: afterVersion as String?,
      );
    }
    final resultStatus = result['status'];
    final statusCode = switch (resultStatus) {
      'SUBMITTED' => 202,
      'APPROVED' => 200,
      'CONFLICT' => 409,
      'REJECTED' => switch (result['reasonCode']) {
        'PERMISSION_DENIED' => 403,
        'PACKAGE_NOT_APPROVED' || 'PACKAGE_UNAVAILABLE' => 404,
        'INVALID_PAGE' => 400,
        _ => 422,
      },
      _ => throw const _ApiError(503, 'HOST_INVALID_RESPONSE', retryable: true),
    };
    _json(request, statusCode, {'apiVersion': 1, 'packageResult': result});
  }

  Future<void> _handleIdentityRoleAdministration(
    HttpRequest request,
    String action,
    Map<String, dynamic> json,
    AuthenticatedSession session,
  ) async {
    final requiredKeys = switch (action) {
      'list' => const {'companyId', 'branchId'},
      'create' ||
      'rename' => const {'companyId', 'branchId', 'roleId', 'displayName'},
      'delete' => const {'companyId', 'branchId', 'roleId'},
      'grant-permission' || 'revoke-permission' => const {
        'companyId',
        'branchId',
        'roleId',
        'permission',
      },
      'assign' ||
      'unassign' => const {'companyId', 'branchId', 'roleId', 'actorId'},
      _ => throw const _ApiError(404, 'NOT_FOUND'),
    };
    if (json.keys.toSet().length != requiredKeys.length ||
        !json.keys.toSet().containsAll(requiredKeys)) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final companyId = _boundedIdentifier(json, 'companyId');
    final branchId = _boundedIdentifier(json, 'branchId');
    if (!session.principal.allowsInScope(
      identityRolesManagePermission,
      companyId,
      branchId,
    )) {
      throw const _ApiError(403, 'PERMISSION_DENIED');
    }
    final gateway = _identityRoleAdministration!;
    if (action == 'list') {
      final roles = await gateway.list(
        session: session,
        companyId: companyId,
        branchId: branchId,
      );
      if (utf8.encode(jsonEncode(roles)).length > 1024 * 1024) {
        throw const _ApiError(413, 'RESPONSE_TOO_LARGE');
      }
      _json(request, 200, {'apiVersion': 1, 'identityRoles': roles});
      return;
    }

    final roleId = _boundedIdentifier(json, 'roleId');
    if (!RegExp(r'^[a-z][a-z0-9_.-]*$').hasMatch(roleId)) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final change = <String, Object?>{
      'action': switch (action) {
        'create' => 'ROLE_CREATED',
        'rename' => 'ROLE_RENAMED',
        'delete' => 'ROLE_DELETED',
        'grant-permission' => 'ROLE_PERMISSION_GRANTED',
        'revoke-permission' => 'ROLE_PERMISSION_REVOKED',
        'assign' => 'ROLE_ASSIGNED',
        'unassign' => 'ROLE_UNASSIGNED',
        _ => throw const _ApiError(404, 'NOT_FOUND'),
      },
      'roleId': roleId,
    };
    if (action == 'create' || action == 'rename') {
      final displayName = requireString(json, 'displayName');
      if (displayName.trim().isEmpty || displayName.length > 120) {
        throw const _ApiError(400, 'INVALID_REQUEST');
      }
      change['displayName'] = displayName;
    } else if (action == 'grant-permission' || action == 'revoke-permission') {
      final permission = _boundedIdentifier(json, 'permission');
      if (!RegExp(r'^[a-z][a-z0-9_.]+$').hasMatch(permission)) {
        throw const _ApiError(400, 'INVALID_REQUEST');
      }
      change['permission'] = permission;
    } else if (action == 'assign' || action == 'unassign') {
      change
        ..['actorId'] = _boundedIdentifier(json, 'actorId')
        ..['companyId'] = companyId
        ..['branchId'] = branchId;
    }
    await gateway.change(
      session: session,
      companyId: companyId,
      branchId: branchId,
      change: change,
    );
    _json(request, 200, {
      'apiVersion': 1,
      'identityRoleResult': {'status': 'APPLIED'},
    });
  }

  Future<void> _handleReadiness(
    HttpRequest request,
    Map<String, dynamic> json,
    AuthenticatedSession session,
    String correlationId,
  ) async {
    const expectedKeys = {'managementApiVersion', 'companyId', 'branchId'};
    if (json.keys.toSet().length != expectedKeys.length ||
        !json.keys.toSet().containsAll(expectedKeys) ||
        json['managementApiVersion'] != managementApiVersion) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final companyId = _boundedIdentifier(json, 'companyId');
    final branchId = _boundedIdentifier(json, 'branchId');
    if (!session.principal.withinScope(
      tenantId: session.principal.tenantId,
      companyId: companyId,
      branchId: branchId,
      actorId: session.principal.actorId,
      deviceId: session.principal.deviceId,
    )) {
      throw const _ApiError(403, 'SCOPE_DENIED');
    }
    if (!session.principal.allowsInScope(
      hostStatusReadPermission,
      companyId,
      branchId,
    )) {
      throw const _ApiError(403, 'PERMISSION_DENIED');
    }
    final snapshot = await _readinessProvider!.checkReadiness();
    if (snapshot.overallState != ManagementHealthState.ready) {
      await _recordReadinessIssue(snapshot, correlationId);
    }
    _json(request, 200, {
      'apiVersion': 1,
      'managementApiVersion': managementApiVersion,
      'correlationId': correlationId,
      'readiness': snapshot.toJson(),
    });
  }

  void _handleDiagnostics(
    HttpRequest request,
    Map<String, dynamic> json,
    AuthenticatedSession session,
    String correlationId,
  ) {
    const expectedKeys = {
      'managementApiVersion',
      'companyId',
      'branchId',
      'limit',
    };
    if (json.keys.toSet().length != expectedKeys.length ||
        !json.keys.toSet().containsAll(expectedKeys) ||
        json['managementApiVersion'] != managementApiVersion) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final companyId = _boundedIdentifier(json, 'companyId');
    final branchId = _boundedIdentifier(json, 'branchId');
    final limit = json['limit'];
    if (limit is! int || limit < 1 || limit > 100) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    if (!session.principal.withinScope(
      tenantId: session.principal.tenantId,
      companyId: companyId,
      branchId: branchId,
      actorId: session.principal.actorId,
      deviceId: session.principal.deviceId,
    )) {
      throw const _ApiError(403, 'SCOPE_DENIED');
    }
    if (!session.principal.allowsInScope(
      hostDiagnosticsReadPermission,
      companyId,
      branchId,
    )) {
      throw const _ApiError(403, 'PERMISSION_DENIED');
    }
    final reader = _diagnostics as ManagementDiagnosticReader;
    _json(request, 200, {
      'apiVersion': 1,
      'managementApiVersion': managementApiVersion,
      'correlationId': correlationId,
      'events': reader
          .recent(limit: limit)
          .map((event) => event.toJson())
          .toList(),
    });
  }

  Future<void> _recordReadinessIssue(
    HostReadinessSnapshot snapshot,
    String correlationId,
  ) async {
    final firstIssue = snapshot.components.firstWhere(
      (component) => component.state != ManagementHealthState.ready,
    );
    await _recordDiagnostic(
      ManagementDiagnosticEvent(
        code: firstIssue.reasonCode ?? 'HOST_NOT_READY',
        component: firstIssue.component.wireValue,
        category: switch (firstIssue.component) {
          ManagementComponent.database => ManagementDiagnosticCategory.database,
          ManagementComponent.schema => ManagementDiagnosticCategory.schema,
          ManagementComponent.recoveryAuthority =>
            ManagementDiagnosticCategory.recovery,
          ManagementComponent.api => ManagementDiagnosticCategory.hostLifecycle,
        },
        severity: firstIssue.state == ManagementHealthState.blocked
            ? ManagementDiagnosticSeverity.critical
            : ManagementDiagnosticSeverity.error,
        occurredAtUtc: DateTime.now().toUtc(),
        correlationId: correlationId,
        retryable: false,
        messageKey: 'host_management.readiness.not_ready',
        safeExplanation: 'One or more Host services are not ready.',
        recommendedAction:
            'Review the readiness summary and contact a Host administrator.',
      ),
    );
  }

  Future<void> _recordInternalFailure(
    String correlationId, {
    String? protectedFailureType,
    String? protectedFailureSource,
  }) => _recordDiagnostic(
    ManagementDiagnosticEvent(
      code: 'HOST_UNAVAILABLE',
      component: 'host_api',
      category: ManagementDiagnosticCategory.apiExecution,
      severity: ManagementDiagnosticSeverity.error,
      occurredAtUtc: DateTime.now().toUtc(),
      correlationId: correlationId,
      retryable: true,
      messageKey: 'host_api.error.host_unavailable',
      safeExplanation: 'The Host could not complete this request.',
      recommendedAction:
          'Retry safely. For command submissions, reuse the same command ID. Share the correlation ID with a Host administrator if the problem continues.',
      protectedFailureType: protectedFailureType,
      protectedFailureSource: protectedFailureSource,
    ),
  );

  String? _protectedFailureSource(StackTrace stackTrace) {
    final frame = RegExp(
      r'^#\d+\s+(.+?)\s+\(',
    ).firstMatch(stackTrace.toString().split('\n').first);
    final symbol = frame?.group(1);
    if (symbol == null) return null;
    final safe = symbol.replaceAll(RegExp(r'[^A-Za-z0-9_.$<>]'), '_');
    return safe.length <= 120 ? safe : safe.substring(0, 120);
  }

  Future<void> _recordDiagnostic(ManagementDiagnosticEvent event) async {
    try {
      await _diagnostics.record(event);
    } catch (_) {
      // Diagnostic collection must never change the request outcome.
    }
  }

  String? _identityRoleAction(String path) => switch (path) {
    '/api/v1/identity/roles/list' => 'list',
    '/api/v1/identity/roles/create' => 'create',
    '/api/v1/identity/roles/rename' => 'rename',
    '/api/v1/identity/roles/delete' => 'delete',
    '/api/v1/identity/roles/grant-permission' => 'grant-permission',
    '/api/v1/identity/roles/revoke-permission' => 'revoke-permission',
    '/api/v1/identity/roles/assign' => 'assign',
    '/api/v1/identity/roles/unassign' => 'unassign',
    _ => null,
  };

  String? _identityUserAction(String path) => switch (path) {
    '/api/v1/management/users/list' => 'list',
    '/api/v1/management/users/audit' => 'audit',
    '/api/v1/management/users/create' => 'create',
    '/api/v1/management/users/grant' => 'grant',
    '/api/v1/management/users/revoke' => 'revoke',
    '/api/v1/management/users/disable' => 'disable',
    '/api/v1/management/users/enable' => 'enable',
    _ => null,
  };

  String? _identityDeviceAction(String path) => switch (path) {
    '${HostManagementRoutes.devices}/list' => 'list',
    '${HostManagementRoutes.devices}/revoke' => 'revoke',
    '${HostManagementRoutes.devices}/rotate-credential' => 'rotate',
    _ => null,
  };

  Future<void> _handleIdentityDeviceAdministration(
    HttpRequest request,
    String action,
    Map<String, dynamic> json,
    AuthenticatedSession session,
    String correlationId,
  ) async {
    final expectedKeys = action == 'list'
        ? const {'managementApiVersion', 'companyId', 'branchId'}
        : action == 'revoke'
        ? const {'managementApiVersion', 'companyId', 'branchId', 'deviceId'}
        : const {
            'managementApiVersion',
            'companyId',
            'branchId',
            'deviceId',
            'credentialId',
          };
    if (json.keys.toSet().length != expectedKeys.length ||
        !json.keys.toSet().containsAll(expectedKeys) ||
        json['managementApiVersion'] != managementApiVersion) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final companyId = _boundedIdentifier(json, 'companyId');
    final branchId = _boundedIdentifier(json, 'branchId');
    final principal = session.principal;
    if (!principal.withinScope(
      tenantId: principal.tenantId,
      companyId: companyId,
      branchId: branchId,
      actorId: principal.actorId,
      deviceId: principal.deviceId,
    )) {
      throw const _ApiError(403, 'SCOPE_DENIED');
    }
    if (!principal.allowsInScope(
      identityDevicesManagePermission,
      companyId,
      branchId,
    )) {
      throw const _ApiError(403, 'PERMISSION_DENIED');
    }

    final gateway = _identityDeviceAdministration!;
    if (action == 'list') {
      final devices = await gateway.list(
        session: session,
        companyId: companyId,
        branchId: branchId,
      );
      if (!_isSafeDeviceProjection(
        devices,
        tenantId: principal.tenantId,
        companyId: companyId,
        branchId: branchId,
      )) {
        throw const _ApiError(503, 'HOST_INVALID_RESPONSE', retryable: true);
      }
      if (utf8.encode(jsonEncode(devices)).length > 1024 * 1024) {
        throw const _ApiError(413, 'RESPONSE_TOO_LARGE');
      }
      _json(request, 200, {
        'apiVersion': 1,
        'managementApiVersion': managementApiVersion,
        'correlationId': correlationId,
        'devices': devices,
      });
      return;
    }

    if (action == 'rotate') {
      final deviceId = _boundedIdentifier(json, 'deviceId');
      final credentialId = _boundedIdentifier(json, 'credentialId');
      if (!_isSafeDeviceManagementDeviceId(deviceId) ||
          !_isSafeDeviceManagementCredentialId(credentialId)) {
        throw const _ApiError(400, 'INVALID_REQUEST');
      }
      final replacement = await _identityDeviceAdministration.rotateCredential(
        session: session,
        companyId: companyId,
        branchId: branchId,
        deviceId: deviceId,
        credentialId: credentialId,
      );
      if (!_isSafeDeviceCredentialRotation(
        replacement,
        tenantId: principal.tenantId,
        companyId: companyId,
        branchId: branchId,
        deviceId: deviceId,
      )) {
        throw const _ApiError(503, 'HOST_INVALID_RESPONSE', retryable: true);
      }
      _json(request, 200, {
        'apiVersion': 1,
        'managementApiVersion': managementApiVersion,
        'correlationId': correlationId,
        'deviceCredential': replacement,
      });
      return;
    }

    final deviceId = _boundedIdentifier(json, 'deviceId');
    if (!_isSafeDeviceManagementDeviceId(deviceId)) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    await gateway.revoke(
      session: session,
      companyId: companyId,
      branchId: branchId,
      deviceId: deviceId,
    );
    _json(request, 200, {
      'apiVersion': 1,
      'managementApiVersion': managementApiVersion,
      'correlationId': correlationId,
      'deviceOperation': {'status': 'APPLIED', 'deviceId': deviceId},
    });
  }

  Future<void> _handleIdentityUserAdministration(
    HttpRequest request,
    String action,
    Map<String, dynamic> json,
    AuthenticatedSession session,
    String correlationId,
  ) async {
    final expectedKeys = switch (action) {
      'list' ||
      'audit' => const {'managementApiVersion', 'companyId', 'branchId'},
      'create' => const {'managementApiVersion', 'companyId', 'branchId'},
      'disable' || 'enable' => const {
        'managementApiVersion',
        'companyId',
        'branchId',
        'actorId',
      },
      'grant' || 'revoke' => const {
        'managementApiVersion',
        'companyId',
        'branchId',
        'actorId',
        'permission',
      },
      _ => throw const _ApiError(404, 'NOT_FOUND'),
    };
    if (json.keys.toSet().length != expectedKeys.length ||
        !json.keys.toSet().containsAll(expectedKeys) ||
        json['managementApiVersion'] != managementApiVersion) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }

    final companyId = _boundedIdentifier(json, 'companyId');
    final branchId = _boundedIdentifier(json, 'branchId');
    final principal = session.principal;
    if (!principal.withinScope(
      tenantId: principal.tenantId,
      companyId: companyId,
      branchId: branchId,
      actorId: principal.actorId,
      deviceId: principal.deviceId,
    )) {
      throw const _ApiError(403, 'SCOPE_DENIED');
    }
    if (!principal.allowsInScope(
      identityUsersManagePermission,
      companyId,
      branchId,
    )) {
      throw const _ApiError(403, 'PERMISSION_DENIED');
    }

    final gateway = _identityUserAdministration!;
    if (action == 'audit') {
      final audit = await gateway.audit(
        session: session,
        companyId: companyId,
        branchId: branchId,
      );
      if (!_isSafeAuditProjection(
        audit,
        tenantId: principal.tenantId,
        companyId: companyId,
        branchId: branchId,
      )) {
        throw const _ApiError(503, 'HOST_INVALID_RESPONSE', retryable: true);
      }
      if (utf8.encode(jsonEncode(audit)).length > 128 * 1024) {
        throw const _ApiError(413, 'RESPONSE_TOO_LARGE');
      }
      _json(request, 200, {
        'apiVersion': 1,
        'managementApiVersion': managementApiVersion,
        'correlationId': correlationId,
        'audit': audit,
      });
      return;
    }

    if (action == 'list') {
      final users = await gateway.list(
        session: session,
        companyId: companyId,
        branchId: branchId,
      );
      if (users['tenantId'] != principal.tenantId ||
          users['companyId'] != companyId ||
          users['branchId'] != branchId ||
          users['items'] is! List) {
        throw const _ApiError(503, 'HOST_INVALID_RESPONSE', retryable: true);
      }
      if (utf8.encode(jsonEncode(users)).length > 1024 * 1024) {
        throw const _ApiError(413, 'RESPONSE_TOO_LARGE');
      }
      _json(request, 200, {
        'apiVersion': 1,
        'managementApiVersion': managementApiVersion,
        'correlationId': correlationId,
        'users': users,
      });
      return;
    }

    final change = <String, Object?>{
      'action': switch (action) {
        'create' => 'USER_CREATED',
        'grant' => 'PERMISSION_GRANTED',
        'revoke' => 'PERMISSION_REVOKED',
        'disable' => 'USER_DISABLED',
        'enable' => 'USER_ENABLED',
        _ => throw const _ApiError(404, 'NOT_FOUND'),
      },
    };
    if (action != 'create') {
      change['actorId'] = _boundedIdentifier(json, 'actorId');
    }
    if (action == 'grant' || action == 'revoke') {
      final permission = _boundedIdentifier(json, 'permission');
      if (!RegExp(r'^[a-z][a-z0-9_.]+$').hasMatch(permission)) {
        throw const _ApiError(400, 'INVALID_REQUEST');
      }
      if (RegExp(
        r'^(identity|host|system|security|recovery|authorization)\.',
      ).hasMatch(permission)) {
        throw const _ApiError(422, 'RESERVED_PERMISSION');
      }
      change['permission'] = permission;
    }
    final createdActorId = await gateway.change(
      session: session,
      companyId: companyId,
      branchId: branchId,
      change: change,
    );
    if ((action == 'create' &&
            (createdActorId == null ||
                !RegExp(r'^usr_[0-9a-f]{32}$').hasMatch(createdActorId))) ||
        (action != 'create' && createdActorId != null)) {
      throw const _ApiError(503, 'HOST_INVALID_RESPONSE', retryable: true);
    }
    _json(request, 200, {
      'apiVersion': 1,
      'managementApiVersion': managementApiVersion,
      'correlationId': correlationId,
      'userOperation': {
        'status': 'APPLIED',
        if (createdActorId != null) 'actorId': createdActorId,
      },
    });
  }

  Future<void> _handleExtensionRecordQuery(
    HttpRequest request,
    Map<String, dynamic> json,
    AuthenticatedSession session,
  ) async {
    const allowedKeys = {
      'companyId',
      'branchId',
      'moduleId',
      'version',
      'docType',
      'recordId',
      'search',
      'filters',
      'filterField',
      'filterContains',
      'sortField',
      'descending',
      'offset',
      'limit',
      'cursor',
    };
    const requiredKeys = {
      'companyId',
      'branchId',
      'moduleId',
      'version',
      'docType',
      'search',
      'filters',
      'filterField',
      'filterContains',
      'sortField',
      'descending',
      'offset',
      'limit',
    };
    if (json.keys.any((key) => !allowedKeys.contains(key)) ||
        !json.keys.toSet().containsAll(requiredKeys)) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final companyId = _boundedIdentifier(json, 'companyId');
    final branchId = _boundedIdentifier(json, 'branchId');
    final moduleId = _boundedIdentifier(json, 'moduleId');
    final version = _boundedIdentifier(json, 'version');
    final docType = _boundedIdentifier(json, 'docType');
    final recordIdValue = json['recordId'];
    if (recordIdValue != null &&
        (recordIdValue is! String ||
            recordIdValue.isEmpty ||
            recordIdValue.length > 128)) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    if (!RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$').hasMatch(moduleId) ||
        moduleId.length > 128 ||
        !RegExp(r'^[A-Z][A-Za-z0-9_]*$').hasMatch(docType) ||
        docType.length > 80) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    try {
      semverParts(version);
    } on ContractError {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final search = requireString(json, 'search', nonEmpty: false);
    if (search.length > 256) throw const _ApiError(400, 'INVALID_REQUEST');
    final rawFilters = requireMap(json['filters'], 'filters');
    if (rawFilters.length > 10 ||
        rawFilters.entries.any(
          (entry) =>
              entry.key.length > 80 ||
              entry.value is Map ||
              entry.value is List ||
              (entry.value is String && (entry.value as String).length > 256),
        )) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final filterFieldValue = json['filterField'];
    final filterContains = requireString(
      json,
      'filterContains',
      nonEmpty: false,
    );
    if ((filterFieldValue != null &&
            (filterFieldValue is! String ||
                filterFieldValue.isEmpty ||
                filterFieldValue.length > 80)) ||
        filterContains.length > 256 ||
        (filterFieldValue == null && filterContains.isNotEmpty)) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final sortFieldValue = json['sortField'];
    if (sortFieldValue != null &&
        (sortFieldValue is! String ||
            sortFieldValue.isEmpty ||
            sortFieldValue.length > 80)) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final descending = json['descending'];
    if (descending is! bool) throw const _ApiError(400, 'INVALID_REQUEST');
    final offset = requireInt(json, 'offset');
    final limit = requireInt(json, 'limit', min: 1);
    final cursorValue = json['cursor'];
    if (offset > 1000000 ||
        limit > 50 ||
        (cursorValue != null &&
            (cursorValue is! String ||
                cursorValue.isEmpty ||
                cursorValue.length > 1024 * 1024 ||
                offset != 0 ||
                recordIdValue != null))) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    if (recordIdValue != null &&
        (offset != 0 ||
            limit != 1 ||
            search.isNotEmpty ||
            rawFilters.isNotEmpty ||
            filterFieldValue != null ||
            filterContains.isNotEmpty)) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final principal = session.principal;
    if (!principal.withinScope(
      tenantId: principal.tenantId,
      companyId: companyId,
      branchId: branchId,
      actorId: principal.actorId,
      deviceId: principal.deviceId,
    )) {
      throw const _ApiError(403, 'SCOPE_DENIED');
    }
    final result = await _extensionRecordQueries!.query(
      session: session,
      companyId: companyId,
      branchId: branchId,
      moduleId: moduleId,
      version: version,
      docType: docType,
      recordId: recordIdValue as String?,
      search: search,
      filters: rawFilters,
      filterField: filterFieldValue as String?,
      filterContains: filterContains,
      sortField: sortFieldValue as String?,
      descending: descending,
      cursor: cursorValue as String?,
      offset: offset,
      limit: limit,
    );
    final statusCode = switch (result['status']) {
      'RECORDS' => 200,
      'REJECTED' => switch (result['reasonCode']) {
        'SCOPE_DENIED' || 'PERMISSION_DENIED' => 403,
        'EXTENSION_NOT_APPROVED' => 404,
        'RECORD_PAGE_TOO_LARGE' => 413,
        _ => 422,
      },
      _ => throw const _ApiError(503, 'HOST_INVALID_RESPONSE', retryable: true),
    };
    if (utf8.encode(jsonEncode(result)).length > 4 * 1024 * 1024) {
      throw const _ApiError(413, 'RESPONSE_TOO_LARGE');
    }
    _json(request, statusCode, {'apiVersion': 1, 'recordResult': result});
  }

  String _boundedIdentifier(Map<String, dynamic> json, String key) {
    final value = requireString(json, key);
    if (value.trim().isEmpty || value.length > 256) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    return value;
  }

  Future<void> _error(
    HttpRequest request,
    int status,
    String code, {
    required String correlationId,
    bool retryable = false,
    int? retryAfterSeconds,
  }) async {
    try {
      if (status == 401)
        request.response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Bearer',
        );
      if (retryable) {
        request.response.headers.set(
          HttpHeaders.retryAfterHeader,
          (retryAfterSeconds ?? 1).clamp(1, 86400).toString(),
        );
      }
      _json(request, status, {
        'apiVersion': 1,
        'correlationId': correlationId,
        'error': {
          'code': code,
          'messageKey': 'host_api.error.${code.toLowerCase()}',
          'message': switch (code) {
            'UNAUTHENTICATED' => 'Valid credentials are required.',
            'SCOPE_DENIED' => 'The requested identity or scope is not allowed.',
            'PERMISSION_DENIED' => 'The requested operation is not permitted.',
            'PERSISTENT_IDENTITY_REQUIRED' =>
              'A persistent Host identity is required.',
            'HOST_UNAVAILABLE' =>
              'Outcome may be unknown. Retry the identical command.',
            'PAIRING_INVALID_OR_EXPIRED' =>
              'The pairing code is invalid, expired, or already used.',
            'PAIRING_RATE_LIMITED' =>
              'Too many pairing attempts were made. Wait and try again.',
            'DEVICE_ALREADY_REGISTERED' =>
              'This device identity is already registered.',
            'PAIRING_TARGET_UNAVAILABLE' =>
              'The selected user is unavailable in this branch.',
            _ => 'The request could not be processed.',
          },
          'retryable': retryable,
        },
      });
    } catch (_) {
      /* Peer disconnected before error delivery. */
    }
  }

  Future<void> _handleExtensionReportQuery(
    HttpRequest request,
    Map<String, dynamic> json,
    AuthenticatedSession session,
  ) async {
    const keys = {
      'companyId',
      'branchId',
      'moduleId',
      'version',
      'docType',
      'reportId',
      'filters',
    };
    if (json.keys.any((key) => !keys.contains(key)) ||
        json.keys.length != keys.length) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final companyId = _boundedIdentifier(json, 'companyId');
    final branchId = _boundedIdentifier(json, 'branchId');
    final moduleId = _boundedIdentifier(json, 'moduleId');
    final version = _boundedIdentifier(json, 'version');
    final docType = _boundedIdentifier(json, 'docType');
    final reportId = _boundedIdentifier(json, 'reportId');
    if (!RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$').hasMatch(moduleId) ||
        moduleId.length > 128 ||
        !RegExp(r'^[A-Z][A-Za-z0-9_]*$').hasMatch(docType) ||
        docType.length > 80 ||
        !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(reportId)) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    try {
      semverParts(version);
    } on ContractError {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final rawFilters = requireMap(json['filters'], 'filters');
    if (rawFilters.length > 10 ||
        rawFilters.entries.any((entry) {
          final value = entry.value;
          return entry.key.length > 80 ||
              value is Map ||
              value is List ||
              value == null ||
              (value is String && value.length > 256) ||
              (value is num && !value.isFinite);
        })) {
      throw const _ApiError(400, 'INVALID_REQUEST');
    }
    final principal = session.principal;
    if (!principal.withinScope(
      tenantId: principal.tenantId,
      companyId: companyId,
      branchId: branchId,
      actorId: principal.actorId,
      deviceId: principal.deviceId,
    )) {
      throw const _ApiError(403, 'SCOPE_DENIED');
    }
    final gateway = _extensionReportQueries;
    if (gateway == null) {
      throw const _ApiError(503, 'REPORT_SERVICE_UNAVAILABLE', retryable: true);
    }
    final result = await gateway.queryReport(
      session: session,
      companyId: companyId,
      branchId: branchId,
      moduleId: moduleId,
      version: version,
      docType: docType,
      reportId: reportId,
      filters: rawFilters,
    );
    final statusCode = switch (result['status']) {
      'REPORT' => 200,
      'REJECTED' => switch (result['reasonCode']) {
        'SCOPE_DENIED' || 'PERMISSION_DENIED' => 403,
        'EXTENSION_NOT_APPROVED' || 'REPORT_NOT_FOUND' => 404,
        'REPORT_TOO_LARGE' => 413,
        _ => 422,
      },
      _ => throw const _ApiError(503, 'HOST_INVALID_RESPONSE', retryable: true),
    };
    if (utf8.encode(jsonEncode(result)).length > 256 * 1024) {
      throw const _ApiError(413, 'RESPONSE_TOO_LARGE');
    }
    _json(request, statusCode, {'apiVersion': 1, 'reportResult': result});
  }

  void _json(HttpRequest request, int status, Map<String, dynamic> body) {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    final bytes = utf8.encode(jsonEncode(body));
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
  }
}

const _safeAuditActions = <String>{
  'USER_CREATED',
  'USER_DISABLED',
  'USER_ENABLED',
  'PERMISSION_GRANTED',
  'PERMISSION_REVOKED',
  'ROLE_CREATED',
  'ROLE_RENAMED',
  'ROLE_DELETED',
  'ROLE_PERMISSION_GRANTED',
  'ROLE_PERMISSION_REVOKED',
  'ROLE_ASSIGNED',
  'ROLE_UNASSIGNED',
};

bool _isSafeAuditProjection(
  Map<String, dynamic> audit, {
  required String tenantId,
  required String companyId,
  required String branchId,
}) {
  if (audit.keys.toSet().length != 4 ||
      !audit.keys.toSet().containsAll(const {
        'tenantId',
        'companyId',
        'branchId',
        'events',
      }) ||
      audit['tenantId'] != tenantId ||
      audit['companyId'] != companyId ||
      audit['branchId'] != branchId ||
      audit['events'] is! List ||
      (audit['events'] as List).length > 100) {
    return false;
  }
  final expectedEventKeys = const {
    'eventId',
    'occurredAtUtc',
    'action',
    'subjectId',
    'operator',
  };
  for (final rawEvent in audit['events'] as List) {
    if (rawEvent is! Map || rawEvent.keys.any((key) => key is! String)) {
      return false;
    }
    final event = Map<String, dynamic>.from(rawEvent);
    if (event.keys.toSet().length != expectedEventKeys.length ||
        !event.keys.toSet().containsAll(expectedEventKeys) ||
        event['eventId'] is! String ||
        !RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(event['eventId'] as String) ||
        event['occurredAtUtc'] is! String ||
        !_isUtcTimestamp(event['occurredAtUtc'] as String) ||
        event['action'] is! String ||
        !_safeAuditActions.contains(event['action']) ||
        !_isSafeAuditLabel(event['subjectId']) ||
        !_isSafeAuditLabel(event['operator'])) {
      return false;
    }
  }
  return true;
}

bool _isTypedOpaqueManagementId(Object? value, String prefix) =>
    value is String &&
    value.startsWith(prefix) &&
    RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value.substring(prefix.length));

bool _isSafeLegacyDeviceManagementId(Object? value) =>
    value is String &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$').hasMatch(value) &&
    !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(value) &&
    !RegExp(
      r'(bearer|password|token|secret|postgres(?:ql)?|credential)',
      caseSensitive: false,
    ).hasMatch(value);

bool _isSafeDeviceManagementDeviceId(Object? value) =>
    _isTypedOpaqueManagementId(value, 'dev_') ||
    _isSafeLegacyDeviceManagementId(value);

bool _isSafeDeviceManagementActorId(Object? value) =>
    _isTypedOpaqueManagementId(value, 'usr_') ||
    _isSafeLegacyDeviceManagementId(value);

bool _isSafeDeviceManagementCredentialId(Object? value) =>
    _isTypedOpaqueManagementId(value, 'cred_') ||
    (value is String &&
        RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$').hasMatch(value) &&
        !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(value));

bool _isSafeDeviceProjection(
  Map<String, dynamic> devices, {
  required String tenantId,
  required String companyId,
  required String branchId,
}) {
  const snapshotKeys = {'tenantId', 'companyId', 'branchId', 'items'};
  if (devices.keys.toSet().length != snapshotKeys.length ||
      !devices.keys.toSet().containsAll(snapshotKeys) ||
      devices['tenantId'] != tenantId ||
      devices['companyId'] != companyId ||
      devices['branchId'] != branchId ||
      devices['items'] is! List ||
      (devices['items'] as List).length > 1000) {
    return false;
  }
  bool utc(Object? value, {bool nullable = false}) {
    if (value == null) return nullable;
    return value is String && _isUtcTimestamp(value);
  }

  for (final rawItem in devices['items'] as List) {
    if (rawItem is! Map || rawItem.keys.any((key) => key is! String)) {
      return false;
    }
    final item = Map<String, dynamic>.from(rawItem);
    const itemKeys = {
      'deviceId',
      'actorId',
      'role',
      'registrationState',
      'registeredAtUtc',
      'lastAuthenticatedAtUtc',
      'credentials',
    };
    if (item.keys.toSet().length != itemKeys.length ||
        !item.keys.toSet().containsAll(itemKeys) ||
        !_isSafeDeviceManagementDeviceId(item['deviceId']) ||
        !_isSafeDeviceManagementActorId(item['actorId']) ||
        !const {'HOST', 'CLIENT', 'UNKNOWN'}.contains(item['role']) ||
        !const {'REGISTERED', 'REVOKED'}.contains(item['registrationState']) ||
        !utc(item['registeredAtUtc']) ||
        !utc(item['lastAuthenticatedAtUtc'], nullable: true) ||
        item['credentials'] is! List ||
        (item['credentials'] as List).length > 100) {
      return false;
    }
    for (final rawCredential in item['credentials'] as List) {
      if (rawCredential is! Map ||
          rawCredential.keys.any((key) => key is! String)) {
        return false;
      }
      final credential = Map<String, dynamic>.from(rawCredential);
      const credentialKeys = {
        'credentialId',
        'state',
        'expiresAtUtc',
        'revokedAtUtc',
      };
      if (credential.keys.toSet().length != credentialKeys.length ||
          !credential.keys.toSet().containsAll(credentialKeys) ||
          !_isSafeDeviceManagementCredentialId(credential['credentialId']) ||
          !const {
            'ACTIVE',
            'EXPIRED',
            'REVOKED',
            'ROTATED',
            'UNKNOWN',
          }.contains(credential['state']) ||
          !utc(credential['expiresAtUtc']) ||
          !utc(credential['revokedAtUtc'], nullable: true)) {
        return false;
      }
    }
  }
  return true;
}

bool _isSafeDeviceCredentialRotation(
  Map<String, dynamic> credential, {
  required String tenantId,
  required String companyId,
  required String branchId,
  required String deviceId,
}) {
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
  final rawActorId = credential['actorId'];
  final rawCredentialId = credential['credentialId'];
  final expiresAt = credential['expiresAtUtc'];
  final bearer = credential['credential'];
  return credential.keys.toSet().length == keys.length &&
      credential.keys.toSet().containsAll(keys) &&
      credential['tenantId'] == tenantId &&
      _isSafeDeviceManagementActorId(rawActorId) &&
      credential['deviceId'] == deviceId &&
      _isSafeDeviceManagementCredentialId(rawCredentialId) &&
      credential['companyId'] == companyId &&
      credential['branchId'] == branchId &&
      expiresAt is String &&
      _isUtcTimestamp(expiresAt) &&
      bearer is String &&
      RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(bearer);
}

bool _isUtcTimestamp(String value) {
  final parsed = DateTime.tryParse(value);
  return parsed != null && parsed.isUtc;
}

bool _isSafeAuditLabel(Object? raw) {
  if (raw is! String) return false;
  if (raw == '[redacted]' || raw == 'Host administrator') return true;
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(raw) ||
      RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(raw) ||
      RegExp(
        r'(bearer|password|token|secret|postgres(?:ql)?|credential)',
        caseSensitive: false,
      ).hasMatch(raw)) {
    return false;
  }
  return true;
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
  final int? retryAfterSeconds;
  const _ApiError(
    this.status,
    this.code, {
    this.retryable = false,
    this.retryAfterSeconds,
  });
}

class _PairingRedeemRateLimiter {
  static const _window = Duration(minutes: 1);
  static const _maxAttempts = 10;
  static const _maxAddresses = 2048;
  final Map<String, _PairingAttemptWindow> _attempts = {};

  bool allow(String address) {
    final now = DateTime.now().toUtc();
    var window = _attempts[address];
    if (window == null) {
      if (_attempts.length >= _maxAddresses) {
        _attempts.removeWhere(
          (_, value) => now.difference(value.startedAt) >= _window,
        );
      }
      if (_attempts.length >= _maxAddresses) return false;
      window = _PairingAttemptWindow(now);
      _attempts[address] = window;
    } else if (now.difference(window.startedAt) >= _window) {
      window
        ..startedAt = now
        ..count = 0;
    }
    if (window.count >= _maxAttempts) return false;
    window.count++;
    return true;
  }
}

class _PairingAttemptWindow {
  _PairingAttemptWindow(this.startedAt);
  DateTime startedAt;
  int count = 0;
}

String _newCorrelationId() {
  final random = math.Random.secure();
  final hex = List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return 'cor_$hex';
}
