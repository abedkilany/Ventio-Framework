import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host/ventio_host.dart';
import 'package:ventio_host_api/ventio_host_api.dart';
import 'package:ventio_postgres/ventio_postgres.dart';

import 'test_support.dart';

Future<int> _stopServerProcess(Process process) async {
  if (Platform.isWindows) {
    process.stdin.writeln('shutdown');
    await process.stdin.flush();
  } else {
    process.kill(ProcessSignal.sigterm);
  }
  return process.exitCode.timeout(const Duration(seconds: 20));
}

class FaultExecutor implements CommandExecutor {
  final Future<pg.Connection> Function() connect;
  final MaintenancePrototype prototype;
  String? fault;
  FaultExecutor(this.connect, this.prototype);

  @override
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session,
  ) async {
    final principal = session.principal;
    final connection = await connect();
    try {
      if (fault == 'database') await connection.close();
      final host = DurableCommandHost(
        connection: connection,
        modules: prototype.modules,
        docTypes: prototype.docTypes,
        testFaultInjector: (stage) {
          if (fault == 'before_commit' && stage == 'before_commit') {
            throw StateError('Injected before commit');
          }
        },
      );
      host.registerTrustedCreateBinding(
        const TrustedCommandBinding(
          'maintenance.create',
          1,
          'MaintenanceRequest',
        ),
      );
      final receipt = await host.execute(command, principal);
      if (fault == 'after_commit')
        throw StateError('Simulated lost result after commit');
      return receipt;
    } finally {
      await connection.close();
    }
  }
}

