import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ventio_core/ventio_core.dart';

import 'host_credentials.dart';
import 'host_extension_packages.dart' show HostSessionIdentity;

const int hostUserManagementApiVersion = 1;
const String manageHostUsersPermission = 'identity.users.manage';

/// User state returned for one exact Host company/branch scope.
enum HostManagedUserState { active, disabled }

class HostManagedUser {
  HostManagedUser({
    required this.actorId,
    required this.state,
    required Iterable<String> directPermissions,
    Iterable<String> roles = const [],
  }) : directPermissions = Set.unmodifiable(directPermissions),
       roles = List.unmodifiable(roles);

  final String actorId;
  /// New Host-generated IDs are opaque and safe to display. Older operator
  /// supplied identifiers may contain private data, so expose only a generic
  /// label here; the page adds a temporary per-session discriminator.
  String get displayName => RegExp(r'^usr_[0-9a-f]{32}$').hasMatch(actorId)
      ? actorId
      : 'Legacy identity';
  final HostManagedUserState state;
  final Set<String> directPermissions;
  final List<String> roles;
}

class HostManagedUserSnapshot {
  HostManagedUserSnapshot({
    required this.tenantId,
    required this.companyId,
    required this.branchId,
    required Iterable<HostManagedUser> users,
  }) : users = List.unmodifiable(users);

  final String tenantId;
  final String companyId;
  final String branchId;
  final List<HostManagedUser> users;
}

/// Allowlisted audit projection. Technical details, request bodies and
/// credential material are intentionally absent from this model.
class HostUserAuditEvent {
  HostUserAuditEvent({
    required this.eventId,
    required DateTime occurredAtUtc,
    required this.action,
    required this.subjectId,
    required this.operatorId,
  }) : occurredAtUtc = occurredAtUtc.toUtc() {
    if (!_validAuditIdentifier(eventId) ||
        !_validAuditIdentifier(subjectId) ||
        !_validAuditIdentifier(operatorId) ||
        !RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(action)) {
      throw ArgumentError('Invalid safe audit event.');
    }
  }

  final String eventId;
  final DateTime occurredAtUtc;
  final String action;
  final String subjectId;
  final String operatorId;
}

class HostUserAuditSnapshot {
  HostUserAuditSnapshot({
    required this.tenantId,
    required this.companyId,
    required this.branchId,
    required Iterable<HostUserAuditEvent> events,
  }) : events = List.unmodifiable(events);

  final String tenantId;
  final String companyId;
  final String branchId;
  final List<HostUserAuditEvent> events;
}

