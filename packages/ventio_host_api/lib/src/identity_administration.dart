import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;

import 'authentication.dart';
import 'private_files.dart';
import 'recovery_authority.dart';

const List<String> initialHostAdministratorPermissions = [
  'host.status.read',
  'host.diagnostics.read',
  'identity.users.manage',
  'identity.devices.manage',
  'identity.pairing.manage',
  'identity.roles.manage',
];

class InitialHostAdministratorCredential {
  const InitialHostAdministratorCredential({
    required this.actorId,
    required this.token,
  });

  final String actorId;
  final String token;
}

/// Server maintenance facade. The DB login needs only EXECUTE on admin_change;
/// direct identity DML and DDL are denied. Every change and audit is one DB call.
class IdentityAdministration {
  final pg.Connection connection;
  final String tenantId;
  final String operatorLabel;
  final RecoveryAuthority? authority;
  final pg.Connection? bootstrapConnection;

  IdentityAdministration({
    required this.connection,
    required this.tenantId,
    required this.operatorLabel,
    this.authority,
    this.bootstrapConnection,
  }) {
    _identifier(tenantId);
    _identifier(operatorLabel);
  }

  Future<void> _change(String action, Map<String, Object?> fields) async {
    Future<void> execute(pg.Session session) async {
      await session.execute(
        pg.Sql.named(
          'SELECT ventio_security.admin_change(CAST(@change AS jsonb))',
        ),
        parameters: {
          'change': jsonEncode({
            'tenantId': tenantId,
            'operatorLabel': operatorLabel,
            'action': action,
            ...fields,
          }),
        },
      );
    }

    if (authority == null) {
      await execute(connection);
    } else {
      await authority!.change(connection, execute);
    }
  }

  Future<void> createUser(String actorId) {
    _identifier(actorId);
    return _change('USER_CREATED', {'actorId': actorId});
  }

  /// Atomically seeds the first scoped Host administrator for a tenant.
  /// This method is for a trusted local bootstrap broker only: it creates one
  /// user, branch, device, direct management grants and a scoped credential.
  /// The caller receives the raw token once; it is never stored in PostgreSQL.
  Future<InitialHostAdministratorCredential> bootstrapFirstAdministrator({
    required String companyId,
    required String branchId,
    required String deviceId,
    required String credentialId,
    required DateTime expiresAt,
    String? requestId,
    InitialHostAdministratorCredential? credential,
  }) async {
    if (authority == null || bootstrapConnection == null) {
      throw StateError(
        'Trusted recovery-admitted bootstrap connection is required',
      );
    }
    for (final value in [companyId, branchId, deviceId, credentialId]) {
      _identifier(value);
    }
    final expiry = expiresAt.toUtc();
    final now = DateTime.now().toUtc();
    if (!expiry.isAfter(now) ||
        expiry.isAfter(now.add(const Duration(days: 30)))) {
      throw ArgumentError('Initial administrator credential expiry is invalid');
    }
    final bootstrapRequestId = requestId ?? OpaqueToken.generate();
    if (!OpaqueToken.isValid(bootstrapRequestId)) {
      throw ArgumentError('Initial administrator request ID is invalid');
    }
    final initialCredential =
        credential ??
        InitialHostAdministratorCredential(
          actorId: 'usr_${OpaqueToken.generate()}',
          token: OpaqueToken.generate(),
        );
    _identifier(initialCredential.actorId);
    if (!OpaqueToken.isValid(initialCredential.token)) {
      throw ArgumentError('Initial administrator token is invalid');
    }
    final request = jsonEncode({
      'tenantId': tenantId,
      'operatorLabel': operatorLabel,
      'actorId': initialCredential.actorId,
      'companyId': companyId,
      'branchId': branchId,
      'deviceId': deviceId,
      'credentialId': credentialId,
      'tokenDigest': OpaqueToken.digest(initialCredential.token),
      'requestId': bootstrapRequestId,
      'expiresAt': expiry.toIso8601String(),
    });
    await authority!.change(bootstrapConnection!, (session) async {
      await session.execute(
        pg.Sql.named(
          'SELECT ventio_security.bootstrap_first_admin(CAST(@request AS jsonb))',
        ),
        parameters: {'request': request},
      );
    }, requireAdmissionProof: true);
    return initialCredential;
  }

