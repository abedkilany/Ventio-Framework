import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_host_api/ventio_host_api.dart';
import 'package:ventio_postgres/ventio_postgres.dart';

/// Fixed, service-identity helper used only by the installed Host service for
/// a UAC-approved, local schema upgrade. It accepts a protected request on
/// stdin and executes only the files shipped in the verified Host payload.
Future<void> main() async {
  pg.Connection? connection;
  var stage = 'REQUEST_READ';
  try {
    final request = await _readRequest();
    stage = 'REQUEST_VALIDATION';
    final operationId = request['operationId'] as String;
    final databaseUrl = request['databaseUrl'] as String;
    final database = Uri.parse(databaseUrl);
    if (!RegExp(r'^upgrade_[0-9a-f]{32}$').hasMatch(operationId) ||
        database.scheme != 'postgresql' ||
        database.host != '127.0.0.1' ||
        database.userInfo.split(':').first != 'ventio_migrator_app' ||
        database.path != '/ventio_host' ||
        (database.port != 54329 &&
            !Platform.environment.containsKey(
              'VENTIO_HOST_UPGRADE_TEST_MODE',
            ))) {
      throw const _UpgradeFailure('REQUEST_INVALID');
    }
    stage = 'HOST_CONFIGURATION_VALIDATION';
    final witnessPath = Platform.environment['VENTIO_RECOVERY_AUTHORITY_FILE'];
    final ownerSid =
        Platform.environment['VENTIO_RECOVERY_AUTHORITY_OWNER_SID'];
    final readerSid =
        Platform.environment['VENTIO_RECOVERY_AUTHORITY_READER_SID'];
    final migrationPath =
        Platform.environment['VENTIO_MIGRATIONS_DIR'] ??
        '${Directory.current.path}${Platform.pathSeparator}migrations';
    final securityPath =
        Platform.environment['VENTIO_SECURITY_DIR'] ??
        '${Directory.current.path}${Platform.pathSeparator}security';
    if (witnessPath == null ||
        ownerSid == null ||
        readerSid == null ||
        Platform.environment['VENTIO_RECOVERY_AUTHORITY_HOST_WRITES'] !=
            'yes' ||
        !Platform.isWindows) {
      throw const _UpgradeFailure('HOST_CONFIGURATION_INVALID');
    }
    final migrations = Directory(migrationPath);
    final security = Directory(securityPath);
    if (!await migrations.exists() || !await security.exists()) {
      throw const _UpgradeFailure('PAYLOAD_INCOMPLETE');
    }

    stage = 'MIGRATION_MANIFEST_VALIDATION';
    final manifest = await _migrationManifest(migrations);
    stage = 'DATABASE_CONNECTION';
    connection = await pg.Connection.openFromUrl(databaseUrl);
    stage = 'DATABASE_ROLE_SWITCH';
    await connection.execute('SET ROLE ventio_owner');
    stage = 'PREPARED_TRANSACTION_PREFLIGHT';
    final preparedTransactions = await connection.execute(
      'SHOW max_prepared_transactions',
    );
    if (preparedTransactions.isEmpty ||
        int.tryParse(preparedTransactions.single[0] as String) == null ||
        int.parse(preparedTransactions.single[0] as String) < 1) {
      throw const _UpgradeFailure('PREPARED_TRANSACTIONS_UNAVAILABLE');
    }
    final authority = RecoveryAuthority(
      witnessPath,
      trustedOwnerSid: ownerSid,
      readerSid: readerSid,
      allowHostMutations: true,
    );
    final runner = PostgresMigrationRunner(connection, migrations);
    stage = 'RECOVERY_AUTHORITY_FINGERPRINT_PREFLIGHT';
    final admission = await authority.inspectSchemaUpgradeAdmission(connection);
    if (admission ==
        SchemaUpgradeAdmissionDiagnostic.databaseFingerprintMismatch) {
      throw const _UpgradeFailure(
        'RECOVERY_FINGERPRINT_MISMATCH',
        stage: 'RECOVERY_AUTHORITY_FINGERPRINT_PREFLIGHT',
      );
    }
    if (admission == SchemaUpgradeAdmissionDiagnostic.unavailable) {
      throw const _UpgradeFailure(
        'RECOVERY_ADMISSION_UNAVAILABLE',
        stage: 'RECOVERY_AUTHORITY_FINGERPRINT_PREFLIGHT',
      );
    }
    // A pending witness may be a crash-interrupted schema upgrade. Let the
    // existing operation-ID and receipt reconciliation logic decide whether
    // this exact transition can resume; never clear or rewrite it here.
    stage = 'RECOVERY_AUTHORITY_SCHEMA_ADMISSION';
    await authority.applySchemaUpgrade(
      connection,
      operationId: operationId,
      migrationManifestSha256: manifest,
      applyAndValidate: (tx) async {
        await runner.applyInTransaction(tx);
      },
    );

    stage = 'SECURITY_CONTRACT_APPLICATION';
    await _applyContracts(database, security);
    stage = 'POST_UPGRADE_CONTRACT_VERIFICATION';
    await _verifyUpgrade(connection, migrations);
    stdout.writeln(
      jsonEncode({'status': 'complete', 'operationId': operationId}),
    );
  } on _UpgradeFailure catch (error) {
    stdout.writeln(
      jsonEncode({
        'status': 'failed',
        'failureCode': error.code,
        'failureStage': error.stage ?? stage,
      }),
    );
    exitCode = 2;
  } on RecoveryMutationOutcomeUnknown {
    stdout.writeln(
      jsonEncode({
        'status': 'unknown',
        'failureCode': 'OUTCOME_UNKNOWN',
        'failureStage': stage,
      }),
    );
    exitCode = 3;
  } on RecoveryAdmissionUnavailable {
    stdout.writeln(
      jsonEncode({
        'status': 'failed',
        'failureCode': 'RECOVERY_ADMISSION',
        'failureStage': stage,
      }),
    );
    exitCode = 2;
  } on Object {
    stdout.writeln(
      jsonEncode({
        'status': 'failed',
        'failureCode': 'UPGRADE_FAILED',
        'failureStage': stage,
      }),
    );
    exitCode = 2;
  } finally {
    await connection?.close();
  }
}

