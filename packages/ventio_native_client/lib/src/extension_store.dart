import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:ventio_core/ventio_core.dart';

const _extensionsTable = 'local_extensions';
const _docTypesTable = 'local_extension_doctypes';
const _recordsTable = 'local_extension_records';

enum ExtensionState {
  draft('DRAFT'),
  active('ACTIVE_LOCAL'),
  disabled('DISABLED_LOCAL');

  const ExtensionState(this.databaseValue);

  final String databaseValue;

  static ExtensionState fromDatabase(Object? value) =>
      ExtensionState.values.firstWhere(
        (state) => state.databaseValue == value,
        orElse: () => throw FormatException('Unknown extension state: $value'),
      );
}

class LocalExtension {
  const LocalExtension({
    required this.moduleId,
    required this.displayName,
    required this.description,
    required this.version,
    required this.dependencies,
    required this.state,
    required this.updatedAtUtc,
  });

  final String moduleId;
  final String displayName;
  final String description;
  final String version;
  final Map<String, String> dependencies;
  final ExtensionState state;
  final DateTime updatedAtUtc;

  /// Local metadata is never evidence of Host approval or shared installation.
  String get authorityState => 'LOCAL_ONLY';

  factory LocalExtension.fromRow(Map<String, Object?> row) {
    final rawDependencies = jsonDecode(row['dependencies_json']! as String);
    if (rawDependencies is! Map ||
        rawDependencies.keys.any((key) => key is! String) ||
        rawDependencies.values.any((value) => value is! String)) {
      throw const FormatException('Stored extension dependencies are invalid.');
    }
    final dependencies = <String, String>{};
    for (final entry in rawDependencies.entries) {
      final id = entry.key as String;
      final version = entry.value as String;
      if (!_moduleId.hasMatch(id)) {
        throw const FormatException(
          'Stored extension dependency ID is invalid.',
        );
      }
      semverParts(version);
      dependencies[id] = version;
    }
    return LocalExtension(
      moduleId: row['module_id']! as String,
      displayName: row['display_name']! as String,
      description: row['description']! as String,
      version: row['version']! as String,
      dependencies: Map.unmodifiable(dependencies),
      state: ExtensionState.fromDatabase(row['state']),
      updatedAtUtc: DateTime.parse(row['updated_at_utc']! as String).toUtc(),
    );
  }
}

class RecordScope {
  const RecordScope({
    required this.organizationId,
    required this.companyId,
    required this.branchId,
  });

  final String organizationId;
  final String companyId;
  final String branchId;

  void validate() {
    for (final value in [organizationId, companyId, branchId]) {
      if (value.trim().isEmpty || value.length > 128) {
        throw ArgumentError('Organization, company and branch are required.');
      }
    }
  }
}

class LocalExtensionRecord {
  LocalExtensionRecord({
    required this.recordId,
    required this.moduleId,
    required this.docTypeName,
    required this.scope,
    required this.schemaVersion,
    required this.revision,
    required this.values,
    required this.updatedAtUtc,
  });

  final String recordId;
  final String moduleId;
  final String docTypeName;
  final RecordScope scope;
  final int schemaVersion;
  final int revision;
  final Map<String, dynamic> values;
  final DateTime updatedAtUtc;

  /// This value stays local until a real Host receipt is stored separately.
  String get syncState => 'LOCAL_ONLY';

  factory LocalExtensionRecord.fromRow(Map<String, Object?> row) {
    final decoded = jsonDecode(row['data_json']! as String);
    if (decoded is! Map) throw const FormatException('Record data is invalid.');
    return LocalExtensionRecord(
      recordId: row['record_id']! as String,
      moduleId: row['module_id']! as String,
      docTypeName: row['doctype_name']! as String,
      scope: RecordScope(
        organizationId: row['organization_id']! as String,
        companyId: row['company_id']! as String,
        branchId: row['branch_id']! as String,
      ),
      schemaVersion: row['schema_version']! as int,
      revision: row['revision']! as int,
      values: Map<String, dynamic>.from(decoded),
      updatedAtUtc: DateTime.parse(row['updated_at_utc']! as String).toUtc(),
    );
  }
}

class ExtensionStoreException implements Exception {
  const ExtensionStoreException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Durable device-local extension drafts, schemas and provisional records.
/// This store deliberately has no Host transport or approval authority.
class LocalExtensionStore {
  LocalExtensionStore._(this._database, this._clock);

  final Database _database;
  final DateTime Function() _clock;
  bool _closed = false;

