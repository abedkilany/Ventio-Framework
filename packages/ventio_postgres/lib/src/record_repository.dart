import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;

/// Scope is mandatory on every read and write. Caller authentication remains
/// the responsibility of the future Host command layer, not the repository.
class RecordScope {
  final String tenantId;
  final String companyId;
  final String branchId;

  RecordScope({
    required this.tenantId,
    required this.companyId,
    required this.branchId,
  }) {
    if ([tenantId, companyId, branchId].any((s) => s.trim().isEmpty)) {
      throw ArgumentError('Record scope fields must be nonempty');
    }
  }
}

class PersistedRecord {
  final RecordScope scope;
  final String docType;
  final String recordId;
  final int revision;
  final Map<String, dynamic> _data;
  Map<String, dynamic> get data =>
      jsonDecode(jsonEncode(_data)) as Map<String, dynamic>;

  PersistedRecord({
    required this.scope,
    required this.docType,
    required this.recordId,
    required this.revision,
    required Map<String, dynamic> data,
  }) : _data = Map.unmodifiable(
          jsonDecode(jsonEncode(data)) as Map<String, dynamic>,
        ) {
    if (docType.trim().isEmpty || recordId.trim().isEmpty || revision < 1) {
      throw ArgumentError('Invalid persisted record identity or revision');
    }
  }
}

/// Persistence-only prototype: not a command processor. The Host must perform
/// permission checks and business validation before calling this adapter.
class PostgresRecordRepository {
  final pg.Connection connection;
  PostgresRecordRepository(this.connection);

  Future<void> insert(PersistedRecord record) async {
    await connection.execute(
      pg.Sql.named('''
      INSERT INTO ventio_records
        (tenant_id, company_id, branch_id, doc_type, record_id,
         revision, record_data)
      VALUES
        (@tenant, @company, @branch, @type, @record, @revision,
         CAST(@data AS jsonb))
    '''),
      parameters: {
        'tenant': record.scope.tenantId,
        'company': record.scope.companyId,
        'branch': record.scope.branchId,
        'type': record.docType,
        'record': record.recordId,
        'revision': record.revision,
        'data': jsonEncode(record.data),
      },
    );
  }

  Future<PersistedRecord?> find(
    RecordScope scope, {
    required String docType,
    required String recordId,
  }) async {
    if (docType.trim().isEmpty || recordId.trim().isEmpty) {
      throw ArgumentError('docType and recordId must be nonempty');
    }
    final rows = await connection.execute(
      pg.Sql.named('''
      SELECT revision, record_data::text AS record_json
      FROM ventio_records
      WHERE tenant_id = @tenant AND company_id = @company
        AND branch_id = @branch AND doc_type = @type AND record_id = @record
    '''),
      parameters: {
        'tenant': scope.tenantId,
        'company': scope.companyId,
        'branch': scope.branchId,
        'type': docType,
        'record': recordId,
      },
    );
    if (rows.isEmpty) return null;
    final values = rows.single.toColumnMap();
    return PersistedRecord(
      scope: scope,
      docType: docType,
      recordId: recordId,
      revision: values['revision'] as int,
      data: jsonDecode(values['record_json'] as String) as Map<String, dynamic>,
    );
  }
}
