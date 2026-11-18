// PREPARED / NOT EXECUTED. Real DB state machine and real executor tests.
// RETRY_LATER inputs below exercise the SQL transition contract explicitly;
// they are not presented as simulated database-outage or physical-crash proof.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

import 'support/wave2_fixture.dart';

Map<String, dynamic> outcome(Map<String, dynamic> receipt) => {
  'commandId': receipt['commandId'],
  'status': receipt['status'],
  if (receipt['reasonCode'] != null) 'reasonCode': receipt['reasonCode'],
};

Future<void> main() async {
  final f = await W2Fixture.open();
  final cases = W2Cases();
  Future<Map<String, dynamic>> effect(
    Map<String, dynamic> claim, {
    W2Identity? as,
  }) async {
    final session = await f.authenticator.authenticate((as ?? f.author).token);
    // Revocation-after-claim tests deliberately keep their earlier real session.
    w2Expect(session != null, 'Fixture session unavailable');
    return f.executor.execute(
      CommandEnvelope.fromJson(requireMap(claim['command'], 'command')),
      session!,
      requireJobAuthorization: true,
    );
  }

  Future<int> effects(int id) async =>
      (await f.observer.execute(
            pg.Sql.named(
              'SELECT count(*) FROM public.ventio_command_journal WHERE tenant_id=@tenant AND command_id=@id AND receipt->>\'status\'=\'ACCEPTED\'',
            ),
            parameters: {'tenant': W2Fixture.tenant, 'id': w2Id(id)},
          )).single[0]
          as int;
  Future<void> complete(int job) async {
    final claim = await f.claim();
    w2Expect(claim?['jobId'] == w2Id(job), 'Claim selected another job');
    final receipt = await effect(claim!);
    w2Expect(
      receipt['status'] == 'ACCEPTED',
      'Executor did not accept command',
    );
    await f.finish(claim, outcome(receipt));
  }

  try {
    await cases.run(
      'W2-J001',
      'J03,L01',
      'Jobs accept one and twenty-five commands and remain cancellable before dispatch',
      () async {
        for (final count in [1, 25]) {
          final id = 100 + count;
          w2Expect(
            (await f.submit(
                  id,
                  List.generate(
                    count,
                    (i) => f.command(1000 + count * 100 + i),
                  ),
                ))['state'] ==
                'QUEUED',
            'Legal batch rejected',
          );
          await f.cancel(id);
          w2Expect(
            (await f.job(id))['state'] == 'CANCELLED',
            'Queued cancellation failed',
          );
        }
      },
    );
    await cases.run(
      'W2-J002',
      'J03,J04',
      'Empty twenty-six-command and oversized wire jobs are rejected',
      () async {
        for (final commands in [
          <CommandEnvelope>[],
          List.generate(26, (i) => f.command(2000 + i)),
          [
            f.command(2030, values: {'name': 'x' * 50000}),
          ],
        ]) {
          w2Expect(
            (await f.http(
                  'jobs/submit',
                  fields: {
                    'jobId': w2Id(200),
                    'commands': commands.map((c) => c.original).toList(),
                  },
                )).status ==
                400,
            'Oversized job accepted',
          );
        }
      },
    );
    await cases.run(
      'W2-J003',
      'J03,L01',
      'Duplicate command IDs in one job are refused by SQL',
      () async {
        final command = f.command(3000);
        final result = await f.submit(300, [command, command], status: 403);
        w2Expect(
          result['reasonCode'] == 'DUPLICATE_COMMAND_ID',
          'Duplicate IDs admitted',
        );
      },
    );
    await cases.run(
      'W2-J004',
      'B02,J04',
      'Direct job envelopes receive strict HTTP command-shape validation',
      () async {
        final original = f.command(4000).original;
        for (final wire in [
          {...original, 'sql': 'select 1'},
          {
            ...original,
            'clientContext': {
              ...requireMap(original['clientContext'], 'clientContext'),
              'script': 'run',
            },
          },
        ]) {
          w2Expect(
            (await f.http(
                  'jobs/submit',
                  fields: {
                    'jobId': w2Id(400),
                    'commands': [wire],
                  },
                )).status ==
                400,
            'Nested wire bypass admitted',
          );
        }
      },
    );
    await cases.run(
      'W2-J005',
      'D08,D09,J03',
      'Job tenant actor device scope dependencies and delete restrictions are enforced',
      () async {
        final command = f.command(5000);
        final source = command.original;
        final context = requireMap(source['clientContext'], 'clientContext');
        for (final wire in [
          {...source, 'tenantId': 'w2-other-tenant'},
          {...source, 'branchId': 'other'},
          {
            ...source,
            'clientContext': {...context, 'actorId': 'other'},
          },
          {
            ...source,
            'clientContext': {...context, 'deviceId': 'other'},
          },
          {
            ...source,
            'dependsOn': [w2Id(999)],
          },
          {
            ...source,
            'type': ExtensionRecordCommand.deleteType,
            'expectedRevision': 1,
          },
        ]) {
          w2Expect(
            (await f.http(
                  'jobs/submit',
                  fields: {
                    'jobId': w2Id(500),
                    'commands': [wire],
                  },
                )).status ==
                403,
            'Job scope restriction bypassed',
          );
        }
      },
    );
    await cases.run(
      'W2-J006',
      'J03,L01',
      'Lost submit-response retries preserve identity; changed payload or source labels conflict',
      () async {
        final commands = [f.command(6000)];
        final first = await f.submit(
          600,
          commands,
          import: 601,
          sourceRows: [7],
        );
        await f.restartHttp();
        w2Equal(
          await f.submit(600, commands, import: 601, sourceRows: [7]),
          first,
          'Lost-response retry duplicated job',
        );
        w2Expect(
          (await f.submit(
                600,
                [f.command(6001)],
                import: 601,
                sourceRows: [7],
                status: 409,
              ))['reasonCode'] ==
              'JOB_ID_REUSED',
          'Changed job payload accepted',
        );
        w2Expect(
          (await f.submit(
                600,
                commands,
                import: 601,
                sourceRows: [8],
                status: 409,
              ))['reasonCode'] ==
              'JOB_ID_REUSED',
          'Changed correlation accepted',
        );
        await f.cancel(600);
      },
    );
    await cases.run(
      'W2-J007',
      'J03',
      'Source-row labels must match commands be unique integers and retain original range',
      () async {
        final commands = [f.command(7000).original, f.command(7001).original];
        for (final correlation in [
          {
            'sourceRows': [2, 3],
          },
          {
            'importId': w2Id(701),
            'sourceRows': [2],
          },
          {
            'importId': w2Id(701),
            'sourceRows': [2, 2],
          },
          {
            'importId': w2Id(701),
            'sourceRows': [1, 3],
          },
          {
            'importId': w2Id(701),
            'sourceRows': [2, 1000000],
          },
          {
            'importId': w2Id(701),
            'sourceRows': [2, 3.5],
          },
        ]) {
          w2Expect(
            (await f.http(
                  'jobs/submit',
                  fields: {
                    'jobId': w2Id(700),
                    'commands': commands,
                    ...correlation,
                  },
                )).status ==
                400,
            'Invalid correlation accepted',
          );
        }
      },
    );
    await cases.run(
      'W2-J008',
      'L01,D08',
      'Public job listing redacts command payloads digests and lease tokens',
      () async {
        await f.submit(800, [
          f.command(8000, values: {'name': 'redaction-sentinel'}),
        ]);
        final result = await f.job(800);
        final encoded = canonicalJson(result);
        for (final forbidden in [
          'redaction-sentinel',
          'credentialDigest',
          'credential_digest',
          'leaseId',
          'lease_id',
          'commands',
        ]) {
          w2Expect(!encoded.contains(forbidden), 'Private worker state leaked');
        }
        await f.cancel(800);
      },
    );
    await cases.run(
      'W2-J009',
      'L01',
      'Concurrent real transactions cannot claim the same runnable job twice',
      () async {
        await f.submit(900, [f.command(9000)]);
        final claims = await Future.wait([f.claim(), f.claim()]);
        w2Expect(
          claims.whereType<Map<String, dynamic>>().length == 1,
          'Lease acquired twice',
        );
        final claim = claims.whereType<Map<String, dynamic>>().single;
        await f.finish(claim, outcome(await effect(claim)));
        w2Expect(
          (await f.job(900))['state'] == 'SUCCEEDED' &&
              await effects(9000) == 1,
          'Claim did not durably execute once',
        );
      },
    );
    await cases.run(
      'W2-J010',
      'L01,J03',
      'Expired lease is reclaimed and stale completion is fenced',
      () async {
        await f.submit(1000, [f.command(10000)]);
        final old = (await f.claim())!;
        await f.advanceJob(1000, expireLease: true);
        final current = (await f.claim())!;
        w2Expect(old['leaseId'] != current['leaseId'], 'Expired lease reused');
        final receipt = await effect(current);
        await f.finish(old, outcome(receipt));
        w2Expect(
          (await f.job(1000))['processed'] == 0,
          'Stale worker advanced job',
        );
        await f.finish(current, outcome(receipt));
        w2Expect(
          (await f.job(1000))['state'] == 'SUCCEEDED' &&
              await effects(10000) == 1,
          'Current lease lost result',
        );
      },
    );
    await cases.run(
      'W2-J011',
      'L01,J03',
      'Retry transition retains row identity backoff and original source correlation',
      () async {
        await f.submit(
          1100,
          [f.command(11000)],
          import: 1101,
          sourceRows: [19],
        );
        final first = (await f.claim())!;
        await f.finish(first, {
          'commandId': w2Id(11000),
          'status': 'RETRY_LATER',
          'reasonCode': 'HOST_EXECUTION_UNAVAILABLE',
        }, retry: true);
        final waiting = await f.job(1100);
        w2Expect(
          waiting['state'] == 'RETRY_WAIT' &&
              waiting['processed'] == 0 &&
              waiting['attempts'] == 1 &&
              (waiting['outcomes'] as List).isEmpty,
          'Retry lost identity',
        );
        w2Expect(await f.claim() == null, 'Backoff was not enforced');
        await f.advanceJob(1100);
        await complete(1100);
        final result = await f.job(1100);
        w2Expect(
          (result['outcomes'] as List).single['sourceRow'] == 19 &&
              (result['outcomes'] as List).single['importId'] == w2Id(1101),
          'Source correlation lost on retry',
        );
      },
    );
    await cases.run(
      'W2-J012',
      'L01',
      'Five failed attempts produce bounded terminal rejection without an effect',
      () async {
        await f.submit(1200, [f.command(12000)]);
        for (var attempt = 1; attempt <= 5; attempt++) {
          final claim = (await f.claim())!;
          w2Expect(
            (await f.job(1200))['attempts'] == attempt,
            'Attempt count incorrect',
          );
          await f.finish(claim, {
            'commandId': w2Id(12000),
            'status': 'RETRY_LATER',
            'reasonCode': 'HOST_EXECUTION_UNAVAILABLE',
          }, retry: true);
          if (attempt < 5) await f.advanceJob(1200);
        }
        final result = await f.job(1200);
        w2Expect(
          result['state'] == 'COMPLETED_WITH_ERRORS' &&
              (result['outcomes'] as List).single['reasonCode'] ==
                  'RETRY_LIMIT',
          'Retry bound not terminal',
        );
        w2Expect(
          await effects(12000) == 0,
          'State-machine retry generated business effect',
        );
      },
    );
    await cases.run(
      'W2-J013',
      'L01,J03',
      'Cancellation before claim prevents execution and is idempotent',
      () async {
        await f.submit(1300, [f.command(13000)]);
        await f.cancel(1300);
        await f.cancel(1300);
        w2Expect(
          await f.claim() == null &&
              (await f.job(1300))['state'] == 'CANCELLED' &&
              await effects(13000) == 0,
          'Cancelled work executed',
        );
      },
    );
    await cases.run(
      'W2-J014',
      'L01,J03',
      'In-flight acceptance survives cancellation with original source row',
      () async {
        await f.submit(
          1400,
          [f.command(14000)],
          import: 1401,
          sourceRows: [23],
        );
        final claim = (await f.claim())!;
        final receipt = await effect(claim);
        await f.cancel(1400);
        await f.finish(claim, outcome(receipt));
        final result = await f.job(1400);
        w2Expect(
          result['state'] == 'CANCELLED' &&
              result['processed'] == 1 &&
              (result['outcomes'] as List).single['status'] == 'ACCEPTED' &&
              (result['outcomes'] as List).single['sourceRow'] == 23,
          'Cancellation erased accepted outcome',
        );
        w2Expect(await effects(14000) == 1, 'Cancellation duplicated effect');
      },
    );
    await cases.run(
      'W2-J015',
      'L01,J03',
      'Cancellation during ambiguous retry records unknown outcome without automatic replay',
      () async {
        await f.submit(1500, [f.command(15000)]);
        final claim = (await f.claim())!;
        await f.cancel(1500);
        await f.finish(claim, {
          'commandId': w2Id(15000),
          'status': 'RETRY_LATER',
        }, retry: true);
        final result = await f.job(1500);
        w2Expect(
          result['state'] == 'CANCELLED' &&
              result['processed'] == 0 &&
              (result['outcomes'] as List).single['reasonCode'] ==
                  'CANCELLED_OUTCOME_UNKNOWN',
          'Ambiguity represented as acceptance',
        );
        w2Expect(
          await f.claim() == null,
          'Ambiguous cancellation replayed automatically',
        );
      },
    );
    await cases.run(
      'W2-J016',
      'D09,L01',
      'Revocation before claim prevents execution under the stored credential',
      () async {
        final user = await f.provision(
          'revoked-worker',
          permissions: W2Fixture.permissions,
        );
        await f.submit(1600, [f.command(16000, as: user)], as: user);
        await user.admin.revokeCredential(user.credential);
        w2Expect(await f.claim() == null, 'Revoked credential claimed work');
        w2Expect(
          (await f.job(1600))['state'] == 'FAILED' &&
              (await f.job(1600))['errorCode'] ==
                  'EXECUTION_AUTHORIZATION_REVOKED',
          'Revoked job not diagnosed',
        );
        w2Expect(await effects(16000) == 0, 'Revoked job produced effect');
      },
    );
    await cases.run(
      'W2-J017',
      'D08,D09,L01',
      'Authority is rechecked inside effect after claim even with a stale session',
      () async {
        final user = await f.provision(
          'revoked-after-claim',
          permissions: W2Fixture.permissions,
        );
        final stale = (await f.authenticator.authenticate(user.token))!;
        await f.submit(1700, [f.command(17000, as: user)], as: user);
        final claim = (await f.claim())!;
        await user.admin.revokeGrant(
          user.actor,
          W2Fixture.company,
          W2Fixture.branch,
          'platform.jobs.run',
        );
        final receipt = await f.executor.execute(
          CommandEnvelope.fromJson(requireMap(claim['command'], 'command')),
          stale,
          requireJobAuthorization: true,
        );
        w2Expect(
          receipt['status'] == 'REJECTED',
          'Stale snapshot permitted job effect',
        );
        await f.finish(claim, outcome(receipt));
        w2Expect(
          await effects(17000) == 0,
          'Revoked execution wrote a receipt as accepted',
        );
      },
    );
    await cases.run(
      'W2-J018',
      'M02,L01',
      'Scoped jobsPaused and maintenanceMode prevent claims until cleared',
      () async {
        var revision = 0;
        for (final setting in ['jobsPaused', 'maintenanceMode']) {
          final id = setting == 'jobsPaused' ? 1800 : 1801;
          await f.submit(id, [f.command(18000 + revision)]);
          final paused = await f.save(
            'configuration',
            'scope',
            {...w2Settings(), setting: true},
            expected: revision,
            request: 180000 + revision,
          );
          revision = paused['revision'] as int;
          w2Expect(await f.claim() == null, 'Operational claim guard ignored');
          final resumed = await f.save(
            'configuration',
            'scope',
            w2Settings(),
            expected: revision,
            request: 180000 + revision,
          );
          revision = resumed['revision'] as int;
          await complete(id);
        }
      },
    );
    await cases.run(
      'W2-J019',
      'L01,J03,M02',
      'Terminal archival scrubs executable state and keeps IDs hashes totals labels and outcomes',
      () async {
        await f.submit(
          1900,
          [f.command(19000)],
          import: 1901,
          sourceRows: [31],
        );
        await complete(1900);
        final before = await f.observer.execute(
          pg.Sql.named(
            'SELECT request_hash,source_rows::text,outcomes::text,total_count FROM public.ventio_wave2_jobs WHERE tenant_id=@tenant AND job_id=@id',
          ),
          parameters: {'tenant': W2Fixture.tenant, 'id': w2Id(1900)},
        );
        await f.advanceJob(1900, ageTerminal: true);
        await f.claim();
        final after = await f.observer.execute(
          pg.Sql.named(
            'SELECT request_hash,source_rows::text,outcomes::text,total_count,commands::text,credential_digest,archived_at IS NOT NULL FROM public.ventio_wave2_jobs WHERE tenant_id=@tenant AND job_id=@id',
          ),
          parameters: {'tenant': W2Fixture.tenant, 'id': w2Id(1900)},
        );
        w2Equal(
          after.single.take(4).toList(),
          before.single,
          'Archival erased audit identities',
        );
        w2Expect(
          after.single[6] == true &&
              after.single[5] == '0' * 64 &&
              !(after.single[4] as String).contains('payload'),
          'Executable state survived archival',
        );
        w2Expect(await effects(19000) == 1, 'Authoritative receipt was lost');
      },
    );
    await cases.run(
      'W2-J020',
      'J03,L01',
      'Real timed worker executes rows and retains nonconsecutive CSV source labels',
      () async {
        await f.submit(
          2000,
          [f.command(20000), f.command(20001)],
          import: 2001,
          sourceRows: [2, 7],
        );
        final worker = f.worker()..start();
        try {
          final result = await f.waitJob(2000, {
            'SUCCEEDED',
            'COMPLETED_WITH_ERRORS',
            'FAILED',
          });
          w2Expect(
            result['state'] == 'SUCCEEDED' && result['processed'] == 2,
            'Worker failed real commands',
          );
          w2Equal(
            (result['outcomes'] as List).map((r) => r['sourceRow']).toList(),
            [2, 7],
            'Worker renumbered CSV rows',
          );
        } finally {
          await worker.close();
        }
        w2Expect(
          await effects(20000) == 1 && await effects(20001) == 1,
          'Worker lost/duplicated effects',
        );
      },
    );
    await cases.run(
      'W2-J021',
      'J03,L01',
      'Commit-before-finish recovery replays the journal receipt instead of duplicating effect',
      () async {
        await f.submit(2100, [f.command(21000)]);
        final abandoned = (await f.claim())!;
        final receipt = await effect(abandoned);
        // Do not call finish: models the exact durable boundary, not a mock crash.
        await f.advanceJob(2100, expireLease: true);
        final worker = f.worker()..start();
        try {
          w2Expect(
            (await f.waitJob(2100, {
                  'SUCCEEDED',
                  'FAILED',
                  'COMPLETED_WITH_ERRORS',
                }))['state'] ==
                'SUCCEEDED',
            'Lease recovery failed',
          );
        } finally {
          await worker.close();
        }
        w2Equal(
          await f.execute(f.command(21000)),
          receipt,
          'Recovered receipt is not immutable',
        );
        w2Expect(await effects(21000) == 1, 'Committed effect replayed');
      },
    );
    await cases.run(
      'W2-J022',
      'L01,J03',
      'Two real workers finish one job without duplicate journal audit or outbox effects',
      () async {
        await f.submit(2200, [f.command(22000), f.command(22001)]);
        final workers = [f.worker()..start(), f.worker()..start()];
        try {
          w2Expect(
            (await f.waitJob(2200, {
                  'SUCCEEDED',
                  'FAILED',
                  'COMPLETED_WITH_ERRORS',
                }))['state'] ==
                'SUCCEEDED',
            'Concurrent workers failed',
          );
        } finally {
          for (final worker in workers) {
            await worker.close();
          }
        }
        for (final table in [
          'ventio_command_journal',
          'ventio_audit_entries',
          'ventio_outbox',
        ]) {
          final rows = await f.observer.execute(
            pg.Sql.named(
              'SELECT count(*) FROM public.$table WHERE tenant_id=@tenant AND command_id=ANY(CAST(@ids AS text[]))',
            ),
            parameters: {
              'tenant': W2Fixture.tenant,
              'ids': [w2Id(22000), w2Id(22001)],
            },
          );
          w2Expect(
            rows.single[0] == 2,
            'Concurrent worker lost/duplicated durable effect',
          );
        }
      },
    );
    await cases.run(
      'W2-J023',
      'L01,D09',
      'Missing independent recovery witness fails closed and records safe worker diagnostics',
      () async {
        await f.submit(2300, [f.command(23000)]);
        final original = f.authority.path;
        final moved = '$original.saved';
        await File(original).rename(moved);
        final worker = f.worker()..start();
        try {
          final watch = Stopwatch()..start();
          while (!f.diagnostics.recent().any(
                (event) => event.code == 'HOST_JOB_WORKER_UNAVAILABLE',
              ) &&
              watch.elapsed < const Duration(seconds: 10)) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          final events = f.diagnostics
              .recent()
              .where((event) => event.code == 'HOST_JOB_WORKER_UNAVAILABLE')
              .toList();
          w2Expect(
            events.isNotEmpty &&
                events.every(
                  (event) => !event.safeExplanation.contains(f.author.token),
                ),
            'Missing witness not safely diagnosed',
          );
        } finally {
          await worker.close();
          await File(moved).rename(original);
        }
        w2Expect(
          (await f.job(2300))['state'] == 'QUEUED' && await effects(23000) == 0,
          'Missing witness did not fail closed',
        );
        await complete(2300);
      },
    );
    await cases.run(
      'W2-J024',
      'L01,D08',
      'Job visibility and cancellation respect actor ownership and tenant',
      () async {
        await f.submit(2400, [f.command(24000)]);
        final readerList = await f.call('jobs/list', as: f.reader);
        w2Expect(
          !(readerList['jobs'] as List).any(
            (job) => job['jobId'] == w2Id(2400),
          ),
          'Another actor saw job without management authority',
        );
        for (final identity in [f.reader, f.outsider]) {
          w2Expect(
            (await f.http(
                  'jobs/cancel',
                  as: identity,
                  fields: {'jobId': w2Id(2400)},
                )).status ==
                403,
            'Foreign job cancelled',
          );
        }
        await f.cancel(2400);
      },
    );
    await cases.run(
      'W2-J025',
      'L01',
      'Twenty-active-job ceiling is per actor and does not silently discard jobs',
      () async {
        final limited = await f.provision(
          'job-limit',
          permissions: W2Fixture.permissions,
        );
        for (var i = 0; i < 20; i++) {
          await f.submit(2500 + i, [
            f.command(25000 + i, as: limited),
          ], as: limited);
        }
        final over = await f.submit(
          2520,
          [f.command(25020, as: limited)],
          as: limited,
          status: 403,
        );
        w2Expect(over['reasonCode'] == 'JOB_LIMIT', 'Active-job bound ignored');
        for (var i = 0; i < 20; i++) {
          await f.cancel(2500 + i);
        }
        w2Expect(
          await f.claim() == null,
          'Cancelled bound fixture left runnable jobs',
        );
      },
    );
    await cases.run(
      'W2-J026',
      'K10,L01,J04',
      'Undeclared governed operation cannot acquire an executable handler through a job',
      () async {
        await f.execute(f.command(26000));
        final command = ExtensionBusinessOperationCommand.execute(
          commandId: w2Id(26001),
          tenantId: W2Fixture.tenant,
          companyId: W2Fixture.company,
          branchId: W2Fixture.branch,
          recordId: 'asset-26000',
          expectedRevision: 1,
          actorId: f.author.actor,
          deviceId: f.author.device,
          moduleId: w2Module,
          moduleVersion: '1.0.0',
          docType: 'Asset',
          schemaVersion: 1,
          operationId: 'undeclared.operation',
          operationVersion: 1,
          inputs: {},
        ).envelope;
        await f.submit(2600, [command]);
        final worker = f.worker()..start();
        try {
          final result = await f.waitJob(2600, {
            'SUCCEEDED',
            'COMPLETED_WITH_ERRORS',
            'FAILED',
          });
          w2Expect(
            result['state'] == 'COMPLETED_WITH_ERRORS' &&
                (result['outcomes'] as List).single['status'] == 'REJECTED',
            'Undeclared handler executed',
          );
        } finally {
          await worker.close();
        }
        w2Expect(await effects(26001) == 0, 'Undeclared operation committed');
      },
    );
    await cases.run(
      'W2-J027',
      'L01,J03',
      'An actually terminated worker with a committed claim is recovered by a fresh process exactly once',
      () async {
        w2Expect(
          await File('.dart_tool/package_config.json').exists(),
          'Dependencies must already be resolved; child never invokes pub',
        );
        await f.execute(f.command(27000));
        final command = ExtensionRecordCommand.update(
          commandId: w2Id(27001),
          tenantId: W2Fixture.tenant,
          companyId: W2Fixture.company,
          branchId: W2Fixture.branch,
          recordId: 'asset-27000',
          expectedRevision: 1,
          actorId: f.author.actor,
          deviceId: f.author.device,
          moduleId: w2Module,
          moduleVersion: '1.0.0',
          docType: 'Asset',
          schemaVersion: 1,
          values: {'name': 'Recovered worker'},
        ).envelope;
        final locked = Completer<void>();
        final release = Completer<void>();
        final locker = f.observer.runTx((tx) async {
          await tx.execute(
            "SELECT 1 FROM public.ventio_records WHERE tenant_id='w2-prepared' AND record_id='asset-27000' FOR UPDATE",
          );
          locked.complete();
          await release.future;
        });
        Future<Process> startWorker() async {
          final process = await Process.start(
            Platform.resolvedExecutable,
            [
              '--packages=.dart_tool/package_config.json',
              'test/support/wave2_worker_process.dart',
            ],
            environment: {
              'VENTIO_WAVE2_WORKER_PROCESS': 'yes',
              'VENTIO_WAVE2_WORKER_WITNESS': f.authority.path,
            },
          );
          // Drain both pipes immediately. Do not print credentials or raw failures.
          process.stderr.drain<void>();
          final ready = Completer<void>();
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((line) {
                if (line == 'W2_WORKER_READY' && !ready.isCompleted) {
                  ready.complete();
                }
              });
          try {
            await ready.future.timeout(const Duration(seconds: 15));
          } catch (_) {
            process.kill();
            await process.exitCode;
            rethrow;
          }
          return process;
        }

        Process? first;
        try {
          await locked.future;
          await f.submit(2700, [command]);
          first = await startWorker();
          await f.waitJob(2700, {'RUNNING'});
          w2Expect(
            first.kill(ProcessSignal.sigkill),
            'Test-owned worker was not terminated',
          );
          await first.exitCode.timeout(const Duration(seconds: 10));
          first = null;
        } finally {
          first?.kill(ProcessSignal.sigkill);
          if (!release.isCompleted) release.complete();
          await locker;
        }
        await f.advanceJob(2700, expireLease: true);
        final restarted = await startWorker();
        try {
          w2Expect(
            (await f.waitJob(2700, {
                  'SUCCEEDED',
                  'FAILED',
                  'COMPLETED_WITH_ERRORS',
                }))['state'] ==
                'SUCCEEDED',
            'Fresh worker did not recover abandoned claim',
          );
        } finally {
          restarted.stdin.writeln('shutdown');
          await restarted.stdin.close();
          await restarted.exitCode.timeout(const Duration(seconds: 10));
        }
        w2Expect(
          await effects(27001) == 1,
          'Worker restart lost/duplicated accepted effect',
        );
        final record = await f.observer.execute(
          "SELECT revision,record_data->>'name' FROM public.ventio_records WHERE tenant_id='w2-prepared' AND record_id='asset-27000'",
        );
        w2Equal(record.single, [
          2,
          'Recovered worker',
        ], 'Worker restart altered record twice');
      },
    );
  } finally {
    await f.close();
  }
}
