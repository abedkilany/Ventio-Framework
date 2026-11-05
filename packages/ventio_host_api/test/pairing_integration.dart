import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart';

class _PairingIntegrationExecutor implements AuthoritativeCommandExecutor {
  @override
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session,
  ) async =>
      CommandReceipt(commandId: command.commandId, status: 'ACCEPTED').toJson();
}

class _SlowPairingTimeoutMarker {
  const _SlowPairingTimeoutMarker();
}

Future<void> main() async {
  final auditUrl = Platform.environment['VENTIO_TEST_DATABASE_URL'];
  final runtimeUrl = Platform.environment['VENTIO_TEST_RUNTIME_DATABASE_URL'];
  final adminUrl = Platform.environment['VENTIO_TEST_ADMIN_DATABASE_URL'];
  final migrationUrl =
      Platform.environment['VENTIO_TEST_MIGRATION_DATABASE_URL'];
  final apiAdminUrl =
      Platform.environment['VENTIO_TEST_API_ADMIN_DATABASE_URL'];
  if (auditUrl == null ||
      runtimeUrl == null ||
      adminUrl == null ||
      migrationUrl == null ||
      apiAdminUrl == null ||
      Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
      ![
        auditUrl,
        runtimeUrl,
        adminUrl,
        migrationUrl,
        apiAdminUrl,
      ].every(_isDisposableTestDatabase)) {
    stderr.writeln(
      'Pairing integration requires the disposable ventio_host_test database and explicit test opt-in.',
    );
    exitCode = 2;
    return;
  }

  final audit = await pg.Connection.openFromUrl(auditUrl);
  final admin = await pg.Connection.openFromUrl(adminUrl);
  final migration = await pg.Connection.openFromUrl(migrationUrl);
  final temporary = await createPrivateTestDirectory('ventio-pairing-');
  var holdAfterCommit = false;
  Completer<void>? afterCommitEntered;
  Completer<void>? releaseAfterCommit;
  final authority = RecoveryAuthority(
    '${temporary.path}/authority.json',
    testBarrier: (stage) async {
      if (stage == 'after_commit' && holdAfterCommit) {
        holdAfterCommit = false;
        afterCommitEntered!.complete();
        await releaseAfterCommit!.future;
      }
    },
  );
  final tenant = 'pairing-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  const company = 'company-pairing';
  const branch = 'branch-pairing';
  HostApi? api;
  pg.Pool<dynamic>? pairingAdministrationPool;
  final additionalApis = <HostApi>[];
  var assertions = 0;
  void check(bool condition, String label) {
    if (!condition) throw StateError('FAIL: $label');
    assertions++;
    stdout.writeln('PASS: $label');
  }

  try {
    await authority.resetForReenrollment(admin, 'pairing-integration-reset');
    final operator = IdentityAdministration(
      connection: admin,
      tenantId: tenant,
      operatorLabel: 'pairing-integration-operator',
      authority: authority,
    );
    await operator.registerBranch(company, branch);
    await operator.registerBranch(company, 'branch-other');

    await operator.createUser('pairing-manager');
    await operator.registerDevice('pairing-manager', 'pairing-manager-host');
    await operator.grant(
      'pairing-manager',
      company,
      branch,
      identityPairingManagePermission,
    );
    await operator.grant(
      'pairing-manager',
      company,
      branch,
      identityDevicesManagePermission,
    );
    await operator.grant(
      'pairing-manager',
      company,
      branch,
      'maintenance.create',
    );
    final managerFile = '${temporary.path}/manager-credential.json';
    await operator.provisionToFile(
      actorId: 'pairing-manager',
      deviceId: 'pairing-manager-host',
      credentialId: 'pairing-manager-credential',
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 10)),
      allowedScopes: [
        {
          'companyId': company,
          'branchId': branch,
          'permissions': [
            identityPairingManagePermission,
            identityDevicesManagePermission,
            'maintenance.create',
          ],
        },
      ],
      outputPath: managerFile,
    );
    final managerToken =
        (jsonDecode(await PrivateFiles.read(managerFile)) as Map)['token']
            as String;

    await operator.createUser('pairing-rate-manager');
    await operator.registerDevice(
      'pairing-rate-manager',
      'pairing-rate-manager-host',
    );
    for (final permission in [
      identityPairingManagePermission,
      identityDevicesManagePermission,
      'maintenance.create',
    ]) {
      await operator.grant('pairing-rate-manager', company, branch, permission);
    }
    final rateManagerFile = '${temporary.path}/rate-manager-credential.json';
    await operator.provisionToFile(
      actorId: 'pairing-rate-manager',
      deviceId: 'pairing-rate-manager-host',
      credentialId: 'pairing-rate-manager-credential',
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 10)),
      allowedScopes: [
        {
          'companyId': company,
          'branchId': branch,
          'permissions': [
            identityPairingManagePermission,
            identityDevicesManagePermission,
            'maintenance.create',
          ],
        },
      ],
      outputPath: rateManagerFile,
    );
    final rateManagerToken =
        (jsonDecode(await PrivateFiles.read(rateManagerFile)) as Map)['token']
            as String;

    await operator.createUser('pairing-target');
    await operator.grant(
      'pairing-target',
      company,
      branch,
      'maintenance.create',
    );
    await operator.createUser('pairing-privileged-target');
    await operator.grant(
      'pairing-privileged-target',
      company,
      branch,
      'maintenance.delete',
    );
    await operator.createUser('pairing-other-branch-target');
    await operator.grant(
      'pairing-other-branch-target',
      company,
      'branch-other',
      'maintenance.create',
    );
    await operator.createUser('pairing-multiscope-target');
    await operator.grant(
      'pairing-multiscope-target',
      company,
      branch,
      'maintenance.create',
    );
    await operator.grant(
      'pairing-multiscope-target',
      company,
      'branch-other',
      'maintenance.create',
    );
    await operator.registerDevice(
      'pairing-multiscope-target',
      'pairing-multiscope-client',
    );
    await operator.provisionToFile(
      actorId: 'pairing-multiscope-target',
      deviceId: 'pairing-multiscope-client',
      credentialId: 'pairing-multiscope-credential',
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      allowedScopes: [
        {
          'companyId': company,
          'branchId': branch,
          'permissions': ['maintenance.create'],
        },
        {
          'companyId': company,
          'branchId': 'branch-other',
          'permissions': ['maintenance.create'],
        },
      ],
      outputPath: '${temporary.path}/multiscope-credential.json',
    );

    Future<pg.Connection> runtimeConnect() =>
        pg.Connection.openFromUrl(runtimeUrl);
    final diagnostics = ManagementDiagnosticBuffer();
    pairingAdministrationPool = pg.Pool<dynamic>.withUrl(
      Uri.parse(apiAdminUrl)
          .replace(
            queryParameters: {
              ...Uri.parse(apiAdminUrl).queryParameters,
              'max_connection_count': '4',
            },
          )
          .toString(),
    );
    api = await HostApi.bind(
      authenticator: PersistentTokenAuthenticator(
        connect: runtimeConnect,
        admission: authority,
      ),
      executor: _PairingIntegrationExecutor(),
      identityPairing: PostgresIdentityPairingGateway(
        administrationPool: pairingAdministrationPool,
        admission: authority,
      ),
      identityDeviceAdministration: PostgresIdentityDeviceAdministrationGateway(
        connectRuntime: runtimeConnect,
        connectAdministration: () => pg.Connection.openFromUrl(apiAdminUrl),
        admission: authority,
      ),
      diagnostics: diagnostics,
    );

    final requestId = _newPairingRequestId();
    final normalWatch = Stopwatch()..start();
    final created = await send(
      api,
      path: HostManagementRoutes.pairingCreateV2,
      token: managerToken,
      headers: {'X-Correlation-ID': requestId},
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
        'requestId': requestId,
      },
    );
    final normalElapsedMs = normalWatch.elapsedMilliseconds;
    check(
      created.status == 201 &&
          created.body['pairing']['deviceRole'] == 'CLIENT' &&
          created.body['pairing']['pairingId'] ==
              'pair_${requestId.substring(4)}' &&
          created.body['correlationId'] == requestId,
      'Authorized exact-branch manager receives a short-lived idempotent CLIENT pairing code in ${normalElapsedMs}ms',
    );
    final normalTimingEvent = diagnostics.recent().singleWhere(
      (event) =>
          event.code == 'PAIRING_CREATED' && event.correlationId == requestId,
    );
    check(
      normalTimingEvent.safeExplanation.contains('connection_acquisition=') &&
          normalTimingEvent.safeExplanation.contains('witness_finalize=') &&
          normalTimingEvent.safeExplanation.contains(
            'db_transaction_residual=',
          ),
      'Pairing timing diagnostics identify safe Host, database and witness stages',
    );
    stdout.writeln(
      'MEASURE: normal_pairing_total=${normalElapsedMs}ms; ${normalTimingEvent.safeExplanation}',
    );

    final releasePool = Completer<void>();
    final poolEntries = List.generate(4, (_) => Completer<void>());
    final heldPoolConnections = List.generate(
      poolEntries.length,
      (index) => pairingAdministrationPool!.withConnection<void>((_) async {
        poolEntries[index].complete();
        await releasePool.future;
      }),
    );
    await Future.wait(
      poolEntries.map(
        (entry) => entry.future.timeout(const Duration(seconds: 5)),
      ),
    );
    final poolWaitRequestId = _newPairingRequestId();
    final countBeforePoolWait = await _pairingCount(audit, tenant);
    var poolWaitResponseReceived = false;
    final poolWaitFuture = send(
      api,
      path: HostManagementRoutes.pairingCreateV2,
      token: managerToken,
      headers: {'X-Correlation-ID': poolWaitRequestId},
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
        'requestId': poolWaitRequestId,
      },
    );
    unawaited(
      poolWaitFuture.then<void>(
        (_) => poolWaitResponseReceived = true,
        onError: (Object _) => poolWaitResponseReceived = true,
      ),
    );
    for (var i = 0; i < 100; i++) {
      if (diagnostics.recent().any(
        (event) =>
            event.code == 'PAIRING_REQUEST_STARTED' &&
            event.correlationId == poolWaitRequestId,
      )) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final remainedQueued = !poolWaitResponseReceived;
    releasePool.complete();
    await Future.wait(heldPoolConnections);
    final poolWaitResponse = await poolWaitFuture.timeout(
      const Duration(seconds: 10),
    );
    final poolWaitTimingEvent = diagnostics.recent().singleWhere(
      (event) =>
          event.code == 'PAIRING_CREATED' &&
          event.correlationId == poolWaitRequestId,
    );
    final connectionAcquisitionMs = int.tryParse(
      RegExp(
            r'connection_acquisition=(\d+)ms',
          ).firstMatch(poolWaitTimingEvent.safeExplanation)?.group(1) ??
          '',
    );
    check(
      remainedQueued &&
          poolWaitResponse.status == 201 &&
          connectionAcquisitionMs != null &&
          connectionAcquisitionMs >= 100 &&
          await _pairingCount(audit, tenant) == countBeforePoolWait + 1,
      'Administration pool contention is measured before pairing mutation and recovers without duplicate issuance (${connectionAcquisitionMs ?? -1}ms)',
    );
    final countBeforePrivilegeCeiling = await _pairingCount(audit, tenant);
    final privilegedTarget = await send(
      api,
      path: HostManagementRoutes.pairingCreate,
      token: managerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-privileged-target',
      },
    );
    check(
      privilegedTarget.status == 403 &&
          privilegedTarget.body['error']['code'] == 'PERMISSION_DENIED' &&
          await _pairingCount(audit, tenant) == countBeforePrivilegeCeiling,
      'A PostgreSQL permission-ceiling failure rolls back pairing data and Recovery Authority admission remains usable',
    );
    final otherBranchTarget = await send(
      api,
      path: HostManagementRoutes.pairingCreate,
      token: managerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-other-branch-target',
      },
    );
    check(
      otherBranchTarget.status == 404 &&
          otherBranchTarget.body['error']['code'] ==
              'PAIRING_TARGET_UNAVAILABLE',
      'Pairing actor selection cannot reveal users outside the authorized branch',
    );
    final pairing = created.body['pairing'] as Map<String, dynamic>;
    final code = pairing['code'] as String;
    final pairingId = pairing['pairingId'] as String;
    final storedDigest =
        (await audit.execute(
              pg.Sql.named('''
        SELECT pairing_digest FROM public.ventio_identity_pairings
        WHERE tenant_id=@tenant AND pairing_id=@pairing
      '''),
              parameters: {'tenant': tenant, 'pairing': pairingId},
            )).single[0]
            as String;
    check(
      storedDigest == OpaqueToken.digest(code) && storedDigest != code,
      'Host stores only the pairing-code digest',
    );
    final pairingCount = await _pairingCount(audit, tenant);
    final sameRequestRetry = await send(
      api,
      path: HostManagementRoutes.pairingCreateV2,
      token: managerToken,
      headers: {'X-Correlation-ID': requestId},
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
        'requestId': requestId,
      },
    );
    check(
      sameRequestRetry.status == 409 &&
          sameRequestRetry.body['error']['code'] ==
              'PAIRING_CODE_UNAVAILABLE' &&
          await _pairingCount(audit, tenant) == pairingCount,
      'Retrying an accepted request ID cannot create a duplicate and never recovers the one-time code',
    );
    final safeDiagnostics = jsonEncode(
      diagnostics.recent().map((event) => event.toJson()).toList(),
    );
    check(
      !safeDiagnostics.contains(code) &&
          !safeDiagnostics.contains(storedDigest) &&
          safeDiagnostics.contains(requestId),
      'Host diagnostics correlate pairing lifecycle events without retaining codes or digests',
    );

    Future<HostApi> bindPairingFailureApi(
      IdentityPairingGateway gateway,
      ManagementDiagnosticBuffer buffer,
    ) async {
      final failureApi = await HostApi.bind(
        authenticator: PersistentTokenAuthenticator(
          connect: runtimeConnect,
          admission: authority,
        ),
        executor: _PairingIntegrationExecutor(),
        identityPairing: gateway,
        diagnostics: buffer,
      );
      additionalApis.add(failureApi);
      return failureApi;
    }

    final countBeforeDatabaseFailure = await _pairingCount(audit, tenant);
    final databaseFailureDiagnostics = ManagementDiagnosticBuffer();
    final databaseFailureApi = await bindPairingFailureApi(
      PostgresIdentityPairingGateway(
        connectAdministration: () async =>
            throw const SocketException('injected database connection failure'),
        admission: authority,
      ),
      databaseFailureDiagnostics,
    );
    final databaseFailureId = _newPairingRequestId();
    final databaseUnavailable = await send(
      databaseFailureApi,
      path: HostManagementRoutes.pairingCreateV2,
      token: managerToken,
      headers: {'X-Correlation-ID': databaseFailureId},
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
        'requestId': databaseFailureId,
      },
    );
    check(
      databaseUnavailable.status == 503 &&
          databaseUnavailable.body['error']['code'] ==
              'PAIRING_DATABASE_UNAVAILABLE' &&
          databaseUnavailable.body['correlationId'] == databaseFailureId &&
          await _pairingCount(audit, tenant) == countBeforeDatabaseFailure &&
          !jsonEncode(
            databaseFailureDiagnostics
                .recent()
                .map((event) => event.toJson())
                .toList(),
          ).contains('injected database connection failure'),
      'A pre-connection database failure is categorized safely and cannot be confused with an accepted mutation',
    );

    final countBeforeRecoveryFailure = await _pairingCount(audit, tenant);
    final recoveryFailureDiagnostics = ManagementDiagnosticBuffer();
    final recoveryFailureApi = await bindPairingFailureApi(
      PostgresIdentityPairingGateway(
        connectAdministration: () => pg.Connection.openFromUrl(apiAdminUrl),
        admission: RecoveryAuthority(
          '${temporary.path}/missing-pairing-authority.json',
        ),
      ),
      recoveryFailureDiagnostics,
    );
    final recoveryFailureId = _newPairingRequestId();
    final recoveryUnavailable = await send(
      recoveryFailureApi,
      path: HostManagementRoutes.pairingCreateV2,
      token: managerToken,
      headers: {'X-Correlation-ID': recoveryFailureId},
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
        'requestId': recoveryFailureId,
      },
    );
    check(
      recoveryUnavailable.status == 503 &&
          recoveryUnavailable.body['error']['code'] ==
              'RECOVERY_AUTHORITY_UNAVAILABLE' &&
          recoveryUnavailable.body['correlationId'] == recoveryFailureId &&
          await _pairingCount(audit, tenant) == countBeforeRecoveryFailure &&
          recoveryFailureDiagnostics.recent().any(
            (event) =>
                event.code == 'RECOVERY_AUTHORITY_UNAVAILABLE' &&
                event.correlationId == recoveryFailureId,
          ),
      'A missing test-specific Recovery Authority witness fails closed before mutation with a distinct diagnostic category',
    );

    final concurrentRequestId = _newPairingRequestId();
    final countBeforeConcurrent = await _pairingCount(audit, tenant);
    final concurrentResults = await Future.wait([
      for (var i = 0; i < 4; i++)
        send(
          api,
          path: HostManagementRoutes.pairingCreateV2,
          token: managerToken,
          headers: {'X-Correlation-ID': concurrentRequestId},
          body: {
            'managementApiVersion': managementApiVersion,
            'companyId': company,
            'branchId': branch,
            'actorId': 'pairing-target',
            'requestId': concurrentRequestId,
          },
        ),
    ]);
    check(
      concurrentResults.where((result) => result.status == 201).length == 1 &&
          concurrentResults.where((result) => result.status == 409).length ==
              3 &&
          await _pairingCount(audit, tenant) == countBeforeConcurrent + 1,
      'Concurrent identical request references serialize to exactly one pairing record',
    );

    final distinctRequestIds = List.generate(4, (_) => _newPairingRequestId());
    final countBeforeDistinctConcurrency = await _pairingCount(audit, tenant);
    final distinctConcurrencyWatch = Stopwatch()..start();
    final distinctResults = await Future.wait([
      for (final distinctRequestId in distinctRequestIds)
        send(
          api,
          path: HostManagementRoutes.pairingCreateV2,
          token: managerToken,
          headers: {'X-Correlation-ID': distinctRequestId},
          body: {
            'managementApiVersion': managementApiVersion,
            'companyId': company,
            'branchId': branch,
            'actorId': 'pairing-target',
            'requestId': distinctRequestId,
          },
        ),
    ]);
    final distinctTimingEvents = diagnostics
        .recent()
        .where(
          (event) =>
              event.code == 'PAIRING_CREATED' &&
              distinctRequestIds.contains(event.correlationId),
        )
        .toList();
    check(
      distinctResults.every((result) => result.status == 201) &&
          await _pairingCount(audit, tenant) ==
              countBeforeDistinctConcurrency + distinctRequestIds.length &&
          distinctTimingEvents.length == distinctRequestIds.length &&
          distinctTimingEvents.every(
            (event) =>
                event.safeExplanation.contains('authority_queue_wait=') &&
                event.safeExplanation.contains('authority_lockfile_setup=') &&
                event.safeExplanation.contains('authority_os_lock_wait='),
          ),
      'Distinct concurrent pairing requests serialize safely through Recovery Authority (${distinctConcurrencyWatch.elapsedMilliseconds}ms total)',
    );
    stdout.writeln(
      'MEASURE: concurrent_distinct_total=${distinctConcurrencyWatch.elapsedMilliseconds}ms; authority queue, lock-file setup and OS lock wait were recorded per request.',
    );

    // Force a Host delay beyond the historical 15-second Client deadline after
    // PostgreSQL COMMIT. This is an isolated test barrier, never a production
    // timing dependency or a modification to the installed Host.
    final slowRequestId = _newPairingRequestId();
    final slowEntered = Completer<void>();
    final slowRelease = Completer<void>();
    afterCommitEntered = slowEntered;
    releaseAfterCommit = slowRelease;
    holdAfterCommit = true;
    final slowCountBefore = await _pairingCount(audit, tenant);
    final slowFuture = send(
      api,
      path: HostManagementRoutes.pairingCreateV2,
      token: rateManagerToken,
      headers: {'X-Correlation-ID': slowRequestId},
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
        'requestId': slowRequestId,
      },
    );
    try {
      await slowEntered.future.timeout(const Duration(seconds: 15));
      final oldDeadlineMarker = const _SlowPairingTimeoutMarker();
      final timedOutAtOldDeadline = await Future.any<Object>([
        slowFuture,
        Future<void>.delayed(
          const Duration(seconds: 16),
        ).then((_) => oldDeadlineMarker),
      ]);
      check(
        identical(timedOutAtOldDeadline, oldDeadlineMarker) &&
            await _pairingCount(audit, tenant) == slowCountBefore + 1,
        'A response delayed beyond 15 seconds can follow a committed pairing mutation',
      );
    } finally {
      if (!slowRelease.isCompleted) slowRelease.complete();
    }
    final slowResponse = await slowFuture.timeout(const Duration(seconds: 10));
    check(
      slowResponse.status == 201 &&
          slowResponse.body['correlationId'] == slowRequestId,
      'The delayed Host response completes after witness finalization resumes',
    );

    final queueLeaderRequestId = _newPairingRequestId();
    final contendedRequestId = _newPairingRequestId();
    final queueLeaderEntered = Completer<void>();
    final queueLeaderRelease = Completer<void>();
    afterCommitEntered = queueLeaderEntered;
    releaseAfterCommit = queueLeaderRelease;
    holdAfterCommit = true;
    final queueCountBefore = await _pairingCount(audit, tenant);
    final queueLeaderFuture = send(
      api,
      path: HostManagementRoutes.pairingCreateV2,
      token: managerToken,
      headers: {'X-Correlation-ID': queueLeaderRequestId},
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
        'requestId': queueLeaderRequestId,
      },
    );
    late Reply contendedResponse;
    try {
      await queueLeaderEntered.future.timeout(const Duration(seconds: 10));
      final contendedFuture = send(
        api,
        path: HostManagementRoutes.pairingCreateV2,
        token: managerToken,
        headers: {'X-Correlation-ID': contendedRequestId},
        body: {
          'managementApiVersion': managementApiVersion,
          'companyId': company,
          'branchId': branch,
          'actorId': 'pairing-target',
          'requestId': contendedRequestId,
        },
      );
      contendedResponse = await contendedFuture.timeout(
        const Duration(seconds: 5),
      );
    } finally {
      if (!queueLeaderRelease.isCompleted) queueLeaderRelease.complete();
    }
    final queueLeaderResponse = await queueLeaderFuture.timeout(
      const Duration(seconds: 10),
    );
    final contendedError = contendedResponse.body['error'];
    final contendedEvents = diagnostics
        .recent()
        .where((event) => event.correlationId == contendedRequestId)
        .map((event) => '${event.code}: ${event.safeExplanation}')
        .toList();
    final queueLeaderError = queueLeaderResponse.body['error'];
    stdout.writeln(
      'MEASURE: pairing_queue_leader_http=${queueLeaderResponse.status} '
      'error=${queueLeaderError is Map ? queueLeaderError['code'] : 'none'}; '
      'contender_http=${contendedResponse.status} '
      'error=${contendedError is Map ? contendedError['code'] : 'none'}; '
      'host_diagnostics=${contendedEvents.join(' | ')}',
    );
    check(
      contendedResponse.status == 503 &&
          contendedError is Map &&
          contendedError['code'] == 'RECOVERY_AUTHORITY_UNAVAILABLE' &&
          queueLeaderResponse.status == 201 &&
          await _pairingCount(audit, tenant) == queueCountBefore + 1 &&
          diagnostics.recent().any(
            (event) =>
                event.code == 'RECOVERY_AUTHORITY_UNAVAILABLE' &&
                event.correlationId == contendedRequestId,
          ),
      'A pairing request during a pending witness fails closed with a recovery-specific response and does not mutate the database',
    );
    final contendedRetry = await send(
      api,
      path: HostManagementRoutes.pairingCreateV2,
      token: managerToken,
      headers: {'X-Correlation-ID': contendedRequestId},
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
        'requestId': contendedRequestId,
      },
    );
    check(
      contendedRetry.status == 201 &&
          contendedRetry.body['pairing']['pairingId'] ==
              'pair_${contendedRequestId.substring(4)}' &&
          await _pairingCount(audit, tenant) == queueCountBefore + 2,
      'The same request reference can be retried safely after Recovery Authority returns to ready',
    );

    // Close the client connection while the Host is paused after COMMIT. Then
    // retry the same request reference and verify that only one row exists.
    final droppedRequestId = _newPairingRequestId();
    final droppedEntered = Completer<void>();
    final droppedRelease = Completer<void>();
    afterCommitEntered = droppedEntered;
    releaseAfterCommit = droppedRelease;
    holdAfterCommit = true;
    final rawClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    final rawRequest = await rawClient.postUrl(
      Uri.parse(
        'http://127.0.0.1:${api.port}${HostManagementRoutes.pairingCreateV2}',
      ),
    );
    rawRequest.headers
      ..set('Authorization', 'Bearer $managerToken')
      ..set('Content-Type', 'application/json')
      ..set('X-Correlation-ID', droppedRequestId);
    rawRequest.add(
      utf8.encode(
        jsonEncode({
          'managementApiVersion': managementApiVersion,
          'companyId': company,
          'branchId': branch,
          'actorId': 'pairing-target',
          'requestId': droppedRequestId,
        }),
      ),
    );
    final droppedResponse = rawRequest.close();
    unawaited(droppedResponse.then<void>((_) {}, onError: (Object _) {}));
    try {
      await droppedEntered.future.timeout(const Duration(seconds: 10));
      rawClient.close(force: true);
    } finally {
      rawClient.close(force: true);
      if (!droppedRelease.isCompleted) droppedRelease.complete();
    }
    for (var i = 0; i < 100; i++) {
      if (diagnostics.recent().any(
        (event) =>
            event.code == 'PAIRING_CREATED' &&
            event.correlationId == droppedRequestId,
      )) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final countBeforeDroppedRetry = await _pairingCount(audit, tenant);
    final droppedRetry = await send(
      api,
      path: HostManagementRoutes.pairingCreateV2,
      token: managerToken,
      headers: {'X-Correlation-ID': droppedRequestId},
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
        'requestId': droppedRequestId,
      },
    );
    final countAfterDroppedRetry = await _pairingCount(audit, tenant);
    stdout.writeln(
      'MEASURE: lost_response_retry_http=${droppedRetry.status} '
      'error=${droppedRetry.body['error'] is Map ? droppedRetry.body['error']['code'] : 'none'}; '
      'pairing_count_before=$countBeforeDroppedRetry '
      'after=$countAfterDroppedRetry; '
      'host_created_event=${diagnostics.recent().any((event) => event.code == 'PAIRING_CREATED' && event.correlationId == droppedRequestId)}',
    );
    check(
      droppedRetry.status == 409 &&
          droppedRetry.body['error']['code'] == 'PAIRING_CODE_UNAVAILABLE' &&
          countAfterDroppedRetry == countBeforeDroppedRetry,
      'A lost response after commit reconciles as code-unavailable without issuing a second record',
    );

    final enrolled = await send(
      api,
      path: HostManagementRoutes.pairingRedeem,
      body: {
        'managementApiVersion': managementApiVersion,
        'code': code,
        'deviceId': 'pairing-target-client',
      },
    );
    check(
      enrolled.status == 201 &&
          enrolled.body['enrollment']['deviceRole'] == 'CLIENT' &&
          enrolled.body['enrollment']['branchId'] == branch,
      'Single-use redemption atomically registers a client credential and exact branch scope (HTTP ${enrolled.status}, error ${enrolled.body['error'] is Map ? enrolled.body['error']['code'] : 'none'}, internal code ${diagnostics.recent().isEmpty ? 'none' : diagnostics.recent().first.protectedTechnicalCode ?? 'none'}, failure type ${diagnostics.recent().isEmpty ? 'none' : diagnostics.recent().first.protectedFailureType ?? 'none'}, source ${diagnostics.recent().isEmpty ? 'none' : diagnostics.recent().first.protectedFailureSource ?? 'none'})',
    );
    final enrollment = enrolled.body['enrollment'] as Map<String, dynamic>;
    final rawCredential = enrollment['credential'] as String;
    final credentialRows = await audit.execute(
      pg.Sql.named('''
        SELECT token_digest,allowed_scopes::text,
          expires_at<=clock_timestamp()+interval '30 days',
          expires_at>clock_timestamp()+interval '29 days'
        FROM public.ventio_identity_credentials
        WHERE tenant_id=@tenant AND credential_id=@credential
      '''),
      parameters: {'tenant': tenant, 'credential': enrollment['credentialId']},
    );
    final credentialRow = credentialRows.single;
    check(
      credentialRow[0] == OpaqueToken.digest(rawCredential) &&
          credentialRow[0] != rawCredential &&
          (credentialRow[1] as String).contains(company) &&
          (credentialRow[1] as String).contains(branch) &&
          !(credentialRow[1] as String).contains(
            identityPairingManagePermission,
          ) &&
          credentialRow[2] == true &&
          credentialRow[3] == true,
      'Enrolled credential is digest-backed, branch-bounded, and capped at 30 days without inheriting pairing permission',
    );
    final deviceRole = (await audit.execute(
      pg.Sql.named('''
        SELECT device_role FROM public.ventio_identity_devices
        WHERE tenant_id=@tenant AND device_id=@device
      '''),
      parameters: {'tenant': tenant, 'device': enrollment['deviceId']},
    )).single[0];
    check(
      deviceRole == 'CLIENT',
      'Database records CLIENT as descriptive device role',
    );

    final recoveryGenerationBeforeAuthentication = (await audit.execute(
      'SELECT generation FROM ventio_security.recovery_state WHERE singleton',
    )).single[0];
    final authenticated = await send(
      api,
      path: '/api/v1/session',
      method: 'GET',
      token: rawCredential,
    );
    final recoveryGenerationAfterAuthentication = (await audit.execute(
      'SELECT generation FROM ventio_security.recovery_state WHERE singleton',
    )).single[0];
    final permissions =
        ((authenticated.body['identity']['scopes'] as List)
                .single['permissions']
            as List);
    check(
      authenticated.status == 200 &&
          permissions.contains('maintenance.create') &&
          !permissions.contains(identityPairingManagePermission) &&
          recoveryGenerationBeforeAuthentication ==
              recoveryGenerationAfterAuthentication,
      'Client authentication preserves target permissions and records telemetry without changing Recovery Authority state',
    );

    final devices = await send(
      api,
      path: HostManagementRoutes.devicesList,
      token: managerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
      },
    );
    check(
      devices.status == 200,
      'Authorized device inventory request succeeds (HTTP ${devices.status}, error ${devices.body['error'] is Map ? devices.body['error']['code'] : 'none'}, internal code ${diagnostics.recent().isEmpty ? 'none' : diagnostics.recent().first.protectedTechnicalCode ?? 'none'}, failure type ${diagnostics.recent().isEmpty ? 'none' : diagnostics.recent().first.protectedFailureType ?? 'none'}, source ${diagnostics.recent().isEmpty ? 'none' : diagnostics.recent().first.protectedFailureSource ?? 'none'})',
    );
    final deviceItems = (devices.body['devices']['items'] as List).cast<Map>();
    final enrolledDevice = deviceItems.singleWhere(
      (device) => device['deviceId'] == enrollment['deviceId'],
    );
    final enrolledCredentials = (enrolledDevice['credentials'] as List)
        .cast<Map>();
    check(
      devices.status == 200 &&
          devices.body['correlationId'] ==
              devices.headers.value('X-Correlation-ID') &&
          enrolledDevice['role'] == 'CLIENT' &&
          enrolledDevice['registrationState'] == 'REGISTERED' &&
          enrolledDevice['lastAuthenticatedAtUtc'] is String &&
          DateTime.tryParse(
                enrolledDevice['lastAuthenticatedAtUtc'] as String,
              )?.isUtc ==
              true &&
          enrolledCredentials.single['credentialId'] ==
              enrollment['credentialId'] &&
          enrolledCredentials.single['state'] == 'ACTIVE' &&
          !jsonEncode(devices.body).contains(rawCredential) &&
          !jsonEncode(devices.body).contains('tokenDigest'),
      'Authorized device inventory returns exact branch status without bearer secrets or digests',
    );

    final rotateResponse = await send(
      api,
      path: HostManagementRoutes.devicesRotateCredential,
      token: managerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'deviceId': enrollment['deviceId'],
        'credentialId': enrollment['credentialId'],
      },
    );
    final rotated = rotateResponse.body['deviceCredential'] as Map;
    final rotatedCredentialId = rotated['credentialId'] as String;
    final rotatedToken = rotated['credential'] as String;
    check(
      rotateResponse.status == 200 &&
          rotateResponse.body['correlationId'] ==
              rotateResponse.headers.value('X-Correlation-ID') &&
          rotated['deviceId'] == enrollment['deviceId'] &&
          rotated['companyId'] == company &&
          rotated['branchId'] == branch &&
          !jsonEncode(rotateResponse.body).contains('tokenDigest'),
      'Authorized Host rotation returns one correlated scoped credential without digests',
    );
    final inventoryAfterRotation = await send(
      api,
      path: HostManagementRoutes.devicesList,
      token: managerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
      },
    );
    final rotatedDevice =
        (inventoryAfterRotation.body['devices']['items'] as List)
            .cast<Map>()
            .singleWhere(
              (device) => device['deviceId'] == enrollment['deviceId'],
            );
    final rotatedCredentials = (rotatedDevice['credentials'] as List)
        .cast<Map>();
    check(
      inventoryAfterRotation.status == 200 &&
          rotatedCredentials.singleWhere(
                (credential) =>
                    credential['credentialId'] == enrollment['credentialId'],
              )['state'] ==
              'ROTATED' &&
          rotatedCredentials.singleWhere(
                (credential) =>
                    credential['credentialId'] == rotatedCredentialId,
              )['state'] ==
              'ACTIVE',
      'Device inventory distinguishes a rotated credential from a revoked credential',
    );
    final rotatedAuthentication = await send(
      api,
      path: '/api/v1/session',
      method: 'GET',
      token: rotatedToken,
    );
    check(
      rotatedAuthentication.status == 200,
      'Rotated Client credential authenticates with its preserved scope',
    );
    final previousCredentialAuthentication = await send(
      api,
      path: '/api/v1/session',
      method: 'GET',
      token: rawCredential,
    );
    check(
      previousCredentialAuthentication.status == 401,
      'Rotation immediately invalidates the previous device credential',
    );

    final multiscopeCredential = await audit.execute(
      pg.Sql.named('''
        SELECT credential_id FROM public.ventio_identity_credentials
        WHERE tenant_id=@tenant AND device_id='pairing-multiscope-client'
          AND revoked_at IS NULL AND expires_at>clock_timestamp()
      '''),
      parameters: {'tenant': tenant},
    );
    final multiscopeRotation = await send(
      api,
      path: HostManagementRoutes.devicesRotateCredential,
      token: managerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'deviceId': 'pairing-multiscope-client',
        'credentialId': multiscopeCredential.single[0],
      },
    );
    check(
      multiscopeRotation.status == 403 &&
          multiscopeRotation.body['error']['code'] == 'PERMISSION_DENIED',
      'Credential rotation refuses to narrow or expand a multi-branch credential',
    );

    final ordinaryDeviceRead = await send(
      api,
      path: HostManagementRoutes.devicesList,
      token: rotatedToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
      },
    );
    check(
      ordinaryDeviceRead.status == 403 &&
          ordinaryDeviceRead.body['error']['code'] == 'PERMISSION_DENIED',
      'Enrolling a CLIENT device does not grant device-administration permission (HTTP ${ordinaryDeviceRead.status}, error ${ordinaryDeviceRead.body['error'] is Map ? ordinaryDeviceRead.body['error']['code'] : 'none'})',
    );

    final crossBranchDeviceRevoke = await send(
      api,
      path: HostManagementRoutes.devicesRevoke,
      token: managerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'deviceId': 'pairing-multiscope-client',
      },
    );
    check(
      crossBranchDeviceRevoke.status == 403 &&
          crossBranchDeviceRevoke.body['error']['code'] == 'PERMISSION_DENIED',
      'A branch manager cannot revoke a device credential scoped to another branch',
    );

    final revoked = await send(
      api,
      path: HostManagementRoutes.devicesRevoke,
      token: managerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'deviceId': enrollment['deviceId'],
      },
    );
    check(
      revoked.status == 200 &&
          revoked.body['deviceOperation']['status'] == 'APPLIED' &&
          revoked.body['deviceOperation']['deviceId'] ==
              enrollment['deviceId'] &&
          revoked.body['correlationId'] ==
              revoked.headers.value('X-Correlation-ID'),
      'Scoped device revocation returns a correlated Host-applied result',
    );
    final revokedState = await audit.execute(
      pg.Sql.named('''
        SELECT d.revoked_at IS NOT NULL,c.revoked_at IS NOT NULL
        FROM public.ventio_identity_devices d
        JOIN public.ventio_identity_credentials c
          ON c.tenant_id=d.tenant_id AND c.actor_id=d.actor_id
          AND c.device_id=d.device_id
        WHERE d.tenant_id=@tenant AND d.device_id=@device
          AND c.credential_id=@credential
      '''),
      parameters: {
        'tenant': tenant,
        'device': enrollment['deviceId'],
        'credential': rotatedCredentialId,
      },
    );
    check(
      revokedState.single[0] == true && revokedState.single[1] == true,
      'Device revocation atomically invalidates the registered device and its credential',
    );
    final revokedAuthentication = await send(
      api,
      path: '/api/v1/session',
      method: 'GET',
      token: rotatedToken,
    );
    check(
      revokedAuthentication.status == 401,
      'A revoked Client credential is rejected by Host authentication',
    );

    final replay = await send(
      api,
      path: HostManagementRoutes.pairingRedeem,
      body: {
        'managementApiVersion': managementApiVersion,
        'code': code,
        'deviceId': 'pairing-target-replay',
      },
    );
    check(
      replay.status == 410 &&
          replay.body['error']['code'] == 'PAIRING_INVALID_OR_EXPIRED',
      'Consumed pairing code cannot be replayed',
    );
    final expiringPairing = await send(
      api,
      path: HostManagementRoutes.pairingCreate,
      token: rateManagerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
      },
    );
    final expiringCode = expiringPairing.body['pairing']['code'] as String;
    final expiringPairingId =
        expiringPairing.body['pairing']['pairingId'] as String;
    await authority.change(audit, (tx) async {
      await tx.execute('SET LOCAL ROLE ventio_owner');
      await tx.execute(
        pg.Sql.named('''
            UPDATE public.ventio_identity_pairings
            SET created_at=transaction_timestamp()-interval '10 minutes',
              expires_at=transaction_timestamp()-interval '5 minutes'
            WHERE tenant_id=@tenant AND pairing_id=@pairing
          '''),
        parameters: {'tenant': tenant, 'pairing': expiringPairingId},
      );
    }, requireAdmissionProof: true);
    final expired = await send(
      api,
      path: HostManagementRoutes.pairingRedeem,
      body: {
        'managementApiVersion': managementApiVersion,
        'code': expiringCode,
        'deviceId': 'pairing-target-expired',
      },
    );
    check(
      expired.status == 410 &&
          expired.body['error']['code'] == 'PAIRING_INVALID_OR_EXPIRED',
      'Expired pairing code cannot be redeemed',
    );
    final countBeforeRateLimit = await _pairingCount(audit, tenant);
    final rateManagerPairingCount = await _pairingCountByCreator(
      audit,
      tenant,
      'pairing-rate-manager',
    );
    final expectedRemainingPairings = math.max(0, 10 - rateManagerPairingCount);
    var rateLimitCreatesSucceeded = 0;
    for (var attempt = 0; attempt < expectedRemainingPairings; attempt++) {
      final createdWithinLimit = await send(
        api,
        path: HostManagementRoutes.pairingCreate,
        token: rateManagerToken,
        body: {
          'managementApiVersion': managementApiVersion,
          'companyId': company,
          'branchId': branch,
          'actorId': 'pairing-target',
        },
      );
      if (createdWithinLimit.status == 201) rateLimitCreatesSucceeded++;
    }
    final rateLimitedCreate = await send(
      api,
      path: HostManagementRoutes.pairingCreate,
      token: rateManagerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
      },
    );
    check(
      rateLimitCreatesSucceeded == expectedRemainingPairings &&
          rateLimitedCreate.status == 429 &&
          rateLimitedCreate.headers.value('Retry-After') == '900' &&
          rateLimitedCreate.body['error']['code'] == 'PAIRING_RATE_LIMITED' &&
          await _pairingCountByCreator(audit, tenant, 'pairing-rate-manager') ==
              10,
      'Host SQL limits pairing issuance to ten per creator, exact branch, and fifteen-minute window ($rateManagerPairingCount existing, $rateLimitCreatesSucceeded new; tenant total $countBeforeRateLimit)',
    );
    final managerCountBeforeLimitedDuplicate = await _pairingCountByCreator(
      audit,
      tenant,
      'pairing-manager',
    );
    final limitedDuplicate = await send(
      api,
      path: HostManagementRoutes.pairingCreateV2,
      token: managerToken,
      headers: {'X-Correlation-ID': requestId},
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
        'requestId': requestId,
      },
    );
    check(
      limitedDuplicate.status == 409 &&
          limitedDuplicate.body['error']['code'] ==
              'PAIRING_CODE_UNAVAILABLE' &&
          managerCountBeforeLimitedDuplicate == 10 &&
          await _pairingCountByCreator(audit, tenant, 'pairing-manager') ==
              managerCountBeforeLimitedDuplicate,
      'An accepted request reference is reconciled before the rate limit and cannot create a duplicate',
    );
    final auditDetails = await audit.execute(
      pg.Sql.named('''
        SELECT coalesce(jsonb_agg(details)::text,'[]')
        FROM public.ventio_identity_audit
        WHERE tenant_id=@tenant AND action IN ('PAIRING_CREATED','DEVICE_ENROLLED')
      '''),
      parameters: {'tenant': tenant},
    );
    check(
      !(auditDetails.single[0] as String).contains(code) &&
          !(auditDetails.single[0] as String).contains(rawCredential) &&
          !jsonEncode(
            diagnostics.recent().map((event) => event.toJson()).toList(),
          ).contains(rawCredential),
      'Audit and diagnostics exclude raw pairing and device credentials',
    );
    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    for (final additionalApi in additionalApis) {
      await additionalApi.close();
    }
    await api?.close();
    await pairingAdministrationPool?.close();
    await admin.close();
    await migration.close();
    await audit.close();
    await temporary.delete(recursive: true);
  }
}

bool _isDisposableTestDatabase(String? url) =>
    url != null &&
    Uri.parse(url).pathSegments.where((part) => part.isNotEmpty).lastOrNull ==
        'ventio_host_test';

Future<int> _pairingCount(pg.Connection audit, String tenant) async =>
    (await audit.execute(
          pg.Sql.named(
            'SELECT count(*) FROM public.ventio_identity_pairings WHERE tenant_id=@tenant',
          ),
          parameters: {'tenant': tenant},
        )).single[0]
        as int;

Future<int> _pairingCountByCreator(
  pg.Connection audit,
  String tenant,
  String creator,
) async =>
    (await audit.execute(
          pg.Sql.named('''
            SELECT count(*)
            FROM public.ventio_identity_pairings
            WHERE tenant_id=@tenant AND created_by_actor_id=@creator
              AND created_at >= transaction_timestamp()-interval '15 minutes'
          '''),
          parameters: {'tenant': tenant, 'creator': creator},
        )).single[0]
        as int;

String _newPairingRequestId() {
  final random = math.Random.secure();
  final suffix = List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return 'cor_$suffix';
}
