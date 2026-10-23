import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

/// Identity reads must run on the command's transaction, at READ COMMITTED.
/// Lock order: user, device, credential, ordered grants. Administration takes
/// the same user's exclusive lock before changing any authorization state.
class PostgresIdentityStore {
  const PostgresIdentityStore();

  Future<Principal?> resolve(pg.TxSession tx, String digest,
      {CommandEnvelope? command}) async {
    final located = await tx.execute(pg.Sql.named('''
      SELECT tenant_id, actor_id, device_id FROM ventio_identity_credentials
      WHERE token_digest = @digest
    '''), parameters: {'digest': digest});
    if (located.isEmpty) return null;
    final identity = located.single.toColumnMap();
    final parameters = <String, Object?>{
      'tenant': identity['tenant_id'],
      'actor': identity['actor_id'],
      'device': identity['device_id'],
      'digest': digest,
    };
    final users = await tx.execute(pg.Sql.named('''
      SELECT disabled_at FROM ventio_identity_users
      WHERE tenant_id = @tenant AND actor_id = @actor FOR SHARE
    '''), parameters: {
      'tenant': parameters['tenant'],
      'actor': parameters['actor']
    });
    if (users.isEmpty || users.single[0] != null) return null;
    final devices = await tx.execute(pg.Sql.named('''
      SELECT revoked_at FROM ventio_identity_devices WHERE tenant_id = @tenant
        AND actor_id = @actor AND device_id = @device FOR SHARE
    '''), parameters: {
      'tenant': parameters['tenant'],
      'actor': parameters['actor'],
      'device': parameters['device']
    });
    if (devices.isEmpty || devices.single[0] != null) return null;
    final credentials = await tx.execute(pg.Sql.named('''
      SELECT revoked_at FROM ventio_identity_credentials WHERE token_digest = @digest
        AND tenant_id = @tenant AND actor_id = @actor AND device_id = @device FOR SHARE
    '''), parameters: parameters);
    if (credentials.isEmpty || credentials.single[0] != null) return null;
    // Evaluate wall-clock expiry AFTER lock acquisition, not at transaction start
    // or before a blocked SELECT. Waiting for revocation must not extend expiry.
    final alive = await tx.execute(pg.Sql.named('''
      SELECT expires_at > clock_timestamp() FROM ventio_identity_credentials
      WHERE token_digest = @digest
    '''), parameters: {'digest': digest});
    if (alive.isEmpty || alive.single[0] != true) return null;
    final grants = await tx.execute(pg.Sql.named('''
      SELECT company_id, branch_id, permission FROM ventio_identity_grants
      WHERE tenant_id = @tenant AND actor_id = @actor
      ${command == null ? '' : 'AND company_id = @company AND branch_id = @branch'}
      ORDER BY company_id, branch_id, permission FOR SHARE
    '''), parameters: {
      'tenant': parameters['tenant'],
      'actor': parameters['actor'],
      if (command != null) 'company': command.companyId,
      if (command != null) 'branch': command.branchId,
    });
    return Principal(
        tenantId: identity['tenant_id'] as String,
        actorId: identity['actor_id'] as String,
        deviceId: identity['device_id'] as String,
        companyIds: grants.map((r) => r[0] as String).toSet(),
        branchIds: grants.map((r) => r[1] as String).toSet(),
        permissions: grants.map((r) => r[2] as String).toSet());
  }
}
