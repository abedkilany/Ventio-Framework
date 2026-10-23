import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;

import 'authentication.dart';

/// Privileged server maintenance API, never an HTTP route or Client capability.
/// The database login is the administrative authority; operatorLabel is an audit
/// label, not a user-authentication claim. Use a restricted server operator login.
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

  Future<void> _audit(pg.TxSession tx, String action, String subject,
          Map<String, dynamic> details) =>
      tx.execute(pg.Sql.named('''
    INSERT INTO ventio_identity_audit (tenant_id, operator_label, action, subject_id, details)
    VALUES (@tenant, @operator, @action, @subject, CAST(@details AS jsonb))
  '''), parameters: {
        'tenant': tenantId,
        'operator': operatorLabel,
        'action': action,
        'subject': subject,
        'details': jsonEncode(details)
      }).then((_) {});

  Future<T> _change<T>(String actorId, Future<T> Function(pg.TxSession) change,
      {bool requireActive = true}) async {
    _identifier(actorId);
    return connection.runTx((tx) async {
      final user = await tx.execute(pg.Sql.named('''
        SELECT disabled_at FROM ventio_identity_users
        WHERE tenant_id = @tenant AND actor_id = @actor FOR UPDATE
      '''), parameters: {'tenant': tenantId, 'actor': actorId});
      if (user.isEmpty || (requireActive && user.single[0] != null)) {
        throw StateError('Unknown or disabled user');
      }
      return change(tx);
    });
  }

  Future<void> createUser(String actorId) async {
    _identifier(actorId);
    await connection.runTx((tx) async {
      // Insert only: disabled identities cannot be silently reactivated.
      await tx.execute(pg.Sql.named('''
        INSERT INTO ventio_identity_users (tenant_id, actor_id) VALUES (@tenant, @actor)
      '''), parameters: {'tenant': tenantId, 'actor': actorId});
      await _audit(tx, 'USER_CREATED', actorId, {});
    });
  }

  Future<void> registerBranch(String companyId, String branchId) async {
    _identifier(companyId);
    _identifier(branchId);
    await connection.runTx((tx) async {
      final result = await tx.execute(pg.Sql.named('''
        INSERT INTO ventio_identity_branches (tenant_id, company_id, branch_id)
        VALUES (@tenant, @company, @branch) ON CONFLICT DO NOTHING RETURNING branch_id
      '''), parameters: {
        'tenant': tenantId,
        'company': companyId,
        'branch': branchId
      });
      if (result.isNotEmpty)
        await _audit(
            tx, 'BRANCH_REGISTERED', branchId, {'companyId': companyId});
    });
  }

  Future<void> registerDevice(String actorId, String deviceId) async {
    _identifier(deviceId);
    await _change(actorId, (tx) async {
      await tx.execute(pg.Sql.named('''
        INSERT INTO ventio_identity_devices (tenant_id, actor_id, device_id)
        VALUES (@tenant, @actor, @device)
      '''), parameters: {
        'tenant': tenantId,
        'actor': actorId,
        'device': deviceId
      });
      await _audit(tx, 'DEVICE_REGISTERED', deviceId, {'actorId': actorId});
    });
  }

  /// Returns the raw token once to the trusted provisioning caller. Never log it.
  /// No Client input token, credential overwrite, revival or implicit renewal.
  Future<String> issueCredential(
      {required String actorId,
      required String deviceId,
      required String credentialId,
      required DateTime expiresAt}) async {
    _identifier(deviceId);
    _identifier(credentialId);
    final token = OpaqueToken.generate();
    return _change(actorId, (tx) async {
      final device = await tx.execute(pg.Sql.named('''
        SELECT revoked_at FROM ventio_identity_devices WHERE tenant_id = @tenant
          AND actor_id = @actor AND device_id = @device FOR UPDATE
      '''), parameters: {
        'tenant': tenantId,
        'actor': actorId,
        'device': deviceId
      });
      if (device.isEmpty || device.single[0] != null)
        throw StateError('Unknown or revoked device');
      await tx.execute(pg.Sql.named('''
        INSERT INTO ventio_identity_credentials
          (tenant_id, actor_id, device_id, credential_id, token_digest, expires_at)
        VALUES (@tenant, @actor, @device, @credential, @digest, @expires)
      '''), parameters: {
        'tenant': tenantId,
        'actor': actorId,
        'device': deviceId,
        'credential': credentialId,
        'digest': OpaqueToken.digest(token),
        'expires': expiresAt.toUtc()
      });
      await _audit(tx, 'CREDENTIAL_ISSUED', credentialId, {
        'actorId': actorId,
        'deviceId': deviceId,
        'expiresAt': expiresAt.toUtc().toIso8601String()
      });
      return token;
    });
  }

  Future<void> grant(String actorId, String companyId, String branchId,
      String permission) async {
    _grantFields(companyId, branchId, permission);
    await _change(actorId, (tx) async {
      final rows = await tx.execute(pg.Sql.named('''
        INSERT INTO ventio_identity_grants (tenant_id, actor_id, company_id, branch_id, permission)
        VALUES (@tenant, @actor, @company, @branch, @permission)
        ON CONFLICT DO NOTHING RETURNING permission
      '''), parameters: {
        'tenant': tenantId,
        'actor': actorId,
        'company': companyId,
        'branch': branchId,
        'permission': permission
      });
      if (rows.isNotEmpty)
        await _audit(tx, 'PERMISSION_GRANTED', actorId, {
          'companyId': companyId,
          'branchId': branchId,
          'permission': permission
        });
    });
  }

  Future<void> revokeGrant(String actorId, String companyId, String branchId,
      String permission) async {
    _grantFields(companyId, branchId, permission);
    await _change(actorId, (tx) async {
      final rows = await tx.execute(pg.Sql.named('''
        DELETE FROM ventio_identity_grants WHERE tenant_id = @tenant AND actor_id = @actor
          AND company_id = @company AND branch_id = @branch AND permission = @permission
        RETURNING permission
      '''), parameters: {
        'tenant': tenantId,
        'actor': actorId,
        'company': companyId,
        'branch': branchId,
        'permission': permission
      });
      if (rows.isNotEmpty)
        await _audit(tx, 'PERMISSION_REVOKED', actorId, {
          'companyId': companyId,
          'branchId': branchId,
          'permission': permission
        });
    }, requireActive: false);
  }

  Future<void> revokeDevice(String deviceId) async {
    _identifier(deviceId);
    final device = await connection.execute(pg.Sql.named('''
      SELECT actor_id FROM ventio_identity_devices WHERE tenant_id = @tenant AND device_id = @device
    '''), parameters: {'tenant': tenantId, 'device': deviceId});
    if (device.isEmpty) throw StateError('Unknown device');
    await _change(device.single[0] as String, (tx) async {
      final rows = await tx.execute(pg.Sql.named('''
        UPDATE ventio_identity_devices SET revoked_at = clock_timestamp()
        WHERE tenant_id = @tenant AND device_id = @device AND revoked_at IS NULL RETURNING device_id
      '''), parameters: {'tenant': tenantId, 'device': deviceId});
      if (rows.isNotEmpty) await _audit(tx, 'DEVICE_REVOKED', deviceId, {});
    }, requireActive: false);
  }

  Future<void> revokeCredential(String credentialId) async {
    _identifier(credentialId);
    final credential = await connection.execute(pg.Sql.named('''
      SELECT actor_id FROM ventio_identity_credentials WHERE tenant_id = @tenant AND credential_id = @credential
    '''), parameters: {'tenant': tenantId, 'credential': credentialId});
    if (credential.isEmpty) throw StateError('Unknown credential');
    await _change(credential.single[0] as String, (tx) async {
      final rows = await tx.execute(pg.Sql.named('''
        UPDATE ventio_identity_credentials SET revoked_at = clock_timestamp()
        WHERE tenant_id = @tenant AND credential_id = @credential AND revoked_at IS NULL RETURNING credential_id
      '''), parameters: {'tenant': tenantId, 'credential': credentialId});
      if (rows.isNotEmpty)
        await _audit(tx, 'CREDENTIAL_REVOKED', credentialId, {});
    }, requireActive: false);
  }

  Future<void> disableUser(String actorId) async {
    await _change(actorId, (tx) async {
      final rows = await tx.execute(pg.Sql.named('''
        UPDATE ventio_identity_users SET disabled_at = clock_timestamp()
        WHERE tenant_id = @tenant AND actor_id = @actor AND disabled_at IS NULL RETURNING actor_id
      '''), parameters: {'tenant': tenantId, 'actor': actorId});
      if (rows.isNotEmpty) await _audit(tx, 'USER_DISABLED', actorId, {});
    }, requireActive: false);
  }
}

void _identifier(String value) {
  if (value.trim().isEmpty || value.length > 256)
    throw ArgumentError('Invalid identity identifier');
}

void _grantFields(String companyId, String branchId, String permission) {
  _identifier(companyId);
  _identifier(branchId);
  _identifier(permission);
  if (!RegExp(r'^[a-z][a-z0-9_.]+$').hasMatch(permission))
    throw ArgumentError('Invalid permission name');
}
