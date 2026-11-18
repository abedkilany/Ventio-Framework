// PREPARED / NOT EXECUTED. Real 001-036 baseline from the accepted Git tree,
// not a guessed legacy schema made by removing lines from current contracts.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_host_api/ventio_host_api.dart';
import 'package:ventio_postgres/ventio_postgres.dart';

import 'support/wave2_fixture.dart';

Future<void> main() async {
  const baselines = {
    '7d74a706ef4bb7f9994d151af486eaa38066e633': 36,
    '7218c1c9994acc31cfa86008b92d2950367c6fac': 40,
  };
  final revision = Platform.environment['VENTIO_W2_UPGRADE_BASELINE'] ?? baselines.keys.first;
  final count = baselines[revision];
  if (count == null) throw StateError('Reviewed upgrade baseline required');
  await runBaseline(revision, count);
}

Future<void> runBaseline(String baselineRevision, int baselineCount) async {
  final f = await W2Fixture.open(); // Reuses the physical-host/cluster guards.
  final cases = W2Cases();
  final psql = Platform.environment['VENTIO_TEST_PSQL'];
  if (psql == null || !File(psql).isAbsolute || !await File(psql).exists()) {
    await f.close();
    throw StateError(
      'An already verified PostgreSQL 16 psql executable is required; no tool is downloaded',
    );
  }
  final directory = await Directory(
    '${f.directory.path}/accepted-baseline',
  ).create();
  final baselineTar = File('${f.directory.path}/baseline.tar');
  final databaseName = 'ventio_w2_upgrade_$pid';
  final source = Uri.parse(Platform.environment['VENTIO_TEST_DATABASE_URL']!);
  String url(String userInfo) =>
      source.replace(path: '/$databaseName', userInfo: userInfo).toString();
  var created = false;
  pg.Connection? owner;
  pg.Connection? admin;
  pg.Connection? migrator;
  var interruptBeforeCommit = false;
  final authority = RecoveryAuthority(
    '${f.directory.path}/upgrade.witness',
    testBarrier: (stage) {
      if (interruptBeforeCommit && stage == 'schema_upgrade_before_commit_attempt') {
        throw StateError('Disposable pre-commit interruption');
      }
    },
  );
  const operation = 'upgrade_20000000000040008000000000000001';
  String? manifest;
  String? identityBefore;
  Future<String> identitySnapshot(pg.Connection db) async {
    final result = <String, Object?>{};
    for (final table in [
      'ventio_identity_users',
      'ventio_identity_devices',
      'ventio_identity_credentials',
      'ventio_identity_grants',
      'ventio_identity_branches',
      'ventio_identity_roles',
      'ventio_identity_role_permissions',
      'ventio_identity_role_assignments',
    ]) {
      final rows = await db.execute(
        "SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]')::text FROM public.$table x WHERE tenant_id='w2-upgrade'",
      );
      result[table] = jsonDecode(rows.single[0] as String);
    }
    return jsonEncode(result); // Kept in memory; credentials never printed.
  }

  Future<void> bootstrap(Directory security) async {
    final process = await Process.run(
      psql,
      [
        '-X',
        '-w',
        '-h',
        source.host,
        '-p',
        '${source.port}',
        '-U',
        source.userInfo.split(':').first,
        '-d',
        databaseName,
        '-v',
        'ON_ERROR_STOP=1',
        '-v',
        'expected_database=$databaseName',
        '-f',
        '${security.path}/bootstrap.sql',
      ],
      environment: {
        'PGPASSWORD': Uri.decodeComponent(
          source.userInfo.substring(source.userInfo.indexOf(':') + 1),
        ),
      },
    );
    w2Expect(
      process.exitCode == 0,
      'Pinned security bootstrap failed; raw output withheld',
    );
  }

  try {
    await cases.run(
      'W2-U001',
      'B02,M01',
      'Materialize exact accepted baseline and seed representative legacy records and identity',
      () async {
        final archive = await Process.run(
          'git',
          [
            'archive',
            '--format=tar',
            baselineRevision,
            '--',
            'migrations/postgres',
            'security/postgres',
          ],
          workingDirectory: '../..',
          stdoutEncoding: null,
        );
        w2Expect(
          archive.exitCode == 0,
          'Pinned baseline Git object unavailable',
        );
        await baselineTar.writeAsBytes(archive.stdout as List<int>);
        final extracted = await Process.run('tar', [
          '-xf',
          baselineTar.path,
          '-C',
          directory.path,
        ]);
        w2Expect(extracted.exitCode == 0, 'Cannot materialize pinned baseline');
        final legacy = Directory('${directory.path}/migrations/postgres');
        final count = await legacy
            .list()
            .where((e) => e is File && e.path.endsWith('.sql'))
            .length;
        w2Expect(count == baselineCount, 'Pinned baseline migration count differs');
        w2Expect(
          (await f.observer.execute(
                pg.Sql.named(
                  'SELECT count(*) FROM pg_database WHERE datname=@name',
                ),
                parameters: {'name': databaseName},
              )).single[0] ==
              0,
          'Upgrade fixture name already exists; refusing to replace it',
        );
        await f.observer.execute('CREATE DATABASE $databaseName');
        created = true;
        owner = await pg.Connection.openFromUrl(
          source.replace(path: '/$databaseName').toString(),
        );
        w2Expect(
          (await PostgresMigrationRunner(owner!, legacy).apply()).length == baselineCount,
          'Legacy migrations incomplete',
        );
        await bootstrap(Directory('${directory.path}/security/postgres'));
        admin = await pg.Connection.openFromUrl(
          url('ventio_admin_test:admin_test_only'),
        );
        await authority.resetForReenrollment(
          admin!,
          'wave2-upgrade-disposable',
        );
        final identity = IdentityAdministration(
          connection: admin!,
          tenantId: 'w2-upgrade',
          operatorLabel: 'wave2-upgrade',
          authority: authority,
        );
        await identity.createUser('legacy-actor');
        await identity.registerBranch('legacy-company', 'legacy-branch');
        await identity.registerDevice('legacy-actor', 'legacy-device');
        await identity.grant(
          'legacy-actor',
          'legacy-company',
          'legacy-branch',
          'maintenance.read',
        );
        await identity.provisionToFile(
          actorId: 'legacy-actor',
          deviceId: 'legacy-device',
          credentialId: 'legacy-credential',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 2)),
          allowedScopes: [
            {
              'companyId': 'legacy-company',
              'branchId': 'legacy-branch',
              'permissions': ['maintenance.read'],
            },
          ],
          outputPath: '${f.directory.path}/legacy-token.json',
        );
        // Deliberate legacy seed through the guarded fixture observer, not a
        // claim that current production code can run against an old schema.
        await owner!.execute(
          "INSERT INTO public.ventio_records(tenant_id,company_id,branch_id,module_id,doc_type,record_id,revision,record_data) VALUES('w2-upgrade','legacy-company','legacy-branch','legacy.fixture','Legacy','preserve-me',7,'{\"memo\":\"before wave2\"}')",
        );
        identityBefore = await identitySnapshot(owner!);
      },
    );
    await cases.run(
      'W2-U002',
      'B02,M01,M02,A12,L01',
      'Witness-aware 036/040-to-041 transitions preserve data and reapply real security contracts',
      () async {
        final migrations = Directory('../../migrations/postgres');
        final files = await migrations
            .list()
            .where((e) => e is File && e.path.endsWith('.sql'))
            .cast<File>()
            .toList();
        files.sort((a, b) => a.path.compareTo(b.path));
        final rows = [
          for (final file in files)
            '${file.uri.pathSegments.last}:${migrationChecksum(await file.readAsString())}',
        ];
        manifest = sha256
            .convert(utf8.encode('${rows.join('\n')}\n'))
            .toString();
        migrator = await pg.Connection.openFromUrl(
          url('ventio_migration_test:migration_test_only'),
        );
        await migrator!.execute('SET ROLE ventio_owner');
        if (baselineCount == 40) {
          final before = await owner!.execute("SELECT pg_get_functiondef('ventio_security.wave2_save_definition(text,text,text,text,text,bigint,text,jsonb)'::regprocedure)");
          final witnessBefore = jsonDecode(await File(authority.path).readAsString()) as Map;
          interruptBeforeCommit = true;
          var refused = false;
          try {
            await authority.applySchemaUpgrade(
              migrator!, operationId: operation, migrationManifestSha256: manifest!,
              applyAndValidate: (tx) async { await PostgresMigrationRunner(migrator!, migrations).applyInTransaction(tx); },
            );
          } on RecoveryAdmissionUnavailable {
            refused = true;
          } finally {
            interruptBeforeCommit = false;
          }
          final after = await owner!.execute("SELECT pg_get_functiondef('ventio_security.wave2_save_definition(text,text,text,text,text,bigint,text,jsonb)'::regprocedure)");
          w2Equal(after.single, before.single, 'Interrupted correction changed the installed function');
          w2Expect(refused && (await owner!.execute('SELECT count(*) FROM public.ventio_schema_migrations')).single[0] == 40, 'Interrupted correction committed its ledger');
          final witnessAfter = jsonDecode(await File(authority.path).readAsString()) as Map;
          w2Expect(witnessAfter['pending'] == false && witnessAfter['fingerprint'] == witnessBefore['fingerprint'], 'Interrupted correction changed ready witness fingerprint');
          w2Equal(await identitySnapshot(owner!), identityBefore, 'Interrupted correction changed identities');
        }
        await authority.applySchemaUpgrade(
          migrator!,
          operationId: operation,
          migrationManifestSha256: manifest!,
          applyAndValidate: (tx) async {
            final applied = await PostgresMigrationRunner(
              migrator!,
              migrations,
            ).applyInTransaction(tx);
            w2Equal(applied, [
              if (baselineCount == 36) ...[
              '037_wave2_platform.sql',
              '038_wave2_administration.sql',
              '039_wave2_operation_execution.sql',
              '040_wave2_job_archival.sql',
              ],
              '041_wave2_customization_validation.sql',
            ], 'Wrong upgrade delta');
          },
        );
        await bootstrap(Directory('../../security/postgres'));
        final definition = (await owner!.execute("SELECT pg_get_functiondef('ventio_security.wave2_save_definition(text,text,text,text,text,bigint,text,jsonb)'::regprocedure)")).single[0] as String;
        w2Expect(definition.contains("((p_body->'properties') - ARRAY") && definition.contains("((p_body->'ui') - ARRAY"), 'Security reapplication restored the broken customization expression');
        await owner!.execute('SELECT ventio_security.assert_schema()');
        w2Equal(
          await identitySnapshot(owner!),
          identityBefore,
          'Upgrade changed legacy identity or ceilings',
        );
        final record = await owner!.execute(
          "SELECT revision,record_data->>'memo' FROM public.ventio_records WHERE tenant_id='w2-upgrade' AND record_id='preserve-me'",
        );
        w2Equal(record.single, [
          7,
          'before wave2',
        ], 'Upgrade changed legacy record');
        final scopes = await owner!.execute(
          "SELECT count(*) FROM public.ventio_wave2_branches WHERE tenant_id='w2-upgrade' AND company_id='legacy-company' AND branch_id='legacy-branch'",
        );
        w2Expect(scopes.single[0] == 1, 'Organization scope was not seeded');
      },
    );
    await cases.run(
      'W2-U003',
      'B02,M09',
      'Replaying the same completed transition does not run its migration callback again',
      () async {
        var invoked = false;
        await authority.applySchemaUpgrade(
          migrator!,
          operationId: operation,
          migrationManifestSha256: manifest!,
          applyAndValidate: (_) async {
            invoked = true;
          },
        );
        w2Expect(!invoked, 'Completed operation reran migration');
        await migrator!.runTx((tx) async {
          await authority.admit(tx);
        });
      },
    );
  } finally {
    await migrator?.close();
    await admin?.close();
    await owner?.close();
    if (created) {
      w2Expect(
        RegExp(r'^ventio_w2_upgrade_[0-9]+$').hasMatch(databaseName),
        'Refusing unsafe fixture deletion',
      );
      await f.observer.execute('DROP DATABASE $databaseName');
    }
    await f.close();
  }
}
