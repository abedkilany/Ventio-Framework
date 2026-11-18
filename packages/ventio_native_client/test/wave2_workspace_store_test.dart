// PREPARED / NOT EXECUTED. Real SQLite files, no Host substitutes or GUI.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/workspace_store.dart';
import 'package:ventio_native_client/ventio_native_client.dart';

import '../../ventio_core/test/support/wave2_fixtures.dart';

HostConnectionProfile profile({
  String endpoint = 'https://localhost:8443',
  String tenant = 'w2-prepared',
  String company = 'company-a',
  String branch = 'branch-a',
  String actor = 'author',
  String? device = 'device-author',
}) => HostConnectionProfile(
  endpoint: endpoint,
  tenantId: tenant,
  companyId: company,
  branchId: branch,
  actorId: actor,
  deviceId: device,
);

void main() {
  late Directory root;
  late String path;
  WorkspaceStore? store;
  Future<WorkspaceStore> open([HostConnectionProfile? owner]) async =>
      store = await WorkspaceStore.open(
        factory: databaseFactoryFfi,
        path: path,
        profile: owner ?? profile(),
      );
  Future<void> reopen([HostConnectionProfile? owner]) async {
    await store?.close();
    store = null;
    await open(owner);
  }

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ventio-wave2-sqlite-');
    path = '${root.path}/workspace.sqlite';
    await open();
  });
  tearDown(() async {
    await store?.close();
    // root comes solely from createTemp; no installed application paths.
    await root.delete(recursive: true);
  });

  test(
    'W2-S001 [C09,D09] unbound profiles cannot open the workspace',
    () async {
      await expectLater(
        WorkspaceStore.open(
          factory: databaseFactoryFfi,
          path: '${root.path}/unbound.sqlite',
          profile: profile(device: null),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'W2-S002 [K09,C09] offline draft body and stable request survive reopening',
    () async {
      final saved = await store!.saveDraft(
        'preferences',
        'mine',
        w2Preferences(),
      );
      await reopen();
      final row = (await store!.list('preferences')).single;
      expect(row['request_id'], saved['request_id']);
      expect(row['body'], saved['body']);
      expect(row['state'], 'DRAFT');
    },
  );
  test(
    'W2-S003 [K09,C09] a newer Host definition marks conflict without replacing local intent',
    () async {
      final local = await store!.saveDraft(
        'preferences',
        'mine',
        w2Preferences(),
      );
      await store!.receive('preferences', [
        {'id': 'mine', 'revision': 2, 'body': w2Preferences(theme: 'light')},
      ]);
      await reopen();
      final row = (await store!.list('preferences')).single;
      expect(row['state'], 'CONFLICT');
      expect(row['body'], local['body']);
      expect(row['request_id'], local['request_id']);
    },
  );
  test(
    'W2-S004 [K09] unchanged base revision does not overwrite a dirty local edit',
    () async {
      await store!.receive('preferences', [
        {'id': 'mine', 'revision': 1, 'body': w2Preferences(theme: 'light')},
      ]);
      await store!.saveDraft('preferences', 'mine', w2Preferences());
      await store!.receive('preferences', [
        {'id': 'mine', 'revision': 1, 'body': w2Preferences(theme: 'light')},
      ]);
      final row = (await store!.list('preferences')).single;
      expect(row['state'], 'DRAFT');
      expect((row['body'] as Map)['theme'], 'dark');
    },
  );
  test(
    'W2-S005 [K09] replayed matching publication can acknowledge a lost response',
    () async {
      await store!.saveDraft('preferences', 'mine', w2Preferences());
      await store!.receive('preferences', [
        {'id': 'mine', 'revision': 3, 'body': w2Preferences()},
      ]);
      final row = (await store!.list('preferences')).single;
      expect(row['state'], 'SYNCED');
      expect(row['revision'], 3);
    },
  );
  test(
    'W2-S006 [K09] stale acknowledgement cannot mark an intervening edit synced',
    () async {
      final first = await store!.saveDraft(
        'preferences',
        'mine',
        w2Preferences(),
      );
      final next = await store!.saveDraft(
        'preferences',
        'mine',
        w2Preferences(theme: 'light'),
      );
      await store!.acknowledge(
        'preferences',
        'mine',
        first['request_id'] as String,
        1,
      );
      final row = (await store!.list('preferences')).single;
      expect(row['state'], 'DRAFT');
      expect(row['request_id'], next['request_id']);
      expect(row['revision'], 0);
    },
  );
  test(
    'W2-S007 [K09] explicit rebase preserves chosen content and creates new CAS intent',
    () async {
      final first = await store!.saveDraft(
        'preferences',
        'mine',
        w2Preferences(),
      );
      await store!.rebaseDraft(
        'preferences',
        'mine',
        7,
        w2Preferences(theme: 'light'),
      );
      final row = (await store!.list('preferences')).single;
      expect(row['revision'], 7);
      expect(row['state'], 'DRAFT');
      expect(row['request_id'], isNot(first['request_id']));
      expect((row['body'] as Map)['theme'], 'light');
    },
  );
  test(
    'W2-S008 [B09,C08,K09] authoritative retirement removes synced metadata and preserves drafts/conflicts',
    () async {
      await store!.receive('saved_view', [
        {'id': 'old', 'revision': 1, 'body': w2View()},
      ]);
      await store!.saveDraft('saved_view', 'draft', w2View());
      await store!.saveDraft('saved_view', 'conflict', w2View());
      await store!.receive('saved_view', [
        {
          'id': 'conflict',
          'revision': 2,
          'body': {...w2View(), 'title': 'Other'},
        },
      ]);
      await store!.receive('saved_view', []);
      expect((await store!.list('saved_view')).map((row) => row['id']), [
        'conflict',
        'draft',
      ]);
    },
  );
  test(
    'W2-S009 [B09,C08,C09] owner isolation covers endpoint tenant company branch and actor',
    () async {
      await store!.saveDraft('preferences', 'mine', w2Preferences());
      for (final other in [
        profile(endpoint: 'https://localhost:9443'),
        profile(tenant: 'other'),
        profile(company: 'other'),
        profile(branch: 'other'),
        profile(actor: 'other'),
      ]) {
        await reopen(other);
        expect(await store!.list('preferences'), isEmpty);
        expect(await store!.pendingJobs(), isEmpty);
        expect(await store!.pendingOperations(), isEmpty);
      }
      await reopen();
      expect(await store!.list('preferences'), hasLength(1));
    },
  );
  test(
    'W2-S010 [C08,F05] cached package stays owner-isolated metadata and retains its original digest inputs',
    () async {
      final bundle = ExtensionBundle.fromJson(w2BundleJson());
      await store!.cacheBundle(bundle);
      await reopen(profile(actor: 'other'));
      expect(await store!.cachedBundles(), isEmpty);
      await reopen();
      expect(
        canonicalJson((await store!.cachedBundles()).single.toJson()),
        canonicalJson(bundle.toJson()),
      );
      // Actual approved-release and business-read authorization are H cases.
    },
  );
  test(
    'W2-S011 [J03,K09] import command IDs and sparse source rows persist before dispatch',
    () async {
      final commands = [w2Create(1).original, w2Create(2).original];
      await store!.stageJobs(
        [commands],
        importId: w2Id(30),
        sourceRows: {w2Id(1): 2, w2Id(2): 7},
      );
      final before = (await store!.pendingJobs()).single;
      await reopen();
      final after = (await store!.pendingJobs()).single;
      expect(after, before);
      expect(jsonDecode(after['source_rows'] as String), [2, 7]);
      expect(jsonDecode(after['commands'] as String), commands);
    },
  );
  test(
    'W2-S012 [J03] invalid later batch rolls back all staged jobs atomically',
    () async {
      final command = w2Create(1).original;
      await expectLater(
        store!.stageJobs(
          [
            [command],
            List.filled(26, command),
          ],
          importId: w2Id(30),
          sourceRows: {w2Id(1): 2},
        ),
        throwsA(isA<ContractError>()),
      );
      expect(await store!.pendingJobs(), isEmpty);
    },
  );
  test(
    'W2-S013 [J03] missing source-row mapping and oversized batch leave no retry intent',
    () async {
      await expectLater(
        store!.stageJobs(
          [
            [w2Create(1).original],
          ],
          importId: w2Id(30),
          sourceRows: {},
        ),
        throwsStateError,
      );
      await expectLater(
        store!.stageJobs(
          [
            [
              w2Create(2, values: {'name': 'x' * 50000}).original,
            ],
          ],
          importId: w2Id(30),
          sourceRows: {w2Id(2): 2},
        ),
        throwsA(isA<ContractError>()),
      );
      expect(await store!.pendingJobs(), isEmpty);
    },
  );
  test(
    'W2-S014 [J03,C09] another owner cannot acknowledge pending import intent',
    () async {
      await store!.stageJobs(
        [
          [w2Create(1).original],
        ],
        importId: w2Id(30),
        sourceRows: {w2Id(1): 2},
      );
      final id = (await store!.pendingJobs()).single['job_id'] as String;
      await reopen(profile(actor: 'other'));
      await store!.acknowledgeJob(id);
      await reopen();
      expect(await store!.pendingJobs(), hasLength(1));
      await store!.acknowledgeJob(id);
      await reopen();
      expect(await store!.pendingJobs(), isEmpty);
    },
  );
  test(
    'W2-S015 [M05,M09] operation retry IDs persist and the twenty-pending bound fails closed',
    () async {
      final first = await store!.stageOperation('BACKUP_NOW', {});
      for (var i = 1; i < 20; i++) {
        await store!.stageOperation('BACKUP_NOW', {});
      }
      await expectLater(
        store!.stageOperation('BACKUP_NOW', {}),
        throwsA(isA<ContractError>()),
      );
      await reopen();
      expect(await store!.pendingOperations(), hasLength(20));
      expect(
        (await store!.pendingOperations()).any(
          (row) => row['operationId'] == first['operationId'],
        ),
        isTrue,
      );
    },
  );
  test(
    'W2-S016 [M05,M09] discarding a local retry cannot discard another owner operation',
    () async {
      final first = await store!.stageOperation('BACKUP_NOW', {});
      await reopen(profile(actor: 'other'));
      await store!.discardOperationRetry(first['operationId'] as String);
      await reopen();
      expect(await store!.pendingOperations(), hasLength(1));
      await store!.discardOperationRetry(first['operationId'] as String);
      expect(await store!.pendingOperations(), isEmpty);
    },
  );

  Future<void> legacy(int version) async {
    await store!.close();
    store = null;
    path = '${root.path}/legacy-$version.sqlite';
    final owner = canonicalJson([
      'https://localhost:8443',
      'w2-prepared',
      'company-a',
      'branch-a',
      'author',
    ]);
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE workspace_metadata(owner TEXT NOT NULL,module_id TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(owner,module_id))',
          );
          await db.execute(
            'CREATE TABLE workspace_definitions(owner TEXT NOT NULL,kind TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,body TEXT NOT NULL,request_id TEXT NOT NULL,state TEXT NOT NULL,PRIMARY KEY(owner,kind,id))',
          );
          await db.execute(
            'CREATE TABLE workspace_job_submissions(owner TEXT NOT NULL,job_id TEXT NOT NULL,commands TEXT NOT NULL,${version == 2 ? "import_id TEXT,source_rows TEXT NOT NULL DEFAULT '[]'," : ""}state TEXT NOT NULL DEFAULT \'PENDING\',PRIMARY KEY(owner,job_id))',
          );
          await db.insert('workspace_definitions', {
            'owner': owner,
            'kind': 'preferences',
            'id': 'mine',
            'revision': 4,
            'body': canonicalJson(w2Preferences()),
            'request_id': w2Id(40),
            'state': 'DRAFT',
          });
          await db.insert('workspace_job_submissions', {
            'owner': owner,
            'job_id': w2Id(41),
            'commands': canonicalJson([w2Create(1).original]),
            'state': 'PENDING',
            if (version == 2) ...{'import_id': w2Id(42), 'source_rows': '[7]'},
          });
        },
      ),
    );
    await db.close();
    await open();
  }

  test(
    'W2-S017 [K09,J03,C09] workspace v1 to v3 preserves pending commands and dirty CAS drafts',
    () async {
      await legacy(1);
      final row = (await store!.list('preferences')).single;
      expect(row['revision'], 4);
      expect(row['request_id'], w2Id(40));
      expect(row['state'], 'DRAFT');
      final job = (await store!.pendingJobs()).single;
      expect(job['job_id'], w2Id(41));
      expect(job['import_id'], isNull);
      expect(job['source_rows'], '[]');
      await store!.stageOperation('BACKUP_NOW', {});
      expect(await store!.pendingOperations(), hasLength(1));
    },
  );
  test(
    'W2-S018 [J03,C09] workspace v2 to v3 preserves import correlation and commands exactly',
    () async {
      await legacy(2);
      await reopen();
      final job = (await store!.pendingJobs()).single;
      expect(job['import_id'], w2Id(42));
      expect(job['source_rows'], '[7]');
      expect(jsonDecode(job['commands'] as String), [w2Create(1).original]);
      expect(await store!.pendingOperations(), isEmpty);
    },
  );
  test(
    'W2-S019 [C09,K09] real workspace connection uses WAL FULL and foreign-key enforcement',
    () async {
      final db = await databaseFactoryFfi.openDatabase(path);
      expect(
        (await db.rawQuery('PRAGMA journal_mode')).single.values.single,
        'wal',
      );
      expect((await db.rawQuery('PRAGMA synchronous')).single.values.single, 2);
      expect(
        (await db.rawQuery('PRAGMA foreign_keys')).single.values.single,
        1,
      );
    },
  );
  test(
    'W2-S020 [B09,C09,C12] invalid authoritative receive is atomic and cannot erase valid local definitions',
    () async {
      await store!.receive('saved_view', [
        {'id': 'old', 'revision': 1, 'body': w2View()},
      ]);
      await expectLater(
        store!.receive('saved_view', [
          {'id': 'new', 'revision': 1, 'body': w2View()},
          {
            'id': 'bad',
            'revision': 1,
            'body': {...w2View(), 'sql': 'select 1'},
          },
        ]),
        throwsA(isA<ContractError>()),
      );
      expect((await store!.list('saved_view')).map((row) => row['id']), [
        'old',
      ]);
    },
  );
}
