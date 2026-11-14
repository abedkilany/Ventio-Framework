import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:ventio_core/ventio_core.dart';

import 'command_id.dart';
import 'extension_store.dart';

/// Dedicated additive SQLite database: existing Wave 1 schemas are untouched.
/// Credentials and granted permissions are never stored here. Metadata, user
/// preferences and provisional import submissions are isolated by owner.
class WorkspaceStore {
  WorkspaceStore._(this._database, this._owner);
  final Database _database;
  final String _owner;

  static Future<WorkspaceStore> open({
    required DatabaseFactory factory,
    required String path,
    required HostConnectionProfile profile,
  }) async {
    if (profile.actorId == null || profile.deviceId == null)
      throw StateError('A bound Host profile is required.');
    final owner = canonicalJson([
      profile.endpoint,
      profile.tenantId,
      profile.companyId,
      profile.branchId,
      profile.actorId,
    ]);
    final database = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys=ON');
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.execute('PRAGMA synchronous=FULL');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              'ALTER TABLE workspace_job_submissions ADD COLUMN import_id TEXT',
            );
            await db.execute(
              "ALTER TABLE workspace_job_submissions ADD COLUMN source_rows TEXT NOT NULL DEFAULT '[]'",
            );
          }
        },
        onCreate: (db, version) async {
          await db.execute('''CREATE TABLE workspace_metadata (
            owner TEXT NOT NULL, module_id TEXT NOT NULL, body TEXT NOT NULL,
            PRIMARY KEY(owner,module_id)
          )''');
          await db.execute('''CREATE TABLE workspace_definitions (
          owner TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL,
          revision INTEGER NOT NULL DEFAULT 0, body TEXT NOT NULL,
          request_id TEXT NOT NULL, state TEXT NOT NULL,
          PRIMARY KEY(owner,kind,id), CHECK(state IN ('DRAFT','SYNCED','CONFLICT'))
        )''');
          await db.execute('''CREATE TABLE workspace_job_submissions (
          owner TEXT NOT NULL, job_id TEXT NOT NULL, commands TEXT NOT NULL,
          import_id TEXT, source_rows TEXT NOT NULL DEFAULT '[]',
          state TEXT NOT NULL DEFAULT 'PENDING', PRIMARY KEY(owner,job_id),
          CHECK(state IN ('PENDING','HOST_RECEIVED'))
        )''');
        },
      ),
    );
    return WorkspaceStore._(database, owner);
  }

  Future<void> close() => _database.close();

  Future<void> cacheBundle(ExtensionBundle bundle) => _database
      .insert('workspace_metadata', {
        'owner': _owner,
        'module_id': bundle.moduleId,
        'body': canonicalJson(bundle.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});

  Future<List<ExtensionBundle>> cachedBundles() async {
    final rows = await _database.query(
      'workspace_metadata',
      where: 'owner=?',
      whereArgs: [_owner],
    );
    return rows
        .map(
          (row) => ExtensionBundle.fromJson(
            requireMap(jsonDecode(row['body'] as String), 'package'),
          ),
        )
        .toList();
  }

  /// Explicit user-directed rebase. The next Host write still uses CAS; a
  /// second concurrent Host edit cannot be silently overwritten.
  Future<void> rebaseDraft(
    String kind,
    String id,
    int revision,
    Map<String, dynamic> body,
  ) async {
    validateWave2Definition(kind, body);
    await _database.update(
      'workspace_definitions',
      {
        'revision': revision,
        'body': canonicalJson(body),
        'request_id': createCommandId(),
        'state': 'DRAFT',
      },
      where: 'owner=? AND kind=? AND id=?',
      whereArgs: [_owner, kind, id],
    );
  }

  Future<List<Map<String, dynamic>>> list(String kind) async {
    final rows = await _database.query(
      'workspace_definitions',
      where: 'owner=? AND kind=?',
      whereArgs: [_owner, kind],
      orderBy: 'id',
    );
    return rows
        .map(
          (row) => <String, dynamic>{
            ...row,
            'body': requireMap(jsonDecode(row['body'] as String), 'body'),
          },
        )
        .toList();
  }

  Future<Map<String, dynamic>> saveDraft(
    String kind,
    String id,
    Map<String, dynamic> body,
  ) async {
    validateWave2Definition(kind, body);
    return _database.transaction((tx) async {
      final rows = await tx.query(
        'workspace_definitions',
        where: 'owner=? AND kind=? AND id=?',
        whereArgs: [_owner, kind, id],
      );
      final draft = <String, dynamic>{
        'owner': _owner,
        'kind': kind,
        'id': id,
        'revision': rows.isEmpty ? 0 : rows.single['revision'],
        'body': canonicalJson(body),
        'request_id': createCommandId(),
        'state': 'DRAFT',
      };
      await tx.insert(
        'workspace_definitions',
        draft,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return {...draft, 'body': body};
    });
  }

  /// Preserve dirty drafts and mark conflicts; never silently replace local
  /// intent with a newer shared definition. Reads contain no business data.
  Future<void> receive(String kind, List<dynamic> definitions) =>
      _database.transaction((tx) async {
        for (final raw in definitions) {
          final definition = requireMap(raw, 'definition');
          final id = requireString(definition, 'id');
          final revision = requireInt(definition, 'revision', min: 1);
          final body = requireMap(definition['body'], 'body');
          validateWave2Definition(kind, body);
          final rows = await tx.query(
            'workspace_definitions',
            where: 'owner=? AND kind=? AND id=?',
            whereArgs: [_owner, kind, id],
          );
          if (rows.isNotEmpty && rows.single['state'] != 'SYNCED') {
            if (rows.single['body'] == canonicalJson(body)) {
              await tx.update(
                'workspace_definitions',
                {'revision': revision, 'state': 'SYNCED'},
                where: 'owner=? AND kind=? AND id=?',
                whereArgs: [_owner, kind, id],
              );
            } else if (rows.single['revision'] != revision) {
              await tx.update(
                'workspace_definitions',
                {'state': 'CONFLICT'},
                where: 'owner=? AND kind=? AND id=?',
                whereArgs: [_owner, kind, id],
              );
            }
            continue;
          }
          await tx.insert('workspace_definitions', {
            'owner': _owner,
            'kind': kind,
            'id': id,
            'revision': revision,
            'body': canonicalJson(body),
            'request_id': createCommandId(),
            'state': 'SYNCED',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });

  Future<void> acknowledge(
    String kind,
    String id,
    String requestId,
    int revision,
  ) => _database
      .update(
        'workspace_definitions',
        {'revision': revision, 'state': 'SYNCED'},
        where: 'owner=? AND kind=? AND id=? AND request_id=?',
        whereArgs: [_owner, kind, id, requestId],
      )
      .then((_) {});

  /// Stores complete stable command IDs before dispatch. A lost HTTP response
  /// retries the same Host job ID; the Host job is distinct from client queue entries.
  Future<void> stageJobs(
    List<List<Map<String, dynamic>>> batches, {
    required String importId,
    required Map<String, int> sourceRows,
  }) => _database.transaction((tx) async {
    for (final commands in batches) {
      if (commands.isEmpty ||
          commands.length > 25 ||
          utf8.encode(canonicalJson(commands)).length > 49152) {
        throw const ContractError(
          'INVALID_JOB',
          'Import batch exceeds the job bound.',
        );
      }
      await tx.insert('workspace_job_submissions', {
        'owner': _owner,
        'job_id': createCommandId(),
        'commands': canonicalJson(commands),
        'import_id': importId,
        'source_rows': canonicalJson([
          for (final command in commands)
            sourceRows[command['commandId']] ??
                (throw StateError('Missing CSV source row')),
        ]),
        'state': 'PENDING',
      });
    }
  });

  Future<List<Map<String, Object?>>> pendingJobs() => _database.query(
    'workspace_job_submissions',
    where: 'owner=? AND state=?',
    whereArgs: [_owner, 'PENDING'],
  );
  Future<void> acknowledgeJob(String jobId) => _database
      .update(
        'workspace_job_submissions',
        {'state': 'HOST_RECEIVED'},
        where: 'owner=? AND job_id=?',
        whereArgs: [_owner, jobId],
      )
      .then((_) {});
}
