// Test-only process fixture. It is never imported by a production launcher.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host/ventio_host.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

class DiagnosticAuthenticator implements PersistentHostAuthenticator {
  final PersistentTokenAuthenticator inner;
  final Future<pg.Connection> Function() connect;

  const DiagnosticAuthenticator(this.inner, this.connect);

  Future<String> _activitySnapshot() async {
    pg.Connection? connection;
    try {
      connection = await connect();
      final rows = await connection.execute('''
        SELECT application_name, state, wait_event_type, wait_event,
          extract(epoch FROM clock_timestamp()-xact_start)::integer
        FROM pg_stat_activity
        WHERE datname=current_database() AND pid<>pg_backend_pid()
          AND application_name LIKE 'ventio-recovery-%'
        ORDER BY xact_start NULLS LAST
        LIMIT 12
      ''');
      return rows
          .map((row) => '${row[0]}:${row[1]}:${row[2]}:${row[3]}:tx${row[4]}')
          .join(', ');
    } catch (_) {
      return 'unavailable';
    } finally {
      await connection?.close();
    }
  }

  @override
  Future<AuthenticatedSession?> authenticate(String token) async {
    try {
      return await inner.authenticate(token);
    } on pg.ServerException catch (error) {
      final code = error.code;
      final safeCode = code != null && RegExp(r'^[0-9A-Z]{5}$').hasMatch(code)
          ? code
          : 'unknown';
      stderr.writeln(
        'VENTIO_HOST_TEST_DIAGNOSTIC: PostgreSQL authenticator failure '
        '$safeCode; activity ${await _activitySnapshot()}',
      );
      rethrow;
    } catch (error) {
      stderr.writeln(
        'VENTIO_HOST_TEST_DIAGNOSTIC: authenticator failure ${error.runtimeType}',
      );
      rethrow;
    }
  }
}

class CrashExecutor implements CommandExecutor {
  final Future<pg.Connection> Function() connect;
  final MaintenancePrototype prototype;
  final String stage;
  final Completer<void> resume;
  CrashExecutor(this.connect, this.prototype, this.stage, this.resume);
  @override
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session,
  ) async {
    final connection = await connect();
    try {
      await verifyRuntimeConnection(connection);
      await connection.execute("SET statement_timeout='15s'");
      await connection.execute("SET lock_timeout='15s'");
      final backend = (await connection.execute(
        'SELECT pg_backend_pid()',
      )).single[0];
      stdout.writeln(jsonEncode({'event': 'executing', 'backend': backend}));
      final host =
          DurableCommandHost(
            connection: connection,
            modules: prototype.modules,
            docTypes: prototype.docTypes,
            testFaultInjector: (point) async {
              if (point == stage) {
                stdout.writeln(
                  jsonEncode({
                    'event': 'barrier',
                    'stage': point,
                    'backend': backend,
                  }),
                );
                await resume.future.timeout(const Duration(seconds: 30));
              }
            },
          )..registerTrustedCreateBinding(
            const TrustedCommandBinding(
              'maintenance.create',
              1,
              'MaintenanceRequest',
            ),
          );
      try {
        return await host.executeAuthorized(
          command,
          (tx) => const PostgresIdentityStore().resolve(
            tx,
            session.credentialDigest!,
            command: command,
          ),
        );
      } on pg.ServerException catch (error) {
        final code = error.code;
        final safeCode = code != null && RegExp(r'^[0-9A-Z]{5}$').hasMatch(code)
            ? code
            : 'unknown';
        stderr.writeln(
          'VENTIO_HOST_TEST_DIAGNOSTIC: PostgreSQL executor failure $safeCode',
        );
        rethrow;
      } catch (error) {
        stderr.writeln(
          'VENTIO_HOST_TEST_DIAGNOSTIC: executor failure ${error.runtimeType}',
        );
        rethrow;
      }
    } finally {
      await connection.close();
    }
  }
}

Future<void> main() async {
  final env = Platform.environment;
  final url = env['VENTIO_TEST_RUNTIME_DATABASE_URL'];
  final executionUrl = env['VENTIO_TEST_EXECUTION_DATABASE_URL'] ?? url;
  if (env['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
      url == null ||
      executionUrl == null ||
      Uri.parse(url).pathSegments.last != 'ventio_host_test' ||
      Uri.parse(executionUrl).pathSegments.last != 'ventio_host_test' ||
      !{'localhost', '127.0.0.1'}.contains(Uri.parse(url).host) ||
      !{'localhost', '127.0.0.1'}.contains(Uri.parse(executionUrl).host)) {
    exitCode = 2;
    return;
  }
  final resume = Completer<void>();
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line == 'resume' && !resume.isCompleted) resume.complete();
  });
  final api = await HostApi.bind(
    authenticator: DiagnosticAuthenticator(
      PersistentTokenAuthenticator(
        connect: () => pg.Connection.openFromUrl(url),
      ),
      () => pg.Connection.openFromUrl(url),
    ),
    executor: CrashExecutor(
      () => pg.Connection.openFromUrl(executionUrl),
      bootstrapMaintenancePrototype('../../spec/v1.2'),
      env['VENTIO_TEST_CRASH_STAGE'] ?? '',
      resume,
    ),
  );
  stdout.writeln(jsonEncode({'event': 'ready', 'port': api.port}));
}