  Future<void> registerBranch(String companyId, String branchId) {
    _identifier(companyId);
    _identifier(branchId);
    return _change('BRANCH_REGISTERED', {
      'companyId': companyId,
      'branchId': branchId,
    });
  }

  Future<void> registerDevice(String actorId, String deviceId) {
    _identifier(actorId);
    _identifier(deviceId);
    return _change('DEVICE_REGISTERED', {
      'actorId': actorId,
      'deviceId': deviceId,
    });
  }

  Future<String> issueCredential({
    required String actorId,
    required String deviceId,
    required String credentialId,
    required DateTime expiresAt,
  }) async {
    _identifier(actorId);
    _identifier(deviceId);
    _identifier(credentialId);
    final token = OpaqueToken.generate();
    await _change('CREDENTIAL_ISSUED', {
      'actorId': actorId,
      'deviceId': deviceId,
      'credentialId': credentialId,
      'tokenDigest': OpaqueToken.digest(token),
      'expiresAt': expiresAt.toUtc().toIso8601String(),
    });
    return token;
  }

  /// Provision through an operator-owned private local file, never a log/HTTP
  /// response. This method intentionally returns no raw credential.
  Future<void> provisionToFile({
    required String actorId,
    required String deviceId,
    required String credentialId,
    required DateTime expiresAt,
    required List<Map<String, Object?>> allowedScopes,
    required String outputPath,
  }) async {
    if (authority == null) throw StateError('Recovery authority is required');
    final token = OpaqueToken.generate();
    await PrivateFiles.create(outputPath, {
      'version': 1,
      'tenantId': tenantId,
      'actorId': actorId,
      'deviceId': deviceId,
      'credentialId': credentialId,
      'token': token,
      'expiresAt': expiresAt.toUtc().toIso8601String(),
    });
    await _change('CREDENTIAL_PROVISIONED', {
      'actorId': actorId,
      'deviceId': deviceId,
      'credentialId': credentialId,
      'tokenDigest': OpaqueToken.digest(token),
      'expiresAt': expiresAt.toUtc().toIso8601String(),
      'allowedScopes': allowedScopes,
    });
  }

  /// Rotation is compare-and-swap on the prior digest. The DB atomically revokes
  /// the old credential, carries its exact scope ceiling and inserts the new one.
  /// Renewal uses this same operation with a new ID/secret; no in-place extension.
  Future<void> rotateToFile({
    required String actorId,
    required String deviceId,
    required String previousCredentialId,
    required String previousToken,
    required String credentialId,
    required DateTime expiresAt,
    required String outputPath,
  }) async {
    if (authority == null || !OpaqueToken.isValid(previousToken)) {
      throw StateError('Trusted rotation context is required');
    }
    final token = OpaqueToken.generate();
    await PrivateFiles.create(outputPath, {
      'version': 1,
      'tenantId': tenantId,
      'actorId': actorId,
      'deviceId': deviceId,
      'credentialId': credentialId,
      'token': token,
      'expiresAt': expiresAt.toUtc().toIso8601String(),
    });
    await _change('CREDENTIAL_ROTATED', {
      'actorId': actorId,
      'deviceId': deviceId,
      'previousCredentialId': previousCredentialId,
      'previousDigest': OpaqueToken.digest(previousToken),
      'credentialId': credentialId,
      'tokenDigest': OpaqueToken.digest(token),
      'expiresAt': expiresAt.toUtc().toIso8601String(),
    });
  }

  Future<void> grant(
    String actorId,
    String companyId,
    String branchId,
    String permission,
  ) {
    _grantFields(actorId, companyId, branchId, permission);
    return _change('PERMISSION_GRANTED', {
      'actorId': actorId,
      'companyId': companyId,
      'branchId': branchId,
      'permission': permission,
    });
  }

