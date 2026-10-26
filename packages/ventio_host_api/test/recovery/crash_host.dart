// Test-only process fixture. It is never imported by a production launcher.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host/ventio_host.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

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
      return await host.executeAuthorized(
        command,
        (tx) => const PostgresIdentityStore().resolve(
          tx,
          session.credentialDigest!,
          command: command,
        ),
      );
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
    authenticator: PersistentTokenAuthenticator(
      connect: () => pg.Connection.openFromUrl(url),
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
