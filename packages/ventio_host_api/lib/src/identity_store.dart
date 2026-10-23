import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

/// The runtime cannot read or lock identity tables directly. The vetted database
/// function owns those operations and binds a transaction-local proof context.
class PostgresIdentityStore {
  const PostgresIdentityStore();

  Future<Principal?> resolve(pg.TxSession tx, String digest,
      {CommandEnvelope? command}) async {
    final rows = await tx.execute(pg.Sql.named('''
      SELECT ventio_security.resolve_identity(@digest, @company, @branch,
        @type, @version, @command, @aggregate)::text
    '''), parameters: {
      'digest': digest,
      'company': command?.companyId,
      'branch': command?.branchId,
      'type': command?.type,
      'version': command?.typeVersion,
      'command': command?.commandId,
      'aggregate': command?.aggregateId,
    });
    if (rows.single[0] == null) return null;
    final identity =
        jsonDecode(rows.single[0] as String) as Map<String, dynamic>;
    return Principal(
        tenantId: identity['tenantId'] as String,
        actorId: identity['actorId'] as String,
        deviceId: identity['deviceId'] as String,
        companyIds: (identity['companyIds'] as List).cast<String>().toSet(),
        branchIds: (identity['branchIds'] as List).cast<String>().toSet(),
        permissions: (identity['permissions'] as List).cast<String>().toSet());
  }
}
