import 'dart:convert';

import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart';

class _UserManagementAuthenticator implements PersistentHostAuthenticator {
  @override
  Future<AuthenticatedSession?> authenticate(String token) async {
    if (token != validToken && token != deniedToken) return null;
    final canManage = token == validToken;
    final scope = PrincipalScope(
      companyId: 'company-001',
      branchId: 'branch-001',
      permissions: canManage
          ? {identityUsersManagePermission}
          : {'maintenance.read'},
    );
    return AuthenticatedSession.persistent(
      Principal(
        actorId: 'manager-001',
        deviceId: 'client-device-001',
        tenantId: 'users-api-test',
        companyIds: {'company-001'},
        branchIds: {'branch-001'},
        permissions: scope.permissions,
        scopeGrants: [scope],
      ),
      OpaqueToken.digest(token),
    );
  }
}

class _NoopExecutor implements AuthoritativeCommandExecutor {
  @override
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session,
  ) async =>
      CommandReceipt(commandId: command.commandId, status: 'ACCEPTED').toJson();
}

class _UserManagementGateway
    implements AuthoritativeIdentityUserAdministrationGateway {
  int listCalls = 0;
  int auditCalls = 0;
  final changes = <Map<String, Object?>>[];
  bool failNextChange = false;
  bool unsafeAudit = false;

  @override
  Future<Map<String, dynamic>> list({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
  }) async {
    listCalls++;
    return {
      'tenantId': session.principal.tenantId,
      'companyId': companyId,
      'branchId': branchId,
      'items': [
        {
          'actorId': 'technician-001',
          'state': 'ACTIVE',
          'directPermissions': ['maintenance.read'],
          'roles': [],
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> audit({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
  }) async {
    auditCalls++;
    return {
      'tenantId': session.principal.tenantId,
      'companyId': companyId,
      'branchId': branchId,
      'events': [
        {
          'eventId': '1',
          'occurredAtUtc': '2026-10-29T17:00:00.000Z',
          'action': 'USER_CREATED',
          'subjectId': unsafeAudit ? 'Bearer synthetic-secret' : 'new-user-001',
          'operator': 'manager-001',
        },
      ],
    };
  }

  @override
  Future<String?> change({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required Map<String, Object?> change,
  }) async {
    if (failNextChange) {
      failNextChange = false;
      throw const IdentityUserAdministrationException(
        'USER_NOT_FOUND',
        statusCode: 404,
      );
    }
    changes.add(Map.of(change));
    return change['action'] == 'USER_CREATED'
        ? 'usr_0123456789abcdef0123456789abcdef'
        : null;
  }
}

Future<void> main() async {
  final gateway = _UserManagementGateway();
  final api = await HostApi.bind(
    authenticator: _UserManagementAuthenticator(),
    executor: _NoopExecutor(),
    identityUserAdministration: gateway,
  );
  try {
    Map<String, Object?> body({
      String company = 'company-001',
      String branch = 'branch-001',
      Map<String, Object?> extra = const {},
    }) => {
      'managementApiVersion': managementApiVersion,
      'companyId': company,
      'branchId': branch,
      ...extra,
    };

    final listed = await send(
      api,
      path: '/api/v1/management/users/list',
      token: validToken,
      body: body(),
    );
    check(
      listed.status == 200 &&
          listed.body['managementApiVersion'] == managementApiVersion &&
          listed.body['correlationId'] ==
              listed.headers.value('X-Correlation-ID') &&
          ((listed.body['users'] as Map)['items'] as List).single['actorId'] ==
              'technician-001',
      'User list is returned only inside the versioned scoped response',
    );

    final audit = await send(
      api,
      path: '/api/v1/management/users/audit',
      token: validToken,
      body: body(),
    );
    final auditObject = audit.body['audit'] as Map;
    final auditEvent = (auditObject['events'] as List).single as Map;
    check(
      audit.status == 200 &&
          audit.body['managementApiVersion'] == managementApiVersion &&
          audit.body['correlationId'] ==
              audit.headers.value('X-Correlation-ID') &&
          auditEvent.keys.toSet().containsAll({
            'eventId',
            'occurredAtUtc',
            'action',
            'subjectId',
            'operator',
          }) &&
          !auditEvent.containsKey('details'),
      'Audit endpoint returns only the allowlisted scoped event projection',
    );

    for (final (route, operation, extra) in [
      ('create', 'USER_CREATED', <String, Object?>{}),
      (
        'grant',
        'PERMISSION_GRANTED',
        <String, Object?>{
          'actorId': 'new-user-001',
          'permission': 'maintenance.read',
        },
      ),
      (
        'revoke',
        'PERMISSION_REVOKED',
        <String, Object?>{
          'actorId': 'new-user-001',
          'permission': 'maintenance.read',
        },
      ),
      (
        'disable',
        'USER_DISABLED',
        <String, Object?>{'actorId': 'new-user-001'},
      ),
      ('enable', 'USER_ENABLED', <String, Object?>{'actorId': 'new-user-001'}),
    ]) {
      final response = await send(
        api,
        path: '/api/v1/management/users/$route',
        token: validToken,
        body: body(extra: extra),
      );
      final userOperation = response.body['userOperation'] as Map;
      check(
        response.status == 200 &&
            response.body['correlationId'] ==
                response.headers.value('X-Correlation-ID') &&
            userOperation['status'] == 'APPLIED' &&
            (route == 'create'
                ? userOperation['actorId'] ==
                      'usr_0123456789abcdef0123456789abcdef'
                : !userOperation.containsKey('actorId')) &&
            gateway.changes.last['action'] == operation,
        '$route applies the scoped user operation and returns its correlation ID',
      );
    }

    final denied = await send(
      api,
      path: '/api/v1/management/users/list',
      token: deniedToken,
      body: body(),
    );
    check(
      denied.status == 403 &&
          denied.body['error']['code'] == 'PERMISSION_DENIED' &&
          gateway.listCalls == 1 &&
          gateway.auditCalls == 1,
      'Ordinary users cannot list managed identities',
    );

    final crossScope = await send(
      api,
      path: '/api/v1/management/users/list',
      token: validToken,
      body: body(branch: 'branch-elsewhere'),
    );
    check(
      crossScope.status == 403 &&
          crossScope.body['error']['code'] == 'SCOPE_DENIED' &&
          gateway.listCalls == 1,
      'The user API rejects requests outside the authenticated exact branch',
    );

    final crossScopeAudit = await send(
      api,
      path: '/api/v1/management/users/audit',
      token: validToken,
      body: body(branch: 'branch-elsewhere'),
    );
    check(
      crossScopeAudit.status == 403 &&
          crossScopeAudit.body['error']['code'] == 'SCOPE_DENIED' &&
          gateway.auditCalls == 1,
      'Audit history cannot be read outside the authenticated exact branch',
    );

    gateway.unsafeAudit = true;
    final unsafeAudit = await send(
      api,
      path: '/api/v1/management/users/audit',
      token: validToken,
      body: body(),
    );
    check(
      unsafeAudit.status == 503 &&
          unsafeAudit.body['error']['code'] == 'HOST_INVALID_RESPONSE' &&
          !jsonEncode(unsafeAudit.body).contains('synthetic-secret'),
      'Unsafe audit labels are suppressed before serialization',
    );
    gateway.unsafeAudit = false;

    final badVersion = await send(
      api,
      path: '/api/v1/management/users/create',
      token: validToken,
      body: {...body(), 'managementApiVersion': managementApiVersion + 1},
    );
    check(
      badVersion.status == 400 &&
          badVersion.body['error']['code'] == 'INVALID_REQUEST',
      'Unknown management contract versions are rejected',
    );

    final extraField = await send(
      api,
      path: '/api/v1/management/users/create',
      token: validToken,
      body: body(extra: {'tenantId': 'attacker-controlled-tenant'}),
    );
    check(
      extraField.status == 400 &&
          extraField.body['error']['code'] == 'INVALID_REQUEST',
      'Caller-supplied tenant or permission claims are not accepted',
    );

    final callerChosenUserId = await send(
      api,
      path: '/api/v1/management/users/create',
      token: validToken,
      body: body(extra: {'actorId': 'branch-b-user-to-probe'}),
    );
    check(
      callerChosenUserId.status == 400 &&
          callerChosenUserId.body['error']['code'] == 'INVALID_REQUEST' &&
          gateway.changes.length == 5,
      'User creation rejects a caller-controlled global actor ID before database access',
    );

    final reservedPermission = await send(
      api,
      path: '/api/v1/management/users/grant',
      token: validToken,
      body: body(
        extra: {
          'actorId': 'new-user-001',
          'permission': 'identity.roles.manage',
        },
      ),
    );
    check(
      reservedPermission.status == 422 &&
          reservedPermission.body['error']['code'] == 'RESERVED_PERMISSION' &&
          gateway.changes.length == 5,
      'Management permissions cannot be delegated by the user API',
    );

    gateway.failNextChange = true;
    final missing = await send(
      api,
      path: '/api/v1/management/users/disable',
      token: validToken,
      body: body(extra: {'actorId': 'missing-user'}),
    );
    check(
      missing.status == 404 &&
          missing.body['error']['code'] == 'USER_NOT_FOUND' &&
          missing.body['correlationId'] ==
              missing.headers.value('X-Correlation-ID'),
      'User administration errors use safe correlated error envelopes',
    );

    print('RESULT: $assertions passed, 0 failed');
  } finally {
    await api.close();
  }
}