Future<Map<String, dynamic>> _readRequest() async {
  final bytes = <int>[];
  await for (final chunk in stdin) {
    if (bytes.length + chunk.length > 16384) {
      throw const _UpgradeFailure('REQUEST_INVALID');
    }
    bytes.addAll(chunk);
  }
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 2 ||
        decoded.keys.toSet().difference({
          'operationId',
          'databaseUrl',
        }).isNotEmpty ||
        decoded['operationId'] is! String ||
        decoded['databaseUrl'] is! String ||
        (decoded['databaseUrl'] as String).length > 4096) {
      throw const _UpgradeFailure('REQUEST_INVALID');
    }
    return decoded;
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

Future<String> _migrationManifest(Directory migrations) async {
  final files = await migrations
      .list(followLinks: false)
      .where((entity) => entity is File && entity.path.endsWith('.sql'))
      .cast<File>()
      .toList();
  files.sort(
    (left, right) =>
        left.uri.pathSegments.last.compareTo(right.uri.pathSegments.last),
  );
  final rows = <String>[];
  for (final file in files) {
    final name = file.uri.pathSegments.last;
    final canonical = canonicalMigrationSql(await file.readAsString());
    rows.add('$name:${migrationChecksum(canonical)}');
  }
  return sha256.convert(utf8.encode('${rows.join('\n')}\n')).toString();
}

Future<void> _applyContracts(Uri database, Directory security) async {
  final password = Uri.decodeComponent(
    database.userInfo.split(':').skip(1).join(':'),
  );
  final psql = File(
    '${Directory.current.path}${Platform.pathSeparator}postgresql${Platform.pathSeparator}bin${Platform.pathSeparator}psql.exe',
  );
  if (!await psql.exists()) throw const _UpgradeFailure('PAYLOAD_INCOMPLETE');
  for (final contract in [
    'pairing.sql',
    'credential_reissues.sql',
    'wave2_upgrade.sql',
    'schema_profile.sql',
  ]) {
    final path = File('${security.path}${Platform.pathSeparator}$contract');
    if (!await path.exists()) throw const _UpgradeFailure('PAYLOAD_INCOMPLETE');
    final process = await Process.start(
      psql.path,
      [
        '-X',
        '-w',
        '-h',
        '127.0.0.1',
        '-p',
        '${database.port}',
        '-U',
        'ventio_migrator_app',
        '-d',
        'ventio_host',
        '-v',
        'ON_ERROR_STOP=1',
        '-c',
        'SET ROLE ventio_owner',
        '-f',
        path.path,
      ],
      environment: {
        'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
        'WINDIR': Platform.environment['WINDIR'] ?? r'C:\Windows',
        if (Platform.environment['SystemDrive'] != null)
          'SystemDrive': Platform.environment['SystemDrive']!,
        if (Platform.environment['TEMP'] != null)
          'TEMP': Platform.environment['TEMP']!,
        if (Platform.environment['TMP'] != null)
          'TMP': Platform.environment['TMP']!,
        'PATH':
            '${Directory.current.path}${Platform.pathSeparator}postgresql${Platform.pathSeparator}bin',
        'PGPASSWORD': password,
      },
      includeParentEnvironment: false,
      workingDirectory: Directory.current.path,
      runInShell: false,
    );
    final out = process.stdout.drain<void>();
    final err = process.stderr.drain<void>();
    final timer = Timer(const Duration(minutes: 3), () {
      process.kill(ProcessSignal.sigkill);
    });
    final code = await process.exitCode;
    timer.cancel();
    await Future.wait([out, err]);
    if (code != 0) {
      final stage = switch (contract) {
        'pairing.sql' => 'SECURITY_CONTRACT_PAIRING',
        'credential_reissues.sql' => 'SECURITY_CONTRACT_CREDENTIAL_REISSUE',
        'schema_profile.sql' => 'SECURITY_CONTRACT_SCHEMA_PROFILE',
        _ => 'SECURITY_CONTRACT_APPLICATION',
      };
      throw _UpgradeFailure('SECURITY_CONTRACT_FAILED', stage: stage);
    }
  }
}

