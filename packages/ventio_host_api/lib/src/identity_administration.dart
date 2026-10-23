import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;

import 'authentication.dart';
import 'private_files.dart';
import 'recovery_authority.dart';

/// Server maintenance facade. The DB login needs only EXECUTE on admin_change;
/// direct identity DML and DDL are denied. Every change and audit is one DB call.
class IdentityAdministration {
  final pg.Connection connection;
  final String tenantId;
  final String operatorLabel;
  final RecoveryAuthority? authority;

  IdentityAdministration({
    required this.connection,
    required this.tenantId,
    required this.operatorLabel,
    this.authority,
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
