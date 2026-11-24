// PREPARED / NOT EXECUTED. SQL control-plane contracts only. Supplied operator
// outcomes are explicit input vectors, not proof of local approval or backups.
import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'support/wave2_fixture.dart';

Future<void> main() async {
  final f = await W2Fixture.open();
  final cases = W2Cases();
  Future<Map<String, dynamic>> prepare(
    int id,
    String operation,
    Map<String, dynamic> body, {
    W2Identity? as,
  }) => f.administrative((tx) async {
    final rows = await tx.execute(
      pg.Sql.named(
        'SELECT ventio_security.wave2_prepare_operation(@digest,@company,@branch,@id,@operation,CAST(@body AS jsonb))::text',
      ),
      parameters: {
        'digest': OpaqueToken.digest((as ?? f.author).token),
        'company': W2Fixture.company,
        'branch': W2Fixture.branch,
        'id': w2Id(id),
        'operation': operation,
        'body': canonicalJson(body),
      },
    );
    return requireMap(jsonDecode(rows.single[0] as String), 'operation');
  });
  Future<List<Map<String, dynamic>>> offers() => f.administrative((tx) async {
    final rows = await tx.execute(
      'SELECT ventio_security.wave2_operation_offers()::text',
    );
    return (jsonDecode(rows.single[0] as String) as List)
        .map((raw) => requireMap(raw, 'offer'))
        .toList();
  });
  Map<String, dynamic> resultBody(
    Map<String, dynamic> offer,
    String state, {
    String code = 'FIXTURE_SQL_TRANSITION',
    bool retryable = false,
    Map<String, dynamic> extra = const {},
  }) => {
    'operationId': offer['operationId'],
    'offerId': offer['offerId'],
    'operation': offer['operation'],
    'tenantId': offer['tenantId'],
    'companyId': offer['companyId'],
    'branchId': offer['branchId'],
    'actorId': offer['requestedBy'],
    'state': state,
    'code': code,
    'retryable': retryable,
    ...extra,
  };
  Future<bool> result(
    Map<String, dynamic> offer,
    Map<String, dynamic> body,
  ) => f.administrative((tx) async {
    final rows = await tx.execute(
      pg.Sql.named(
        'SELECT ventio_security.wave2_operation_result(@id,@offer,CAST(@result AS jsonb))',
      ),
      parameters: {
        'id': offer['operationId'],
        'offer': offer['offerId'],
        'result': canonicalJson(body),
      },
    );
    return rows.single[0] == true;
  });
  Map<String, dynamic>? scheduled;
  Map<String, dynamic>? approved;
  var policyRevision = 0;
  Future<void> policy(int request, Map<String, dynamic> body) async {
    policyRevision =
        (await f.save(
              'backup_policy',
              'scope',
              body,
              request: request,
              expected: policyRevision,
            ))['revision']
            as int;
  }

  try {
    await cases.run(
      'W2-O001',
      'M05',
      'SQL prepares no scheduled operation before an explicit approved policy outcome',
      () async {
        w2Expect((await offers()).isEmpty, 'Unapproved scheduler armed');
        await policy(1, w2Policy());
        await prepare(1, 'APPLY_POLICY', {});
        final pending = await offers();
        approved = pending.singleWhere((row) => row['operationId'] == w2Id(1));
        w2Expect(
          pending.every((row) => row['scheduled'] == false),
          'Policy request itself armed schedule',
        );
        final body = requireMap(approved!['body'], 'policy body');
        w2Expect(
          body['policyRevision'] == 1 &&
              RegExp(
                r'^[0-9a-f]{64}$',
              ).hasMatch(body['policySha256'] as String),
          'Policy offer not pinned',
        );
        w2Equal(body['policy'], w2Policy(), 'Policy offer changed content');
      },
    );
    await cases.run(
      'W2-O002',
      'M05,M09,D09',
      'Operation identity is idempotent and tenant-bound; unauthorized callers cannot prepare',
      () async {
        w2Expect(
          (await prepare(1, 'APPLY_POLICY', {}))['state'] ==
              'AWAITING_LOCAL_APPROVAL',
          'Request retry changed state',
        );
        w2Expect(
          (await prepare(1, 'BACKUP_NOW', {}))['reasonCode'] ==
              'OPERATION_ID_REUSED',
          'Changed operation reused ID',
        );
        w2Expect(
          (await prepare(
                1,
                'APPLY_POLICY',
                {},
                as: f.outsider,
              ))['reasonCode'] ==
              'OPERATION_ID_REUSED',
          'Operation ID crossed tenant',
        );
        w2Expect(
          (await prepare(2, 'BACKUP_NOW', {}, as: f.reader))['reasonCode'] ==
              'PERMISSION_DENIED',
          'Unauthorized physical request admitted',
        );
      },
    );
    await cases.run(
      'W2-O003',
      'M05',
      'SQL approved-policy transition produces one daily offer with stable request identity',
      () async {
        w2Expect(
          await result(approved!, resultBody(approved!, 'SUCCEEDED')),
          'Approved SQL input rejected',
        );
        final initial = (await offers())
            .where((row) => row['scheduled'] == true)
            .toList();
        w2Expect(initial.length == 1, 'Daily offer missing or duplicated');
        scheduled = initial.single;
        final repeated = (await offers())
            .where((row) => row['scheduled'] == true)
            .toList();
        w2Expect(
          repeated.length == 1 &&
              repeated.single['operationId'] == scheduled!['operationId'],
          'Polling duplicated daily offer',
        );
      },
    );
    await cases.run(
      'W2-O004',
      'M05',
      'SQL schedule retry requires known retryable failure backoff and bounded attempt count',
      () async {
        for (var attempt = 1; attempt <= 3; attempt++) {
          final current = scheduled!;
          await result(current, resultBody(current, 'FAILED', retryable: true));
          w2Expect(
            (await offers()).where((row) => row['scheduled'] == true).isEmpty,
            'Retry ignored backoff',
          );
          await f.observer.execute(
            pg.Sql.named(
              'UPDATE public.ventio_wave2_operations SET updated_at=clock_timestamp()-interval \'6 minutes\' WHERE operation_id=@id',
            ),
            parameters: {'id': current['operationId']},
          );
          final next = (await offers())
              .where((row) => row['scheduled'] == true)
              .toList();
          if (attempt < 3) {
            w2Expect(
              next.length == 1 &&
                  next.single['operationId'] != current['operationId'],
              'Retry did not receive separate identity',
            );
            scheduled = next.single;
          } else {
            w2Expect(next.isEmpty, 'Retry ceiling exceeded');
          }
        }
      },
    );
    await cases.run(
      'W2-O005',
      'M05,M02',
      'Changing or disabling policy invalidates old approval instead of silently rearming',
      () async {
        await policy(5, {...w2Policy(), 'enabled': false});
        w2Expect(
          (await offers()).where((row) => row['scheduled'] == true).isEmpty,
          'Disabled policy scheduled',
        );
        await policy(6, w2Policy());
        w2Expect(
          (await offers()).where((row) => row['scheduled'] == true).isEmpty,
          'New revision reused old approval',
        );
      },
    );
    await cases.run(
      'W2-O006',
      'M05,M09',
      'Trusted outcome inputs are fenced by offer identity exact scope and terminal immutability',
      () async {
        await prepare(60, 'BACKUP_NOW', {});
        final offer = (await offers()).singleWhere(
          (row) => row['operationId'] == w2Id(60),
        );
        final wrong = {...offer, 'offerId': w2Id(999)};
        w2Expect(
          !await result(wrong, resultBody(wrong, 'SUCCEEDED')),
          'Unrelated offer accepted',
        );
        String? state;
        try {
          await result(offer, {
            ...resultBody(offer, 'SUCCEEDED'),
            'tenantId': 'other',
          });
        } on pg.ServerException catch (error) {
          state = error.code;
        }
        w2Expect(state == '42501', 'Outcome context not checked');
        final success = resultBody(offer, 'SUCCEEDED');
        w2Expect(
          await result(offer, success) && await result(offer, success),
          'Exact outcome replay failed',
        );
        await result(offer, resultBody(offer, 'FAILED'));
        final saved = await f.observer.execute(
          pg.Sql.named(
            'SELECT state FROM public.ventio_wave2_operations WHERE operation_id=@id',
          ),
          parameters: {'id': offer['operationId']},
        );
        w2Expect(
          saved.single[0] == 'SUCCEEDED',
          'Terminal outcome overwritten',
        );
      },
    );
    await cases.run(
      'W2-O007',
      'M09',
      'SQL restore preparation requires a recent successful exact backup plan',
      () async {
        const backup =
            'ventio-postgresql-before-upgrade-20261116T000000000Z-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        final body = {
          'backupName': backup,
          'planOperationId': w2Id(70),
          'planSha256': 'a' * 64,
        };
        w2Expect(
          (await prepare(71, 'RESTORE', body))['reasonCode'] ==
              'RESTORE_PLAN_CHANGED',
          'Missing plan accepted',
        );
        await prepare(70, 'RESTORE_PLAN', {'backupName': backup});
        final plan = (await offers()).singleWhere(
          (row) => row['operationId'] == w2Id(70),
        );
        await result(
          plan,
          resultBody(plan, 'SUCCEEDED', extra: {'planSha256': 'a' * 64}),
        );
        w2Expect(
          (await prepare(72, 'RESTORE', {
                ...body,
                'planSha256': 'b' * 64,
              }))['reasonCode'] ==
              'RESTORE_PLAN_CHANGED',
          'Changed plan hash accepted',
        );
        w2Expect(
          (await prepare(73, 'RESTORE', body))['state'] ==
              'AWAITING_LOCAL_APPROVAL',
          'Exact plan not admitted for local approval',
        );
        await f.observer.execute(
          pg.Sql.named(
            'UPDATE public.ventio_wave2_operations SET updated_at=clock_timestamp()-interval \'2 hours\' WHERE operation_id=@id',
          ),
          parameters: {'id': w2Id(70)},
        );
        w2Expect(
          (await prepare(74, 'RESTORE', body))['reasonCode'] ==
              'RESTORE_PLAN_CHANGED',
          'Expired plan accepted',
        );
      },
    );
    await cases.run(
      'W2-O008',
      'M05,D09',
      'Expired pending requests and revoked credentials lose executable offers',
      () async {
        await prepare(80, 'BACKUP_NOW', {});
        await f.observer.execute(
          pg.Sql.named(
            'UPDATE public.ventio_wave2_operations SET created_at=clock_timestamp()-interval \'2 days\' WHERE operation_id=@id',
          ),
          parameters: {'id': w2Id(80)},
        );
        w2Expect(
          !(await offers()).any((row) => row['operationId'] == w2Id(80)),
          'Expired request still offered',
        );
        await prepare(81, 'BACKUP_NOW', {});
        await f.author.admin.revokeGrant(
          f.author.actor,
          W2Fixture.company,
          W2Fixture.branch,
          'platform.operations.manage',
        );
        w2Expect(
          !(await offers()).any((row) => row['operationId'] == w2Id(81)),
          'Revoked request still offered',
        );
        final rows = await f.observer.execute(
          pg.Sql.named(
            'SELECT state FROM public.ventio_wave2_operations WHERE operation_id=ANY(CAST(@ids AS text[]))',
          ),
          parameters: {
            'ids': [w2Id(80), w2Id(81)],
          },
        );
        w2Expect(
          rows.every((row) => row[0] == 'EXPIRED'),
          'Expired requests not marked',
        );
      },
    );
  } finally {
    await f.close();
  }
}
