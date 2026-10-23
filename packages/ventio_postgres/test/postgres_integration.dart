import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_postgres/ventio_postgres.dart';

Future<void> main() async {
  final url = Platform.environment['VENTIO_TEST_DATABASE_URL'];
  final explicit = Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'];
  if (url == null ||
      url.isEmpty ||
      explicit != 'yes' ||
      Uri.parse(url).pathSegments.where((s) => s.isNotEmpty).lastOrNull !=
          'ventio_host_test') {
    stderr.writeln('Integration tests require VENTIO_TEST_DATABASE_URL '
        'pointing to ventio_host_test and VENTIO_ALLOW_DATABASE_TESTS=yes.');
    exitCode = 2;
    return;
  }
  final migrations = Directory(Platform.environment['VENTIO_MIGRATIONS_DIR'] ??
      '../../migrations/postgres');
  var assertions = 0;
  void expect(bool condition, String label) {
    if (!condition) throw StateError('FAIL: $label');
    assertions++;
    stdout.writeln('PASS: $label');
  }

  final conn = await pg.Connection.openFromUrl(url);
  final id = 'pg-test-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  final scope = RecordScope(
      tenantId: id, companyId: 'test-company', branchId: 'test-branch');
  try {
    final runner = PostgresMigrationRunner(conn, migrations);
    final migrationsFirst = await runner.apply();
    expect(migrationsFirst.length <= 5, 'Migration runner accepts known files');
    final ledger =
        await conn.execute('SELECT count(*) FROM ventio_schema_migrations');
    expect(ledger.single[0] == 5, 'All five migrations are recorded');
    final migrationsSecond = await runner.apply();
    expect(migrationsSecond.isEmpty, 'Migrations are idempotent');
    final repo = PostgresRecordRepository(conn);
    final record = PersistedRecord(
        scope: scope,
        docType: 'Inspection',
        recordId: 'record-1',
        revision: 1,
        data: {'condition': 'ok'});
    await repo.insert(record);
    final loaded =
        await repo.find(scope, docType: 'Inspection', recordId: 'record-1');
    expect(loaded?.data['condition'] == 'ok', 'Stored data can be read');
    var duplicateRejected = false;
    try {
      await repo.insert(record);
    } on pg.UniqueViolationException {
      duplicateRejected = true;
    }
    expect(duplicateRejected, 'Composite primary key rejects duplicates');
    expect(
        await repo.find(
                RecordScope(
                    tenantId: 'other',
                    companyId: scope.companyId,
                    branchId: scope.branchId),
                docType: 'Inspection',
                recordId: 'record-1') ==
            null,
        'Tenant scope prevents accidental cross-tenant lookup');
    expect(
        await repo.find(
                RecordScope(
                    tenantId: scope.tenantId,
                    companyId: 'another-company',
                    branchId: scope.branchId),
                docType: 'Inspection',
                recordId: 'record-1') ==
            null,
        'Company scope prevents accidental cross-company lookup');
    expect(
        await repo.find(
                RecordScope(
                    tenantId: scope.tenantId,
                    companyId: scope.companyId,
                    branchId: 'another-branch'),
                docType: 'Inspection',
                recordId: 'record-1') ==
            null,
        'Branch scope prevents accidental cross-branch lookup');

    // An aborted transaction must not persist its record.
    try {
      await conn.runTx((session) async {
        await session.execute(pg.Sql.named('''
          INSERT INTO ventio_records
          (tenant_id, company_id, branch_id, doc_type, record_id,
           revision, record_data)
          VALUES (@tenant, @company, @branch, 'Inspection', 'rolled-back',
           1, '{}'::jsonb)
        '''), parameters: {
          'tenant': id,
          'company': scope.companyId,
          'branch': scope.branchId,
        });
        throw StateError('Simulated transaction failure');
      });
    } on StateError {
      // Expected failure.
    }
    expect(
        await repo.find(scope,
                docType: 'Inspection', recordId: 'rolled-back') ==
            null,
        'Failed transaction is rolled back');

    // A new connection observes committed data, proving persistence beyond
    // one connection. This is not yet a Host restart test.
    final restarted = await pg.Connection.openFromUrl(url);
    try {
      expect(
          (await PostgresRecordRepository(restarted)
                  .find(scope, docType: 'Inspection', recordId: 'record-1')) !=
              null,
          'New connection reads committed record');
    } finally {
      await restarted.close();
    }
    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    // Test scope only; run against a disposable dedicated test database.
    await conn.execute(
        pg.Sql.named('DELETE FROM ventio_records WHERE tenant_id = @tenant'),
        parameters: {'tenant': id});
    await conn.close();
  }
}