Future<void> _verifyUpgrade(
  pg.Connection connection,
  Directory migrations,
) async {
  await connection.execute('SELECT ventio_security.assert_schema()');
  final count = await connection.execute(
    'SELECT count(*) FROM public.ventio_schema_migrations',
  );
  final expected = await migrations
      .list(followLinks: false)
      .where((entity) => entity is File && entity.path.endsWith('.sql'))
      .length;
  if ((count.single[0] as int) != expected) {
    throw const _UpgradeFailure('MIGRATION_LEDGER_INVALID');
  }
  final flags = await connection.execute('''
    SELECT relrowsecurity AND relforcerowsecurity
    FROM pg_class WHERE oid='public.host_schema_upgrade_receipts'::regclass
  ''');
  if (flags.isEmpty || flags.single[0] != true) {
    throw const _UpgradeFailure('UPGRADE_RECEIPT_PROFILE_INVALID');
  }
  final pairing = await connection.execute('''
    SELECT position('Pairing request was already accepted' IN
      pg_get_functiondef('ventio_security.scoped_pairing_create(text,text,text,text,text,text)'::regprocedure)) > 0
      AND position('TRUSTED_PAIRING_CREATED' IN
      pg_get_functiondef('ventio_security.trusted_windows_pairing_create(text,text,text,text,text,text,text,text,text[],text)'::regprocedure)) > 0
      AND position('CREDENTIAL_CEILING_DENIED' IN
      pg_get_functiondef('ventio_security.permission_denial_reason(text,text,text,text,text)'::regprocedure)) > 0
      AND has_function_privilege('ventio_identity_api',
        'ventio_security.trusted_windows_pairing_create(text,text,text,text,text,text,text,text,text[],text)','EXECUTE')
      AND NOT has_function_privilege('ventio_runtime',
        'ventio_security.trusted_windows_pairing_create(text,text,text,text,text,text,text,text,text[],text)','EXECUTE')
      AND has_function_privilege('ventio_identity_api',
        'ventio_security.permission_denial_reason(text,text,text,text,text)','EXECUTE')
      AND NOT has_function_privilege('ventio_runtime',
        'ventio_security.permission_denial_reason(text,text,text,text,text)','EXECUTE')
  ''');
  if (pairing.isEmpty || pairing.single[0] != true) {
    throw const _UpgradeFailure('PAIRING_CONTRACT_INVALID');
  }
  final reissue = await connection.execute('''
    SELECT jsonb_build_array(
      has_function_privilege('ventio_identity_api','ventio_security.trusted_windows_credential_reissue_prepare(text,text,text,text,text,text,text,text,text,text,text,bytea,text[],text[],text)','EXECUTE'),
      NOT has_function_privilege('ventio_runtime','ventio_security.trusted_windows_credential_reissue_prepare(text,text,text,text,text,text,text,text,text,text,text,bytea,text[],text[],text)','EXECUTE'),
      has_function_privilege('ventio_identity_api','ventio_security.credential_reissue_claim(text,text)','EXECUTE'),
      has_function_privilege('ventio_identity_api','ventio_security.credential_reissue_pending_claim(text)','EXECUTE'),
      has_function_privilege('ventio_identity_api','ventio_security.credential_reissue_finalize(text,text)','EXECUTE'),
      has_function_privilege('ventio_identity_api','ventio_security.assert_schema()','EXECUTE'),
      (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid='public.ventio_identity_credential_reissues'::regclass),
      (SELECT count(*)=2 FROM pg_trigger WHERE tgrelid='public.ventio_identity_credential_reissues'::regclass AND NOT tgisinternal AND tgname IN ('ventio_recovery_lock','ventio_recovery_mark'))
    )::text
  ''');
  if (reissue.isEmpty ||
      reissue.single[0] != '[true, true, true, true, true, true, true, true]') {
    throw const _UpgradeFailure('CREDENTIAL_REISSUE_CONTRACT_INVALID');
  }
}

class _UpgradeFailure implements Exception {
  const _UpgradeFailure(this.code, {this.stage});
  final String code;
  final String? stage;
}
