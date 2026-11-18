// PREPARED / NOT EXECUTED. Adds Wave 2-specific proofs to existing SQL suites.
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';
import 'package:ventio_postgres/ventio_postgres.dart';

import 'support/wave2_fixture.dart';

Future<void> denied(Future<void> Function() action) async {
  String? state;
  try {
    await action();
  } on pg.ServerException catch (error) {
    state = error.code;
  }
  w2Expect(
    state == '42501',
    'Expected actual SQL privilege denial, not another failure',
  );
}

class _Rollback implements Exception {}

Future<void> main() async {
  final f = await W2Fixture.open();
  final cases = W2Cases();
  final migrationRoot = Directory('../../migrations/postgres');
  Future<List<List<Object?>>> ledger() async => (await f.observer.execute(
    'SELECT name,sha256 FROM public.ventio_schema_migrations ORDER BY name',
  )).map((row) => row.toList()).toList();
  try {
    await cases.run(
      'W2-D001',
      'B02,M01,M02,L01',
      'All forty-one migration identities match canonical repository sources',
      () async {
        final rows = await ledger();
        final files = await migrationRoot
            .list(followLinks: false)
            .where((e) => e is File && e.path.endsWith('.sql'))
            .cast<File>()
            .toList();
        w2Expect(
          rows.length == 41 && files.length == 41,
          'Incomplete or unknown migration ledger',
        );
        final expected = {
          for (final file in files)
            file.uri.pathSegments.last: migrationChecksum(
              await file.readAsString(),
            ),
        };
        for (final row in rows) {
          w2Expect(expected[row[0]] == row[1], 'Migration checksum mismatch');
        }
        await f.observer.execute('SELECT ventio_security.assert_schema()');
      },
    );
    await cases.run(
      'W2-D002',
      'B02',
      'Applying the same migration directory is idempotent',
      () async {
        final before = await ledger();
        w2Expect(
          (await PostgresMigrationRunner(
            f.observer,
            migrationRoot,
          ).apply()).isEmpty,
          'Existing migrations reapplied',
        );
        w2Equal(await ledger(), before, 'Ledger changed on reapply');
      },
    );
    await cases.run(
      'W2-D003',
      'M01,A12,L01,M05,M09',
      'Every new private Wave 2 table has owner RLS FORCE RLS and no public grants',
      () async {
        final rows = await f.observer.execute('''
        SELECT c.relname,r.rolname,c.relrowsecurity,c.relforcerowsecurity,
          NOT EXISTS(SELECT FROM aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a WHERE a.grantee=0)
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_roles r ON r.oid=c.relowner
        WHERE n.nspname='public' AND c.relkind='r' AND c.relname LIKE 'ventio_wave2_%'
        ORDER BY c.relname
      ''');
        final names = rows.map((row) => row[0]).toSet();
        w2Expect(
          names.containsAll({
            'ventio_wave2_definitions',
            'ventio_wave2_revisions',
            'ventio_wave2_jobs',
            'ventio_wave2_events',
            'ventio_wave2_organizations',
            'ventio_wave2_companies',
            'ventio_wave2_branches',
            'ventio_wave2_operations',
            'ventio_wave2_customization_rebases',
          }),
          'A new relation is missing',
        );
        w2Expect(
          rows.every(
            (r) =>
                r[1] == 'ventio_owner' &&
                r[2] == true &&
                r[3] == true &&
                r[4] == true,
          ),
          'A new table lacks isolation controls',
        );
      },
    );
    await cases.run(
      'W2-D004',
      'D08,M01,L01',
      'Operational roles cannot directly read or mutate private Wave 2 storage',
      () async {
        for (final url in [
          Platform.environment['VENTIO_TEST_RUNTIME_DATABASE_URL']!,
          Platform.environment['VENTIO_TEST_API_ADMIN_DATABASE_URL']!,
        ]) {
          final db = await pg.Connection.openFromUrl(url);
          try {
            for (final table in [
              'ventio_wave2_definitions',
              'ventio_wave2_revisions',
              'ventio_wave2_jobs',
              'ventio_wave2_events',
              'ventio_wave2_operations',
            ]) {
              await denied(() async {
                await db.execute('SELECT * FROM public.$table');
              });
              await denied(() async {
                await db.execute('DELETE FROM public.$table');
              });
            }
            await denied(() async {
              await db.execute('SET ROLE ventio_owner');
            });
          } finally {
            await db.close();
          }
        }
      },
    );
    await cases.run(
      'W2-D005',
      'L01,M05,M09',
      'Runtime cannot claim finish or manufacture trusted local-operation outcomes',
      () async {
        final db = await pg.Connection.openFromUrl(
          Platform.environment['VENTIO_TEST_RUNTIME_DATABASE_URL']!,
        );
        try {
          for (final sql in [
            'SELECT ventio_security.wave2_claim_job()',
            "SELECT ventio_security.wave2_finish_job('w2-prepared','${w2Id(1)}','${w2Id(2)}','{}',false)",
            'SELECT ventio_security.wave2_operation_offers()',
            "SELECT ventio_security.wave2_operation_result('${w2Id(1)}','${w2Id(2)}','{}')",
          ]) {
            await denied(() async {
              await db.execute(sql);
            });
          }
        } finally {
          await db.close();
        }
      },
    );
    await cases.run(
      'W2-D006',
      'D08,D09,H04',
      'Forged tenant and actor GUCs do not create an RLS proof',
      () async {
        await f.execute(f.command(600));
        final runtime = await pg.Connection.openFromUrl(
          Platform.environment['VENTIO_TEST_RUNTIME_DATABASE_URL']!,
        );
        try {
          await runtime.runTx((tx) async {
            await tx.execute(
              "SELECT set_config('ventio.tenant_id','w2-prepared',true),set_config('ventio.company_id','company-a',true),set_config('ventio.branch_id','branch-a',true),set_config('ventio.actor_id','author',true)",
            );
            final rows = await tx.execute(
              "SELECT count(*) FROM public.ventio_records WHERE tenant_id='w2-prepared'",
            );
            w2Expect(
              rows.single[0] == 0,
              'Caller-authored scope bypassed proof',
            );
          });
        } finally {
          await runtime.close();
        }
      },
    );
    await cases.run(
      'W2-D007',
      'B09,C09,D08',
      'SQL-level saved definitions derive tenant from real digest and remain actor isolated',
      () async {
        await f.save('preferences', 'mine', w2Preferences(), request: 700);
        await f.save(
          'preferences',
          'mine',
          w2Preferences(theme: 'light'),
          request: 700,
          as: f.outsider,
        );
        final runtime = await pg.Connection.openFromUrl(
          Platform.environment['VENTIO_TEST_RUNTIME_DATABASE_URL']!,
        );
        try {
          for (final (user, theme) in [
            (f.author, 'dark'),
            (f.outsider, 'light'),
          ]) {
            await runtime.runTx((tx) async {
              await f.authority.admit(tx);
              final rows = await tx.execute(
                pg.Sql.named(
                  'SELECT ventio_security.wave2_definitions(@digest,@company,@branch,\'preferences\')::text',
                ),
                parameters: {
                  'digest': OpaqueToken.digest(user.token),
                  'company': W2Fixture.company,
                  'branch': W2Fixture.branch,
                },
              );
              final result = requireMap(
                jsonDecode(rows.single[0] as String),
                'definitions',
              );
              w2Expect(
                requireList(result, 'definitions').single['body']['theme'] ==
                    theme,
                'SQL tenant isolation failed',
              );
            });
          }
        } finally {
          await runtime.close();
        }
      },
    );
    await cases.run(
      'W2-D008',
      'M01,M02,A12',
      'Platform administration permission cannot be manufactured through a business role',
      () async {
        await f.author.admin.createRole(
          'attempted-platform-role',
          'Attempted platform role',
        );
        await f.author.admin.grantRolePermission(
          'attempted-platform-role',
          'platform.configuration.manage',
        );
        final user = await f.provision(
          'role-only-platform',
          permissions: ['host.status.read', 'platform.configuration.manage'],
        );
        await user.admin.assignRole(
          actorId: user.actor,
          roleId: 'attempted-platform-role',
          companyId: W2Fixture.company,
          branchId: W2Fixture.branch,
        );
        await user.admin.revokeGrant(
          user.actor,
          W2Fixture.company,
          W2Fixture.branch,
          'platform.configuration.manage',
        );
        final result = await f.save(
          'configuration',
          'scope',
          w2Settings(),
          request: 800,
          as: user,
          status: 403,
        );
        w2Expect(
          result['reasonCode'] == 'PERMISSION_DENIED',
          'Role-only platform authority bypassed direct-grant requirement',
        );
      },
    );
    await cases.run(
      'W2-D009',
      'B02',
      'A later failed migration rolls back earlier new DDL and ledger entries',
      () async {
        final directory = await Directory(
          '${f.directory.path}/failure-migrations',
        ).create();
        await for (final file in migrationRoot.list(followLinks: false)) {
          if (file is File && file.path.endsWith('.sql')) {
            await file.copy('${directory.path}/${file.uri.pathSegments.last}');
          }
        }
        await File('${directory.path}/041_prepared_fixture.sql').writeAsString(
          'CREATE TABLE public.ventio_wave2_rollback_probe(id integer)',
        );
        await File('${directory.path}/042_prepared_failure.sql').writeAsString(
          "DO \$probe\$ BEGIN RAISE EXCEPTION 'prepared deterministic failure' USING ERRCODE='23514'; END \$probe\$",
        );
        final before = await ledger();
        String? state;
        try {
          await PostgresMigrationRunner(f.observer, directory).apply();
        } on pg.ServerException catch (error) {
          state = error.code;
        }
        w2Expect(state == '23514', 'Migration failed for an unrelated reason');
        w2Equal(
          await ledger(),
          before,
          'Failed batch partially committed ledger',
        );
        w2Expect(
          (await f.observer.execute(
                "SELECT to_regclass('public.ventio_wave2_rollback_probe') IS NULL",
              )).single[0] ==
              true,
          'Failed batch left DDL',
        );
      },
    );
    await cases.run(
      'W2-D010',
      'B02,D09',
      'Modified applied checksum is rejected before additional migrations execute',
      () async {
        final before = await ledger();
        var refused = false;
        try {
          await f.observer.runTx((tx) async {
            await tx.execute(
              "UPDATE public.ventio_schema_migrations SET sha256='tampered' WHERE name='037_wave2_platform.sql'",
            );
            try {
              await PostgresMigrationRunner(
                f.observer,
                migrationRoot,
              ).applyInTransaction(tx);
            } on StateError {
              refused = true;
            }
            throw _Rollback();
          });
        } on _Rollback {
          /* Always roll back the deliberately altered fixture. */
        }
        w2Expect(refused, 'Modified ledger accepted');
        w2Equal(await ledger(), before, 'Tamper probe changed baseline');
      },
    );
    await cases.run(
      'W2-D011',
      'M09,J03,L01,D09',
      'Logical restore retains Wave 2 data and receipts but cannot resurrect revoked authority',
      () async {
        final command = f.command(1100);
        final receipt = await f.execute(command);
        await f.save('saved_view', 'restored-view', w2View(), request: 1101);
        final restoredUrl = await f.database.backupAndRestore(f.observer);
        final restored = await pg.Connection.openFromUrl(restoredUrl);
        try {
          final record = await restored.execute(
            pg.Sql.named(
              'SELECT receipt::text FROM public.ventio_command_journal WHERE tenant_id=@tenant AND command_id=@id',
            ),
            parameters: {'tenant': W2Fixture.tenant, 'id': command.commandId},
          );
          w2Equal(
            jsonDecode(record.single[0] as String),
            receipt,
            'Restore altered authoritative receipt',
          );
          w2Expect(
            (await restored.execute(
                  "SELECT count(*) FROM public.ventio_wave2_definitions WHERE definition_id='restored-view'",
                )).single[0] ==
                1,
            'Restore omitted Wave 2 state',
          );
          await f.author.admin.revokeCredential(f.author.credential);
          var rejected = false;
          try {
            await restored.runTx((tx) async {
              await f.authority.admit(tx);
            });
          } on pg.ServerException catch (error) {
            rejected = error.code == '28000';
          }
          w2Expect(
            rejected,
            'Restored stale identity silently adopted current witness',
          );
        } finally {
          await restored.close();
        }
        // This is logical DB recovery, not installed Windows backup acceptance.
      },
    );
  } finally {
    await f.close();
  }
}
