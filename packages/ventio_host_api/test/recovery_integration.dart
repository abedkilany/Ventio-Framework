// Real process/connection interruption and isolated logical restore verification.
import 'dart:io';
import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'recovery/commit_proxy.dart';
import 'recovery/database_fixture.dart';
import 'recovery/support.dart';
import 'test_support.dart' show command, check, assertions;

Future<void> main() async {
  final env = Platform.environment;
  final url = env['VENTIO_TEST_DATABASE_URL']!;
  final runtimeUrl = env['VENTIO_TEST_RUNTIME_DATABASE_URL']!;
  final adminUrl = env['VENTIO_TEST_ADMIN_DATABASE_URL']!;
  for (final value in [url, runtimeUrl, adminUrl]) {
    final uri = Uri.parse(value);
    if (env['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
        uri.path != '/ventio_host_test' ||
        !{'localhost', '127.0.0.1'}.contains(uri.host)) {
      throw StateError('Isolated loopback test database required');
    }
  }
  final fixture = await DatabaseFixture.guarded(url);
  pg.Connection? control;
  pg.Connection? administration;
  pg.Connection? restoredControl;
  pg.Connection? restoredAdmin;
  final hosts = <TestHost>[];
  final proxies = <CommitProxy>[];
  final tenant = 'recovery-${DateTime.now().microsecondsSinceEpoch}';
  final acknowledged = <String, (Map<String, dynamic>, Map<String, dynamic>)>{};
  var sequence = 5000;
  Map<String, dynamic> next() => command(tenant, id: ++sequence);
  Future<TestHost> host({
    String? stage,
    String? executionUrl,
    String? databaseUrl,
  }) async {
    final h = await TestHost.start(
      databaseUrl ?? runtimeUrl,
      stage: stage,
      executionUrl: executionUrl,
    );
    hosts.add(h);
    return h;
  }

  Future<void> kill(TestHost h) async {
    await h.kill();
    hosts.remove(h);
  }

  Future<void> stop(TestHost h) async {
    await h.stop();
    hosts.remove(h);
  }

  Future<void> gone(int backend) => waitFor(
    () async =>
        (await control!.execute(
          pg.Sql.named('SELECT count(*) FROM pg_stat_activity WHERE pid=@pid'),
          parameters: {'pid': backend},
        )).single[0] ==
        0,
    'terminated command backend',
  );
  Future<void> counts(
    Map<String, dynamic> cmd,
    int expected,
    String label, {
    pg.Connection? db,
  }) async {
    check(
      (await effectCounts(db ?? control!, cmd)).every((n) => n == expected),
      label,
    );
  }

  Future<Map<String, dynamic>> accepted(
    TestHost h,
    String token,
    Map<String, dynamic> cmd,
  ) async {
    final response = await request(h, token, cmd);
    check(
      response.status == 200 &&
          response.body?['receipt']?['status'] == 'ACCEPTED',
      'Command accepted through restricted persistent Host',
    );
    final receipt = response.body!['receipt'] as Map<String, dynamic>;
    acknowledged[cmd['commandId'] as String] = (cmd, receipt);
    return receipt;
  }

  bool same(Object? a, Object? b) => canonicalJson(a) == canonicalJson(b);
  try {
    control = await pg.Connection.openFromUrl(url);
    administration = await pg.Connection.openFromUrl(adminUrl);
    final admin = IdentityAdministration(
      connection: administration,
      tenantId: tenant,
      operatorLabel: 'recovery-test',
    );
    Future<String> provision(
      String actor,
      String device, {
      DateTime? expires,
    }) async {
      await admin.createUser(actor);
      await admin.registerDevice(actor, device);
      await admin.grant(
        actor,
        'company-001',
        'branch-001',
        'maintenance.create',
      );
      return admin.issueCredential(
        actorId: actor,
        deviceId: device,
        credentialId: 'credential-$device',
        expiresAt:
            expires ?? DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
    }

    await admin.registerBranch('company-001', 'branch-001');
    final token = await provision('user-001', 'device-001');
    for (final setting in ['fsync', 'full_page_writes', 'synchronous_commit']) {
      check(
        (await control.execute('SHOW $setting')).single[0] == 'on',
        'PostgreSQL $setting enabled for crash tests',
      );
    }
    // Each kill interrupts a real separate Host process while its DB transaction
    // is paused. No exception injection is used to cause rollback.
    for (final stage in [
      'after_reservation',
      'after_record',
      'after_audit',
      'after_outbox',
      'before_commit',
      'after_commit',
    ]) {
      final cmd = next();
      final worker = await host(stage: stage);
      final response = request(worker, token, cmd);
      final barrier = await worker.event('barrier');
      final committed = stage == 'after_commit';
      final receipt = committed ? await savedReceipt(control, cmd) : null;
      await kill(worker);
      await response;
      await gone(barrier['backend'] as int);
      await counts(
        cmd,
        committed ? 1 : 0,
        'SIGKILL at $stage leaves all four effects ${committed ? 'committed' : 'absent'}',
      );
      final restarted = await host();
      final first = await accepted(restarted, token, cmd);
      final second = await accepted(restarted, token, cmd);
      check(
        same(first, second) && (!committed || same(first, receipt)),
        'Restart at $stage returns stable journal receipt',
      );
      await counts(
        cmd,
        1,
        'Restart retry at $stage creates exactly one complete effect',
      );
      await stop(restarted);
    }
    // A duplicate waits on the uncommitted unique reservation. Two unrelated
    // Host workers then die together on opposite sides of commit.
    await admin.registerBranch('company-002', 'branch-002');
    await admin.grant(
      'user-001',
      'company-002',
      'branch-002',
      'maintenance.create',
    );
    await administration.close();
    administration = null;
    final alpha = next();
    final beta = next()
      ..['companyId'] = 'company-002'
      ..['branchId'] = 'branch-002';
    final a = await host(stage: 'before_commit');
    final ar = request(a, token, alpha);
    await _barrierBeforeResponse(a, ar);
    final b = await host(stage: 'unused');
    final br = request(b, token, alpha);
    await waitFor(
      () async => (await control!.execute(
        pg.Sql.named(
          "SELECT pid FROM pg_stat_activity WHERE application_name=@app AND wait_event_type='Lock' LIMIT 1",
        ),
        parameters: {'app': b.applicationName},
      )).isNotEmpty,
      'concurrent Host lock wait',
    );
    final c = await host(stage: 'after_commit');
    final cr = request(c, token, beta);
    await _barrierBeforeResponse(c, cr);
    final betaReceipt = await savedReceipt(control, beta);
    await Future.wait([kill(a), kill(c)]);
    await Future.wait([ar, cr]);
    final survivor = await br;
    check(
      survivor.status == 200 &&
          survivor.body?['receipt']?['status'] == 'ACCEPTED',
      'Waiting duplicate survives concurrent Host SIGKILLs',
    );
    await kill(b);
    final recovered = await host();
    check(
      same(await accepted(recovered, token, alpha), survivor.body?['receipt']),
      'Duplicate winner receipt survives restart',
    );
    check(
      same(await accepted(recovered, token, beta), betaReceipt),
      'Concurrently committed command receipt survives restart',
    );
    await counts(
      alpha,
      1,
      'Concurrent duplicate has one journal/audit/outbox/record',
    );
    await counts(
      beta,
      1,
      'Concurrent committed command has one journal/audit/outbox/record',
    );
    await stop(recovered);

    for (final forwarded in [false, true]) {
      final source = Uri.parse(runtimeUrl);
      final proxy = CommitProxy(
        source.host,
        source.port,
        forwardCommit: forwarded,
      );
      proxies.add(proxy);
      await proxy.start();
      final proxiedUrl = source
          .replace(host: '127.0.0.1', port: proxy.port)
          .toString();
      final cmd = next();
      final worker = await host(stage: 'unused', executionUrl: proxiedUrl);
      final response = request(worker, token, cmd);
      await proxy.reached.future.timeout(const Duration(seconds: 20));
      final receipt = forwarded ? await savedReceipt(control, cmd) : null;
      await proxy.close();
      proxies.remove(proxy);
      final lost = await response;
      check(
        lost.status != 200,
        'Lost commit acknowledgement is never reported as success',
      );
      await kill(worker);
      await counts(
        cmd,
        forwarded ? 1 : 0,
        'Unknown-outcome connection leaves the expected committed state before retry',
      );
      final restarted = await host();
      final retried = await accepted(restarted, token, cmd);
      check(
        !forwarded || same(retried, receipt),
        'Unknown commit outcome reconciles ${forwarded ? 'committed' : 'uncommitted'} transaction by original ID',
      );
      await counts(
        cmd,
        1,
        'Unknown commit outcome retry has exactly one complete effect',
      );
      await stop(restarted);
    }
    final terminated = next();
    final backendHost = await host(stage: 'before_commit');
    final pending = request(backendHost, token, terminated);
    final backend = (await backendHost.event('barrier'))['backend'];
    check(
      (await control.execute(
            pg.Sql.named('SELECT pg_terminate_backend(@pid)'),
            parameters: {'pid': backend},
          )).single[0] ==
          true,
      'PostgreSQL command backend forcibly terminated',
    );
    backendHost.resume();
    check(
      (await pending).status != 200,
      'Terminated PostgreSQL backend cannot report accepted',
    );
    await kill(backendHost);
    await counts(
      terminated,
      0,
      'Backend termination rolls back all four effects',
    );
    final backendRestart = await host();
    await accepted(backendRestart, token, terminated);
    await stop(backendRestart);

    final before = next();
    final after = next()
      ..['companyId'] = 'company-002'
      ..['branchId'] = 'branch-002';
    final beforeHost = await host(stage: 'before_commit');
    final beforeResponse = request(beforeHost, token, before);
    await beforeHost.event('barrier');
    final afterHost = await host(stage: 'after_commit');
    final afterResponse = request(afterHost, token, after);
    await afterHost.event('barrier');
    final afterReceipt = await savedReceipt(control, after);
    await administration?.close();
    administration = null;
    await control.close();
    control = null;
    // This is actual PostgreSQL PID 1 SIGKILL on the dedicated container,
    // followed by startup on its existing volume, not a thrown DB exception.
    await fixture.restartAfterKill();
    await Future.wait([kill(beforeHost), kill(afterHost)]);
    await Future.wait([beforeResponse, afterResponse]);
    control = await pg.Connection.openFromUrl(url);
    administration = await pg.Connection.openFromUrl(adminUrl);
    for (final entry in acknowledged.values) {
      check(
        same(await savedReceipt(control, entry.$1), entry.$2),
        'Server crash retains previously HTTP-acknowledged receipt',
      );
      await counts(
        entry.$1,
        1,
        'Server crash retains every previously acknowledged complete effect',
      );
    }
    await counts(
      before,
      0,
      'PostgreSQL server crash discards uncommitted command',
    );
    await counts(
      after,
      1,
      'PostgreSQL server crash retains committed journal and effects',
    );
    final walHost = await host();
    await accepted(walHost, token, before);
    check(
      same(await accepted(walHost, token, after), afterReceipt),
      'WAL recovery preserves exact committed receipt',
    );
    await counts(
      before,
      1,
      'WAL recovery retry applies previously uncommitted command once',
    );
    await stop(walHost);

    final backupAdmin = IdentityAdministration(
      connection: administration,
      tenantId: tenant,
      operatorLabel: 'backup-test',
    );
    // Provision all identity states before the snapshot. Expiry is evaluated
    // using PostgreSQL time, independently of process restarts and restore.
    final revokedToken = await provisionWith(
      backupAdmin,
      'revoked-user',
      'revoked-device',
    );
    final revokedCredential = await provisionWith(
      backupAdmin,
      'credential-user',
      'credential-device',
    );
    final deniedToken = await provisionWith(
      backupAdmin,
      'denied-user',
      'denied-device',
    );
    final expiredToken = await provisionWith(
      backupAdmin,
      'expired-user',
      'expired-device',
      expires: DateTime.now().toUtc().add(const Duration(seconds: 2)),
    );
    await waitFor(
      () async =>
          (await control!.execute(
            pg.Sql.named(
              "SELECT expires_at <= clock_timestamp() FROM ventio_identity_credentials WHERE tenant_id=@tenant AND credential_id='credential-expired-device'",
            ),
            parameters: {'tenant': tenant},
          )).single[0] ==
          true,
      'real credential expiry before backup',
    );
    final laterToken = await provisionWith(
      backupAdmin,
      'later-user',
      'later-device',
    );
    await backupAdmin.revokeDevice('revoked-device');
    await backupAdmin.revokeCredential('credential-credential-device');
    await backupAdmin.revokeGrant(
      'denied-user',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    final baseline = await manifest(control);
    final restoredUrl = await fixture.backupAndRestore(control);
    restoredControl = await pg.Connection.openFromUrl(restoredUrl);
    final restoredManifest = await manifest(restoredControl);
    final differences = baseline.keys
        .where((key) => baseline[key] != restoredManifest[key])
        .join(', ');
    if (differences.contains('security-1')) {
      final sourceRelations = await relationSecurityRows(control);
      final targetRelations = await relationSecurityRows(restoredControl);
      for (var index = 0; index < sourceRelations.length; index++) {
        if (!same(sourceRelations[index], targetRelations[index])) {
          stdout.writeln(
            'RELATION_DIFF source=${jsonEncode(sourceRelations[index])} target=${jsonEncode(targetRelations[index])}',
          );
        }
      }
    }
    check(
      same(restoredManifest, baseline),
      'Fresh cluster restore preserves full rows, sequences, migration ledger, roles, ACLs, function definitions and FORCE RLS policies (differences: $differences)',
    );
    await fixture.provisionRestoredPasswords();
    String restoredLogin(String original) => Uri.parse(
      original,
    ).replace(host: '127.0.0.1', port: Uri.parse(restoredUrl).port).toString();
    final restoredRuntime = restoredLogin(runtimeUrl);
    restoredAdmin = await pg.Connection.openFromUrl(restoredLogin(adminUrl));
    final runtime = await pg.Connection.openFromUrl(restoredRuntime);
    try {
      await verifyRuntimeConnection(runtime);
      check(
        (await runtime.execute(
              'SELECT count(*) FROM ventio_command_journal',
            )).single[0] ==
            0,
        'Restored RLS denies unproven direct SQL scope',
      );
      var denied = false;
      try {
        await runtime.execute(
          "UPDATE ventio_identity_devices SET revoked_at=NULL",
        );
      } on pg.ServerException catch (error) {
        denied = error.code == '42501';
      }
      check(
        denied,
        'Restored runtime cannot undo device revocation through direct SQL',
      );
    } finally {
      await runtime.close();
    }
    // Deliberately demonstrate snapshot RPO: accepted writes and revocations
    // AFTER pg_dump are absent from an older restore. Keep target quarantined.
    final lateCommand = next();
    final sourceHost = await host();
    await accepted(sourceHost, token, lateCommand);
    await stop(sourceHost);
    await backupAdmin.revokeDevice('later-device');
    await counts(
      lateCommand,
      0,
      'Snapshot restore does not claim to recover commands accepted after backup',
      db: restoredControl,
    );
    final lateRevocation = await restoredControl.execute(
      pg.Sql.named(
        'SELECT revoked_at FROM ventio_identity_devices WHERE tenant_id=@tenant AND device_id=\'later-device\'',
      ),
      parameters: {'tenant': tenant},
    );
    check(
      lateRevocation.single[0] == null,
      'Snapshot alone cannot preserve post-backup device revocation',
    );
    final reconciliation = IdentityAdministration(
      connection: restoredAdmin,
      tenantId: tenant,
      operatorLabel: 'restore-reconciliation',
    );
    await reconciliation.revokeDevice('later-device');
    final targetHost = await host(databaseUrl: restoredRuntime);
    check(
      same(await accepted(targetHost, token, after), afterReceipt),
      'Restored Host replays pre-backup accepted receipt without reapplying effects',
    );
    await counts(
      after,
      1,
      'Restored replay preserves single audit and outbox',
      db: restoredControl,
    );
    for (final entry in [
      (revokedToken, 'revoked-user', 'revoked-device', 401),
      (revokedCredential, 'credential-user', 'credential-device', 401),
      (deniedToken, 'denied-user', 'denied-device', 403),
      (expiredToken, 'expired-user', 'expired-device', 401),
      (laterToken, 'later-user', 'later-device', 401),
    ]) {
      final cmd = next();
      cmd['clientContext']['actorId'] = entry.$2;
      cmd['clientContext']['deviceId'] = entry.$3;
      check(
        (await request(targetHost, entry.$1, cmd)).status == entry.$4,
        'Restored authorization rejects ${entry.$3}',
      );
      await counts(
        cmd,
        0,
        'Denied restored identity leaves no command effects',
        db: restoredControl,
      );
    }
    final foreign = next()..['branchId'] = 'foreign-branch';
    check(
      (await request(targetHost, token, foreign)).status == 403,
      'Restored Host rejects manipulated branch',
    );
    final foreignCompany = next()..['companyId'] = 'foreign-company';
    check(
      (await request(targetHost, token, foreignCompany)).status == 403,
      'Restored Host rejects manipulated company',
    );
    final foreignTenant = next()..['tenantId'] = '$tenant-foreign';
    check(
      (await request(targetHost, token, foreignTenant)).status == 403,
      'Restored Host rejects manipulated tenant',
    );
    final newCommand = next();
    await accepted(targetHost, token, newCommand);
    await counts(
      newCommand,
      1,
      'Restored sequences allow a new atomic journal/audit/outbox command',
      db: restoredControl,
    );
    await reconciliation.revokeDevice('device-001');
    check(
      (await request(targetHost, token, after)).status == 401,
      'Revoked restored device cannot retrieve an old accepted receipt',
    );
    await stop(targetHost);
    final targetRestart = await host(databaseUrl: restoredRuntime);
    check(
      (await request(targetRestart, token, after)).status == 401,
      'Restored revocation survives another production Host restart',
    );
    await stop(targetRestart);
    // An independent restored cluster is new evidence: rerun the full existing
    // identity and hostile-SQL suites with the restored restricted logins.
    for (final suite in [
      'identity_integration',
      'database_security_integration',
    ]) {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'test/$suite.dart'],
        environment: {
          'VENTIO_ALLOW_DATABASE_TESTS': 'yes',
          'VENTIO_TEST_DATABASE_URL': restoredUrl,
          'VENTIO_TEST_RUNTIME_DATABASE_URL': restoredRuntime,
          'VENTIO_TEST_ADMIN_DATABASE_URL': restoredLogin(adminUrl),
          'VENTIO_TEST_MIGRATION_DATABASE_URL': Uri.parse(restoredRuntime)
              .replace(userInfo: 'ventio_migration_test:migration_test_only')
              .toString(),
        },
      ).timeout(const Duration(seconds: 120));
      check(result.exitCode == 0, 'Full $suite passes on restored cluster');
      for (final line in (result.stdout as String).split('\n')) {
        if (line.startsWith('RESULT:')) stdout.writeln('RESTORED $line');
      }
    }
    stdout.writeln(
      'RESULT: $assertions crash recovery and backup/restore assertions passed',
    );
  } finally {
    for (final proxy in proxies) {
      await proxy.close();
    }
    for (final h in hosts) {
      h.process.kill(ProcessSignal.sigkill);
      await h.process.exitCode;
    }
    await restoredAdmin?.close();
    await restoredControl?.close();
    await administration?.close();
    await control?.close();
    await fixture.close();
  }
}

Future<void> _barrierBeforeResponse(
  TestHost host,
  Future<HttpOutcome> response,
) async {
  await Future.any<void>([
    host.event('barrier'),
    response.then<void>((outcome) {
      final error = outcome.body?['error'];
      final code = error is Map ? error['code'] : null;
      throw StateError(
        'Host request returned before its crash barrier '
        '(status: ${outcome.status}, code: $code, '
        'events: ${host.observedEvents.isEmpty ? 'none' : host.observedEvents}, '
        'diagnostics: ${host.safeDiagnostics.isEmpty ? 'none' : host.safeDiagnostics})',
      );
    }),
  ]);
}

Future<String> provisionWith(
  IdentityAdministration admin,
  String actor,
  String device, {
  DateTime? expires,
}) async {
  await admin.createUser(actor);
  await admin.registerDevice(actor, device);
  await admin.grant(actor, 'company-001', 'branch-001', 'maintenance.create');
  return admin.issueCredential(
    actorId: actor,
    deviceId: device,
    credentialId: 'credential-$device',
    expiresAt: expires ?? DateTime.now().toUtc().add(const Duration(hours: 1)),
  );
}