  static Future<LocalExtensionStore> open({
    required DatabaseFactory factory,
    required String path,
    DateTime Function()? clock,
  }) async {
    final database = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onConfigure: (database) async {
          await database.execute('PRAGMA foreign_keys = ON');
          await database.rawQuery('PRAGMA journal_mode = WAL');
          await database.execute('PRAGMA synchronous = FULL');
        },
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE $_extensionsTable (
              module_id TEXT PRIMARY KEY NOT NULL,
              display_name TEXT NOT NULL,
              description TEXT NOT NULL,
              version TEXT NOT NULL,
              dependencies_json TEXT NOT NULL DEFAULT '{}',
              state TEXT NOT NULL CHECK (state IN ('DRAFT', 'ACTIVE_LOCAL', 'DISABLED_LOCAL')),
              created_at_utc TEXT NOT NULL,
              updated_at_utc TEXT NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE $_docTypesTable (
              module_id TEXT NOT NULL,
              doctype_name TEXT NOT NULL,
              schema_version INTEGER NOT NULL CHECK (schema_version > 0),
              metadata_json TEXT NOT NULL,
              PRIMARY KEY (module_id, doctype_name),
              FOREIGN KEY (module_id) REFERENCES $_extensionsTable(module_id)
                ON DELETE CASCADE
            )
          ''');
          await database.execute('''
            CREATE TABLE $_recordsTable (
              record_id TEXT PRIMARY KEY NOT NULL,
              module_id TEXT NOT NULL,
              doctype_name TEXT NOT NULL,
              organization_id TEXT NOT NULL,
              company_id TEXT NOT NULL,
              branch_id TEXT NOT NULL,
              data_json TEXT NOT NULL,
              schema_version INTEGER NOT NULL CHECK (schema_version > 0),
              revision INTEGER NOT NULL CHECK (revision > 0),
              sync_state TEXT NOT NULL DEFAULT 'LOCAL_ONLY'
                CHECK (sync_state = 'LOCAL_ONLY'),
              created_at_utc TEXT NOT NULL,
              updated_at_utc TEXT NOT NULL,
              FOREIGN KEY (module_id, doctype_name)
                REFERENCES $_docTypesTable(module_id, doctype_name)
                ON DELETE RESTRICT
            )
          ''');
          await database.execute('''
            CREATE INDEX local_extension_records_scope
            ON $_recordsTable(module_id, doctype_name, organization_id, company_id,
              branch_id, updated_at_utc DESC)
          ''');
        },
        onUpgrade: (database, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await database.execute('''
              ALTER TABLE $_extensionsTable
              ADD COLUMN dependencies_json TEXT NOT NULL DEFAULT '{}'
            ''');
          }
        },
      ),
    );
    return LocalExtensionStore._(database, clock ?? DateTime.now);
  }

  Future<void> createExtension({
    required String moduleId,
    required String displayName,
    required String description,
    String version = '0.1.0',
    Map<String, String> dependencies = const {},
  }) async {
    _ensureOpen();
    final id = moduleId.trim();
    final name = displayName.trim();
    final summary = description.trim();
    if (!_moduleId.hasMatch(id) || id.length > 128) {
      throw const ExtensionStoreException(
        'INVALID_MODULE_ID',
        'Use a lowercase namespaced ID such as com.example.asset_register.',
      );
    }
    if (name.isEmpty || name.length > 120) {
      throw const ExtensionStoreException(
        'INVALID_DISPLAY_NAME',
        'The extension name must contain 1 to 120 characters.',
      );
    }
    if (summary.length > 2000) {
      throw const ExtensionStoreException(
        'INVALID_DESCRIPTION',
        'The description cannot exceed 2,000 characters.',
      );
    }
    semverParts(version);
    final normalizedDependencies = _normalizeDependencies(id, dependencies);
    final now = _now();
    try {
      await _database.transaction((transaction) async {
        await _validateDependencyGraph(
          transaction,
          moduleId: id,
          dependencies: normalizedDependencies,
        );
        await _validateDependencyTargets(transaction, normalizedDependencies);
        await transaction.insert(_extensionsTable, {
          'module_id': id,
          'display_name': name,
          'description': summary,
          'version': version,
          'dependencies_json': canonicalJson(normalizedDependencies),
          'state': ExtensionState.draft.databaseValue,
          'created_at_utc': now,
          'updated_at_utc': now,
        }, conflictAlgorithm: ConflictAlgorithm.abort);
      });
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw const ExtensionStoreException(
          'DUPLICATE_MODULE',
          'An extension with this ID already exists on this device.',
        );
      }
      rethrow;
    }
  }

  Future<List<LocalExtension>> listExtensions() async {
    _ensureOpen();
    final rows = await _database.query(
      _extensionsTable,
      orderBy: 'display_name COLLATE NOCASE, module_id',
    );
    return List.unmodifiable(rows.map(LocalExtension.fromRow));
  }

  Future<LocalExtension?> getExtension(String moduleId) async {
    _ensureOpen();
    final rows = await _database.query(
      _extensionsTable,
      where: 'module_id = ?',
      whereArgs: [moduleId],
      limit: 1,
    );
    return rows.isEmpty ? null : LocalExtension.fromRow(rows.single);
  }

  Future<void> updateExtensionDetails({
    required String moduleId,
    required String displayName,
    required String description,
    required String version,
    Map<String, String>? dependencies,
  }) async {
    _ensureOpen();
    final name = displayName.trim();
    final summary = description.trim();
    semverParts(version);
    if (name.isEmpty || name.length > 120 || summary.length > 2000) {
      throw const ExtensionStoreException(
        'INVALID_EXTENSION_DETAILS',
        'Enter a name up to 120 characters and a description up to 2,000 characters.',
      );
    }
    await _database.transaction((transaction) async {
      final rows = await transaction.query(
        _extensionsTable,
        where: 'module_id = ?',
        whereArgs: [moduleId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Unknown extension: $moduleId');
      final existing = LocalExtension.fromRow(rows.single);
      if (compareSemver(version, existing.version) < 0) {
        throw const ExtensionStoreException(
          'VERSION_DOWNGRADE',
          'Extension versions cannot move backwards.',
        );
      }
      final nextDependencies = _normalizeDependencies(
        moduleId,
        dependencies ?? existing.dependencies,
      );
      if (existing.state == ExtensionState.active &&
          !_sameDependencies(existing.dependencies, nextDependencies)) {
        throw const ExtensionStoreException(
          'DISABLE_BEFORE_DEPENDENCY_CHANGE',
          'Disable the extension before changing its dependencies.',
        );
      }
      await _validateDependencyGraph(
        transaction,
        moduleId: moduleId,
        dependencies: nextDependencies,
      );
      await _validateDependencyTargets(transaction, nextDependencies);
      await _validateDependentsForVersion(transaction, moduleId, version);
      await transaction.update(
        _extensionsTable,
        {
          'display_name': name,
          'description': summary,
          'version': version,
          'dependencies_json': canonicalJson(nextDependencies),
          'updated_at_utc': _now(),
        },
        where: 'module_id = ?',
        whereArgs: [moduleId],
      );
    });
  }

  Future<List<Map<String, dynamic>>> listDocTypes(String moduleId) async {
    _ensureOpen();
    final rows = await _database.query(
      _docTypesTable,
      columns: const ['metadata_json'],
      where: 'module_id = ?',
      whereArgs: [moduleId],
      orderBy: 'doctype_name COLLATE NOCASE',
    );
    return List.unmodifiable(
      rows.map((row) => _decodeMap(row['metadata_json'])),
    );
  }

  Future<Map<String, dynamic>?> getDocType(
    String moduleId,
    String docTypeName,
  ) async {
    _ensureOpen();
    final rows = await _database.query(
      _docTypesTable,
      columns: const ['metadata_json'],
      where: 'module_id = ? AND doctype_name = ?',
      whereArgs: [moduleId, docTypeName],
      limit: 1,
    );
    return rows.isEmpty ? null : _decodeMap(rows.single['metadata_json']);
  }

  Future<void> saveDocType(Map<String, dynamic> metadata) async {
    _ensureOpen();
    final definition = DocTypeDefinition.fromJson(metadata);
    if (definition.kind != 'operational') {
      throw const ExtensionStoreException(
        'UNSUPPORTED_DOCTYPE_KIND',
        'Only operational DocTypes are supported by the local data engine.',
      );
    }
    _validateDefinition(definition);
    final normalized = jsonDecode(jsonEncode(metadata)) as Map<String, dynamic>;
    final now = _now();

    await _database.transaction((transaction) async {
      final extensions = await transaction.query(
        _extensionsTable,
        where: 'module_id = ?',
        whereArgs: [definition.moduleId],
        limit: 1,
      );
      if (extensions.isEmpty) {
        throw const ExtensionStoreException(
          'UNKNOWN_MODULE',
          'Create the extension before adding DocTypes.',
        );
      }
      final oldRows = await transaction.query(
        _docTypesTable,
        where: 'module_id = ? AND doctype_name = ?',
        whereArgs: [definition.moduleId, definition.name],
        limit: 1,
      );
      final existingNames = await transaction.query(
        _docTypesTable,
        columns: const ['doctype_name'],
        where: 'module_id = ?',
        whereArgs: [definition.moduleId],
      );
      final knownNames =
          existingNames.map((row) => row['doctype_name']! as String).toSet()
            ..add(definition.name);
      for (final field in definition.fields.where(
        (item) => item.type == 'reference',
      )) {
        if (!knownNames.contains(field.referenceTo)) {
          throw ExtensionStoreException(
            'UNKNOWN_RELATION_TARGET',
            '${field.name} refers to an unknown DocType: ${field.referenceTo}',
          );
        }
      }
      if (oldRows.isNotEmpty) {
        final oldJson = _decodeMap(oldRows.single['metadata_json']);
        final previous = DocTypeDefinition.fromJson(oldJson);
        _validateNonDestructiveUpgrade(previous, definition);
        if (definition.schemaVersion <= previous.schemaVersion) {
          throw const ExtensionStoreException(
            'SCHEMA_VERSION_REQUIRED',
            'A saved DocType update must increase its schema version.',
          );
        }
        final module = LocalExtension.fromRow(extensions.single);
        await transaction.update(
          _extensionsTable,
          {'version': _nextPatch(module.version), 'updated_at_utc': now},
          where: 'module_id = ?',
          whereArgs: [definition.moduleId],
        );
        await transaction.update(
          _docTypesTable,
          {
            'schema_version': definition.schemaVersion,
            'metadata_json': canonicalJson(normalized),
          },
          where: 'module_id = ? AND doctype_name = ?',
          whereArgs: [definition.moduleId, definition.name],
        );
        await transaction.update(
          _recordsTable,
          {'schema_version': definition.schemaVersion, 'updated_at_utc': now},
          where: 'module_id = ? AND doctype_name = ?',
          whereArgs: [definition.moduleId, definition.name],
        );
        return;
      }

      await transaction.insert(_docTypesTable, {
        'module_id': definition.moduleId,
        'doctype_name': definition.name,
        'schema_version': definition.schemaVersion,
        'metadata_json': canonicalJson(normalized),
      });
      if (existingNames.isNotEmpty) {
        final module = LocalExtension.fromRow(extensions.single);
        await transaction.update(
          _extensionsTable,
          {'version': _nextPatch(module.version), 'updated_at_utc': now},
          where: 'module_id = ?',
          whereArgs: [definition.moduleId],
        );
      }
    });
  }

  Future<void> activate(String moduleId) async {
    _ensureOpen();
    await _database.transaction((transaction) async {
      final module = await transaction.query(
        _extensionsTable,
        where: 'module_id = ?',
        whereArgs: [moduleId],
        limit: 1,
      );
      if (module.isEmpty) throw StateError('Unknown extension: $moduleId');
      final extension = LocalExtension.fromRow(module.single);
      await _validateDependenciesActive(transaction, extension.dependencies);
      final definitions = await transaction.query(
        _docTypesTable,
        columns: const ['metadata_json'],
        where: 'module_id = ?',
        whereArgs: [moduleId],
      );
      if (definitions.isEmpty) {
        throw const ExtensionStoreException(
          'EMPTY_EXTENSION',
          'Add at least one DocType before activating this extension.',
        );
      }
      await transaction.update(
        _extensionsTable,
        {
          'state': ExtensionState.active.databaseValue,
          'updated_at_utc': _now(),
        },
        where: 'module_id = ?',
        whereArgs: [moduleId],
      );
    });
  }

  Future<void> disable(String moduleId) async {
    _ensureOpen();
    await _database.transaction((transaction) async {
      final modules = await transaction.query(
        _extensionsTable,
        where: 'module_id = ?',
        whereArgs: [moduleId],
        limit: 1,
      );
      if (modules.isEmpty) throw StateError('Unknown extension: $moduleId');
      await _ensureNoActiveDependents(transaction, moduleId);
      await transaction.update(
        _extensionsTable,
        {
          'state': ExtensionState.disabled.databaseValue,
          'updated_at_utc': _now(),
        },
        where: 'module_id = ?',
        whereArgs: [moduleId],
      );
    });
  }

  Future<void> remove(String moduleId) async {
    _ensureOpen();
    await _database.transaction((transaction) async {
      await _ensureNoDependents(transaction, moduleId);
      final count = await _countRecords(transaction, moduleId);
      if (count != 0) {
        throw const ExtensionStoreException(
          'DATA_PRESERVED',
          'This extension has local records. Disable it to preserve its data; export and review the records before removal.',
        );
      }
      final deleted = await transaction.delete(
        _extensionsTable,
        where: 'module_id = ?',
        whereArgs: [moduleId],
      );
      if (deleted == 0) throw StateError('Unknown extension: $moduleId');
    });
  }

  Future<LocalExtensionRecord> createRecord({
    required String moduleId,
    required String docTypeName,
    required RecordScope scope,
    required Map<String, dynamic> values,
    required String recordId,
  }) async {
    _ensureOpen();
    scope.validate();
    return _database.transaction((transaction) async {
      final metadata = await _loadActiveDocType(
        transaction,
        moduleId,
        docTypeName,
      );
      final definition = DocTypeDefinition.fromJson(metadata);
      _requireOperation(definition, 'create');
      _validatePayload(definition, values);
      await _validateReferences(transaction, definition, values, scope);
      final now = _now();
      await transaction.insert(_recordsTable, {
        'record_id': recordId,
        'module_id': moduleId,
        'doctype_name': docTypeName,
        'organization_id': scope.organizationId,
        'company_id': scope.companyId,
        'branch_id': scope.branchId,
        'data_json': canonicalJson(values),
        'schema_version': definition.schemaVersion,
        'revision': 1,
        'sync_state': 'LOCAL_ONLY',
        'created_at_utc': now,
        'updated_at_utc': now,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
      return LocalExtensionRecord(
        recordId: recordId,
        moduleId: moduleId,
        docTypeName: docTypeName,
        scope: scope,
        schemaVersion: definition.schemaVersion,
        revision: 1,
        values: Map.unmodifiable(
          jsonDecode(canonicalJson(values)) as Map<String, dynamic>,
        ),
        updatedAtUtc: DateTime.parse(now),
      );
    });
  }

  Future<LocalExtensionRecord> updateRecord({
    required String moduleId,
    required String docTypeName,
    required String recordId,
    required RecordScope scope,
    required int expectedRevision,
    required Map<String, dynamic> values,
  }) async {
    _ensureOpen();
    scope.validate();
    if (expectedRevision < 1) throw ArgumentError.value(expectedRevision);
    return _database.transaction((transaction) async {
      final definition = DocTypeDefinition.fromJson(
        await _loadActiveDocType(transaction, moduleId, docTypeName),
      );
      _requireOperation(definition, 'update');
      final rows = await transaction.query(
        _recordsTable,
        where: '''record_id = ? AND module_id = ? AND doctype_name = ?
          AND organization_id = ? AND company_id = ?
          AND branch_id = ?''',
        whereArgs: [
          recordId,
          moduleId,
          docTypeName,
          scope.organizationId,
          scope.companyId,
          scope.branchId,
        ],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Record is not available in this scope.');
      }
      final current = LocalExtensionRecord.fromRow(rows.single);
      if (current.revision != expectedRevision) {
        throw ExtensionStoreException(
          'REVISION_CONFLICT',
          'The record is at revision ${current.revision}; reload before saving.',
        );
      }
      _validatePayload(definition, values);
      await _validateReferences(transaction, definition, values, scope);
      final nextRevision = current.revision + 1;
      final now = _now();
      final changed = await transaction.update(
        _recordsTable,
        {
          'data_json': canonicalJson(values),
          'schema_version': definition.schemaVersion,
          'revision': nextRevision,
          'updated_at_utc': now,
        },
        where: '''record_id = ? AND organization_id = ? AND company_id = ?
          AND branch_id = ? AND revision = ?''',
        whereArgs: [
          recordId,
          scope.organizationId,
          scope.companyId,
          scope.branchId,
          expectedRevision,
        ],
      );
      if (changed != 1) {
        throw const ExtensionStoreException(
          'REVISION_CONFLICT',
          'The record changed while it was being saved.',
        );
      }
      return LocalExtensionRecord(
        recordId: recordId,
        moduleId: current.moduleId,
        docTypeName: current.docTypeName,
        scope: scope,
        schemaVersion: definition.schemaVersion,
        revision: nextRevision,
        values: Map.unmodifiable(
          jsonDecode(canonicalJson(values)) as Map<String, dynamic>,
        ),
        updatedAtUtc: DateTime.parse(now),
      );
    });
  }

  Future<LocalExtensionRecord?> getRecord({
    required String moduleId,
    required String docTypeName,
    required String recordId,
    required RecordScope scope,
  }) async {
    _ensureOpen();
    scope.validate();
    final definition = DocTypeDefinition.fromJson(
      await _loadActiveDocType(_database, moduleId, docTypeName),
    );
    _requireOperation(definition, 'read');
    final rows = await _database.query(
      _recordsTable,
      where: '''record_id = ? AND module_id = ? AND doctype_name = ?
        AND organization_id = ? AND company_id = ?
        AND branch_id = ?''',
      whereArgs: [
        recordId,
        moduleId,
        docTypeName,
        scope.organizationId,
        scope.companyId,
        scope.branchId,
      ],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return LocalExtensionRecord.fromRow(rows.single);
  }

  Future<List<LocalExtensionRecord>> listRecords({
    required String moduleId,
    required String docTypeName,
    required RecordScope scope,
    String search = '',
    int limit = 200,
  }) async {
    _ensureOpen();
    scope.validate();
    if (limit < 1 || limit > 1000) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 1000');
    }
    final definition = DocTypeDefinition.fromJson(
      await _loadActiveDocType(_database, moduleId, docTypeName),
    );
    _requireOperation(definition, 'read');
    final rows = await _database.query(
      _recordsTable,
      where: '''module_id = ? AND doctype_name = ? AND organization_id = ?
        AND company_id = ? AND branch_id = ?''',
      whereArgs: [
        moduleId,
        docTypeName,
        scope.organizationId,
        scope.companyId,
        scope.branchId,
      ],
      orderBy: 'updated_at_utc DESC, record_id ASC',
      limit: 1000,
    );
    final query = search.trim().toLowerCase();
    final records = rows
        .map(LocalExtensionRecord.fromRow)
        .where((record) {
          if (query.isEmpty) return true;
          return record.values.values.any(
            (value) =>
                value != null && value.toString().toLowerCase().contains(query),
          );
        })
        .take(limit)
        .toList(growable: false);
    return List.unmodifiable(records);
  }

  Future<int> countRecords(String moduleId) async {
    _ensureOpen();
    return _countRecords(_database, moduleId);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _database.close();
  }

  Future<Map<String, dynamic>> _loadActiveDocType(
    DatabaseExecutor transaction,
    String moduleId,
    String docTypeName,
  ) async {
    final modules = await transaction.query(
      _extensionsTable,
      columns: const ['state'],
      where: 'module_id = ?',
      whereArgs: [moduleId],
      limit: 1,
    );
    if (modules.isEmpty) throw StateError('Unknown extension: $moduleId');
    if (modules.single['state'] != ExtensionState.active.databaseValue) {
      throw StateError('Only active local extensions can change records.');
    }
    final rows = await transaction.query(
      _docTypesTable,
      columns: const ['metadata_json'],
      where: 'module_id = ? AND doctype_name = ?',
      whereArgs: [moduleId, docTypeName],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Unknown DocType: $docTypeName');
    return _decodeMap(rows.single['metadata_json']);
  }

  void _requireOperation(DocTypeDefinition definition, String operation) {
    if (!definition.operations.contains(operation)) {
      throw ExtensionStoreException(
        'OPERATION_NOT_DECLARED',
        'The ${definition.name} DocType does not declare the $operation operation.',
      );
    }
  }

  Future<void> _validateReferences(
    Transaction transaction,
    DocTypeDefinition definition,
    Map<String, dynamic> values,
    RecordScope scope,
  ) async {
    for (final field in definition.fields.where(
      (item) => item.type == 'reference',
    )) {
      final value = values[field.name];
      if (value == null) continue;
      final targets = await transaction.query(
        _recordsTable,
        columns: const ['record_id'],
        where: '''record_id = ? AND module_id = ? AND doctype_name = ?
          AND organization_id = ? AND company_id = ? AND branch_id = ?''',
        whereArgs: [
          value,
          definition.moduleId,
          field.referenceTo,
          scope.organizationId,
          scope.companyId,
          scope.branchId,
        ],
        limit: 1,
      );
      if (targets.isEmpty) {
        throw ExtensionStoreException(
          'INVALID_REFERENCE',
          '${field.name} must reference a record of ${field.referenceTo} in the same organization, company and branch.',
        );
      }
    }
  }

  void _validateDefinition(DocTypeDefinition definition) {
    if (!_docTypeName.hasMatch(definition.name) ||
        definition.name.length > 80) {
      throw const ExtensionStoreException(
        'INVALID_DOCTYPE_NAME',
        'Use a DocType name beginning with a letter and containing letters, numbers or underscores.',
      );
    }
    if (definition.fields.length > 100) {
      throw const ExtensionStoreException(
        'TOO_MANY_FIELDS',
        'A DocType may contain at most 100 fields.',
      );
    }
    final permissionPrefix = _permissionPrefix(definition.moduleId);
    if (definition.permissions.values.any(
      (permission) => !permission.startsWith('$permissionPrefix.'),
    )) {
      throw const ExtensionStoreException(
        'PERMISSION_NAMESPACE',
        'An extension can declare only permission names in its own namespace. A Host administrator grants permissions separately.',
      );
    }
    for (final field in definition.fields) {
      if (!_fieldName.hasMatch(field.name) || field.name.length > 80) {
        throw ExtensionStoreException(
          'INVALID_FIELD_NAME',
          'Invalid field name: ${field.name}',
        );
      }
      if (field.type == 'reference' &&
          !_docTypeName.hasMatch(field.referenceTo ?? '')) {
        throw ExtensionStoreException(
          'INVALID_RELATION',
          'Invalid referenced DocType for ${field.name}.',
        );
      }
    }
  }

  void _validatePayload(
    DocTypeDefinition definition,
    Map<String, dynamic> values,
  ) {
    final issues = definition.validatePayload(values);
    if (issues.isNotEmpty) {
      throw ExtensionStoreException('INVALID_RECORD', issues.join(', '));
    }
  }

  void _validateNonDestructiveUpgrade(
    DocTypeDefinition previous,
    DocTypeDefinition next,
  ) {
    final oldFields = {for (final field in previous.fields) field.name: field};
    final newFields = {for (final field in next.fields) field.name: field};
    for (final old in previous.fields) {
      final updated = newFields[old.name];
      if (updated == null) {
        throw ExtensionStoreException(
          'DESTRUCTIVE_SCHEMA_CHANGE',
          'Removing ${old.name} would make saved local data unavailable.',
        );
      }
      if (updated.type != old.type || updated.referenceTo != old.referenceTo) {
        throw ExtensionStoreException(
          'DESTRUCTIVE_SCHEMA_CHANGE',
          'Changing the type or relation of ${old.name} requires a reviewed migration.',
        );
      }
      if (!updated.enumValues.toSet().containsAll(old.enumValues)) {
        throw ExtensionStoreException(
          'DESTRUCTIVE_SCHEMA_CHANGE',
          'Removing a saved enum value from ${old.name} requires a reviewed migration.',
        );
      }
      if (!old.required && updated.required) {
        throw ExtensionStoreException(
          'DESTRUCTIVE_SCHEMA_CHANGE',
          'Making ${old.name} required needs a default or reviewed data migration.',
        );
      }
    }
    for (final added in next.fields.where(
      (field) => !oldFields.containsKey(field.name),
    )) {
      if (added.required) {
        throw const ExtensionStoreException(
          'DESTRUCTIVE_SCHEMA_CHANGE',
          'New fields must be optional until a reviewed migration can populate existing records.',
        );
      }
    }
  }

  Future<void> _validateDependencyTargets(
    DatabaseExecutor executor,
    Map<String, String> dependencies,
  ) async {
    for (final entry in dependencies.entries) {
      final rows = await executor.query(
        _extensionsTable,
        columns: const ['version'],
        where: 'module_id = ?',
        whereArgs: [entry.key],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw ExtensionStoreException(
          'MISSING_DEPENDENCY',
          'Install local dependency ${entry.key} before declaring it.',
        );
      }
      final currentVersion = rows.single['version']! as String;
      if (!_versionSatisfies(currentVersion, entry.value)) {
        throw ExtensionStoreException(
          'INCOMPATIBLE_DEPENDENCY',
          '${entry.key} $currentVersion does not satisfy the compatible range starting at ${entry.value}.',
        );
      }
    }
  }

  Future<void> _validateDependencyGraph(
    DatabaseExecutor executor, {
    required String moduleId,
    required Map<String, String> dependencies,
  }) async {
    final rows = await executor.query(
      _extensionsTable,
      columns: const ['module_id', 'dependencies_json'],
    );
    final graph = <String, Set<String>>{
      for (final row in rows)
        row['module_id']! as String: _decodeDependencies(
          row['dependencies_json']! as String,
        ).keys.toSet(),
    };
    graph[moduleId] = dependencies.keys.toSet();
    final visiting = <String>{};
    final visited = <String>{};
    bool visit(String current) {
      if (visiting.contains(current)) return false;
      if (!visited.add(current)) return true;
      visiting.add(current);
      for (final dependency in graph[current] ?? const <String>{}) {
        if (graph.containsKey(dependency) && !visit(dependency)) return false;
      }
      visiting.remove(current);
      return true;
    }

    for (final id in graph.keys) {
      if (!visit(id)) {
        throw const ExtensionStoreException(
          'DEPENDENCY_CYCLE',
          'Extension dependencies cannot contain a cycle.',
        );
      }
    }
  }

  Future<void> _validateDependenciesActive(
    DatabaseExecutor executor,
    Map<String, String> dependencies,
  ) async {
    for (final entry in dependencies.entries) {
      final rows = await executor.query(
        _extensionsTable,
        columns: const ['version', 'state'],
        where: 'module_id = ?',
        whereArgs: [entry.key],
        limit: 1,
      );
      if (rows.isEmpty ||
          rows.single['state'] != ExtensionState.active.databaseValue) {
        throw ExtensionStoreException(
          'DEPENDENCY_NOT_ACTIVE',
          '${entry.key} must be active on this device first.',
        );
      }
      if (!_versionSatisfies(rows.single['version']! as String, entry.value)) {
        throw ExtensionStoreException(
          'INCOMPATIBLE_DEPENDENCY',
          '${entry.key} no longer satisfies the required compatible version ${entry.value}.',
        );
      }
    }
  }

  Future<void> _validateDependentsForVersion(
    DatabaseExecutor executor,
    String moduleId,
    String version,
  ) async {
    final rows = await executor.query(
      _extensionsTable,
      columns: const ['module_id', 'dependencies_json'],
    );
    for (final row in rows) {
      final dependencies = _decodeDependencies(
        row['dependencies_json']! as String,
      );
      final requiredVersion = dependencies[moduleId];
      if (requiredVersion != null &&
          !_versionSatisfies(version, requiredVersion)) {
        throw ExtensionStoreException(
          'BREAKING_DEPENDENCY_UPDATE',
          '${row['module_id']} requires $moduleId compatible with $requiredVersion.',
        );
      }
    }
  }

  Future<void> _ensureNoActiveDependents(
    DatabaseExecutor executor,
    String moduleId,
  ) async {
    final rows = await executor.query(
      _extensionsTable,
      columns: const ['module_id', 'state', 'dependencies_json'],
    );
    for (final row in rows) {
      if (row['state'] == ExtensionState.active.databaseValue &&
          _decodeDependencies(
            row['dependencies_json']! as String,
          ).containsKey(moduleId)) {
        throw ExtensionStoreException(
          'ACTIVE_DEPENDENTS',
          'Disable ${row['module_id']} before disabling $moduleId.',
        );
      }
    }
  }

  Future<void> _ensureNoDependents(
    DatabaseExecutor executor,
    String moduleId,
  ) async {
    final rows = await executor.query(
      _extensionsTable,
      columns: const ['module_id', 'dependencies_json'],
    );
    for (final row in rows) {
      if (_decodeDependencies(
        row['dependencies_json']! as String,
      ).containsKey(moduleId)) {
        throw ExtensionStoreException(
          'EXTENSION_IS_DEPENDENCY',
          'Remove ${row['module_id']} dependency on $moduleId before removing it.',
        );
      }
    }
  }

  String _now() => _clock().toUtc().toIso8601String();

  void _ensureOpen() {
    if (_closed) throw StateError('Extension store is closed.');
  }
}

final RegExp _moduleId = RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$');
final RegExp _docTypeName = RegExp(r'^[A-Z][A-Za-z0-9_]*$');
final RegExp _fieldName = RegExp(r'^[a-z][A-Za-z0-9_]*$');

Map<String, String> _normalizeDependencies(
  String moduleId,
  Map<String, String> dependencies,
) {
  if (dependencies.length > 32) {
    throw const ExtensionStoreException(
      'TOO_MANY_DEPENDENCIES',
      'An extension may declare at most 32 dependencies.',
    );
  }
  final normalized = <String, String>{};
  for (final entry in dependencies.entries) {
    if (!_moduleId.hasMatch(entry.key) || entry.key.length > 128) {
      throw ExtensionStoreException(
        'INVALID_DEPENDENCY_ID',
        'Invalid dependency module ID: ${entry.key}',
      );
    }
    if (entry.key == moduleId) {
      throw const ExtensionStoreException(
        'INVALID_DEPENDENCY',
        'An extension cannot depend on itself.',
      );
    }
    semverParts(entry.value);
    normalized[entry.key] = entry.value;
  }
  return Map.unmodifiable(normalized);
}

Map<String, String> _decodeDependencies(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map ||
      decoded.keys.any((key) => key is! String) ||
      decoded.values.any((value) => value is! String)) {
    throw const FormatException('Stored extension dependencies are invalid.');
  }
  return decoded.cast<String, String>();
}

bool _versionSatisfies(String version, String minimumCompatibleVersion) {
  final current = semverParts(version);
  final minimum = semverParts(minimumCompatibleVersion);
  if (compareSemver(version, minimumCompatibleVersion) < 0) return false;
  if (minimum[0] == 0) {
    return current[0] == 0 && current[1] == minimum[1];
  }
  return current[0] == minimum[0];
}

bool _sameDependencies(Map<String, String> left, Map<String, String> right) =>
    left.length == right.length &&
    left.entries.every((entry) => right[entry.key] == entry.value);

String permissionKey(String moduleId, String docTypeName, String operation) =>
    '${_permissionPrefix(moduleId)}.${docTypeName.toLowerCase()}.$operation';

String _permissionPrefix(String moduleId) =>
    'extension.${moduleId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';

String _nextPatch(String version) {
  final parts = semverParts(version);
  return '${parts[0]}.${parts[1]}.${parts[2] + 1}';
}

Map<String, dynamic> _decodeMap(Object? value) {
  if (value is! String) {
    throw const FormatException('Stored metadata is invalid.');
  }
  final decoded = jsonDecode(value);
  if (decoded is! Map) {
    throw const FormatException('Stored metadata is invalid.');
  }
  return Map<String, dynamic>.from(decoded);
}

Future<int> _countRecords(DatabaseExecutor executor, String moduleId) async {
  final rows = await executor.rawQuery(
    'SELECT COUNT(*) AS count FROM $_recordsTable WHERE module_id = ?',
    [moduleId],
  );
  return rows.single['count']! as int;
}
