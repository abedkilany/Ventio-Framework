// Destructive operations are restricted to the explicitly selected CI fixture.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;

import 'support.dart';

class DatabaseFixture {
  final String source;
  final String sourceUrl;
  String? restored;
  Directory? temporary;
  DatabaseFixture(this.source, this.sourceUrl);
  static Future<DatabaseFixture> guarded(String url) async {
    final env = Platform.environment;
    final id = env['VENTIO_TEST_POSTGRES_CONTAINER_ID'] ?? '';
    final uri = Uri.parse(url);
    if (env['VENTIO_ALLOW_POSTGRES_CONTAINER_KILL'] != 'yes' ||
        env['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
        !RegExp(r'^[a-f0-9]{12,64}$').hasMatch(id) ||
        !{'localhost', '127.0.0.1'}.contains(uri.host) ||
        uri.path != '/ventio_host_test') {
      throw StateError(
          'Explicit disposable CI container authorization required');
    }
    final fixture = DatabaseFixture(id, url);
    final inspected = jsonDecode(await fixture.docker(['inspect', id])) as List;
    final info = inspected.single as Map;
    final config = info['Config'] as Map;
    final ports = info['NetworkSettings']['Ports']['5432/tcp'] as List;
    if (config['Image'] != 'postgres:16' ||
        !(config['Env'] as List).contains('POSTGRES_DB=ventio_host_test') ||
        !ports.any((p) => int.parse(p['HostPort'] as String) == uri.port)) {
      throw StateError('Container does not match the disposable test database');
    }
    return fixture;
  }

  Future<String> docker(List<String> arguments) async {
    final result = await Process.run('docker', arguments)
        .timeout(const Duration(seconds: 45));
    if (result.exitCode != 0)
      throw StateError('Fixture Docker operation failed: ${arguments.first}');
    return result.stdout as String;
  }

  Future<void> pipe(List<String> arguments, File input) async {
    final process = await Process.start('docker', arguments);
    final output = process.stdout.drain<void>();
    final errors = process.stderr.drain<void>();
    await process.stdin.addStream(input.openRead());
    await process.stdin.close();
    if (await process.exitCode.timeout(const Duration(seconds: 45)) != 0) {
      throw StateError('Restore operation failed');
    }
    await Future.wait([output, errors]);
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

  Future<void> restartAfterKill() async {
    await docker(['kill', '--signal', 'KILL', source]);
    final state =
        (jsonDecode(await docker(['inspect', source])) as List).single['State'];
    if (state['ExitCode'] != 137 || state['OOMKilled'] != false) {
      throw StateError(
          'PostgreSQL container did not exit from deliberate SIGKILL');
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

  Future<String> backupAndRestore() async {
    temporary = await Directory.systemTemp.createTemp('ventio-recovery-');
    await Process.run('chmod', ['700', temporary!.path]);
    final dump = File('${temporary!.path}/database.dump');
    final globals = File('${temporary!.path}/roles.sql');
    await capture([
      'exec',
      source,
      'pg_dump',
      '-U',
      'ventio',
      '-d',
      'ventio_host_test',
      '-Fc'
    ], dump);
    // Roles and memberships are cluster objects. Passwords are deliberately excluded.
    await capture([
      'exec',
      source,
      'pg_dumpall',
      '-U',
      'ventio',
      '--roles-only',
      '--no-role-passwords'
    ], globals);
    restored = (await docker([
      'run',
      '--detach',
      '--name',
      'ventio-restore-${DateTime.now().microsecondsSinceEpoch}',
      '--env',
      'POSTGRES_USER=restore_bootstrap',
      '--env',
      'POSTGRES_PASSWORD=restore_fixture_only',
      '--env',
      'POSTGRES_DB=postgres',
      '--publish',
      '127.0.0.1::5432',
      'postgres:16'
    ]))
        .trim();
    final mapping = (await docker(['port', restored!, '5432/tcp'])).trim();
    final port = int.parse(mapping.split(':').last);
    final control =
        'postgresql://restore_bootstrap:restore_fixture_only@127.0.0.1:$port/postgres?sslmode=disable&connect_timeout=2';
    await ready(control);
    await pipe([
      'exec',
      '-i',
      restored!,
      'psql',
      '-X',
      '-v',
      'ON_ERROR_STOP=1',
      '-U',
      'restore_bootstrap',
      '-d',
      'postgres'
    ], globals);
    // Restore ownership and ACLs; never repair/re-bootstrap security before comparison.
    await pipe([
      'exec',
      '-i',
      restored!,
      'pg_restore',
      '--create',
      '--exit-on-error',
      '-U',
      'restore_bootstrap',
      '-d',
      'postgres'
    ], dump);
    return Uri.parse(control).replace(path: '/ventio_host_test').toString();
  }

  Future<void> provisionRestoredPasswords() async {
    // Test fixture secrets only; backup contains no login password hashes.
    await docker([
      'exec',
      restored!,
      'psql',
      '-X',
      '-v',
      'ON_ERROR_STOP=1',
      '-U',
      'restore_bootstrap',
      '-d',
      'ventio_host_test',
      '-c',
      "ALTER ROLE ventio_runtime_test PASSWORD 'runtime_test_only'; ALTER ROLE ventio_admin_test PASSWORD 'admin_test_only'; ALTER ROLE ventio_migration_test PASSWORD 'migration_test_only';"
    ]);
  }

  Future<void> close() async {
    if (restored != null)
      await docker(['rm', '--force', '--volumes', restored!]);
    if (temporary != null) await temporary!.delete(recursive: true);
  }
}

// Stable manifest ignores cluster-local object OIDs, physical storage, password
// hashes and statistics. It includes full row contents, not just row counts.
Future<String> manifest(pg.Connection db) async {
  final parts = <Object?>[];
  final tables = await db.execute(
      "SELECT schemaname, tablename FROM pg_tables WHERE schemaname IN ('public','ventio_security') ORDER BY 1,2");
  for (final row in tables) {
    final name = '"${row[0]}"."${row[1]}"';
    final rows = await db.execute(
        'SELECT to_jsonb(t)::text FROM $name t ORDER BY to_jsonb(t)::text');
    parts.add([name, rows.map((r) => r[0]).toList()]);
  }
  for (final query in [
    "SELECT schemaname, sequencename, sequenceowner, data_type, start_value, min_value, max_value, increment_by, cycle, cache_size, last_value FROM pg_sequences WHERE schemaname IN ('public','ventio_security') ORDER BY 1,2",
    "SELECT n.nspname,c.relname,pg_get_userbyid(c.relowner),c.relrowsecurity,c.relforcerowsecurity,c.relacl::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','ventio_security') AND c.relkind IN ('r','S') ORDER BY 1,2",
    "SELECT schemaname,tablename,policyname,permissive,roles::text,cmd,qual,with_check FROM pg_policies WHERE schemaname IN ('public','ventio_security') ORDER BY 1,2,3",
    "SELECT n.nspname,p.proname,pg_get_userbyid(p.proowner),p.prosecdef,p.proconfig::text,p.proacl::text,pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ventio_security' ORDER BY 1,2",
    "SELECT rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls,rolconnlimit,rolvaliduntil::text,rolconfig::text FROM pg_roles WHERE rolname LIKE 'ventio%' ORDER BY 1",
    "SELECT r.rolname,m.rolname,a.admin_option,a.inherit_option,a.set_option FROM pg_auth_members a JOIN pg_roles r ON r.oid=a.roleid JOIN pg_roles m ON m.oid=a.member WHERE r.rolname LIKE 'ventio%' ORDER BY 1,2",
    "SELECT datname,pg_get_userbyid(datdba),datacl::text FROM pg_database WHERE datname='ventio_host_test'",
    "SELECT nspname,pg_get_userbyid(nspowner),nspacl::text FROM pg_namespace WHERE nspname IN ('public','ventio_security') ORDER BY 1",
  ]) {
    final rows = await db.execute(query);
    parts.add(rows.map((r) => r.map((v) => v?.toString()).toList()).toList());
  }
  return sha256.convert(utf8.encode(jsonEncode(parts))).toString();
}