/// Safe transport failure. Server supplied prose and technical exception
/// details are deliberately omitted; callers can show a localized message and
/// the Host correlation ID when one was returned.
class HostUserManagementException implements Exception {
  const HostUserManagementException(
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
      'Host user management error: $code${correlationId == null ? '' : ' [$correlationId]'}';
}

typedef HostUserManagementExchange =
    Future<HostUserManagementHttpResponse> Function({
      required Uri uri,
      required Map<String, String> headers,
      required String body,
      required Duration timeout,
      required int maxResponseBytes,
    });

/// Narrow HTTP exchange seam used by deterministic tests and platform adapters.
class HostUserManagementHttpResponse {
  const HostUserManagementHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final Map<String, dynamic> body;
  final Map<String, String> headers;
}

/// Authenticated management API scoped to one caller-verified session grant.
///
/// [verifiedIdentity] must be the result of a fresh authenticated
/// `/api/v1/session` request. This local check only controls the UI/client; the
/// Host must independently authorize every request and revalidate the grant.
/// Device role is not represented by this identity and is never used here.
class HostUserManagementClient {
  HostUserManagementClient({
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
    _validateIdentifier(companyId, 'companyId');
    _validateIdentifier(branchId, 'branchId');
    if (timeout <= Duration.zero || maxResponseBytes < 1) {
      throw ArgumentError(
        'Host user-management transport limits must be positive.',
      );
    }
  }

  final Uri endpoint;
  final HostCredentialVault credentials;
  final HostSessionIdentity verifiedIdentity;
  final String companyId;
  final String branchId;
  final HttpClient Function() _clientFactory;
  final HostUserManagementExchange? exchange;
  final Duration timeout;
  final int maxResponseBytes;

  bool get canManageUsers =>
      verifiedIdentity.persistent &&
      verifiedIdentity.tenantId.trim().isNotEmpty &&
      verifiedIdentity.scopes.any(
        (scope) =>
            scope.companyId == companyId &&
            scope.branchId == branchId &&
            scope.permissions.contains(manageHostUsersPermission),
      );

  Future<HostManagedUserSnapshot> listUsers() async {
    final response = await _post('list', const {});
    if (response.statusCode != HttpStatus.ok) {
      throw _error(response);
    }
    final raw = response.body['users'];
    if (raw is! Map) throw _invalidResponse(response);
    final result = Map<String, dynamic>.from(raw);
    const allowed = {'tenantId', 'companyId', 'branchId', 'items'};
    if (result.keys.any((key) => !allowed.contains(key)) ||
        result.length != allowed.length ||
        result['items'] is! List) {
      throw _invalidResponse(response);
    }
    String identifier(Object? value) {
      if (value is! String || value.trim().isEmpty || value.length > 256) {
        throw _invalidResponse(response);
      }
      return value;
    }

    final tenantId = identifier(result['tenantId']);
    final responseCompanyId = identifier(result['companyId']);
    final responseBranchId = identifier(result['branchId']);
    if (tenantId != verifiedIdentity.tenantId ||
        responseCompanyId != companyId ||
        responseBranchId != branchId) {
      throw _invalidResponse(response);
    }
    final rawUsers = result['items'] as List;
    if (rawUsers.length > 5000) throw _invalidResponse(response);
    final users = rawUsers
        .map((rawUser) {
          if (rawUser is! Map) throw _invalidResponse(response);
          final user = Map<String, dynamic>.from(rawUser);
          const keys = {'actorId', 'state', 'directPermissions', 'roles'};
          // `roles` is optional for Hosts that do not expose role assignment
          // projections in the users endpoint yet.
          if (user.keys.any((key) => !keys.contains(key)) ||
              user.length < 4 ||
              user.length > 5 ||
              !user.keys.toSet().containsAll(keys.difference({'roles'})) ||
              (user.containsKey('roles') && user['roles'] is! List) ||
              user['directPermissions'] is! List ||
              (user['directPermissions'] as List).any(
                (value) => value is! String,
              )) {
            throw _invalidResponse(response);
          }
          final actorId = identifier(user['actorId']);
          final rawState = user['state'];
          final rawPermissions = (user['directPermissions'] as List)
              .cast<String>();
          final rawRoles = ((user['roles'] as List?) ?? const [])
              .cast<Object?>();
          if (rawPermissions.length > 500 ||
              rawPermissions.toSet().length != rawPermissions.length ||
              rawRoles.length > 100 ||
              rawRoles.any((value) => value is! String) ||
              rawRoles.toSet().length != rawRoles.length) {
            throw _invalidResponse(response);
          }
          final state = switch (rawState) {
            'ACTIVE' => HostManagedUserState.active,
            'DISABLED' => HostManagedUserState.disabled,
            _ => throw _invalidResponse(response),
          };
          for (final permission in rawPermissions) {
            if (!_validPermissionSyntax(permission)) {
              throw _invalidResponse(response);
            }
          }
          for (final role in rawRoles.cast<String>()) {
            if (role.trim().isEmpty || role.length > 128) {
              throw _invalidResponse(response);
            }
          }
          return HostManagedUser(
            actorId: actorId,
            state: state,
            directPermissions: rawPermissions,
            roles: rawRoles.cast<String>(),
          );
        })
        .toList(growable: false);
    if (users.map((user) => user.actorId).toSet().length != users.length) {
      throw _invalidResponse(response);
    }
    return HostManagedUserSnapshot(
      tenantId: tenantId,
      companyId: responseCompanyId,
      branchId: responseBranchId,
      users: users,
    );
  }

  Future<HostUserAuditSnapshot> listAudit() async {
    final response = await _post('audit', const {'limit': 100});
    if (response.statusCode != HttpStatus.ok) throw _error(response);
    const envelopeKeys = {
      'apiVersion',
      'managementApiVersion',
      'correlationId',
      'audit',
    };
    if (response.body.length != envelopeKeys.length ||
        response.body.keys.any((key) => !envelopeKeys.contains(key))) {
      throw _invalidResponse(response);
    }
    final rawAudit = response.body['audit'];
    if (rawAudit is! Map) throw _invalidResponse(response);
    final audit = Map<String, dynamic>.from(rawAudit);
    const auditKeys = {'tenantId', 'companyId', 'branchId', 'events'};
    if (audit.length != auditKeys.length ||
        audit.keys.any((key) => !auditKeys.contains(key)) ||
        audit['events'] is! List) {
      throw _invalidResponse(response);
    }
    String scopeIdentifier(Object? value) {
      if (value is! String || value.trim().isEmpty || value.length > 256) {
        throw _invalidResponse(response);
      }
      return value;
    }

    final tenantId = scopeIdentifier(audit['tenantId']);
    final responseCompanyId = scopeIdentifier(audit['companyId']);
    final responseBranchId = scopeIdentifier(audit['branchId']);
    if (tenantId != verifiedIdentity.tenantId ||
        responseCompanyId != companyId ||
        responseBranchId != branchId) {
      throw _invalidResponse(response);
    }
    final rawEvents = audit['events'] as List;
    if (rawEvents.length > 100) throw _invalidResponse(response);
    final events = rawEvents
        .map((rawEvent) {
          if (rawEvent is! Map) throw _invalidResponse(response);
          final event = Map<String, dynamic>.from(rawEvent);
          const eventKeys = {
            'eventId',
            'occurredAtUtc',
            'action',
            'subjectId',
            'operator',
          };
          if (event.length != eventKeys.length ||
              event.keys.any((key) => !eventKeys.contains(key))) {
            throw _invalidResponse(response);
          }
          String auditIdentifier(Object? value) {
            if (value is! String || !_validAuditIdentifier(value)) {
              throw _invalidResponse(response);
            }
            return value;
          }

          final eventId = auditIdentifier(event['eventId']);
          final subjectId = auditIdentifier(event['subjectId']);
          final operatorId = auditIdentifier(event['operator']);
          final action = event['action'];
          final timestamp = event['occurredAtUtc'];
          final occurredAtUtc = timestamp is String && timestamp.endsWith('Z')
              ? DateTime.tryParse(timestamp)
              : null;
          if (action is! String ||
              !RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(action) ||
              occurredAtUtc == null ||
              !occurredAtUtc.isUtc) {
            throw _invalidResponse(response);
          }
          return HostUserAuditEvent(
            eventId: eventId,
            occurredAtUtc: occurredAtUtc,
            action: action,
            subjectId: subjectId,
            operatorId: operatorId,
          );
        })
        .toList(growable: false);
    if (events.map((event) => event.eventId).toSet().length != events.length) {
      throw _invalidResponse(response);
    }
    return HostUserAuditSnapshot(
      tenantId: tenantId,
      companyId: responseCompanyId,
      branchId: responseBranchId,
      events: events,
    );
  }

  /// Creates a Host-generated user ID without permissions or role assignments.
  Future<String> createUser() async => (await _mutate('create', const {}))!;

  Future<void> grantPermission({
    required String actorId,
    required String permission,
  }) async {
    _validateIdentifier(actorId, 'actorId');
    if (!isGrantableNonManagementPermission(permission)) {
      throw const HostUserManagementException('PERMISSION_NOT_GRANTABLE');
    }
    await _mutate('grant', {
      'actorId': actorId.trim(),
      'permission': permission,
    });
  }

  Future<void> revokePermission({
    required String actorId,
    required String permission,
  }) async {
    _validateIdentifier(actorId, 'actorId');
    if (!isGrantableNonManagementPermission(permission)) {
      throw const HostUserManagementException('PERMISSION_NOT_REVOCABLE_HERE');
    }
    await _mutate('revoke', {
      'actorId': actorId.trim(),
      'permission': permission,
    });
  }

  Future<void> disableUser({required String actorId}) async {
    _validateIdentifier(actorId, 'actorId');
    await _mutate('disable', {'actorId': actorId.trim()});
  }

  static bool isGrantableNonManagementPermission(String value) =>
      _validPermissionSyntax(value) &&
      !const [
        'identity.',
        'host.',
        'system.',
        'security.',
        'recovery.',
        'authorization.',
      ].any(value.startsWith);

  Future<String?> _mutate(String action, Map<String, Object?> values) async {
    final response = await _post(action, values);
    if (response.statusCode != HttpStatus.ok) throw _error(response);
    if (action == 'create') {
      const envelopeKeys = {
        'apiVersion',
        'managementApiVersion',
        'correlationId',
        'userOperation',
      };
      if (response.body.length != envelopeKeys.length ||
          response.body.keys.any((key) => !envelopeKeys.contains(key))) {
        throw _invalidResponse(response);
      }
    }
    final raw = response.body['userOperation'];
    if (raw is! Map) throw _invalidResponse(response);
    final result = Map<String, dynamic>.from(raw);
    if (action == 'create') {
      final actorId = result['actorId'];
      if (result.length != 2 ||
          result.keys.any(
            (key) => !const {'status', 'actorId'}.contains(key),
          ) ||
          result['status'] != 'APPLIED' ||
          actorId is! String ||
          !RegExp(r'^usr_[0-9a-f]{32}$').hasMatch(actorId)) {
        throw _invalidResponse(response);
      }
      return actorId;
    }
    if (result.keys.toSet().difference(const {'status'}).isNotEmpty ||
        result.length != 1 ||
        result['status'] != 'APPLIED') {
      throw _invalidResponse(response);
    }
    return null;
  }

  Future<_ManagementResponse> _post(
    String action,
    Map<String, Object?> fields,
  ) async {
    _requireAuthorized();
    final token = await credentials.read(endpoint);
    if (token == null) {
      throw const HostUserManagementException('HOST_CREDENTIAL_MISSING');
    }
    try {
      final body = canonicalJson({
        'managementApiVersion': hostUserManagementApiVersion,
        'companyId': companyId,
        'branchId': branchId,
        ...fields,
      });
      final response = await (exchange ?? _httpExchange)(
        uri: endpoint.replace(path: '/api/v1/management/users/$action'),
        headers: {
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
          HttpHeaders.authorizationHeader: 'Bearer $token',
        },
        body: body,
        timeout: timeout,
        maxResponseBytes: maxResponseBytes,
      ).timeout(timeout);
      final envelope = response.body;
      final correlationId = _correlationId(
        envelope['correlationId'] ??
            response.headers['x-correlation-id'] ??
            response.headers['X-Correlation-ID'],
      );
      if (correlationId == null) {
        throw HostUserManagementException(
          'HOST_INVALID_RESPONSE',
          statusCode: response.statusCode,
        );
      }
      if (envelope['apiVersion'] != hostUserManagementApiVersion ||
          envelope['managementApiVersion'] != hostUserManagementApiVersion) {
        throw HostUserManagementException(
          'HOST_API_VERSION_MISMATCH',
          statusCode: response.statusCode,
          correlationId: correlationId,
        );
      }
      return _ManagementResponse(response.statusCode, envelope, correlationId);
    } on HostUserManagementException {
      rethrow;
    } on TimeoutException {
      throw const HostUserManagementException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    } on SocketException {
      throw const HostUserManagementException(
        'HOST_UNREACHABLE',
        retryable: true,
      );
    } on TlsException {
      throw const HostUserManagementException('HOST_TLS_VALIDATION_FAILED');
    } on HttpException {
      throw const HostUserManagementException('HOST_INVALID_RESPONSE');
    } on FormatException {
      throw const HostUserManagementException('HOST_INVALID_RESPONSE');
    } catch (_) {
      throw const HostUserManagementException(
        'HOST_UNAVAILABLE',
        retryable: true,
      );
    }
  }

  Future<HostUserManagementHttpResponse> _httpExchange({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    final watch = Stopwatch()..start();
    final client = _clientFactory()..connectionTimeout = timeout;
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
        throw const HostUserManagementException('HOST_INVALID_RESPONSE');
      }
      if (response.contentLength > maxResponseBytes) {
        throw const HostUserManagementException('HOST_RESPONSE_TOO_LARGE');
      }
      final bytes = await response
          .fold<List<int>>(<int>[], (buffer, chunk) {
            if (buffer.length + chunk.length > maxResponseBytes) {
              throw const HostUserManagementException(
                'HOST_RESPONSE_TOO_LARGE',
              );
            }
            buffer.addAll(chunk);
            return buffer;
          })
          .timeout(_remaining(watch));
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const HostUserManagementException('HOST_INVALID_RESPONSE');
      }
      final correlationIdHeader = response.headers.value('x-correlation-id');
      return HostUserManagementHttpResponse(
        statusCode: response.statusCode,
        body: Map<String, dynamic>.from(decoded),
        headers: {'x-correlation-id': ?correlationIdHeader},
      );
    } finally {
      client.close(force: true);
    }
  }

