// Isolated PostgreSQL / Linux audit. No production database or external API.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'recovery/database_fixture.dart';
import 'recovery/support.dart';
import 'test_support.dart' show check, command, assertions;

Future<void> main() async {
  final env = Platform.environment;
  final url = env['VENTIO_TEST_DATABASE_URL']!;
  final runtimeUrl = env['VENTIO_TEST_RUNTIME_DATABASE_URL']!;
  final adminUrl = env['VENTIO_TEST_ADMIN_DATABASE_URL']!;
  final binary = env['VENTIO_AUDIT_HOST_BINARY']!;
  final fixture = await DatabaseFixture.guarded(url);
  final uid = int.parse((await Process.run('id', ['-u'])).stdout as String);
  final gid = int.parse((await Process.run('id', ['-g'])).stdout as String);
  if (uid == 65534) throw StateError('Audit writer must differ from nobody');
  final root = await Directory.systemTemp.createTemp(
    'ventio-engineering-audit-',
  );
  await Process.run('chmod', ['711', root.path]);
  final private = await Directory('${root.path}/operator').create();
  final witness = await Directory('${root.path}/witness').create();
  await Process.run('chmod', ['700', private.path]);
  await Process.run('chmod', ['750', witness.path]);
  final authority = RecoveryAuthority(
    '${witness.path}/authority.json',
    readerGroupId: gid,
  );
  final db = await pg.Connection.openFromUrl(url);
  final administration = await pg.Connection.openFromUrl(adminUrl);
  final observer = await pg.Connection.openFromUrl(url);
  pg.Connection? restored;
  final active = <TestHost>[];
  final tenant = 'engineering-audit';
  var sequence = 9000;
  Map<String, dynamic> next() => command(tenant, id: ++sequence);
  final admin = IdentityAdministration(
    connection: administration,
    tenantId: tenant,
    operatorLabel: 'engineering-audit',
    authority: authority,
  );
  final metrics = <Map<String, Object?>>[];
  Map<String, String> environment(
    String database,
    String file, {
    String? owner,
  }) => {
    'PATH': '/usr/bin:/bin',
    'VENTIO_ENABLE_LOCAL_HOST': 'yes',
    'VENTIO_HOST_DATABASE_URL': database,
    'VENTIO_HOST_PORT': '0',
    'VENTIO_RECOVERY_AUTHORITY_FILE': file,
    'VENTIO_RECOVERY_AUTHORITY_OWNER_UID': owner ?? '$uid',
  };
  // The runner's root-owned helper accepts only the audit's commands, then
  // drops all root privileges before executing them. Secrets cross stdin.
  Future<Process> isolatedStart(
    List<String> command, {
    Map<String, String>? configuration,
  }) async {
    final privilegeHelper = env['VENTIO_AUDIT_PRIVILEGE_HELPER'];
    if (privilegeHelper == null ||
        !privilegeHelper.startsWith('/usr/local/libexec/')) {
      throw StateError(
        'VENTIO_AUDIT_PRIVILEGE_HELPER must name the installed CI helper',
      );
    }
    final process = await Process.start('sudo', [
      '-n',
      '--',
      privilegeHelper,
    ], workingDirectory: env['VENTIO_AUDIT_HOST_WORKDIR']);
    process.stdin.writeln(
      jsonEncode({
        'command': command,
        'environment': configuration ?? {'PATH': '/usr/bin:/bin'},
      }),
    );
    await process.stdin.close();
    return process;
  }

  Future<ProcessResult> collect(Process process) async {
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    return ProcessResult(process.pid, code, await output, await errors);
  }

  Future<TestHost> start({String? database, String? file}) async {
    final process = await isolatedStart(
      [binary],
      configuration: environment(database ?? runtimeUrl, file ?? authority.path)
        ..['VENTIO_HOST_TEST_DIAGNOSTICS'] = 'yes',
    );
    final host = await TestHost.attach(process);
    active.add(host);
    return host;
  }

  Future<void> stop(TestHost h) async {
    await h.stop();
    active.remove(h);
    check(
      await h.process.exitCode == 0,
      'OS-separated Host shuts down cleanly',
    );
  }

  Future<void> startupDenied(
    String label, {
    String? database,
    String? file,
    String? owner,
    bool sameUid = false,
  }) async {
    final configuration = environment(
      database ?? runtimeUrl,
      file ?? authority.path,
      owner: owner,
    );
    final process = sameUid
        ? await Process.start(
            binary,
            [],
            environment: configuration,
            workingDirectory: env['VENTIO_AUDIT_HOST_WORKDIR'],
          )
        : await isolatedStart([binary], configuration: configuration);
    final result = await collect(process).timeout(const Duration(seconds: 20));
    check(
      result.exitCode == 2 && !(result.stdout as String).contains('listening'),
      '$label (exit=${result.exitCode}; diagnostic=${result.stderr})',
    );
  }

  Future<HttpOutcome> accepted(
    TestHost host,
    String token,
    Map<String, dynamic> body,
  ) async {
    final result = await request(host, token, body);
    check(
      result.status == 200 && result.body?['receipt']?['status'] == 'ACCEPTED',
      'Audited launcher accepts a scoped durable command',
    );
    return result;
  }

  try {
    final runtimeIdentity = await collect(await isolatedStart(['id', '-u']));
    check(
      runtimeIdentity.exitCode == 0 &&
          (runtimeIdentity.stdout as String).trim() == '65534',
      'Audit subprocess really runs under the separate nobody OS identity',
    );
    // Linux read-only witness boundary: administration retains the only write
    // capability. Database and filesystem identities are independently separated.
    await authority.resetForReenrollment(
      administration,
      'audited-initial-enrollment',
    );
    await admin.createUser('user-001');
    await admin.registerBranch('company-001', 'branch-001');
    await admin.registerDevice('user-001', 'device-001');
    await admin.grant(
      'user-001',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    final delivery = '${private.path}/credential.json';
    await admin.provisionToFile(
      actorId: 'user-001',
      deviceId: 'device-001',
      credentialId: 'audit-credential',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': 'company-001',
          'branchId': 'branch-001',
          'permissions': ['maintenance.create'],
        },
      ],
      outputPath: delivery,
    );
    final token =
        (jsonDecode(await PrivateFiles.read(delivery)) as Map)['token']
            as String;
    final tlsPrivateKey = '${private.path}/tls-private-key-test';
    await PrivateFiles.create(tlsPrivateKey, {'testOnly': true});
    await PrivateFiles.verifyPrivateFile(tlsPrivateKey);
    await Process.run('chmod', ['640', tlsPrivateKey]);
    var permissiveTlsKeyRejected = false;
    try {
      await PrivateFiles.verifyPrivateFile(tlsPrivateKey);
    } on StateError {
      permissiveTlsKeyRejected = true;
    }
    check(
      permissiveTlsKeyRejected,
      'Remote Host rejects group-readable TLS private keys',
    );
    await Process.run('chmod', ['600', tlsPrivateKey]);
    final privateConfig = '${private.path}/operator-config.json';
    await PrivateFiles.create(privateConfig, {
      'administrationDatabaseUrl': adminUrl,
    });
    await startupDenied(
      'Same-UID Host cannot claim independently protected witness ownership',
      sameUid: true,
    );
    await startupDenied(
      'Wrong configured witness owner is rejected',
      owner: '${uid + 1}',
    );
    await Process.run('chmod', ['770', witness.path]);
    await startupDenied(
      'Writable witness directory is rejected even when the file is read-only',
    );
    await Process.run('chmod', ['750', witness.path]);
    final denied = await collect(
      await isolatedStart([
        'python3',
        '-c',
        r'''
import os,sys,json
path,config=sys.argv[1:]
checks=[]
for action in [lambda:open(path,'w'),lambda:os.unlink(path),lambda:os.rename(path,path+'.old'),lambda:open(config,'r')]:
    try: action();checks.append(False)
    except PermissionError: checks.append(True)
print(json.dumps(checks))
''',
        authority.path,
        privateConfig,
      ]),
    );
    check(
      denied.exitCode == 0 &&
          (jsonDecode(denied.stdout as String) as List).every((v) => v == true),
      'Host OS account cannot overwrite, unlink, rename witness or read admin connection secrets',
    );
    await db.execute(
      "INSERT INTO ventio_schema_migrations(name,sha256) VALUES ('999_unknown.sql','unsupported')",
    );
    await startupDenied('Unknown migration ledger entry blocks startup');
    await db.execute(
      "DELETE FROM ventio_schema_migrations WHERE name='999_unknown.sql'",
    );
    final host = await start();
    await db.execute(
      "INSERT INTO ventio_schema_migrations(name,sha256) VALUES ('999_unknown.sql','unsupported')",
    );
    check(
      (await request(host, token, next())).status == 503,
      'Changed migration manifest quarantines a running Host',
    );
    await db.execute(
      "DELETE FROM ventio_schema_migrations WHERE name='999_unknown.sql'",
    );
    final initial = next();
    await accepted(host, token, initial);
    final healthClient = HttpClient();
    final health = await (await healthClient.getUrl(
      Uri.parse('http://127.0.0.1:${host.port}/healthz'),
    )).close();
    check(
      health.statusCode == 200,
      'Liveness remains distinct from security/database readiness',
    );
    await health.drain<void>();
    healthClient.close(force: true);

    // FIFO path is a real non-regular-file hazard, not a mocked I/O failure.
    final fifo = '${private.path}/input.fifo';
    await Process.run('mkfifo', [fifo]);
    final fifoTime = Stopwatch()..start();
    var fifoRejected = false;
    try {
      await PrivateFiles.read(fifo);
    } catch (_) {
      fifoRejected = true;
    }
    check(
      fifoRejected && fifoTime.elapsed < const Duration(seconds: 2),
      'FIFO input is rejected before a blocking open can hang the helper',
    );
    final fake = await Directory('${private.path}/interpreter').create();
    final pidFile = '${private.path}/helper.pid';
    final fakePython = File('${fake.path}/python3');
    await fakePython.writeAsString(
      '#!/bin/sh\necho \$\$ > "$pidFile"\nexec /bin/sleep 30\n',
    );
    await Process.run('chmod', ['700', fakePython.path]);
    final timeoutResult = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'test/recovery/private_file_probe.dart', privateConfig],
      environment: {'PATH': '${fake.path}:${env['PATH']}'},
    ).timeout(const Duration(seconds: 20));
    final helperPid = (await File(pidFile).readAsString()).trim();
    final alive = await Process.run('kill', ['-0', helperPid]);
    check(
      timeoutResult.exitCode == 0 &&
          (timeoutResult.stdout as String).contains(
            'EXPECTED_PRIVATE_STORAGE_FAILURE',
          ) &&
          alive.exitCode != 0,
      'Timed-out private-file helper is killed and reaped',
    );

    // Profile growth in identity and audit independently of business records.
    var priorUsers = 0;
    var priorDevices = 0;
    var priorAudit = 0;
    for (final size in [(10, 100), (100, 5000), (1000, 20000)]) {
      await authority.change(db, (tx) async {
        await tx.execute(
          "INSERT INTO ventio_identity_branches(tenant_id,company_id,branch_id) VALUES ('benchmark-fixture','fixture-company','fixture-branch') ON CONFLICT DO NOTHING",
        );
        await tx.execute(
          pg.Sql.named(
            "INSERT INTO ventio_identity_users(tenant_id,actor_id) SELECT 'benchmark-fixture','fixture-user-'||i FROM generate_series(CAST(@a AS integer),CAST(@b AS integer)) i",
          ),
          parameters: {'a': priorUsers + 1, 'b': size.$1},
        );
        await tx.execute(
          pg.Sql.named(
            "INSERT INTO ventio_identity_devices(tenant_id,actor_id,device_id) SELECT 'benchmark-fixture','fixture-user-'||((i+1)/2),'fixture-device-'||i FROM generate_series(CAST(@a AS integer),CAST(@b AS integer)) i",
          ),
          parameters: {'a': priorDevices + 1, 'b': size.$1 * 2},
        );
        await tx.execute(
          pg.Sql.named(
            "INSERT INTO ventio_identity_credentials(tenant_id,actor_id,device_id,credential_id,token_digest,expires_at) SELECT 'benchmark-fixture','fixture-user-'||((i+1)/2),'fixture-device-'||i,'fixture-credential-'||i,encode(sha256(convert_to('non-deliverable-fixture:'||i,'UTF8')),'hex'),clock_timestamp()+interval '1 hour' FROM generate_series(CAST(@a AS integer),CAST(@b AS integer)) i",
          ),
          parameters: {'a': priorDevices + 1, 'b': size.$1 * 2},
        );
        await tx.execute(
          pg.Sql.named(
            "INSERT INTO ventio_identity_grants(tenant_id,actor_id,company_id,branch_id,permission) SELECT 'benchmark-fixture','fixture-user-'||i,'fixture-company','fixture-branch','maintenance.create' FROM generate_series(CAST(@a AS integer),CAST(@b AS integer)) i",
          ),
          parameters: {'a': priorUsers + 1, 'b': size.$1},
        );
        await tx.execute(
          pg.Sql.named(
            "INSERT INTO ventio_identity_audit(tenant_id,operator_label,action,subject_id,details) SELECT 'benchmark-fixture','benchmark','BENCHMARK_FIXTURE','history-'||i,'{}' FROM generate_series(CAST(@a AS integer),CAST(@b AS integer)) i",
          ),
          parameters: {'a': priorAudit + 1, 'b': size.$2},
        );
      });
      priorUsers = size.$1;
      priorDevices = size.$1 * 2;
      priorAudit = size.$2;
      final fingerprintTimes = <double>[];
      for (var sample = 0; sample < 5; sample++) {
        final watch = Stopwatch()..start();
        await RecoveryAuthority.snapshot(administration);
        fingerprintTimes.add(watch.elapsedMicroseconds / 1000);
      }
      final commands = <Map<String, dynamic>>[];
      final outcomes = <HttpOutcome>[];
      final durations = <double>[];
      // Two waves, four actual HTTP requests in parallel. No synthetic sleep
      // stands in for database CPU/lock or authorization costs.
      for (var wave = 0; wave < 2; wave++) {
        await Future.wait(
          List.generate(4, (_) async {
            final body = next();
            commands.add(body);
            final watch = Stopwatch()..start();
            outcomes.add(await request(host, token, body));
            durations.add(watch.elapsedMicroseconds / 1000);
          }),
        );
      }
      final successes = outcomes
          .where(
            (r) =>
                r.status == 200 && r.body?['receipt']?['status'] == 'ACCEPTED',
          )
          .length;
      // Under overload, a missing/503 result is provisional and must reconcile
      // by ORIGINAL envelope. Never equate a failed response to rollback.
      for (final body in commands) {
        await accepted(host, token, body);
        check(
          (await effectCounts(db, body)).every((n) => n == 1),
          'Concurrent profile reconciles one complete effect per command',
        );
      }
      final rows = <String, int>{};
      for (final table in [
        'users',
        'devices',
        'credentials',
        'grants',
        'audit',
      ]) {
        rows[table] =
            (await db.execute(
                  'SELECT count(*) FROM ventio_identity_$table',
                )).single[0]
                as int;
      }
      final rls = await pg.Connection.openFromUrl(runtimeUrl);
      double? readMs;
      int? readRows;
      String? readFailure;
      try {
        await rls.execute("SET statement_timeout='10s'");
        final watch = Stopwatch()..start();
        readRows = await rls.runTx((tx) async {
          await authority.admit(tx);
          await const PostgresIdentityStore().resolve(
            tx,
            OpaqueToken.digest(token),
            command: CommandEnvelope.fromJson(next()),
          );
          return (await tx.execute(
            pg.Sql.named(
              'SELECT record_id FROM ventio_records WHERE tenant_id=@tenant AND company_id=\'company-001\' AND branch_id=\'branch-001\' LIMIT 20',
            ),
            parameters: {'tenant': tenant},
          )).length;
        });
        readMs = watch.elapsedMicroseconds / 1000;
      } on pg.ServerException catch (error) {
        readFailure = error.code;
      } finally {
        await rls.close();
      }
      final entry = <String, Object?>{
        'fixtureUsers': size.$1,
        'fixtureAudit': size.$2,
        'actualRows': rows,
        'fingerprintMs': summary(fingerprintTimes),
        'httpConcurrency': 4,
        'httpSamples': durations.length,
        'httpMs': summary(durations),
        'httpAcceptedWithoutRetry': successes,
        'rlsReadLimit': 20,
        'rlsReadRows': readRows,
        'rlsReadMs': readMs,
        'rlsReadSqlState': readFailure,
      };
      metrics.add(entry);
      stdout.writeln('BENCHMARK: ${jsonEncode(entry)}');
      if (size.$1 == 10) {
        check(
          successes == 8 &&
              percentile(durations, .95) < 10000 &&
              readFailure == null,
          'Bounded small-profile acceptance: eight accepted commands, p95 below ten seconds, scoped read completes',
        );
      }
    }

    // Fail closed while the independent witness is pending during real admin TX.
    final entered = Completer<void>();
    final release = Completer<void>();
    final heldAuthority = RecoveryAuthority(
      authority.path,
      readerGroupId: gid,
      testBarrier: (stage) async {
        if (stage == 'before_commit') {
          entered.complete();
          await release.future;
        }
      },
    );
    final heldAdmin = IdentityAdministration(
      connection: administration,
      tenantId: tenant,
      operatorLabel: 'concurrent-audit',
      authority: heldAuthority,
    );
    final change = heldAdmin.grant(
      'user-001',
      'company-001',
      'branch-001',
      'maintenance.read',
    );
    await entered.future;
    final pendingCommand = next();
    check(
      (await request(host, token, pendingCommand)).status == 503,
      'Pending authority closes new command admission during administrative commit',
    );
    release.complete();
    await change;
    await accepted(host, token, pendingCommand);

    // Actual lock timeout must not be reported as an accepted command.
    final lockEntered = Completer<void>();
    final unlock = Completer<void>();
    final held = db.runTx((tx) async {
      await tx.execute('SELECT pg_advisory_xact_lock(86744321)');
      lockEntered.complete();
      await unlock.future;
    });
    await lockEntered.future;
    final timedCommand = next();
    check(
      (await request(host, token, timedCommand)).status == 503,
      'Database lock timeout produces no false acceptance',
    );
    unlock.complete();
    await held;
    await accepted(host, token, timedCommand);
    check(
      (await effectCounts(db, timedCommand)).every((n) => n == 1),
      'Lock-timeout retry does not duplicate command effects',
    );

    // Drain a real admitted command while SIGTERM is forwarded by sudo to Host.
    final drainEntered = Completer<void>();
    final drainRelease = Completer<void>();
    final drainLock = db.runTx((tx) async {
      await tx.execute('SELECT pg_advisory_xact_lock(86744321)');
      drainEntered.complete();
      await drainRelease.future;
    });
    await drainEntered.future;
    final drainCommand = next();
    final drainResponse = request(host, token, drainCommand);
    await waitFor(
      () async =>
          (await observer.execute(
                "SELECT count(*) FROM pg_stat_activity WHERE usename='ventio_runtime_test' AND wait_event_type='Lock'",
              )).single[0]
              as int >
          0,
      'admitted runtime waiter',
    );
    host.process.kill(ProcessSignal.sigterm);
    drainRelease.complete();
    await drainLock;
    check(
      (await drainResponse).status == 200,
      'SIGTERM drains the admitted real PostgreSQL command',
    );
    check(
      await host.process.exitCode.timeout(const Duration(seconds: 20)) == 0,
      'OS-separated production launcher exits after its drain',
    );
    active.remove(host);
    final restarted = await start();
    await accepted(restarted, token, drainCommand);
    await stop(restarted);
    check(
      (await effectCounts(db, drainCommand)).every((n) => n == 1),
      'Post-shutdown replay retains exactly one durable effect',
    );

    // Reproduce the fundamental rollback boundary rather than claiming a local
    // file is a monotonic external service. Operator-only, isolated restore.
    final oldWitness = jsonDecode(
      await PrivateFiles.readAuthority(authority.path),
    );
    final restoredUrl = await fixture.backupAndRestore(db);
    await fixture.provisionRestoredPasswords();
    restored = await pg.Connection.openFromUrl(restoredUrl);
    final targetRuntime = Uri.parse(
      runtimeUrl,
    ).replace(host: '127.0.0.1', port: Uri.parse(restoredUrl).port).toString();
    await admin.revokeCredential('audit-credential');
    final latestWitness = jsonDecode(
      await PrivateFiles.readAuthority(authority.path),
    );
    await PrivateFiles.replaceAuthority(authority.path, oldWitness, gid);
    await startupDenied(
      'Witness-only rollback is denied against current identity state',
    );
    await PrivateFiles.replaceAuthority(authority.path, latestWitness, gid);
    await startupDenied(
      'Database-only rollback is denied against latest independent witness',
      database: targetRuntime,
    );
    final bothPath = '${witness.path}/deliberately-old.json';
    await PrivateFiles.createAuthority(bothPath, oldWitness, gid);
    final both = await start(database: targetRuntime, file: bothPath);
    await accepted(both, token, next());
    check(
      true,
      'Known production blocker reproduced: rolling back BOTH trusted copies cannot prove freshness locally',
    );
    await stop(both);
    final versions = {
      'dart': Platform.version.split(' ').first,
      'postgres': (await db.execute('SHOW server_version')).single[0],
      'visibleLogicalProcessors': Platform.numberOfProcessors,
      'os': Platform.operatingSystem,
      'architecture': (await Process.run('uname', [
        '-m',
      ])).stdout.toString().trim(),
    };
    final result = {
      'schemaVersion': 1,
      'environment': versions,
      'profiles': metrics,
      'smallProfileGate': 'passed',
      'productionReadiness': 'blocked',
      'qualityScore': null,
    };
    await File(
      env['VENTIO_AUDIT_RESULTS_FILE'] ?? '/tmp/ventio-host-audit-results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
    stdout.writeln('ENVIRONMENT: ${jsonEncode(versions)}');
    stdout.writeln('RESULT: $assertions engineering audit assertions passed');
  } finally {
    for (final h in active) {
      h.process.kill(ProcessSignal.sigterm);
      await h.process.exitCode.timeout(const Duration(seconds: 20));
    }
    await observer.close();
    await restored?.close();
    await administration.close();
    await db.close();
    await fixture.close();
    await root.delete(recursive: true);
  }
}

Map<String, double> summary(List<double> values) => {
  'min': values.reduce(min),
  'median': percentile(values, .5),
  'p95': percentile(values, .95),
  'max': values.reduce(max),
};
double percentile(List<double> values, double fraction) {
  final sorted = [...values]..sort();
  return sorted[(sorted.length * fraction).ceil() - 1];
}
