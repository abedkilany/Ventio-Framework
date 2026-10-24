import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;

class TestHost {
  final Process process;
  final List<Map<String, dynamic>> _events = [];
  late final int port;
  TestHost._(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.startsWith('{')) {
            _events.add(jsonDecode(line) as Map<String, dynamic>);
          } else {
            final match = RegExp(
              r'listening on (?:https?://)?127\.0\.0\.1:(\d+)',
            ).firstMatch(line);
            if (match != null) {
              _events.add({
                'event': 'ready',
                'port': int.parse(match.group(1)!),
              });
            }
          }
        }, onDone: () {});
    // Capture neither credentials nor database diagnostics in shared test logs.
    process.stderr.drain<void>();
  }
  static Future<TestHost> attach(Process process) async {
    final host = TestHost._(process);
    host.port = (await host.event('ready'))['port'] as int;
    return host;
  }

  static Future<TestHost> start(
    String url, {
    String? stage,
    String? executionUrl,
    String? authorityFile,
  }) async {
    final crash = stage != null;
    final p = await Process.start(
      Platform.resolvedExecutable,
      [
        'run',
        crash
            ? 'test/recovery/crash_host.dart'
            : authorityFile == null
            ? 'test/recovery/legacy_host.dart'
            : 'test/recovery/same_account_host.dart',
      ],
      environment: {
        if (authorityFile != null)
          'VENTIO_RECOVERY_AUTHORITY_FILE': authorityFile,
        'VENTIO_ALLOW_DATABASE_TESTS': 'yes',
        'VENTIO_TEST_RUNTIME_DATABASE_URL': url,
        'VENTIO_ENABLE_LOCAL_HOST': 'yes',
        'VENTIO_HOST_DATABASE_URL': url,
        'VENTIO_HOST_PORT': '0',
        if (stage != null) 'VENTIO_TEST_CRASH_STAGE': stage,
        if (executionUrl != null)
          'VENTIO_TEST_EXECUTION_DATABASE_URL': executionUrl,
      },
    );
    final result = TestHost._(p);
    try {
      result.port = (await result.event('ready'))['port'] as int;
      return result;
    } catch (_) {
      p.kill(ProcessSignal.sigkill);
      await p.exitCode;
      rethrow;
    }
  }

  Future<Map<String, dynamic>> event(String name) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      for (final e in _events) {
        if (e['event'] == name) return e;
      }
      if (DateTime.now().isAfter(deadline))
        throw StateError('Host event timed out: $name');
      // A short bounded poll avoids losing a signal between inspection/listen.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> kill() async {
    if (!process.kill(ProcessSignal.sigkill))
      throw StateError('Host SIGKILL was not delivered');
    if (await process.exitCode.timeout(const Duration(seconds: 10)) !=
        -ProcessSignal.sigkill.signalNumber)
      throw StateError('Host was not terminated by SIGKILL');
  }

  void resume() => process.stdin.writeln('resume');
  Future<void> stop() async {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(const Duration(seconds: 10));
  }
}

class HttpOutcome {
  final int? status;
  final Map<String, dynamic>? body;
  HttpOutcome(this.status, this.body);
}

Future<HttpOutcome> request(
  TestHost host,
  String token,
  Map<String, dynamic> body,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:${host.port}/api/v1/commands'),
    );
    req.headers.set('Authorization', 'Bearer $token');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final response = await req.close().timeout(const Duration(seconds: 35));
    return HttpOutcome(
      response.statusCode,
      jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>,
    );
  } on SocketException {
    return HttpOutcome(null, null);
  } on HttpException {
    return HttpOutcome(null, null);
  } on TimeoutException {
    return HttpOutcome(null, null);
  } finally {
    client.close(force: true);
  }
}

Future<void> waitFor(Future<bool> Function() condition, String label) async {
  final watch = Stopwatch()..start();
  while (!await condition()) {
    if (watch.elapsed > const Duration(seconds: 15))
      throw StateError('Timed out: $label');
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

Future<List<int>> effectCounts(
  pg.Connection c,
  Map<String, dynamic> command,
) async {
  final result = <int>[];
  for (final table in [
    'ventio_records',
    'ventio_command_journal',
    'ventio_audit_entries',
    'ventio_outbox',
  ]) {
    final column = table == 'ventio_records' ? 'record_id' : 'command_id';
    final rows = await c.execute(
      pg.Sql.named(
        'SELECT count(*) FROM public.$table WHERE tenant_id=@tenant AND $column=@id',
      ),
      parameters: {
        'tenant': command['tenantId'],
        'id': command[table == 'ventio_records' ? 'aggregateId' : 'commandId'],
      },
    );
    result.add(rows.single[0] as int);
  }
  return result;
}

Future<Map<String, dynamic>?> savedReceipt(
  pg.Connection c,
  Map<String, dynamic> command,
) async {
  final rows = await c.execute(
    pg.Sql.named(
      'SELECT receipt::text FROM public.ventio_command_journal WHERE tenant_id=@tenant AND command_id=@command',
    ),
    parameters: {
      'tenant': command['tenantId'],
      'command': command['commandId'],
    },
  );
  return rows.isEmpty
      ? null
      : jsonDecode(rows.single[0] as String) as Map<String, dynamic>;
}