  void _requireAuthorized() {
    if (!canManageUsers) {
      throw const HostUserManagementException('HOST_PERMISSION_DENIED');
    }
  }

  Duration _remaining(Stopwatch watch) {
    final remaining = timeout - watch.elapsed;
    if (remaining <= Duration.zero) {
      throw const HostUserManagementException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    }
    return remaining;
  }

  HostUserManagementException _error(_ManagementResponse response) {
    final raw = response.body['error'];
    final error = raw is Map ? Map<String, dynamic>.from(raw) : const {};
    final value = error['code'];
    final code =
        value is String && RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(value)
        ? value
        : 'HOST_HTTP_ERROR';
    return HostUserManagementException(
      code,
      statusCode: response.statusCode,
      correlationId: response.correlationId,
      retryable: error['retryable'] == true || response.statusCode >= 500,
    );
  }

  HostUserManagementException _invalidResponse(_ManagementResponse response) =>
      HostUserManagementException(
        'HOST_INVALID_RESPONSE',
        statusCode: response.statusCode,
        correlationId: response.correlationId,
      );
}

class _ManagementResponse {
  const _ManagementResponse(this.statusCode, this.body, this.correlationId);

  final int statusCode;
  final Map<String, dynamic> body;
  final String correlationId;
}

String? _correlationId(Object? value) =>
    value is String && RegExp(r'^cor_[a-f0-9]{32}$').hasMatch(value)
    ? value
    : null;

bool _validPermissionSyntax(String value) =>
    value.length <= 256 && RegExp(r'^[a-z][a-z0-9_.]+$').hasMatch(value);

bool _validAuditIdentifier(String value) =>
    value.length <= 128 &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,127}$').hasMatch(value) &&
    !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(value);

void _validateIdentifier(String value, String field) {
  if (value.trim().isEmpty || value.length > 256) {
    throw HostUserManagementException('INVALID_${field.toUpperCase()}');
  }
}
