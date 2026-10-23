import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;

import 'authentication.dart';

/// Server maintenance facade. The DB login needs only EXECUTE on admin_change;
/// direct identity DML and DDL are denied. Every change and audit is one DB call.
class IdentityAdministration {
  final pg.Connection connection;
  final String tenantId;
  final String operatorLabel;

  IdentityAdministration(
      {required this.connection,
      required this.tenantId,
      required this.operatorLabel}) {
    _identifier(tenantId);
    _identifier(operatorLabel);
  }

  Future<void> _change(String action, Map<String, Object?> fields) async {
    await connection.execute(
        pg.Sql.named(
            'SELECT ventio_security.admin_change(CAST(@change AS jsonb))'),
        parameters: {
          'change': jsonEncode({
            'tenantId': tenantId,
            'operatorLabel': operatorLabel,
            'action': action,
            ...fields
          })
        });
  }

  Future<void> createUser(String actorId) {
    _identifier(actorId);
    return _change('USER_CREATED', {'actorId': actorId});
  }

  Future<void> registerBranch(String companyId, String branchId) {
    _identifier(companyId);
    _identifier(branchId);
    return _change(
        'BRANCH_REGISTERED', {'companyId': companyId, 'branchId': branchId});
  }

  Future<void> registerDevice(String actorId, String deviceId) {
    _identifier(actorId);
    _identifier(deviceId);
    return _change(
        'DEVICE_REGISTERED', {'actorId': actorId, 'deviceId': deviceId});
  }

  Future<String> issueCredential(
      {required String actorId,
      required String deviceId,
      required String credentialId,
      required DateTime expiresAt}) async {
    _identifier(actorId);
    _identifier(deviceId);
    _identifier(credentialId);
    final token = OpaqueToken.generate();
    await _change('CREDENTIAL_ISSUED', {
      'actorId': actorId,
      'deviceId': deviceId,
      'credentialId': credentialId,
      'tokenDigest': OpaqueToken.digest(token),
      'expiresAt': expiresAt.toUtc().toIso8601String()
    });
    return token;
  }

  Future<void> grant(
      String actorId, String companyId, String branchId, String permission) {
    _grantFields(actorId, companyId, branchId, permission);
    return _change('PERMISSION_GRANTED', {
      'actorId': actorId,
      'companyId': companyId,
      'branchId': branchId,
      'permission': permission
    });
  }

  Future<void> revokeGrant(
      String actorId, String companyId, String branchId, String permission) {
    _grantFields(actorId, companyId, branchId, permission);
    return _change('PERMISSION_REVOKED', {
      'actorId': actorId,
      'companyId': companyId,
      'branchId': branchId,
      'permission': permission
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
    String actorId, String companyId, String branchId, String permission) {
  for (final value in [actorId, companyId, branchId, permission]) {
    _identifier(value);
  }
  if (!RegExp(r'^[a-z][a-z0-9_.]+$').hasMatch(permission))
    throw ArgumentError('Invalid permission name');
}
