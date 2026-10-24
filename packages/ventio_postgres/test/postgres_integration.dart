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
    stderr.writeln(
      'Integration tests require VENTIO_TEST_DATABASE_URL '
      'pointing to ventio_host_test and VENTIO_ALLOW_DATABASE_TESTS=yes.',
    );
    exitCode = 2;
    return;
  }
  final migrations = Directory(
    Platform.environment['VENTIO_MIGRATIONS_DIR'] ??
        '../../migrations/postgres',
  );
  var assertions = 0;
  void expect(bool condition, String label) {
    if (!condition) throw StateError('FAIL: $label');
    assertions++;
    stdout.writeln('PASS: $label');
  }

  final conn = await pg.Connection.openFromUrl(url);
  final id = 'pg-test-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  final scope = RecordScope(
    tenantId: id,
    companyId: 'test-company',
    branchId: 'test-branch',
  );
  try {
    final runner = PostgresMigrationRunner(conn, migrations);
    final migrationsFirst = await runner.apply();
    final expectedMigrations = await migrations
        .list()
        .where((file) => file is File && file.path.endsWith('.sql'))
        .length;
    expect(
      migrationsFirst.length <= expectedMigrations,
      'Migration runner accepts known files',
    );
    final ledger = await conn.execute(
      'SELECT count(*) FROM ventio_schema_migrations',
    );
    expect(
      ledger.single[0] == expectedMigrations,
      'All ordered migrations are recorded',
    );
    final migrationsSecond = await runner.apply();
    expect(migrationsSecond.isEmpty, 'Migrations are idempotent');
    final repo = PostgresRecordRepository(conn);
    final record = PersistedRecord(
      scope: scope,
      docType: 'Inspection',
      recordId: 'record-1',
      revision: 1,
      data: {'condition': 'ok'},
    );
    await repo.insert(record);
    final loaded = await repo.find(
      scope,
      docType: 'Inspection',
      recordId: 'record-1',
    );
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
              branchId: scope.branchId,
            ),
            docType: 'Inspection',
            recordId: 'record-1',
          ) ==
          null,
      'Tenant scope prevents accidental cross-tenant lookup',
    );
    expect(
      await repo.find(
            RecordScope(
              tenantId: scope.tenantId,
              companyId: 'another-company',
              branchId: scope.branchId,
            ),
            docType: 'Inspection',
            recordId: 'record-1',
          ) ==
          null,
      'Company scope prevents accidental cross-company lookup',
    );
    expect(
      await repo.find(
            RecordScope(
              tenantId: scope.tenantId,
              companyId: scope.companyId,
              branchId: 'another-branch',
            ),
            docType: 'Inspection',
            recordId: 'record-1',
          ) ==
          null,
      'Branch scope prevents accidental cross-branch lookup',
    );

    // An aborted transaction must not persist its record.
    try {
      await conn.runTx((session) async {
        await session.execute(
          pg.Sql.named('''
          INSERT INTO ventio_records
          (tenant_id, company_id, branch_id, doc_type, record_id,
           revision, record_data)
          VALUES (@tenant, @company, @branch, 'Inspection', 'rolled-back',
           1, '{}'::jsonb)
        '''),
          parameters: {
            'tenant': id,
            'company': scope.companyId,
            'branch': scope.branchId,
          },
        );
        throw StateError('Simulated transaction failure');
      });
    } on StateError {
      // Expected failure.
    }
    expect(
      await repo.find(scope, docType: 'Inspection', recordId: 'rolled-back') ==
          null,
      'Failed transaction is rolled back',
    );

    // A new connection observes committed data, proving persistence beyond
    // one connection. This is not yet a Host restart test.
    final restarted = await pg.Connection.openFromUrl(url);
    try {
      expect(
        (await PostgresRecordRepository(
              restarted,
            ).find(scope, docType: 'Inspection', recordId: 'record-1')) !=
            null,
        'New connection reads committed record',
      );
    } finally {
      await restarted.close();
    }
    final nestedSource = <String, dynamic>{
      'nested': {
        'items': [1, 2],
      },
    };
    final nested = PersistedRecord(
      scope: scope,
      docType: 'Inspection',
      recordId: 'nested',
      revision: 1,
      data: nestedSource,
    );
    nestedSource['nested']['items'].add(3);
    nested.data['nested']['items'].add(4);
    expect(
      (nested.data['nested']['items'] as List).length == 2,
      'Repository records do not expose nested internal data',
    );
    final temporary = await Directory.systemTemp.createTemp(
      'ventio-migration-audit-',
    );
    try {
      for (final source
          in await migrations
              .list()
              .where((e) => e is File && e.path.endsWith('.sql'))
              .cast<File>()
              .toList()) {
        await source.copy('${temporary.path}/${source.uri.pathSegments.last}');
      }
      Future<bool> rejected() async {
        try {
          await PostgresMigrationRunner(conn, temporary).apply();
          return false;
        } catch (_) {
          return true;
        }
      }

      final first = File('${temporary.path}/001_records.sql');
      final original = await first.readAsString();
      await first.delete();
      expect(
        await rejected(),
        'Missing previously applied migration is rejected',
      );
      await first.writeAsString('$original\n-- altered checksum');
      expect(
        await rejected(),
        'Modified historical migration is rejected before new DDL',
      );
      await first.writeAsString(original);
      final collision = File('${temporary.path}/001_duplicate.sql');
      await collision.writeAsString('SELECT 1');
      expect(
        await rejected(),
        'Duplicate migration numeric version is rejected',
      );
      await collision.delete();
      await File(
        '${temporary.path}/013_audit_probe.sql',
      ).writeAsString('CREATE TABLE ventio_migration_probe(id int)');
      await File(
        '${temporary.path}/014_audit_failure.sql',
      ).writeAsString('NOT VALID POSTGRESQL');
      expect(
        await rejected(),
        'Later invalid migration rejects whole new batch',
      );
      expect(
        (await conn.execute(
              "SELECT to_regclass('public.ventio_migration_probe') IS NULL",
            )).single[0] ==
            true,
        'Earlier new table is rolled back after later migration failure',
      );
      expect(
        (await conn.execute(
              "SELECT count(*) FROM ventio_schema_migrations WHERE name IN ('013_audit_probe.sql','014_audit_failure.sql')",
            )).single[0] ==
            0,
        'Failed new batch leaves no migration ledger entries',
      );
      await conn.execute(
        "INSERT INTO ventio_schema_migrations(name,sha256) VALUES('999_unknown.sql','fixture')",
      );
      expect(await rejected(), 'Database newer than the checkout is rejected');
      await conn.execute(
        "DELETE FROM ventio_schema_migrations WHERE name='999_unknown.sql'",
      );
      expect(
        (await runner.apply()).isEmpty,
        'Baseline migrations remain intact after negative cases',
      );
    } finally {
      await temporary.delete(recursive: true);
    }
    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    // Test scope only; run against a disposable dedicated test database.
    await conn.execute(
      pg.Sql.named('DELETE FROM ventio_records WHERE tenant_id = @tenant'),
      parameters: {'tenant': id},
    );
    await conn.close();
  }
}
