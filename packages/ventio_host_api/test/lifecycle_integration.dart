import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'recovery/database_fixture.dart';
import 'recovery/commit_proxy.dart';
import 'recovery/support.dart';
import 'test_support.dart'
    show
        check,
        command,
        assertions,
        hasPrivateTestFilePermissions,
        hasForcedTerminationExitCode,
        makeTestFileReadableByEveryone,
        createPrivateTestDirectory;

Future<void> main() async {
  final env = Platform.environment;
  final ownerUrl = env['VENTIO_TEST_DATABASE_URL']!;
  final runtimeUrl = env['VENTIO_TEST_RUNTIME_DATABASE_URL']!;
  final adminUrl = env['VENTIO_TEST_ADMIN_DATABASE_URL']!;
  final fixture = await DatabaseFixture.guarded(ownerUrl);
  final directory = await createPrivateTestDirectory('ventio-lifecycle-');
  final authority = RecoveryAuthority('${directory.path}/authority.json');
  final db = await pg.Connection.openFromUrl(ownerUrl);
  final administration = await pg.Connection.openFromUrl(adminUrl);
  pg.Connection? targetDb;
  pg.Connection? targetAdmin;
  final running = <TestHost>[];
  final tenant = 'lifecycle-${DateTime.now().microsecondsSinceEpoch}';
  var counter = 8000;
  final tokens = <String>[];
  final admin = IdentityAdministration(
    connection: administration,
    tenantId: tenant,
    operatorLabel: 'lifecycle-test',
    authority: authority,
  );
  String path(String name) => '${directory.path}/$name.json';
  Map<String, dynamic> next(String device) =>
      command(tenant, id: ++counter)..['clientContext']['deviceId'] = device;
  final scopes = <Map<String, Object?>>[
    {
      'companyId': 'company-001',
      'branchId': 'branch-001',
      'permissions': ['maintenance.create'],
    },
  ];
  Future<TestHost> start(String url, String witness) async {
    final h = await TestHost.start(url, authorityFile: witness);
    running.add(h);
    return h;
  }

  Future<void> stop(TestHost h) async {
    await h.stop();
    running.remove(h);
  }

  Future<String> tokenFile(String file) async {
    final data =
        jsonDecode(await PrivateFiles.read(file)) as Map<String, dynamic>;
    final token = data['token'] as String;
    tokens.add(token);
    return token;
  }

  Future<void> refused(Future<void> Function() action, String label) async {
    var rejected = false;
    try {
      await action();
    } catch (_) {
      rejected = true;
    }
    check(rejected, label);
  }

  Future<void> startupDenied(String url, String? witness, String label) async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'test/recovery/same_account_host.dart'],
      environment: {
        'VENTIO_ALLOW_DATABASE_TESTS': 'yes',
        'VENTIO_ENABLE_LOCAL_HOST': 'yes',
        'VENTIO_HOST_DATABASE_URL': url,
        'VENTIO_HOST_PORT': '0',
        if (witness != null) 'VENTIO_RECOVERY_AUTHORITY_FILE': witness,
      },
    ).timeout(const Duration(seconds: 20));
    check(
      result.exitCode == 2 && !(result.stdout as String).contains('listening'),
      label,
    );
    check(
      tokens.every((t) => !('${result.stdout}${result.stderr}').contains(t)),
      'Startup diagnostics reveal no credential',
    );
  }

  Future<String> enroll(
    String device,
    String credential, {
    IdentityAdministration? operator,
    String? output,
  }) async {
    final a = operator ?? admin;
    await a.registerDevice('user-001', device);
    await a.grant(
      'user-001',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    final file = output ?? path(credential);
    await a.provisionToFile(
      actorId: 'user-001',
      deviceId: device,
      credentialId: credential,
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: scopes,
      outputPath: file,
    );
    return tokenFile(file);
  }

  Future<Map<String, dynamic>> cli(
    String name,
    String action,
    Map<String, Object?> fields, {
    String? witness,
  }) async {
    final file = path('request-$name');
    await PrivateFiles.create(file, {
      'authorityFile': witness ?? authority.path,
      'administrationDatabaseUrl': adminUrl,
      'operatorLabel': 'operator-cli',
      'tenantId': tenant,
      'action': action,
      ...fields,
    });
    return {'file': file};
  }

  Future<ProcessResult> invoke(Map<String, dynamic> request) => Process.run(
    Platform.resolvedExecutable,
    ['run', 'bin/identity_admin.dart', request['file'] as String],
  ).timeout(const Duration(seconds: 30));
  Future<void> allowed(
    TestHost h,
    String token,
    Map<String, dynamic> cmd,
  ) async {
    final result = await request(h, token, cmd);
    check(
      result.status == 200 && result.body?['receipt']?['status'] == 'ACCEPTED',
      'Scoped credential executes one authoritative command',
    );
  }

  try {
    await startupDenied(
      runtimeUrl,
      null,
      'Production launcher refuses missing independent recovery evidence',
    );
    await authority.resetForReenrollment(administration, 'initial-enrollment');
    final corruptWitness = path('corrupt-authority');
    await PrivateFiles.create(corruptWitness, {
      'version': 1,
      'pending': false,
      'authorityId': OpaqueToken.generate(),
      'fingerprint': List.filled(64, '0').join(),
    });
    await startupDenied(
      runtimeUrl,
      corruptWitness,
      'Unverified authority content cannot admit a production Host',
    );
    await admin.createUser('user-001');
    await admin.registerBranch('company-001', 'branch-001');
    await admin.registerBranch('company-001', 'branch-002');
    await admin.registerBranch('company-002', 'branch-002');
    await admin.grant(
      'user-001',
      'company-001',
      'branch-002',
      'maintenance.create',
    );
    await admin.grant(
      'user-001',
      'company-002',
      'branch-002',
      'maintenance.create',
    );
    final original = await enroll('device-001', 'original');
    final initialProof =
        (jsonDecode(await PrivateFiles.read(authority.path))
            as Map)['fingerprint'];
    await administration.execute("SET timezone='Asia/Beirut'");
    check(
      await RecoveryAuthority.snapshot(administration) == initialProof,
      'Independent fingerprint is invariant across administration session timezones',
    );
    await administration.execute("SET timezone='UTC'");
    final host = await start(runtimeUrl, authority.path);
    final saved = next('device-001');
    await allowed(host, original, saved);
    await admin.revokeGrant(
      'user-001',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    check(
      (await request(host, original, saved)).status == 403,
      'Current permission withdrawal blocks accepted-receipt retries under enforced admission',
    );
    await admin.grant(
      'user-001',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    await allowed(host, original, saved);
    check(
      (await effectCounts(db, saved)).every((n) => n == 1),
      'Reviewed permission restoration replays without duplicate effects',
    );
    for (final pair in [
      ('company-001', 'branch-002'),
      ('company-002', 'branch-002'),
      ('company-002', 'branch-001'),
    ]) {
      final forged = next('device-001')
        ..['companyId'] = pair.$1
        ..['branchId'] = pair.$2;
      check(
        (await request(host, original, forged)).status == 403,
        'Credential scope ceiling denies company/branch leakage',
      );
      check(
        (await effectCounts(db, forged)).every((n) => n == 0),
        'Denied scope leaves no journal/audit/outbox/record',
      );
    }
    final crossTenant = next('device-001')..['tenantId'] = '$tenant-other';
    check(
      (await request(host, original, crossTenant)).status == 403,
      'Credential cannot assert a different tenant',
    );
    check(
      await hasPrivateTestFilePermissions(path('original')),
      Platform.isWindows
          ? 'Delivery artifact is created with a protected owner/system/administrators ACL'
          : 'Delivery artifact is created with mode 0600',
    );
    final malformedRequest = await cli('unsupported', 'unsupported', {
      'secretMustNotLeak': original,
    });
    final rejectedCli = await invoke(malformedRequest);
    check(
      rejectedCli.exitCode == 2 &&
          !('${rejectedCli.stdout}${rejectedCli.stderr}').contains(original) &&
          !('${rejectedCli.stdout}${rejectedCli.stderr}').contains(adminUrl),
      'Administrative errors reveal neither submitted secrets nor database connection',
    );
    final unsafe = path('unsafe');
    await File(unsafe).writeAsString('unchanged');
    await makeTestFileReadableByEveryone(unsafe);
    await refused(
      () => PrivateFiles.read(unsafe).then((_) {}),
      'World-readable credential input is refused',
    );
    final link = path('symlink');
    await Link(link).create(path('original'));
    await refused(
      () => PrivateFiles.read(link).then((_) {}),
      'Credential input symlink is refused',
    );
    await refused(
      () => admin.provisionToFile(
        actorId: 'user-001',
        deviceId: 'device-001',
        credentialId: 'overwrite',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        allowedScopes: scopes,
        outputPath: path('original'),
      ),
      'Existing delivery artifact is never overwritten',
    );
    await refused(
      () => admin.provisionToFile(
        actorId: 'user-001',
        deviceId: 'device-001',
        credentialId: 'escalated',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        allowedScopes: [
          {
            'companyId': 'company-001',
            'branchId': 'branch-001',
            'permissions': ['identity.admin'],
          },
        ],
        outputPath: path('escalated'),
      ),
      'Provisioning cannot exceed current server grants',
    );
    await allowed(host, original, next('device-001'));

    final runtime = await pg.Connection.openFromUrl(runtimeUrl);
    try {
      for (final sql in [
        "SELECT ventio_security.recovery_snapshot()",
        "SELECT ventio_security.reset_recovery('x','x')",
        "SELECT ventio_security.admin_change('{}')",
      ]) {
        var denied = false;
        try {
          await runtime.execute(sql);
        } on pg.ServerException catch (e) {
          denied = e.code == '42501';
        }
        check(
          denied,
          'Runtime cannot obtain authority snapshot or administer identity',
        );
      }
      final withoutProof = await runtime.runTx(
        (tx) => const PostgresIdentityStore().resolve(
          tx,
          OpaqueToken.digest(original),
        ),
      );
      check(
        withoutProof == null,
        'Configured RLS identity resolution cannot bypass external admission proof',
      );
      final direct = await runtime.runTx((tx) async {
        await authority.admit(tx);
        final forged = next('device-001')
          ..['companyId'] = 'company-002'
          ..['branchId'] = 'branch-002';
        return const PostgresIdentityStore().resolve(
          tx,
          OpaqueToken.digest(original),
          command: CommandEnvelope.fromJson(forged),
        );
      });
      check(
        direct != null &&
            !direct.allowsInScope(
              'maintenance.create',
              'company-002',
              'branch-002',
            ),
        'Direct SQL proof retains exact credential scope ceiling',
      );
    } finally {
      await runtime.close();
    }

    final rotationRequests = await Future.wait([
      for (final id in ['rotation-a', 'rotation-b'])
        cli(id, 'rotate', {
          'actorId': 'user-001',
          'deviceId': 'device-001',
          'previousCredentialFile': path('original'),
          'credentialId': id,
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 2))
              .toUtc()
              .toIso8601String(),
          'outputPath': path(id),
        }),
    ]);
    final results = await Future.wait(rotationRequests.map(invoke));
    check(
      results.where((r) => r.exitCode == 0).length == 1 &&
          results.where((r) => r.exitCode == 2).length == 1,
      'Two actual CLI processes rotating the same credential have one winner',
    );
    final rotatedTokens = [
      await tokenFile(path('rotation-a')),
      await tokenFile(path('rotation-b')),
    ];
    final winner = results.indexWhere((r) => r.exitCode == 0);
    check(
      results.every(
        (r) => tokens.every((t) => !('${r.stdout}${r.stderr}').contains(t)),
      ),
      'Concurrent CLI success/error logs contain no raw credentials',
    );
    check(
      (await request(host, original, saved)).status == 401,
      'Rotated old credential cannot replay its saved receipt',
    );
    check(
      (await request(
            host,
            rotatedTokens[1 - winner],
            next('device-001'),
          )).status ==
          401,
      'Losing rotation artifact has no usable credential',
    );
    await allowed(host, rotatedTokens[winner], next('device-001'));
    final winningId = winner == 0 ? 'rotation-a' : 'rotation-b';
    final renewFile = path('renewed');
    await admin.rotateToFile(
      actorId: 'user-001',
      deviceId: 'device-001',
      previousCredentialId: winningId,
      previousToken: rotatedTokens[winner],
      credentialId: 'renewed',
      expiresAt: DateTime.now().add(const Duration(hours: 3)),
      outputPath: renewFile,
    );
    final renewed = await tokenFile(renewFile);
    check(
      (await request(host, rotatedTokens[winner], next('device-001'))).status ==
          401,
      'Renewal retires the previous secret instead of extending it in place',
    );
    await allowed(host, renewed, next('device-001'));
    await admin.revokeCredential('renewed');
    await admin.revokeCredential('renewed');
    check(
      (await request(host, renewed, next('device-001'))).status == 401,
      'Repeated revocation is safe and a revoked secret cannot be reused',
    );
    await refused(
      () => admin.rotateToFile(
        actorId: 'user-001',
        deviceId: 'device-001',
        previousCredentialId: 'renewed',
        previousToken: renewed,
        credentialId: 'revived',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        outputPath: path('revived'),
      ),
      'Revoked credential cannot renew or rotate',
    );
    final expiringFile = path('expiring');
    await admin.provisionToFile(
      actorId: 'user-001',
      deviceId: 'device-001',
      credentialId: 'expiring',
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      allowedScopes: scopes,
      outputPath: expiringFile,
    );
    final expiring = await tokenFile(expiringFile);
    await waitFor(
      () async =>
          (await db.execute(
            pg.Sql.named(
              "SELECT expires_at<=clock_timestamp() FROM ventio_identity_credentials WHERE tenant_id=@t AND credential_id='expiring'",
            ),
            parameters: {'t': tenant},
          )).single[0] ==
          true,
      'credential expiry',
      timeout: const Duration(minutes: 2),
    );
    check(
      (await request(host, expiring, next('device-001'))).status == 401,
      'Credential expiry is enforced by PostgreSQL time',
    );
    await refused(
      () => admin.rotateToFile(
        actorId: 'user-001',
        deviceId: 'device-001',
        previousCredentialId: 'expiring',
        previousToken: expiring,
        credentialId: 'expired-rotation',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        outputPath: path('expired-rotation'),
      ),
      'Expired credential requires fresh enrollment',
    );
    final raceToken = await enroll('race-device', 'race-original');
    final raceRequests = await Future.wait([
      cli('race-rotate', 'rotate', {
        'actorId': 'user-001',
        'deviceId': 'race-device',
        'previousCredentialFile': path('race-original'),
        'credentialId': 'race-new',
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
        'outputPath': path('race-new'),
      }),
      cli('race-revoke', 'revoke-device', {'deviceId': 'race-device'}),
    ]);
    final raceResults = await Future.wait(raceRequests.map(invoke));
    check(
      raceResults[1].exitCode == 0 && [0, 2].contains(raceResults[0].exitCode),
      'Concurrent rotation/device revocation linearize through independent processes',
    );
    final raceNew = await tokenFile(path('race-new'));
    check(
      (await request(host, raceToken, next('race-device'))).status == 401 &&
          (await request(host, raceNew, next('race-device'))).status == 401,
      'Device revocation defeats both old and concurrent replacement credentials',
    );
    await stop(host);
    final restarted = await start(runtimeUrl, authority.path);
    check(
      (await request(restarted, renewed, saved)).status == 401,
      'Credential revocation survives production Host restart',
    );
    await stop(restarted);

    // Real logical restore, then a later source revocation/permission change.
    final backupToken = await enroll('snapshot-device', 'snapshot-credential');
    final beforeSnapshot = await manifest(db);
    final restoredUrl = await fixture.backupAndRestore(db);
    targetDb = await pg.Connection.openFromUrl(restoredUrl);
    check(
      canonicalJson(await manifest(targetDb)) == canonicalJson(beforeSnapshot),
      'Backup bundle preserves enforced recovery state and scoped credentials',
    );
    await fixture.provisionRestoredPasswords();
    String targetLogin(String source) => Uri.parse(
      source,
    ).replace(host: '127.0.0.1', port: Uri.parse(restoredUrl).port).toString();
    final targetRuntime = targetLogin(runtimeUrl);
    targetAdmin = await pg.Connection.openFromUrl(targetLogin(adminUrl));
    final oldTarget = await start(targetRuntime, authority.path);
    await allowed(oldTarget, backupToken, next('snapshot-device'));
    await admin.revokeDevice('snapshot-device');
    await admin.revokeGrant(
      'user-001',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    final blocked = next('snapshot-device');
    check(
      (await request(oldTarget, backupToken, blocked)).status == 503,
      'Already-running restored Host closes access when latest independent witness changes',
    );
    check(
      (await effectCounts(targetDb, blocked)).every((n) => n == 0),
      'Stale restored authorization cannot commit a command',
    );
    await stop(oldTarget);
    await startupDenied(
      targetRuntime,
      authority.path,
      'Restored stale database cannot reopen with latest trusted witness',
    );
    await startupDenied(
      targetRuntime,
      path('missing-authority'),
      'Missing authority never falls back to a restored DB snapshot',
    );
    final replacement = RecoveryAuthority(path('replacement-authority'));
    await replacement.resetForReenrollment(
      targetAdmin,
      'operator-verified-reenrollment',
    );
    check(
      (await targetDb.execute(
            'SELECT count(*) FROM ventio_identity_grants',
          )).single[0] ==
          0,
      'No-evidence recovery clears every old permission grant',
    );
    check(
      (await targetDb.execute(
            'SELECT count(*) FROM ventio_identity_credentials WHERE revoked_at IS NULL',
          )).single[0] ==
          0,
      'No-evidence recovery permanently retires all restored credentials',
    );
    final targetHost = await start(targetRuntime, replacement.path);
    check(
      (await request(
            targetHost,
            backupToken,
            next('snapshot-device'),
          )).status ==
          401,
      'Reset cannot revive a credential/device from an old backup',
    );
    final replacementAdmin = IdentityAdministration(
      connection: targetAdmin,
      tenantId: tenant,
      operatorLabel: 'reviewed-reenrollment',
      authority: replacement,
    );
    await replacementAdmin.registerDevice('user-001', 'reviewed-device');
    await refused(
      () => replacementAdmin.provisionToFile(
        actorId: 'user-001',
        deviceId: 'reviewed-device',
        credentialId: 'unreviewed',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        allowedScopes: scopes,
        outputPath: path('unreviewed'),
      ),
      'Reenrollment cannot inherit stale permissions without explicit review',
    );
    await replacementAdmin.grant(
      'user-001',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    await replacementAdmin.provisionToFile(
      actorId: 'user-001',
      deviceId: 'reviewed-device',
      credentialId: 'reviewed',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      allowedScopes: scopes,
      outputPath: path('reviewed'),
    );
    await allowed(
      targetHost,
      await tokenFile(path('reviewed')),
      next('reviewed-device'),
    );
    check(
      (await request(
            targetHost,
            backupToken,
            next('snapshot-device'),
          )).status ==
          401,
      'Reviewed new device does not reactivate any old credential',
    );
    await stop(targetHost);

    // Actual SIGKILL while issuing/revoking, at all commit boundaries. The
    // witness remains pending even when the database commit outcome is known.
    for (final action in ['provision', 'revoke-credential']) {
      for (final stage in [
        'before_database',
        'before_commit',
        'after_commit',
      ]) {
        await authority.resetForReenrollment(
          administration,
          'crash-fixture-reset',
        );
        final device = 'crash-${++counter}';
        final existingId = 'existing-$counter';
        final existing = await enroll(device, existingId);
        final issuedId = 'interrupted-$counter';
        final config = path('worker-$counter');
        await PrivateFiles.create(config, {
          'administrationDatabaseUrl': adminUrl,
          'authorityFile': authority.path,
          'tenantId': tenant,
          'stage': stage,
          'action': action,
          'deviceId': device,
          'credentialId': action == 'provision' ? issuedId : existingId,
          'outputPath': path(issuedId),
        });
        final process = await Process.start(
          Platform.resolvedExecutable,
          ['run', 'test/recovery/lifecycle_worker.dart', config],
          environment: {'VENTIO_ALLOW_DATABASE_TESTS': 'yes'},
        );
        process.stderr.drain<void>();
        final event =
            jsonDecode(
                  await process.stdout
                      .transform(utf8.decoder)
                      .transform(const LineSplitter())
                      .first
                      .timeout(const Duration(seconds: 20)),
                )
                as Map;
        check(
          event['event'] == 'barrier' && event['stage'] == stage,
          'Administration reached real $action $stage barrier',
        );
        check(
          process.kill(ProcessSignal.sigkill),
          'Administration process receives an immediate forced termination',
        );
        check(
          hasForcedTerminationExitCode(await process.exitCode),
          'Administration process terminated without cleanup',
        );
        await waitFor(
          () async =>
              (await db.execute(
                pg.Sql.named(
                  'SELECT count(*) FROM pg_stat_activity WHERE pid=@pid',
                ),
                parameters: {'pid': event['backend']},
              )).single[0] ==
              0,
          'administration backend rollback/close',
        );
        if (action == 'provision') {
          final count = (await db.execute(
            pg.Sql.named(
              'SELECT count(*) FROM ventio_identity_credentials WHERE tenant_id=@t AND credential_id=@c',
            ),
            parameters: {'t': tenant, 'c': issuedId},
          )).single[0];
          check(
            count == (stage == 'after_commit' ? 1 : 0),
            'Interrupted issuance has the expected atomic committed state',
          );
        } else {
          final revoked = (await db.execute(
            pg.Sql.named(
              'SELECT revoked_at IS NOT NULL FROM ventio_identity_credentials WHERE tenant_id=@t AND credential_id=@c',
            ),
            parameters: {'t': tenant, 'c': existingId},
          )).single[0];
          check(
            revoked == (stage == 'after_commit'),
            'Interrupted revocation has the expected atomic committed state',
          );
        }
        final expectedAction = action == 'provision'
            ? 'CREDENTIAL_PROVISIONED'
            : 'CREDENTIAL_REVOKED';
        final subject = action == 'provision' ? issuedId : existingId;
        final auditCount = (await db.execute(
          pg.Sql.named(
            'SELECT count(*) FROM ventio_identity_audit WHERE tenant_id=@tenant AND action=@action AND subject_id=@subject',
          ),
          parameters: {
            'tenant': tenant,
            'action': expectedAction,
            'subject': subject,
          },
        )).single[0];
        check(
          auditCount == (stage == 'after_commit' ? 1 : 0),
          'Interrupted credential mutation and its audit commit atomically',
        );
        check(
          (jsonDecode(await PrivateFiles.read(authority.path))
                  as Map)['pending'] ==
              true,
          'SIGKILL leaves durable independent evidence pending',
        );
        if (action == 'provision') await tokenFile(path(issuedId));
        await startupDenied(
          runtimeUrl,
          authority.path,
          'Interrupted administration leaves recovery admission closed across restart',
        );
        await authority.resetForReenrollment(
          administration,
          'verified-safe-reset',
        );
        final resetHost = await start(runtimeUrl, authority.path);
        check(
          (await request(resetHost, existing, next(device))).status == 401,
          'Crash recovery reset never resurrects an old secret',
        );
        await stop(resetHost);
      }
    }
    // Actual PostgreSQL COMMIT succeeds but its acknowledgement is withheld.
    // An unknown administrative outcome must leave the external witness pending.
    await authority.resetForReenrollment(
      administration,
      'unknown-commit-setup',
    );
    await enroll('unknown-device', 'unknown-original');
    final adminUri = Uri.parse(adminUrl);
    final proxy = CommitProxy(
      adminUri.host,
      adminUri.port,
      forwardCommit: true,
    );
    await proxy.start();
    final uncertainDb = await pg.Connection.openFromUrl(
      adminUri.replace(host: '127.0.0.1', port: proxy.port).toString(),
    );
    try {
      final uncertainAdmin = IdentityAdministration(
        connection: uncertainDb,
        tenantId: tenant,
        operatorLabel: 'unknown-commit-test',
        authority: authority,
      );
      final outcome = uncertainAdmin
          .provisionToFile(
            actorId: 'user-001',
            deviceId: 'unknown-device',
            credentialId: 'unknown-result',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
            allowedScopes: scopes,
            outputPath: path('unknown-result'),
          )
          .then((_) => true, onError: (Object _) => false);
      await proxy.reached.future.timeout(const Duration(seconds: 20));
      await proxy.close();
      check(
        !await outcome,
        'Lost administrative COMMIT acknowledgement never reports completion',
      );
      await tokenFile(path('unknown-result'));
      check(
        (await db.execute(
              pg.Sql.named(
                "SELECT count(*) FROM ventio_identity_credentials WHERE tenant_id=@tenant AND credential_id='unknown-result'",
              ),
              parameters: {'tenant': tenant},
            )).single[0] ==
            1,
        'Unknown issuance outcome can contain a real committed credential',
      );
      check(
        (jsonDecode(await PrivateFiles.read(authority.path))
                as Map)['pending'] ==
            true,
        'Unknown commit outcome never publishes ready recovery evidence',
      );
      await startupDenied(
        runtimeUrl,
        authority.path,
        'Unknown administrative commit blocks production admission',
      );
    } finally {
      await proxy.close();
      await uncertainDb.close();
    }
    await authority.resetForReenrollment(
      administration,
      'unknown-commit-safe-reenrollment',
    );
    final serverLogs = fixture.serverLog == null
        ? await Process.run('docker', ['logs', fixture.source])
        : await fixture.serverLog!.readAsString();
    final serverLogText = serverLogs is ProcessResult
        ? '${serverLogs.stdout}${serverLogs.stderr}'
        : serverLogs as String;
    check(
      tokens.every((token) => !serverLogText.contains(token)),
      'PostgreSQL/container logs contain no raw provisioned credential',
    );
    final audit =
        (await db.execute(
              'SELECT coalesce(jsonb_agg(details)::text,\'\') FROM ventio_identity_audit',
            )).single[0]
            as String;
    check(
      tokens.every(
        (t) => !audit.contains(t) && !audit.contains(OpaqueToken.digest(t)),
      ),
      'Identity audit stores neither raw tokens nor credential digests',
    );
    stdout.writeln(
      'RESULT: $assertions credential lifecycle and recovery admission assertions passed',
    );
  } finally {
    for (final host in running) {
      host.process.kill(ProcessSignal.sigkill);
      await host.process.exitCode;
    }
    await targetAdmin?.close();
    await targetDb?.close();
    await administration.close();
    await db.close();
    await fixture.close();
    await directory.delete(recursive: true);
  }
}
