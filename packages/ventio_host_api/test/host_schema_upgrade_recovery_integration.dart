import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_host_api/ventio_host_api.dart';
import 'package:ventio_postgres/ventio_postgres.dart';

import 'test_support.dart';

Future<void> main() async {
  final templateUrl = Platform.environment['VENTIO_TEST_UPGRADE_TEMPLATE_URL'];
  final templateName = Platform.environment['VENTIO_TEST_UPGRADE_TEMPLATE'];
  final allowed = Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] == 'yes';
  if (!allowed ||
      templateUrl == null ||
      templateName == null ||
      !RegExp(
        r'^ventio_schema_upgrade_baseline_[a-f0-9]{16}$',
      ).hasMatch(templateName) ||
      Uri.parse(templateUrl).host != '127.0.0.1' ||
      Uri.parse(templateUrl).pathSegments.last != templateName) {
    stderr.writeln(
      'Schema upgrade integration requires the explicitly disposable pre-0.1.12 PostgreSQL template.',
    );
    exitCode = 2;
    return;
  }

  final templateUri = Uri.parse(templateUrl);
  final rootUri = templateUri.replace(path: '/postgres');
  final migrationUri = templateUri.replace(
    userInfo: 'ventio_migration_test:migration_test_only',
  );
  final adminUri = templateUri.replace(
    userInfo: 'ventio_admin_test:admin_test_only',
  );
  final apiUri = templateUri.replace(
    userInfo: 'ventio_user_api_test:user_api_test_only',
  );
  final prefix =
      'ventio_schema_upgrade_it_${sha256.convert(utf8.encode(OpaqueToken.generate())).toString().substring(0, 16)}';
  final databases = <String>{};
  final root = await pg.Connection.openFromUrl(rootUri.toString());
  final temporary = await createPrivateTestDirectory('ventio-schema-upgrade-');
  final baselineWitness =
      '${temporary.path}${Platform.pathSeparator}baseline.witness';
  var assertions = 0;
  void check(bool condition, String description) {
    if (!condition) throw StateError('FAIL: $description');
    assertions++;
    stdout.writeln('PASS: $description');
  }

  Future<void> clone(String suffix) async {
    final name = '${prefix}_$suffix';
    await root.execute('CREATE DATABASE $name TEMPLATE $templateName');
    databases.add(name);
  }

  String urlFor(Uri uri, String database) =>
      uri.replace(path: '/$database').toString();

  Future<(Map<String, dynamic>, int)> invokeTrustedUpgrade(
    String databaseUrl,
    String witnessPath,
    String operationId,
  ) async {
    final executable =
        Platform.environment['VENTIO_TEST_TRUSTED_HOST_UPGRADE_EXE'];
    final payload = Platform.environment['VENTIO_TEST_HOST_PAYLOAD_DIR'];
    final ownerSid = Platform.environment['VENTIO_TEST_RECOVERY_OWNER_SID'];
    if (!Platform.isWindows ||
        executable == null ||
        payload == null ||
        ownerSid == null ||
        !File(executable).existsSync() ||
        !Directory(payload).existsSync()) {
      throw StateError(
        'The isolated Windows trusted-upgrade reproduction is incomplete.',
      );
    }
    final process = await Process.start(
      executable,
      const [],
      workingDirectory: payload,
      environment: {
        'VENTIO_HOST_UPGRADE_TEST_MODE': 'yes',
        'VENTIO_RECOVERY_AUTHORITY_FILE': witnessPath,
        'VENTIO_RECOVERY_AUTHORITY_OWNER_SID': ownerSid,
        'VENTIO_RECOVERY_AUTHORITY_READER_SID': ownerSid,
        'VENTIO_RECOVERY_AUTHORITY_HOST_WRITES': 'yes',
        'VENTIO_MIGRATIONS_DIR': Platform.environment['VENTIO_MIGRATIONS_DIR']!,
        'VENTIO_SECURITY_DIR': Platform.environment['VENTIO_SECURITY_DIR']!,
        if (Platform.environment['SystemRoot'] != null)
          'SystemRoot': Platform.environment['SystemRoot']!,
        if (Platform.environment['WINDIR'] != null)
          'WINDIR': Platform.environment['WINDIR']!,
        if (Platform.environment['SystemDrive'] != null)
          'SystemDrive': Platform.environment['SystemDrive']!,
        if (Platform.environment['TEMP'] != null)
          'TEMP': Platform.environment['TEMP']!,
        if (Platform.environment['TMP'] != null)
          'TMP': Platform.environment['TMP']!,
        if (Platform.environment['PATH'] != null)
          'PATH': Platform.environment['PATH']!,
      },
      includeParentEnvironment: false,
      runInShell: false,
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.drain<void>();
    process.stdin.write(
      jsonEncode({'operationId': operationId, 'databaseUrl': databaseUrl}),
    );
    await process.stdin.close();
    final exit = await process.exitCode;
    await stderr;
    return (jsonDecode(await stdout) as Map<String, dynamic>, exit);
  }

  String upgradeId() =>
      'upgrade_${sha256.convert(utf8.encode(OpaqueToken.generate())).toString().substring(0, 32)}';

  Future<pg.Connection> openMigration(String name) async {
    final connection = await pg.Connection.openFromUrl(
      urlFor(migrationUri, name),
    );
    await connection.execute('SET ROLE ventio_owner');
    return connection;
  }

  Future<pg.Connection> openApi(String name) =>
      pg.Connection.openFromUrl(urlFor(apiUri, name));

  Map<String, dynamic> readWitness(String path) =>
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

  Future<void> copyWitness(String destination) =>
      PrivateFiles.create(destination, readWitness(baselineWitness));

  Future<(int, int, int, String, String, String)> identitySnapshot(
    pg.Connection connection,
  ) async {
    final row = (await connection.execute('''
      SELECT
        (SELECT count(*)::integer FROM public.ventio_identity_users),
        (SELECT count(*)::integer FROM public.ventio_identity_devices),
        (SELECT count(*)::integer FROM public.ventio_identity_credentials),
        (SELECT actor_id FROM public.ventio_identity_users ORDER BY actor_id LIMIT 1),
        (SELECT device_id FROM public.ventio_identity_devices ORDER BY device_id LIMIT 1),
        (SELECT credential_id FROM public.ventio_identity_credentials ORDER BY credential_id LIMIT 1)
    ''')).single;
    return (
      row[0] as int,
      row[1] as int,
      row[2] as int,
      row[3] as String,
      row[4] as String,
      row[5] as String,
    );
  }

  Future<void> assertDenied(
    pg.Connection api,
    Map<String, dynamic> witness,
  ) async {
    var denied = false;
    try {
      await api.runTx((tx) async {
        await tx.execute(
          pg.Sql.named(
            'SELECT ventio_security.admit_recovery(@fingerprint,@authority)',
          ),
          parameters: {
            'fingerprint': witness['fingerprint'],
            'authority': witness['authorityId'],
          },
        );
      });
    } on pg.ServerException catch (error) {
      denied = error.code == '28000';
    }
    check(
      denied,
      'Stale/rolled-back recovery evidence fails closed with SQLSTATE 28000',
    );
  }

  try {
    final seedApi = await openApi(templateName);
    final seedAdmin = await pg.Connection.openFromUrl(
      urlFor(adminUri, templateName),
    );
    final seedAuthority = RecoveryAuthority(baselineWitness);
    final tenant = 'upgrade-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final actor = 'usr_${OpaqueToken.generate()}';
    const company = 'upgrade-company';
    const branch = 'upgrade-branch';
    const device = 'upgrade-device';
    const credentialId = 'upgrade-credential';
    final token = OpaqueToken.generate();
    await seedAuthority.prepareFirstAdministratorBootstrap(
      seedApi,
      requestId: OpaqueToken.generate(),
      tenantId: tenant,
      actorId: actor,
      companyId: company,
      branchId: branch,
      deviceId: device,
      credentialId: credentialId,
      token: token,
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
    );
    final firstAdmin = IdentityAdministration(
      connection: seedAdmin,
      bootstrapConnection: seedApi,
      tenantId: tenant,
      operatorLabel: 'schema-upgrade-fixture',
      authority: seedAuthority,
    );
    await firstAdmin.bootstrapFirstAdministrator(
      companyId: company,
      branchId: branch,
      deviceId: device,
      credentialId: credentialId,
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      requestId: OpaqueToken.generate(),
      credential: InitialHostAdministratorCredential(
        actorId: actor,
        token: token,
      ),
    );
    await seedAdmin.close();
    await seedApi.close();

    final sourceDb = await openMigration(templateName);
    final beforeIdentity = await identitySnapshot(sourceDb);
    final beforeFingerprint = await RecoveryAuthority.snapshot(sourceDb);
    final initialLedger = await sourceDb.execute(
      'SELECT count(*) FROM public.ventio_schema_migrations',
    );
    check(
      initialLedger.single[0] == 30,
      'Fixture represents a persisted pre-0.1.12 Host at migration 030',
    );
    check(
      beforeIdentity.$1 == 1 &&
          beforeIdentity.$2 == 1 &&
          beforeIdentity.$3 == 1 &&
          beforeIdentity.$4 == actor &&
          beforeIdentity.$5 == device &&
          beforeIdentity.$6 == credentialId,
      'Pre-upgrade Host has persisted user, device, and credential identity rows',
    );
    final migrationDirectory = Directory(
      Platform.environment['VENTIO_MIGRATIONS_DIR'] ??
          '../../migrations/postgres',
    );
    final migrationFiles = await migrationDirectory
        .list(followLinks: false)
        .where((entry) => entry is File && entry.path.endsWith('.sql'))
        .cast<File>()
        .toList();
    migrationFiles.sort(
      (a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
    );
    final manifestRows = <String>[];
    for (final file in migrationFiles) {
      final name = file.uri.pathSegments.last;
      final canonical = canonicalMigrationSql(await file.readAsString());
      manifestRows.add('$name:${migrationChecksum(canonical)}');
    }
    final manifest = sha256
        .convert(utf8.encode('${manifestRows.join('\n')}\n'))
        .toString();
    await sourceDb.close();

    for (final suffix in [
      'success',
      'legacy',
      'interrupted',
      'ambiguous',
      'prepared_retry',
      'rollback',
      'unresolved',
    ]) {
      await clone(suffix);
    }

    final successName = '${prefix}_success';
    final successWitness =
        '${temporary.path}${Platform.pathSeparator}success.witness';
    await copyWitness(successWitness);
    var migration = await openMigration(successName);
    final identityBeforeSuccess = await identitySnapshot(migration);
    final authority = RecoveryAuthority(successWitness);
    final operation = upgradeId();
    await authority.applySchemaUpgrade(
      migration,
      operationId: operation,
      migrationManifestSha256: manifest,
      applyAndValidate: (tx) async {
        await PostgresMigrationRunner(
          migration,
          migrationDirectory,
        ).applyInTransaction(tx);
      },
    );
    final afterFingerprint = await RecoveryAuthority.snapshot(migration);
    final upgradedLedger = await migration.execute(
      'SELECT count(*) FROM public.ventio_schema_migrations',
    );
    final identityAfterSuccess = await identitySnapshot(migration);
    check(
      upgradedLedger.single[0] == 33 && afterFingerprint != beforeFingerprint,
      'Recovery-coordinated upgrade applies 031-033 and advances the database fingerprint',
    );
    check(
      identityBeforeSuccess == identityAfterSuccess,
      'Successful upgrade preserves existing actor, device, credential, and counts',
    );
    final readyWitness = readWitness(successWitness);
    check(
      readyWitness['pending'] == false &&
          readyWitness['fingerprint'] == afterFingerprint,
      'Independent witness is finalized to the committed schema fingerprint',
    );

    final staleApi = await openApi(successName);
    await assertDenied(staleApi, readWitness(baselineWitness));
    await staleApi.close();
    await migration.close();

    final legacyName = '${prefix}_legacy';
    final legacyWitness =
        '${temporary.path}${Platform.pathSeparator}legacy.witness';
    await copyWitness(legacyWitness);
    migration = await openMigration(legacyName);
    final preLegacyFingerprint = await RecoveryAuthority.snapshot(migration);
    final legacyDirectory = Directory(
      '${temporary.path}${Platform.pathSeparator}migrations-032',
    );
    await legacyDirectory.create();
    for (final file in migrationFiles.where(
      (file) => int.parse(file.uri.pathSegments.last.substring(0, 3)) <= 32,
    )) {
      await file.copy(
        '${legacyDirectory.path}${Platform.pathSeparator}${file.uri.pathSegments.last}',
      );
    }
    await PostgresMigrationRunner(migration, legacyDirectory).apply();
    final postLegacyFingerprint = await RecoveryAuthority.snapshot(migration);
    final legacyLedger = await migration.execute('''
      SELECT
        count(*) FILTER (WHERE name IN (
          '031_identity_credential_reissues.sql',
          '032_identity_credential_reissue_pending.sql'
        ))::integer,
        count(*) FILTER (WHERE name='033_host_schema_upgrade_receipts.sql')::integer
      FROM public.ventio_schema_migrations
    ''');
    check(
      postLegacyFingerprint != preLegacyFingerprint &&
          legacyLedger.single[0] == 2 &&
          legacyLedger.single[1] == 0,
      'Reproduction applies exactly 0.1.12 migrations 031 and 032 to the persisted 030 Host',
    );
    check(
      readWitness(legacyWitness)['fingerprint'] != postLegacyFingerprint,
      'Reproduction confirms the independent ready witness and post-0.1.12 database fingerprints disagree',
    );
    final legacyIdentityBeforeUpgradeAttempt = await identitySnapshot(
      migration,
    );
    final legacyWitnessBeforeUpgradeAttempt = jsonEncode(
      readWitness(legacyWitness),
    );
    final stalePreflight = await RecoveryAuthority(
      legacyWitness,
    ).inspectSchemaUpgradeAdmission(migration);
    check(
      stalePreflight ==
          SchemaUpgradeAdmissionDiagnostic.databaseFingerprintMismatch,
      'Read-only upgrade preflight classifies the stale witness without exposing either fingerprint',
    );
    var staleWitnessUpgradeRejected = false;
    try {
      await RecoveryAuthority(legacyWitness).applySchemaUpgrade(
        migration,
        operationId: upgradeId(),
        migrationManifestSha256: manifest,
        applyAndValidate: (tx) async {
          await PostgresMigrationRunner(
            migration,
            migrationDirectory,
          ).applyInTransaction(tx);
        },
      );
    } on RecoveryAdmissionUnavailable {
      staleWitnessUpgradeRejected = true;
    }
    final legacyLedgerAfterRejectedUpgrade = await migration.execute(
      'SELECT count(*) FROM public.ventio_schema_migrations',
    );
    final legacyIdentityAfterRejectedUpgrade = await identitySnapshot(
      migration,
    );
    check(
      staleWitnessUpgradeRejected &&
          legacyLedgerAfterRejectedUpgrade.single[0] == 32 &&
          legacyIdentityAfterRejectedUpgrade ==
              legacyIdentityBeforeUpgradeAttempt &&
          jsonEncode(readWitness(legacyWitness)) ==
              legacyWitnessBeforeUpgradeAttempt,
      'Reproduction: trusted schema-upgrade admission rejects stale 031/032 state before DDL and preserves database, identity, and witness',
    );
    await migration.close();

    await root.execute('CREATE DATABASE ventio_host TEMPLATE $legacyName');
    databases.add('ventio_host');
    await root.execute('''
      CREATE ROLE ventio_migrator_app LOGIN PASSWORD 'ventio_migrator_app_test_only'
        INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    ''');
    await root.execute('GRANT ventio_migrator TO ventio_migrator_app');
    final helperWitness =
        '${temporary.path}${Platform.pathSeparator}legacy-helper.witness';
    await copyWitness(helperWitness);
    final helperDatabaseUrl =
        'postgresql://ventio_migrator_app:ventio_migrator_app_test_only@127.0.0.1:${templateUri.port}/ventio_host?sslmode=disable';
    final (helperResult, helperExitCode) = await invokeTrustedUpgrade(
      helperDatabaseUrl,
      helperWitness,
      upgradeId(),
    );
    final afterHelper = await openMigration('ventio_host');
    final helperIdentity = await identitySnapshot(afterHelper);
    final helperLedger = await afterHelper.execute(
      'SELECT count(*) FROM public.ventio_schema_migrations',
    );
    check(
      helperExitCode == 2 &&
          helperResult['status'] == 'failed' &&
          helperResult['failureCode'] == 'RECOVERY_FINGERPRINT_MISMATCH' &&
          helperResult['failureStage'] ==
              'RECOVERY_AUTHORITY_FINGERPRINT_PREFLIGHT' &&
          helperLedger.single[0] == 32 &&
          helperIdentity == legacyIdentityBeforeUpgradeAttempt &&
          jsonEncode(readWitness(helperWitness)) ==
              legacyWitnessBeforeUpgradeAttempt,
      'Instrumented trusted upgrade helper reports the exact stale-witness preflight failure without changing identity or migration state',
    );
    await afterHelper.close();
    final legacyApi = await openApi(legacyName);
    await assertDenied(legacyApi, readWitness(legacyWitness));
    await legacyApi.close();

    final interruptedName = '${prefix}_interrupted';
    final interruptedWitness =
        '${temporary.path}${Platform.pathSeparator}interrupted.witness';
    await copyWitness(interruptedWitness);
    migration = await openMigration(interruptedName);
    final interruptedOperation = upgradeId();
    final interrupted = RecoveryAuthority(
      interruptedWitness,
      testBarrier: (step) {
        if (step == 'schema_upgrade_before_commit_attempt') {
          throw StateError('simulated interruption before commit request');
        }
      },
    );
    var preCommitInterrupted = false;
    try {
      await interrupted.applySchemaUpgrade(
        migration,
        operationId: interruptedOperation,
        migrationManifestSha256: manifest,
        applyAndValidate: (tx) async {
          await PostgresMigrationRunner(
            migration,
            migrationDirectory,
          ).applyInTransaction(tx);
        },
      );
    } on RecoveryAdmissionUnavailable {
      preCommitInterrupted = true;
    }
    final rolledBackCount = await migration.execute(
      'SELECT count(*) FROM public.ventio_schema_migrations',
    );
    check(
      preCommitInterrupted &&
          rolledBackCount.single[0] == 30 &&
          readWitness(interruptedWitness)['pending'] == false,
      'Interrupted pre-commit upgrade rolls back DDL and restores only the unchanged ready witness',
    );
    await RecoveryAuthority(interruptedWitness).applySchemaUpgrade(
      migration,
      operationId: interruptedOperation,
      migrationManifestSha256: manifest,
      applyAndValidate: (tx) async {
        await PostgresMigrationRunner(
          migration,
          migrationDirectory,
        ).applyInTransaction(tx);
      },
    );
    check(
      readWitness(interruptedWitness)['pending'] == false,
      'Retry after a verified pre-commit interruption completes the same logical upgrade',
    );
    await migration.close();

    final ambiguousName = '${prefix}_ambiguous';
    final ambiguousWitness =
        '${temporary.path}${Platform.pathSeparator}ambiguous.witness';
    await copyWitness(ambiguousWitness);
    migration = await openMigration(ambiguousName);
    final ambiguousOperation = upgradeId();
    var unknownObserved = false;
    try {
      await RecoveryAuthority(
        ambiguousWitness,
        testBarrier: (step) {
          if (step == 'schema_upgrade_after_database_commit') {
            throw StateError('simulated lost commit acknowledgement');
          }
        },
      ).applySchemaUpgrade(
        migration,
        operationId: ambiguousOperation,
        migrationManifestSha256: manifest,
        applyAndValidate: (tx) async {
          await PostgresMigrationRunner(
            migration,
            migrationDirectory,
          ).applyInTransaction(tx);
        },
      );
    } on RecoveryMutationOutcomeUnknown {
      unknownObserved = true;
    }
    check(
      unknownObserved && readWitness(ambiguousWitness)['pending'] == true,
      'Lost commit acknowledgement leaves the witness pending and reports unknown outcome',
    );
    await RecoveryAuthority(ambiguousWitness).applySchemaUpgrade(
      migration,
      operationId: ambiguousOperation,
      migrationManifestSha256: manifest,
      applyAndValidate: (tx) async {
        await PostgresMigrationRunner(
          migration,
          migrationDirectory,
        ).applyInTransaction(tx);
      },
    );
    check(
      readWitness(ambiguousWitness)['pending'] == false,
      'Retry verifies the exact durable receipt and reconciles an ambiguous committed upgrade',
    );
    await migration.close();

    final preparedName = '${prefix}_prepared_retry';
    final preparedWitness =
        '${temporary.path}${Platform.pathSeparator}prepared-reconcile.witness';
    await copyWitness(preparedWitness);
    migration = await openMigration(preparedName);
    final preparedOperation = upgradeId();
    var preparationInterrupted = false;
    try {
      await RecoveryAuthority(
        preparedWitness,
        testBarrier: (step) {
          if (step == 'schema_upgrade_database_prepared') {
            throw StateError(
              'simulated process crash before commit authorization',
            );
          }
        },
      ).applySchemaUpgrade(
        migration,
        operationId: preparedOperation,
        migrationManifestSha256: manifest,
        applyAndValidate: (tx) async {
          await PostgresMigrationRunner(
            migration,
            migrationDirectory,
          ).applyInTransaction(tx);
        },
      );
    } on RecoveryAdmissionUnavailable {
      preparationInterrupted = true;
    }
    final interruptedWitnessState = readWitness(preparedWitness);
    final preparedCount = await migration.execute(
      pg.Sql.named('SELECT count(*) FROM pg_prepared_xacts WHERE gid=@gid'),
      parameters: {'gid': 'ventio_$preparedOperation'},
    );
    check(
      preparationInterrupted &&
          interruptedWitnessState['pending'] == false &&
          preparedCount.single[0] == 0 &&
          (await migration.execute(
                'SELECT count(*) FROM public.ventio_schema_migrations',
              )).single[0] ==
              30,
      'Crash after PREPARE but before witness commit authorization rolls back safely',
    );
    await RecoveryAuthority(preparedWitness).applySchemaUpgrade(
      migration,
      operationId: preparedOperation,
      migrationManifestSha256: manifest,
      applyAndValidate: (tx) async {
        await PostgresMigrationRunner(
          migration,
          migrationDirectory,
        ).applyInTransaction(tx);
      },
    );
    check(
      readWitness(preparedWitness)['pending'] == false,
      'Retry after an interrupted prepared transaction completes the same operation',
    );
    await migration.close();

    final unresolvedName = '${prefix}_unresolved';
    final unresolvedWitness =
        '${temporary.path}${Platform.pathSeparator}unresolved.witness';
    await copyWitness(unresolvedWitness);
    migration = await openMigration(unresolvedName);
    final unresolvedOperation = upgradeId();
    try {
      await RecoveryAuthority(
        unresolvedWitness,
        testBarrier: (step) {
          if (step == 'schema_upgrade_commit_authorized') {
            throw StateError('simulated Host crash after commit authorization');
          }
        },
      ).applySchemaUpgrade(
        migration,
        operationId: unresolvedOperation,
        migrationManifestSha256: manifest,
        applyAndValidate: (tx) async {
          await PostgresMigrationRunner(
            migration,
            migrationDirectory,
          ).applyInTransaction(tx);
        },
      );
    } on RecoveryMutationOutcomeUnknown {
      // The durable witness now authorizes commit; reconciliation must finish
      // that exact prepared transaction and must never silently roll it back.
    }
    final unresolvedWitnessState = readWitness(unresolvedWitness);
    check(
      unresolvedWitnessState['pending'] == true &&
          (unresolvedWitnessState['schemaUpgrade'] as Map)['phase'] ==
              'commit_authorized',
      'Commit authorization is durably recorded before PostgreSQL commit',
    );
    await migration.execute(
      "ROLLBACK PREPARED 'ventio_$unresolvedOperation'",
      queryMode: pg.QueryMode.simple,
    );
    var unresolvedClosed = false;
    try {
      await RecoveryAuthority(unresolvedWitness).applySchemaUpgrade(
        migration,
        operationId: unresolvedOperation,
        migrationManifestSha256: manifest,
        applyAndValidate: (tx) async {
          await PostgresMigrationRunner(
            migration,
            migrationDirectory,
          ).applyInTransaction(tx);
        },
      );
    } on RecoveryMutationOutcomeUnknown {
      unresolvedClosed = true;
    }
    check(
      unresolvedClosed && readWitness(unresolvedWitness)['pending'] == true,
      'Database rollback after commit authorization remains quarantined without its receipt',
    );
    await migration.close();

    final rollbackName = '${prefix}_rollback';
    final rollbackWitness =
        '${temporary.path}${Platform.pathSeparator}rollback.witness';
    await copyWitness(rollbackWitness);
    migration = await openMigration(rollbackName);
    final rollbackOperation = upgradeId();
    await RecoveryAuthority(rollbackWitness).applySchemaUpgrade(
      migration,
      operationId: rollbackOperation,
      migrationManifestSha256: manifest,
      applyAndValidate: (tx) async {
        await PostgresMigrationRunner(
          migration,
          migrationDirectory,
        ).applyInTransaction(tx);
      },
    );
    await migration.close();
    await root.execute('DROP DATABASE $rollbackName WITH (FORCE)');
    databases.remove(rollbackName);
    await clone('rollback');
    final rollbackApi = await openApi(rollbackName);
    await assertDenied(rollbackApi, readWitness(rollbackWitness));
    await rollbackApi.close();

    check(
      true,
      'All disposable Host schema upgrade recovery assertions completed ($assertions checks)',
    );
  } finally {
    for (final database in databases) {
      try {
        await root.execute('DROP DATABASE $database WITH (FORCE)');
      } catch (_) {
        // Isolated test cleanup is best-effort after the explicit teardown
        // below; no command targets a database outside its generated prefix.
      }
    }
    await root.close();
    if (await temporary.exists()) await temporary.delete(recursive: true);
  }
}
