// Destructive operations are restricted to the explicitly selected CI fixture.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;

import '../test_support.dart'
    show createPrivateTestDirectory, hasPrivateTestFilePermissions;
import 'support.dart';

class DatabaseFixture {
  final String source;
  final String sourceUrl;
  final bool _nativeProcess;
  final String? dataDirectory;
  final String? binaryDirectory;
  final int? port;
  final File? serverLog;
  String? restored;
  Directory? temporary;
  String? _restoredDataDirectory;
  int? _restoredPort;

  DatabaseFixture._container(this.source, this.sourceUrl)
    : _nativeProcess = false,
      dataDirectory = null,
      binaryDirectory = null,
      port = null,
      serverLog = null;

  DatabaseFixture._process({
    required this.source,
    required this.sourceUrl,
    required this.dataDirectory,
    required this.binaryDirectory,
    required this.port,
    required this.serverLog,
  }) : _nativeProcess = true;

  static Future<DatabaseFixture> guarded(String url) async {
    final env = Platform.environment;
    final uri = Uri.parse(url);
    if (env['VENTIO_ALLOW_POSTGRES_CRASH_TEST'] != 'yes' ||
        env['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
        !{'localhost', '127.0.0.1'}.contains(uri.host) ||
        uri.path != '/ventio_host_test') {
      throw StateError(
        'Explicit disposable CI database authorization required',
      );
    }

    if (env['VENTIO_TEST_POSTGRES_MODE'] == 'process') {
      final runLabel = env['VENTIO_CI_RUN_LABEL'] ?? '';
      final temp = env['RUNNER_TEMP'];
      final data = env['VENTIO_TEST_POSTGRES_DATA_DIRECTORY'];
      final binary = env['VENTIO_TEST_POSTGRES_BIN_DIR'];
      final port = int.tryParse(env['VENTIO_TEST_POSTGRES_PORT'] ?? '');
      final log = env['VENTIO_TEST_POSTGRES_LOG_FILE'];
      if (!RegExp(r'^\d+-\d+$').hasMatch(runLabel) ||
          temp == null ||
          data == null ||
          binary == null ||
          port == null ||
          log == null) {
        throw StateError(
          'Disposable PostgreSQL process metadata is incomplete',
        );
      }
      final expectedRoot =
          '${Directory(temp).absolute.path}${Platform.pathSeparator}'
          'ventio-pg-$runLabel';
      final expectedData = '$expectedRoot${Platform.pathSeparator}data';
      final dataPath = Directory(data).absolute.path;
      final samePath = Platform.isWindows
          ? dataPath.toLowerCase() == expectedData.toLowerCase()
          : dataPath == expectedData;
      final guardFailures = <String>[
        if (!samePath) 'data path is outside this run fixture',
        if (uri.port != port) 'connection URL uses a different port',
        if (!RegExp(
          r'^postgresql://ventio:ventio_test_only@127\.0\.0\.1:',
        ).hasMatch(url))
          'connection URL is not the loopback test credential',
        if (!File('$binary${Platform.pathSeparator}postgres.exe').existsSync())
          'PostgreSQL server binary is missing',
        if (!File('$binary${Platform.pathSeparator}pg_ctl.exe').existsSync())
          'PostgreSQL control binary is missing',
        if (!await hasPrivateTestFilePermissions(expectedRoot))
          'fixture ACL is not private',
      ];
      if (guardFailures.isNotEmpty) {
        throw StateError(
          'PostgreSQL process does not match the private CI fixture: '
          '${guardFailures.join('; ')}',
        );
      }
      final fixture = DatabaseFixture._process(
        source: dataPath,
        sourceUrl: url,
        dataDirectory: dataPath,
        binaryDirectory: binary,
        port: port,
        serverLog: File(log),
      );
      final connection = await pg.Connection.openFromUrl(url);
      try {
        final rows = await connection.execute(
          "SELECT current_database(), inet_server_addr()::text, inet_server_port(), current_setting('data_directory'), version()",
        );
        final row = rows.single;
        final serverAddress = row[1] as String;
        final actualData = Directory(
          Platform.isWindows
              ? (row[3] as String).replaceAll('/', Platform.pathSeparator)
              : row[3] as String,
        ).absolute.path;
        final serverFailures = <String>[
          if (row[0] != 'ventio_host_test') 'unexpected database name',
          if (!RegExp(r'^127\.0\.0\.1(?:/32)?$').hasMatch(serverAddress))
            'server is not bound to IPv4 loopback',
          if (row[2] != port) 'connected server port does not match fixture',
          if (Platform.isWindows
              ? actualData.toLowerCase() != dataPath.toLowerCase()
              : actualData != dataPath)
            'server data path does not match fixture',
          if (!(row[4] as String).startsWith('PostgreSQL 16.'))
            'server version is not PostgreSQL 16',
        ];
        if (serverFailures.isNotEmpty) {
          throw StateError(
            'Connected PostgreSQL server is outside the fixture: '
            '${serverFailures.join('; ')}',
          );
        }
      } finally {
        await connection.close();
      }
      return fixture;
    }

    // The Linux engineering gate retains its isolated postgres:16 service.
    final id = env['VENTIO_TEST_POSTGRES_CONTAINER_ID'] ?? '';
    final runLabel = env['VENTIO_CI_RUN_LABEL'] ?? '';
    if (!RegExp(r'^\d+-\d+$').hasMatch(runLabel) ||
        !RegExp(r'^[a-f0-9]{12,64}$').hasMatch(id)) {
      throw StateError(
        'Explicit disposable CI container authorization required',
      );
    }
    final fixture = DatabaseFixture._container(id, url);
    final inspected = jsonDecode(await fixture.docker(['inspect', id])) as List;
    final info = inspected.single as Map;
    final config = info['Config'] as Map;
    final labels = config['Labels'] as Map? ?? const {};
    final ports = info['NetworkSettings']['Ports']['5432/tcp'] as List;
    if (config['Image'] != 'postgres:16' ||
        (labels['io.ventio.ci.fixture'] != null &&
            labels['io.ventio.ci.fixture'] != 'postgres-test') ||
        (labels['io.ventio.ci.run'] != null &&
            labels['io.ventio.ci.run'] != runLabel) ||
        !(config['Env'] as List).contains('POSTGRES_DB=ventio_host_test') ||
        !(config['Env'] as List).contains('POSTGRES_USER=ventio') ||
        !ports.any((p) => int.parse(p['HostPort'] as String) == uri.port)) {
      throw StateError('Container does not match the disposable test database');
    }
    return fixture;
  }

  Future<String> docker(List<String> arguments) async {
    final result = await Process.run(
      'docker',
      arguments,
    ).timeout(const Duration(seconds: 45));
    if (result.exitCode != 0)
      throw StateError('Fixture Docker operation failed: ${arguments.first}');
    return result.stdout as String;
  }

  Future<void> pipe(List<String> arguments, File input) async {
    final process = await Process.start('docker', arguments);
    final output = process.stdout.drain<void>();
    final errors = process.stderr.transform(utf8.decoder).join();
    await process.stdin.addStream(input.openRead());
    await process.stdin.close();
    if (await process.exitCode.timeout(const Duration(seconds: 45)) != 0) {
      final diagnostic = (await errors).split('\n').first;
      throw StateError('Restore operation failed: $diagnostic');
    }
    await output;
    await errors;
  }

  Future<void> capture(List<String> arguments, File output) async {
    final process = await Process.start('docker', arguments);
    final errors = process.stderr.drain<void>();
    await process.stdout.pipe(output.openWrite());
    if (await process.exitCode.timeout(const Duration(seconds: 45)) != 0) {
      throw StateError('Backup operation failed');
    }
    await errors;
  }

  Future<void> capturePipe(
    List<String> arguments,
    File input,
    File output,
  ) async {
    final process = await Process.start('docker', arguments);
    final errors = process.stderr.transform(utf8.decoder).join();
    final stdoutDone = process.stdout.pipe(output.openWrite());
    await process.stdin.addStream(input.openRead());
    await process.stdin.close();
    final exitCode = await process.exitCode.timeout(const Duration(minutes: 5));
    await stdoutDone;
    final diagnostic = await errors;
    if (exitCode != 0) {
      throw StateError(
        'PostgreSQL restore-script export failed '
        '(exit=$exitCode; diagnostic=${_safeDiagnostic(diagnostic)})',
      );
    }
  }

  String _safeDiagnostic(String value) {
    final sanitized = value
        .replaceAll(
          RegExp(r'postgres(?:ql)?://\S+', caseSensitive: false),
          'postgresql://[redacted]',
        )
        .replaceAll(
          RegExp(
            r'(password|token|secret)\s*[=:]\s*[^\s,;]+',
            caseSensitive: false,
          ),
          '[redacted]',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return sanitized.length <= 512
        ? sanitized
        : '${sanitized.substring(0, 512)}…';
  }

  Future<void> restartAfterKill() async {
    if (_nativeProcess) {
      final data = dataDirectory!;
      final bin = binaryDirectory!;
      final log = serverLog!.path;
      await _runPgTool('pg_ctl', [
        '-D',
        data,
        '-m',
        'immediate',
        '-w',
        '-t',
        '30',
        'stop',
      ]);
      final stopped = await _runPgTool('pg_ctl', [
        '-D',
        data,
        'status',
      ], allowFailure: true);
      if (stopped.exitCode == 0) {
        throw StateError('PostgreSQL remained online after immediate shutdown');
      }
      await _startNativeCluster(
        dataDirectory: data,
        port: port!,
        password: 'ventio_test_only',
        logFile: log,
        binaryDirectory: bin,
      );
      await ready(sourceUrl);
      return;
    }
    await docker(['kill', '--signal', 'KILL', source]);
    final state =
        (jsonDecode(await docker(['inspect', source])) as List).single['State'];
    if (state['ExitCode'] != 137 || state['OOMKilled'] != false) {
      throw StateError(
        'PostgreSQL container did not exit from deliberate SIGKILL',
      );
    }
    await docker(['start', source]);
    await ready(sourceUrl);
  }

  Future<void> ready(String url) async {
    await waitFor(() async {
      try {
        final db = await pg.Connection.openFromUrl(url);
        await db.close();
        return true;
      } catch (_) {
        return false;
      }
    }, 'PostgreSQL restart');
  }

  Future<String> backupAndRestore(pg.Connection sourceConnection) async {
    temporary = _nativeProcess
        ? await _createRecoveryDirectory()
        : await createPrivateTestDirectory('ventio-recovery-');
    final dump = File('${temporary!.path}/database.dump');
    final globals = File('${temporary!.path}/roles.sql');
    final sequenceAcls = File('${temporary!.path}/sequence-acls.sql');
    await sequenceAcls.writeAsString(
      await exportSequenceAcls(sourceConnection),
    );
    if (_nativeProcess) {
      await _capturePgTool(
        'pg_dump',
        ['--dbname=$sourceUrl', '--format=custom'],
        dump,
        password: 'ventio_test_only',
      );
      await _capturePgTool(
        'pg_dumpall',
        [
          '--dbname=${_controlUrl(sourceUrl)}',
          '--roles-only',
          '--no-role-passwords',
        ],
        globals,
        password: 'ventio_test_only',
      );
    } else {
      await capture([
        'exec',
        source,
        'pg_dump',
        '-U',
        'ventio',
        '-d',
        'ventio_host_test',
        '-Fc',
      ], dump);
      // Roles and memberships are cluster objects. Passwords are deliberately excluded.
      await capture([
        'exec',
        source,
        'pg_dumpall',
        '-U',
        'ventio',
        '--roles-only',
        '--no-role-passwords',
      ], globals);
    }
    // PostgreSQL 16 treats the cluster bootstrap grantor (OID 10) specially.
    // Preserve its source name/identity by initializing the target with ventio.
    // Only its redundant CREATE is omitted; its dumped attributes, memberships,
    // grantors and options are replayed unchanged. Passwords are provisioned anew.
    final rolesSql = await globals.readAsString();
    const bootstrapCreate = 'CREATE ROLE ventio;';
    if (bootstrapCreate.allMatches(rolesSql).length != 1) {
      throw StateError(
        'Expected exactly one trusted bootstrap role definition',
      );
    }
    final replay = File('${temporary!.path}/roles-replay.sql');
    await replay.writeAsString(
      rolesSql.replaceFirst(
        bootstrapCreate,
        '-- Bootstrap role already exists in this fresh cluster.',
      ),
    );
    late final String control;
    if (_nativeProcess) {
      final restoreData =
          '${temporary!.path}${Platform.pathSeparator}restored-data';
      final restoreLog =
          '${temporary!.path}${Platform.pathSeparator}restored-postgres.log';
      final restorePort = await _findLoopbackPort();
      _restoredDataDirectory = restoreData;
      _restoredPort = restorePort;
      _restoredPassword = 'restore_fixture_only';
      await _startNativeCluster(
        dataDirectory: restoreData,
        port: restorePort,
        password: _restoredPassword!,
        logFile: restoreLog,
        binaryDirectory: binaryDirectory!,
      );
      restored = restoreData;
      control = _controlUrl(
        'postgresql://ventio:restore_fixture_only@127.0.0.1:$restorePort/postgres?sslmode=disable',
      );
    } else {
      restored = (await docker([
        'run',
        '--detach',
        '--name',
        'ventio-restore-${DateTime.now().microsecondsSinceEpoch}',
        '--label',
        'io.ventio.ci.fixture=postgres-test',
        '--label',
        'io.ventio.ci.run=${Platform.environment['VENTIO_CI_RUN_LABEL']}',
        '--env',
        'POSTGRES_USER=ventio',
        '--env',
        'POSTGRES_PASSWORD=restore_fixture_only',
        '--env',
        'POSTGRES_DB=postgres',
        '--publish',
        '127.0.0.1::5432',
        'postgres:16',
      ])).trim();
      final mapping = (await docker(['port', restored!, '5432/tcp'])).trim();
      final restorePort = int.parse(mapping.split(':').last);
      control =
          'postgresql://ventio:restore_fixture_only@127.0.0.1:$restorePort/postgres?sslmode=disable&connect_timeout=2';
    }
    await ready(control);
    if (_nativeProcess) {
      await _pipePgTool(
        'psql',
        ['-X', '-v', 'ON_ERROR_STOP=1', '--dbname=$control'],
        replay,
        password: _restoredPassword,
      );
    } else {
      await pipe([
        'exec',
        '-i',
        restored!,
        'psql',
        '-X',
        '-v',
        'ON_ERROR_STOP=1',
        '-U',
        'ventio',
        '-d',
        'postgres',
      ], replay);
    }
    // The custom archive omits extension owners. Export its SQL, then assign
    // pgcrypto to the reviewed private owner at creation time during restore.
    // This keeps the restore login and database ownership unchanged.
    final restoreScript = File('${temporary!.path}/restore.sql');
    if (_nativeProcess) {
      await _capturePgTool('pg_restore', [
        '--create',
        '--file=-',
        dump.path,
      ], restoreScript);
    } else {
      await capturePipe(
        ['exec', '-i', restored!, 'pg_restore', '--create', '--file=-'],
        dump,
        restoreScript,
      );
    }
    final restoreSql = (await restoreScript.readAsString()).replaceAll(
      '\r\r\n',
      '\r\n',
    );
    const extensionDdl =
        'CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA ventio_crypto;';
    if (extensionDdl.allMatches(restoreSql).length != 1) {
      throw StateError(
        'PostgreSQL archive has an unsupported extension profile',
      );
    }
    await restoreScript.writeAsString(
      restoreSql.replaceFirst(
        extensionDdl,
        'GRANT CREATE ON DATABASE ventio_host_test TO ventio_owner;\n'
        'SET ROLE ventio_owner;\n$extensionDdl\nRESET ROLE;',
      ),
    );
    if (_nativeProcess) {
      await _runPgTool('psql', [
        '-X',
        '-v',
        'ON_ERROR_STOP=1',
        '--dbname=$control',
        '--file=${restoreScript.path}',
      ], password: _restoredPassword);
    } else {
      await pipe([
        'exec',
        '-i',
        restored!,
        'psql',
        '-X',
        '-v',
        'ON_ERROR_STOP=1',
        '-U',
        'ventio',
        '-d',
        'postgres',
      ], restoreScript);
    }
    final restoredDatabase = control.replaceFirst(
      '/postgres?',
      '/ventio_host_test?',
    );
    // Explicit source ACL snapshot is a required backup component: PG16's
    // identity-sequence recreation may differ from the source's owner ACL.
    final restoredDatabaseUrl = restoredDatabase;
    if (_nativeProcess) {
      await _pipePgTool(
        'psql',
        ['-X', '-v', 'ON_ERROR_STOP=1', '--dbname=$restoredDatabaseUrl'],
        sequenceAcls,
        password: _restoredPassword,
      );
    } else {
      await pipe([
        'exec',
        '-i',
        restored!,
        'psql',
        '-X',
        '-v',
        'ON_ERROR_STOP=1',
        '-U',
        'ventio',
        '-d',
        'ventio_host_test',
      ], sequenceAcls);
    }
    return restoredDatabaseUrl;
  }

  Future<void> provisionRestoredPasswords() async {
    // Test fixture secrets only; backup contains no login password hashes.
    if (_nativeProcess) {
      await _runPgTool('psql', [
        '-X',
        '-v',
        'ON_ERROR_STOP=1',
        '--dbname=${_restoredDatabaseUrl()}',
        '-c',
        "ALTER ROLE ventio_runtime_test PASSWORD 'runtime_test_only'; ALTER ROLE ventio_admin_test PASSWORD 'admin_test_only'; ALTER ROLE ventio_migration_test PASSWORD 'migration_test_only';",
      ], password: _restoredPassword);
      return;
    }
    await docker([
      'exec',
      restored!,
      'psql',
      '-X',
      '-v',
      'ON_ERROR_STOP=1',
      '-U',
      'ventio',
      '-d',
      'ventio_host_test',
      '-c',
      "ALTER ROLE ventio_runtime_test PASSWORD 'runtime_test_only'; ALTER ROLE ventio_admin_test PASSWORD 'admin_test_only'; ALTER ROLE ventio_migration_test PASSWORD 'migration_test_only';",
    ]);
  }

  Future<void> close() async {
    if (_nativeProcess && _restoredDataDirectory != null) {
      await _runPgTool('pg_ctl', [
        '-D',
        _restoredDataDirectory!,
        '-m',
        'immediate',
        '-w',
        '-t',
        '30',
        'stop',
      ], allowFailure: true);
      final status = await _runPgTool('pg_ctl', [
        '-D',
        _restoredDataDirectory!,
        'status',
      ], allowFailure: true);
      if (status.exitCode == 0) {
        throw StateError(
          'Refusing to delete a running restored PostgreSQL cluster',
        );
      }
    }
    if (restored != null)
      if (!_nativeProcess)
        await docker(['rm', '--force', '--volumes', restored!]);
    if (temporary != null) await temporary!.delete(recursive: true);
  }

  String? _restoredPassword;

  String _restoredDatabaseUrl() {
    final restoredPort = _restoredPort;
    if (restoredPort == null)
      throw StateError('Restore database is unavailable');
    return 'postgresql://ventio:restore_fixture_only@127.0.0.1:$restoredPort/ventio_host_test?sslmode=disable';
  }

  Future<ProcessResult> _runPgTool(
    String tool,
    List<String> arguments, {
    String? password,
    bool allowFailure = false,
  }) async {
    final binary = binaryDirectory;
    if (binary == null)
      throw StateError('Native PostgreSQL tools are unavailable');
    final result = await Process.run(
      '$binary${Platform.pathSeparator}$tool.exe',
      arguments,
      environment: {
        ...Platform.environment,
        if (password != null) 'PGPASSWORD': password,
      },
    ).timeout(const Duration(minutes: 2));
    if (!allowFailure && result.exitCode != 0) {
      throw StateError('PostgreSQL ${tool} operation failed');
    }
    return result;
  }

  Future<void> _capturePgTool(
    String tool,
    List<String> arguments,
    File output, {
    String? password,
  }) async {
    final binary = binaryDirectory;
    if (binary == null)
      throw StateError('Native PostgreSQL tools are unavailable');
    final process = await Process.start(
      '$binary${Platform.pathSeparator}$tool.exe',
      arguments,
      environment: {
        ...Platform.environment,
        if (password != null) 'PGPASSWORD': password,
      },
    );
    final errors = process.stderr.drain<void>();
    await process.stdout.pipe(output.openWrite());
    if (await process.exitCode.timeout(const Duration(minutes: 5)) != 0) {
      await errors;
      throw StateError('PostgreSQL $tool backup operation failed');
    }
    await errors;
  }

  Future<void> _pipePgTool(
    String tool,
    List<String> arguments,
    File input, {
    String? password,
  }) async {
    final binary = binaryDirectory;
    if (binary == null)
      throw StateError('Native PostgreSQL tools are unavailable');
    final process = await Process.start(
      '$binary${Platform.pathSeparator}$tool.exe',
      arguments,
      environment: {
        ...Platform.environment,
        if (password != null) 'PGPASSWORD': password,
      },
    );
    final output = process.stdout.drain<void>();
    final errors = process.stderr.drain<void>();
    await process.stdin.addStream(input.openRead());
    await process.stdin.close();
    if (await process.exitCode.timeout(const Duration(minutes: 5)) != 0) {
      await output;
      await errors;
      throw StateError('PostgreSQL $tool restore operation failed');
    }
    await output;
    await errors;
  }

  Future<void> _startNativeCluster({
    required String dataDirectory,
    required int port,
    required String password,
    required String logFile,
    required String binaryDirectory,
  }) async {
    final passwordFile = File(
      '${Directory(dataDirectory).parent.path}${Platform.pathSeparator}'
      'bootstrap-password.txt',
    );
    if (!File(
      '$dataDirectory${Platform.pathSeparator}PG_VERSION',
    ).existsSync()) {
      await Directory(dataDirectory).parent.create(recursive: true);
      await passwordFile.writeAsString(password, flush: true);
      final init = await Process.run(
        '$binaryDirectory${Platform.pathSeparator}initdb.exe',
        [
          '-D',
          dataDirectory,
          '-U',
          'ventio',
          '--auth-local=scram-sha-256',
          '--auth-host=scram-sha-256',
          '--pwfile=${passwordFile.path}',
          '--encoding=UTF8',
          '--no-sync',
        ],
        environment: {...Platform.environment},
      ).timeout(const Duration(minutes: 2));
      await passwordFile.delete();
      if (init.exitCode != 0) {
        throw StateError('Could not initialize restored PostgreSQL cluster');
      }
    }
    final start = await Process.start(
      '$binaryDirectory${Platform.pathSeparator}pg_ctl.exe',
      [
        '-D',
        dataDirectory,
        '-l',
        logFile,
        '-o',
        '-h 127.0.0.1 -p $port -c listen_addresses=127.0.0.1 -c logging_collector=off',
        '-w',
        '-t',
        '60',
        'start',
      ],
      environment: {...Platform.environment},
    );
    final stdout = start.stdout.listen((_) {});
    final stderr = start.stderr.listen((_) {});
    try {
      final exitCode = await start.exitCode.timeout(
        const Duration(seconds: 90),
      );
      if (exitCode != 0) {
        throw StateError('Could not start restored PostgreSQL cluster');
      }
    } finally {
      await stdout.cancel();
      await stderr.cancel();
    }
  }

  Future<int> _findLoopbackPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final found = socket.port;
    await socket.close();
    return found;
  }

  Future<Directory> _createRecoveryDirectory() async {
    final sourceData = dataDirectory;
    if (sourceData == null) {
      throw StateError('Native PostgreSQL fixture data path is unavailable');
    }
    final fixtureRoot = Directory(sourceData).parent.path;
    final directory = Directory(
      '$fixtureRoot${Platform.pathSeparator}recovery-$pid-'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    final normalized = directory.absolute.path;
    final normalizedRoot = Directory(fixtureRoot).absolute.path;
    final isInsideFixture = Platform.isWindows
        ? normalized.toLowerCase().startsWith(
            '${normalizedRoot.toLowerCase()}${Platform.pathSeparator}',
          )
        : normalized.startsWith('$normalizedRoot${Platform.pathSeparator}');
    if (!isInsideFixture) {
      throw StateError(
        'Recovery files must stay inside the private CI fixture',
      );
    }
    await directory.create();
    return directory;
  }

  String _controlUrl(String databaseUrl) {
    final uri = Uri.parse(databaseUrl);
    return uri.replace(path: '/postgres').toString();
  }
}

// Stable manifest ignores cluster-local object OIDs, physical storage, password
// hashes and statistics. It includes full row contents, not just row counts.
Future<Map<String, String>> manifest(pg.Connection db) async {
  final parts = <String, Object?>{};
  final extensions = await db.execute("""
    SELECT e.extname, e.extversion, n.nspname, pg_get_userbyid(e.extowner)
    FROM pg_catalog.pg_extension e
    JOIN pg_catalog.pg_namespace n ON n.oid=e.extnamespace
    ORDER BY e.extname
  """);
  parts['extensions'] = extensions
      .map((row) => row.map((value) => value?.toString()).toList())
      .toList();
  final tables = await db.execute(
    "SELECT schemaname, tablename FROM pg_tables WHERE schemaname IN ('public','ventio_security') ORDER BY 1,2",
  );
  for (final row in tables) {
    final name = '"${row[0]}"."${row[1]}"';
    final rows = await db.execute(
      'SELECT to_jsonb(t)::text FROM $name t ORDER BY to_jsonb(t)::text',
    );
    parts[name] = rows.map((r) => r[0]).toList();
  }
  var queryIndex = 0;
  for (final query in [
    "SELECT schemaname, sequencename, sequenceowner, data_type, start_value, min_value, max_value, increment_by, cycle, cache_size, last_value FROM pg_sequences WHERE schemaname IN ('public','ventio_security') ORDER BY 1,2",
    relationSecuritySql,
    "SELECT schemaname,tablename,policyname,permissive,roles::text,cmd,qual,with_check FROM pg_policies WHERE schemaname IN ('public','ventio_security') ORDER BY 1,2,3",
    "SELECT n.nspname,p.proname,pg_get_userbyid(p.proowner),p.prosecdef,p.proconfig::text,p.proacl::text,replace(replace(pg_get_functiondef(p.oid),E'\\r\\n',E'\\n'),E'\\r',E'\\n') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ventio_security' ORDER BY 1,2,pg_get_function_identity_arguments(p.oid)",
    "SELECT rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls,rolconnlimit,rolvaliduntil::text,rolconfig::text FROM pg_roles WHERE rolname LIKE 'ventio%' ORDER BY 1",
    "SELECT r.rolname,m.rolname,pg_get_userbyid(a.grantor),a.admin_option,a.inherit_option,a.set_option FROM pg_auth_members a JOIN pg_roles r ON r.oid=a.roleid JOIN pg_roles m ON m.oid=a.member WHERE r.rolname LIKE 'ventio%' ORDER BY 1,2",
    "SELECT datname,pg_get_userbyid(datdba),datacl::text FROM pg_database WHERE datname='ventio_host_test'",
    "SELECT pg_get_userbyid(d.defaclrole),n.nspname,d.defaclobjtype,d.defaclacl::text FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace ORDER BY 1,2,3",
    "SELECT nspname,pg_get_userbyid(nspowner),nspacl::text FROM pg_namespace WHERE nspname IN ('public','ventio_security') ORDER BY 1",
  ]) {
    final rows = await db.execute(query);
    parts['security-${queryIndex++}'] = rows
        .map((r) => r.map((v) => v?.toString()).toList())
        .toList();
  }
  return parts.map(
    (key, value) => MapEntry(
      key,
      sha256.convert(utf8.encode(jsonEncode(value))).toString(),
    ),
  );
}

// Privilege metadata only; never includes row contents or credential digests.
const relationSecuritySql =
    "SELECT n.nspname,c.relname,pg_get_userbyid(c.relowner),c.relrowsecurity,c.relforcerowsecurity,(SELECT jsonb_agg(jsonb_build_array(CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,pg_get_userbyid(a.grantor),a.privilege_type,a.is_grantable) ORDER BY CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,pg_get_userbyid(a.grantor),a.privilege_type,a.is_grantable)::text FROM aclexplode(COALESCE(c.relacl,acldefault(CASE WHEN c.relkind='S' THEN 'S'::\"char\" ELSE 'r'::\"char\" END,c.relowner))) a) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','ventio_security') AND c.relkind IN ('r','S') ORDER BY 1,2";
Future<List<List<String?>>> relationSecurityRows(pg.Connection db) async =>
    (await db.execute(
      relationSecuritySql,
    )).map((row) => row.map((value) => value?.toString()).toList()).toList();

// Export privileges from the quiesced source, never infer/widen them at restore.
// This fixture has direct owner grants; dependent grant-chain restoration is
// outside its supported profile. Final manifest equality is always mandatory.
Future<String> exportSequenceAcls(pg.Connection db) async {
  final rows = await db.execute(
    "SELECT n.nspname,c.relname,CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,pg_get_userbyid(a.grantor),a.privilege_type,a.is_grantable FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl,acldefault('S',c.relowner))) a WHERE c.relkind='S' AND n.nspname IN ('public','ventio_security') ORDER BY 1,2,3,4,5",
  );
  String identifier(String value) => '"${value.replaceAll('"', '""')}"';
  final resets = <String>{};
  final grants = <String>[];
  for (final row in rows) {
    final sequence =
        '${identifier(row[0] as String)}.${identifier(row[1] as String)}';
    final grantee = row[2] == 'PUBLIC'
        ? 'PUBLIC'
        : identifier(row[2] as String);
    final grantor = identifier(row[3] as String);
    final privilege = row[4] as String;
    if (!{'SELECT', 'UPDATE', 'USAGE'}.contains(privilege)) {
      throw StateError('Unsupported sequence privilege in source snapshot');
    }
    resets.add('REVOKE ALL ON SEQUENCE $sequence FROM PUBLIC;');
    resets.add('REVOKE ALL ON SEQUENCE $sequence FROM $grantee;');
    grants.add(
      'SET ROLE $grantor;\nGRANT $privilege ON SEQUENCE $sequence TO $grantee${row[5] == true ? ' WITH GRANT OPTION' : ''};\nRESET ROLE;',
    );
  }
  return ['BEGIN;', ...resets, ...grants, 'COMMIT;', ''].join('\n');
}