  Future<void> revokeGrant(
    String actorId,
    String companyId,
    String branchId,
    String permission,
  ) {
    _grantFields(actorId, companyId, branchId, permission);
    return _change('PERMISSION_REVOKED', {
      'actorId': actorId,
      'companyId': companyId,
      'branchId': branchId,
      'permission': permission,
    });
  }

  /// Roles group permission keys, but assignments always carry one exact
  /// company and branch. A role never widens the credential's provisioned
  /// scope or permission ceiling.
  Future<void> createRole(String roleId, String displayName) {
    _role(roleId);
    _displayName(displayName);
    return _change('ROLE_CREATED', {
      'roleId': roleId,
      'displayName': displayName.trim(),
    });
  }

  Future<void> renameRole(String roleId, String displayName) {
    _role(roleId);
    _displayName(displayName);
    return _change('ROLE_RENAMED', {
      'roleId': roleId,
      'displayName': displayName.trim(),
    });
  }

  Future<void> deleteRole(String roleId) {
    _role(roleId);
    return _change('ROLE_DELETED', {'roleId': roleId});
  }

  Future<void> grantRolePermission(String roleId, String permission) {
    _role(roleId);
    _rolePermission(permission);
    return _change('ROLE_PERMISSION_GRANTED', {
      'roleId': roleId,
      'permission': permission,
    });
  }

  Future<void> revokeRolePermission(String roleId, String permission) {
    _role(roleId);
    _rolePermission(permission);
    return _change('ROLE_PERMISSION_REVOKED', {
      'roleId': roleId,
      'permission': permission,
    });
  }

  Future<void> assignRole({
    required String actorId,
    required String roleId,
    required String companyId,
    required String branchId,
  }) {
    for (final value in [actorId, companyId, branchId]) {
      _identifier(value);
    }
    _role(roleId);
    return _change('ROLE_ASSIGNED', {
      'actorId': actorId,
      'roleId': roleId,
      'companyId': companyId,
      'branchId': branchId,
    });
  }

  Future<void> revokeRoleAssignment({
    required String actorId,
    required String roleId,
    required String companyId,
    required String branchId,
  }) {
    for (final value in [actorId, companyId, branchId]) {
      _identifier(value);
    }
    _role(roleId);
    return _change('ROLE_UNASSIGNED', {
      'actorId': actorId,
      'roleId': roleId,
      'companyId': companyId,
      'branchId': branchId,
    });
  }

  Future<void> revokeDevice(String deviceId) {
    _identifier(deviceId);
    return _change('DEVICE_REVOKED', {'deviceId': deviceId});
  }

  Future<void> revokeCredential(String credentialId) {
    _identifier(credentialId);
    return _change('CREDENTIAL_REVOKED', {'credentialId': credentialId});
  }

  Future<void> disableUser(String actorId) {
    _identifier(actorId);
    return _change('USER_DISABLED', {'actorId': actorId});
  }

  Future<void> enableUser(String actorId) {
    _identifier(actorId);
    return _change('USER_ENABLED', {'actorId': actorId});
  }
}

void _identifier(String value) {
  if (value.trim().isEmpty || value.length > 256)
    throw ArgumentError('Invalid identity identifier');
}

void _grantFields(
  String actorId,
  String companyId,
  String branchId,
  String permission,
) {
  for (final value in [actorId, companyId, branchId, permission]) {
    _identifier(value);
  }
  if (!RegExp(r'^[a-z][a-z0-9_.]+$').hasMatch(permission))
    throw ArgumentError('Invalid permission name');
}

void _role(String roleId) {
  if (roleId.length > 128 || !RegExp(r'^[a-z][a-z0-9_.-]*$').hasMatch(roleId)) {
    throw ArgumentError('Invalid role identifier');
  }
}

void _rolePermission(String permission) {
  _identifier(permission);
  if (!RegExp(r'^[a-z][a-z0-9_.]+$').hasMatch(permission)) {
    throw ArgumentError('Invalid role permission');
  }
}

void _displayName(String value) {
  if (value.trim().isEmpty || value.length > 120) {
    throw ArgumentError('Invalid role display name');
  }
}