Future<void> main() async {
  final url = Platform.environment['VENTIO_TEST_DATABASE_URL'];
  if (url == null ||
      Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
      Uri.parse(url).pathSegments.where((s) => s.isNotEmpty).lastOrNull !=
          'ventio_host_test') {
    stderr.writeln(
      'Use only a disposable ventio_host_test database and explicit test opt-in.',
    );
    exitCode = 2;
    return;
  }
  final db = await pg.Connection.openFromUrl(url);
  final tenant = 'api-${DateTime.now().microsecondsSinceEpoch}';
  final prototype = bootstrapMaintenancePrototype('../../spec/v1.2');
  final executor = PostgresCommandExecutor(
    connect: () => pg.Connection.openFromUrl(url),
    modules: prototype.modules,
    docTypes: prototype.docTypes,
    bindings: const [
      TrustedCommandBinding('maintenance.create', 1, 'MaintenanceRequest'),
    ],
  );
  HostApi? api;
  Directory? temp;
  Process? child;
  Future<int> count(String table) async =>
      (await db.execute(
            pg.Sql.named(
              'SELECT count(*) FROM $table WHERE tenant_id = @tenant',
            ),
            parameters: {'tenant': tenant},
          )).single[0]
          as int;
  Future<void> effects(int expected, String label) async {
    final counts = await Future.wait(
      [
        'ventio_records',
        'ventio_command_journal',
        'ventio_audit_entries',
        'ventio_outbox',
      ].map(count),
    );
    check(counts.every((n) => n == expected), label);
  }

  try {
    await PostgresMigrationRunner(
      db,
      Directory('../../migrations/postgres'),
    ).apply();
    api = await HostApi.bind(
      authenticator: authenticator(tenant),
      executor: executor,
    );
    final first = command(tenant);
    Future<Reply> submit(Map<String, dynamic> body, {String? token}) =>
        send(api!, token: token ?? validToken, body: body);
    final receipt = await submit(first);
    check(
      receipt.status == 200 && receipt.body['receipt']['status'] == 'ACCEPTED',
      'HTTP command commits through the durable engine',
    );
    await effects(1, 'Record, journal, audit and outbox commit together');
    check(
      canonicalJson((await submit(first)).body) == canonicalJson(receipt.body),
      'HTTP replay returns the original saved receipt',
    );
    await effects(1, 'Replay has one business effect');
    check(
      (await submit(command(tenant, record: 'changed'))).status == 409,
      'Altered envelope with same ID is rejected',
    );
    check(
      (await submit(first, token: deniedToken)).status == 403,
      'Durable permissions are rechecked on replay',
    );
    for (final key in [
      'tenantId',
      'companyId',
      'branchId',
      'actorId',
      'deviceId',
    ]) {
      final forged = command(tenant, id: 99);
      if (key == 'actorId' || key == 'deviceId') {
        forged['clientContext'][key] = 'forged';
      } else {
        forged[key] = 'forged';
      }
      check(
        (await submit(forged)).status == 403,
        'HTTP forgery of $key cannot reach persistence',
      );
    }
    final invalid = command(tenant, id: 99)..['payload'] = {'unexpected': true};
    check(
      (await submit(invalid)).body['receipt']['reasonCode'] ==
          'INVALID_PAYLOAD',
      'DocType payload validation remains enforced',
    );
    await effects(1, 'Rejected requests leave all effect tables unchanged');
    final concurrent = command(tenant, id: 2);
    final duplicates = await Future.wait(
      List.generate(4, (_) => submit(concurrent)),
    );
    check(
      duplicates.every(
        (r) =>
            r.status == 200 &&
            canonicalJson(r.body) == canonicalJson(duplicates.first.body),
      ),
      'Concurrent HTTP retries recover one stored receipt',
    );
    await effects(2, 'Concurrent retries commit one set of effects');
    final competing = await Future.wait([
      submit(command(tenant, id: 3, record: 'shared')),
      submit(command(tenant, id: 4, record: 'shared')),
    ]);
    check(
      competing.where((r) => r.status == 200).length == 1 &&
          competing.where((r) => r.status == 409).length == 1,
      'Conflicting HTTP commands cannot create duplicate records',
    );
    await effects(3, 'Competing creates preserve atomic table counts');

    await api.close();
    api = await HostApi.bind(
      authenticator: authenticator(tenant),
      executor: executor,
    );
    check(
      canonicalJson((await submit(first)).body) == canonicalJson(receipt.body),
      'New HTTP server and database connection recover saved receipt',
    );
    await api.close();
    final fault = FaultExecutor(
      () => pg.Connection.openFromUrl(url),
      prototype,
    );
    api = await HostApi.bind(
      authenticator: authenticator(tenant),
      executor: fault,
    );
    fault.fault = 'before_commit';
    final before = command(tenant, id: 5);
    check(
      (await submit(before)).status == 503,
      'Pre-commit interruption never reports success',
    );
    await effects(
      3,
      'Pre-commit interruption rolls back all four effect tables',
    );
    fault.fault = null;
    check(
      (await submit(before)).status == 200,
      'Retry succeeds after rolled back interruption',
    );
    fault.fault = 'database';
    final unavailable = command(tenant, id: 6);
    check(
      (await submit(unavailable)).status == 503,
      'Closed database connection never reports success',
    );
    await effects(4, 'Database failure creates no effects');
    fault.fault = null;
    check(
      (await submit(unavailable)).status == 200,
      'Identical retry succeeds after database recovery',
    );
    fault.fault = 'after_commit';
    final ambiguous = command(tenant, id: 7);
    check(
      (await submit(ambiguous)).status == 503,
      'Simulated lost post-commit result is not reported as success',
    );
    await effects(
      6,
      'Post-commit failure retains exactly one committed effect',
    );
    fault.fault = null;
    final recovered = await submit(ambiguous);
    check(
      recovered.status == 200 &&
          recovered.body['receipt']['status'] == 'ACCEPTED',
      'Identical retry recovers post-commit outcome',
    );
    check(
      canonicalJson((await submit(ambiguous)).body) ==
          canonicalJson(recovered.body),
      'Recovered receipt remains stable',
    );
    await effects(6, 'Ambiguous-outcome retries cannot duplicate effects');
    await api.close();
    api = null;

    // Actual independent OS processes, fresh DB connections and server startup.
    // This verifies graceful process restart, not an in-transaction SIGKILL.
    temp = await Directory.systemTemp.createTemp('ventio-api-');
    final identity = File('${temp.path}/identity.json');
    await identity.writeAsString(
      jsonEncode({
        'tokenDigest': DevelopmentCredential.digest(validToken),
        'actorId': 'user-001',
        'deviceId': 'device-001',
        'tenantId': tenant,
        'companyIds': ['company-001'],
        'branchIds': ['branch-001'],
        'permissions': ['maintenance.create'],
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 1))
            .toIso8601String(),
      }),
    );
    Future<int> startChild() async {
      child = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'bin/development_host.dart'],
        environment: {
          'VENTIO_ENVIRONMENT': 'development',
          'VENTIO_ENABLE_DEVELOPMENT_API': 'yes',
          'VENTIO_DEVELOPMENT_IDENTITY_FILE': identity.absolute.path,
          'VENTIO_HOST_DATABASE_URL': url,
          'VENTIO_HOST_PORT': '0',
          if (Platform.isWindows) 'VENTIO_TEST_SHUTDOWN_VIA_STDIN': 'yes',
        },
      );
      child!.stderr.drain<void>();
      final line = await child!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 30));
      return int.parse(line.split(':').last);
    }

    Future<Reply> childSubmit(int port) async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:$port/api/v1/commands'),
        );
        request.headers.set('Authorization', 'Bearer $validToken');
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(first));
        final response = await request.close();
        return Reply(
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
          response.headers,
        );
      } finally {
        client.close(force: true);
      }
    }

    final firstPort = await startChild();
    check(
      canonicalJson((await childSubmit(firstPort)).body) ==
          canonicalJson(receipt.body),
      'Independent server process reads durable receipt',
    );
    final firstShutdownCode = await _stopServerProcess(child!);
    check(firstShutdownCode == 0, 'Server process shuts down gracefully');
    child = null;
    final secondPort = await startChild();
    check(
      canonicalJson((await childSubmit(secondPort)).body) ==
          canonicalJson(receipt.body),
      'Restarted server process returns identical persisted receipt',
    );
    final secondShutdownCode = await _stopServerProcess(child!);
    check(secondShutdownCode == 0, 'Restarted process shuts down cleanly');
    child = null;
    await effects(6, 'Process restart does not duplicate any persisted effect');
    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    child?.kill(ProcessSignal.sigkill);
    await api?.close();
    if (temp != null) await temp.delete(recursive: true);
    for (final table in [
      'ventio_outbox',
      'ventio_audit_entries',
      'ventio_command_journal',
      'ventio_records',
    ]) {
      await db.execute(
        pg.Sql.named('DELETE FROM $table WHERE tenant_id = @tenant'),
        parameters: {'tenant': tenant},
      );
    }
    await db.close();
  }
}
