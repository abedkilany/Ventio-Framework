import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:ventio_core/ventio_core.dart';

const _extensionsTable = 'local_extensions';
const _docTypesTable = 'local_extension_doctypes';
const _recordsTable = 'local_extension_records';
const _hostProfileTable = 'local_host_profile';

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

/// A device-local routing choice. Host permissions remain authoritative and
/// are revalidated for every request; these identifiers are never trusted by
/// the Host without matching the credential's current exact-scope grants.
class HostConnectionProfile {
  const HostConnectionProfile({
    required this.endpoint,
    required this.tenantId,
    required this.companyId,
    required this.branchId,
    this.actorId,
    this.deviceId,
  });

  final String endpoint;
  final String tenantId;
  final String companyId;
  final String branchId;
  final String? actorId;
  final String? deviceId;

  factory HostConnectionProfile.fromRow(Map<String, Object?> row) =>
      HostConnectionProfile(
        endpoint: row['endpoint']! as String,
        tenantId: row['tenant_id']! as String,
        companyId: row['company_id']! as String,
        branchId: row['branch_id']! as String,
        actorId: row['actor_id'] as String?,
        deviceId: row['device_id'] as String?,
      );
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
    this.hostRevision,
    this.pendingCommandId,
    this.authorityState = 'LOCAL_ONLY',
  });

  final String recordId;
  final String moduleId;
  final String docTypeName;
  final RecordScope scope;
  final int schemaVersion;
  final int revision;
  final Map<String, dynamic> values;
  final DateTime updatedAtUtc;
  final int? hostRevision;
  final String? pendingCommandId;
  final String authorityState;

  String get syncState => authorityState;

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
      hostRevision: row['host_revision'] as int?,
      pendingCommandId: row['pending_command_id'] as String?,
      authorityState: row['authority_state'] as String? ?? 'LOCAL_ONLY',
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
  LocalExtensionStore._(this._database, this._clock, this.platformApiVersion);

  final Database _database;
  final DateTime Function() _clock;
  final String platformApiVersion;
  bool _closed = false;

  static Future<LocalExtensionStore> open({
    required DatabaseFactory factory,
    required String path,
    DateTime Function()? clock,
    String platformApiVersion = '0.1.0',
  }) async {
    semverParts(platformApiVersion);
    final database = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
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
              host_revision INTEGER CHECK (host_revision IS NULL OR host_revision > 0),
              pending_command_id TEXT,
              authority_state TEXT NOT NULL DEFAULT 'LOCAL_ONLY'
                CHECK (authority_state IN ('LOCAL_ONLY', 'PENDING', 'HOST_ACCEPTED', 'CONFLICT', 'REJECTED')),
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
          await database.execute('''
            CREATE TABLE $_hostProfileTable (
              singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
              endpoint TEXT NOT NULL,
              tenant_id TEXT NOT NULL,
              company_id TEXT NOT NULL,
              branch_id TEXT NOT NULL,
              actor_id TEXT,
              device_id TEXT,
              updated_at_utc TEXT NOT NULL
            )
          ''');
        },
        onUpgrade: (database, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await database.execute('''
              ALTER TABLE $_extensionsTable
              ADD COLUMN dependencies_json TEXT NOT NULL DEFAULT '{}'
            ''');
          }
          if (oldVersion < 3) {
            await database.execute('''
              CREATE TABLE $_hostProfileTable (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                endpoint TEXT NOT NULL,
                tenant_id TEXT NOT NULL,
                company_id TEXT NOT NULL,
                branch_id TEXT NOT NULL,
                actor_id TEXT,
                device_id TEXT,
                updated_at_utc TEXT NOT NULL
              )
            ''');
          }
          if (oldVersion < 4) {
            final recordTable = await database.rawQuery(
              "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
              [_recordsTable],
            );
            if (recordTable.isNotEmpty) {
              await database.execute('''
                ALTER TABLE $_recordsTable ADD COLUMN host_revision INTEGER
                  CHECK (host_revision IS NULL OR host_revision > 0)
              ''');
              await database.execute('''
                ALTER TABLE $_recordsTable ADD COLUMN pending_command_id TEXT
              ''');
              await database.execute('''
                ALTER TABLE $_recordsTable ADD COLUMN authority_state TEXT NOT NULL
                  DEFAULT 'LOCAL_ONLY'
                  CHECK (authority_state IN ('LOCAL_ONLY', 'PENDING', 'HOST_ACCEPTED', 'CONFLICT', 'REJECTED'))
              ''');
            }
            if (oldVersion >= 3) {
              final profileTable = await database.rawQuery(
                "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                [_hostProfileTable],
              );
              if (profileTable.isNotEmpty) {
                await database.execute('''
                  ALTER TABLE $_hostProfileTable ADD COLUMN actor_id TEXT
                ''');
                await database.execute('''
                  ALTER TABLE $_hostProfileTable ADD COLUMN device_id TEXT
                ''');
              }
            }
          }
        },
      ),
    );
    return LocalExtensionStore._(
      database,
      clock ?? DateTime.now,
      platformApiVersion,
    );
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

  Future<HostConnectionProfile?> getHostProfile() async {
    _ensureOpen();
    final rows = await _database.query(_hostProfileTable, limit: 1);
    return rows.isEmpty ? null : HostConnectionProfile.fromRow(rows.single);
  }

  Future<void> saveHostProfile(HostConnectionProfile profile) async {
    _ensureOpen();
    if (profile.endpoint.trim().isEmpty || profile.endpoint.length > 2048) {
      throw ArgumentError('A valid Host endpoint is required.');
    }
    for (final value in [
      profile.tenantId,
      profile.companyId,
      profile.branchId,
    ]) {
      if (value.trim().isEmpty || value.length > 256) {
        throw ArgumentError('The selected Host scope is invalid.');
      }
    }
    await _database.insert(_hostProfileTable, {
      'singleton': 1,
      'endpoint': profile.endpoint,
      'tenant_id': profile.tenantId,
      'company_id': profile.companyId,
      'branch_id': profile.branchId,
      'actor_id': profile.actorId,
      'device_id': profile.deviceId,
      'updated_at_utc': _now(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearHostProfile() async {
    _ensureOpen();
    await _database.delete(_hostProfileTable);
  }

  /// Produces a bounded declarative package from the persisted local draft.
  /// The result is metadata only; exporting it does not grant Host approval.
  Future<ExtensionBundle> exportBundle(String moduleId) async {
    _ensureOpen();
    final extension = await getExtension(moduleId);
    if (extension == null) {
      throw const ExtensionStoreException(
        'UNKNOWN_MODULE',
        'Create the extension before exporting it.',
      );
    }
    final docTypes = await listDocTypes(moduleId);
    if (docTypes.isEmpty) {
      throw const ExtensionStoreException(
        'EMPTY_EXTENSION',
        'Add at least one DocType before exporting the extension.',
      );
    }

    final namespace =
        'extension.${moduleId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';
    final catalog = <String, String>{};
    void addLabel(Object? rawKey, Object? rawLabel) {
      if (rawKey is! String || rawLabel is! String) {
        throw const ExtensionStoreException(
          'INVALID_BUNDLE_METADATA',
          'Every exported message needs a nonempty key and English label.',
        );
      }
      final existing = catalog[rawKey];
      if (existing != null && existing != rawLabel) {
        throw const ExtensionStoreException(
          'DUPLICATE_MESSAGE_KEY',
          'Different labels use the same localization key.',
        );
      }
      catalog[rawKey] = rawLabel;
    }

    final displayNameKey = '$namespace.module.name';
    final descriptionKey = '$namespace.module.description';
    addLabel(displayNameKey, extension.displayName);
    addLabel(descriptionKey, extension.description);
    for (final docType in docTypes) {
      addLabel(docType['labelKey'], docType['label']);
      if (docType.containsKey('descriptionKey')) {
        addLabel(docType['descriptionKey'], docType['description']);
      }
      final fields = docType['fields'];
      if (fields is! List) {
        throw const ExtensionStoreException(
          'INVALID_BUNDLE_METADATA',
          'A DocType has an invalid fields definition.',
        );
      }
      for (final rawField in fields) {
        if (rawField is! Map<String, dynamic>) {
          throw const ExtensionStoreException(
            'INVALID_BUNDLE_METADATA',
            'A field has an invalid metadata definition.',
          );
        }
        addLabel(rawField['labelKey'], rawField['label']);
        if (rawField.containsKey('descriptionKey')) {
          addLabel(rawField['descriptionKey'], rawField['description']);
        }
        final enumLabels = rawField['enumLabels'];
        if (enumLabels is Map) {
          for (final rawLabel in enumLabels.values) {
            if (rawLabel is! Map) {
              throw const ExtensionStoreException(
                'INVALID_BUNDLE_METADATA',
                'An enum option has an invalid label definition.',
              );
            }
            addLabel(rawLabel['labelKey'], rawLabel['label']);
          }
        }
      }
    }

    return ExtensionBundle.fromJson({
      'manifest': {
        'manifestVersion': 0,
        'moduleId': moduleId,
        'version': extension.version,
        'minPlatformApi': '0.1.0',
        'displayName': extension.displayName,
        'displayNameKey': displayNameKey,
        'description': extension.description,
        'descriptionKey': descriptionKey,
        'englishCatalog':
            'localization/en.${namespace.substring('extension.'.length)}.json',
        'dependencies': extension.dependencies.keys.toList()..sort(),
        'docTypes': docTypes.map((type) => type['name'] as String).toList(),
        'commands': <Object>[],
        'requiredCapabilities': <String>[],
        'offline': {'enabled': false, 'allowedCommands': <String>[]},
      },
      'docTypes': docTypes,
      'dependencyVersions': extension.dependencies,
      'englishCatalog': catalog,
    });
  }

  /// Installs or upgrades a metadata-only package atomically.
  /// Executable content is rejected by ExtensionBundle before this method can
  /// be called. A new package remains a local draft until explicitly activated.
  Future<void> installBundle(ExtensionBundle bundle) async {
    _ensureOpen();
    if (compareSemver(platformApiVersion, bundle.manifest.minPlatformApi) < 0) {
      throw const ExtensionStoreException(
        'INCOMPATIBLE_PLATFORM',
        'This Ventio version does not satisfy the package platform requirement.',
      );
    }
    final moduleId = bundle.moduleId;
    final displayName = bundle.manifest.displayName;
    final description = bundle.manifestJson['description'] as String? ?? '';
    final dependencies = bundle.dependencyVersions;
    final incomingByName = <String, Map<String, dynamic>>{
      for (final json in bundle.docTypeJson) json['name'] as String: json,
    };
    final now = _now();

    await _database.transaction((transaction) async {
      final modules = await transaction.query(
        _extensionsTable,
        where: 'module_id = ?',
        whereArgs: [moduleId],
        limit: 1,
      );
      await _validateDependencyGraph(
        transaction,
        moduleId: moduleId,
        dependencies: dependencies,
      );
      await _validateDependencyTargets(transaction, dependencies);

      final existingByName = <String, Map<String, dynamic>>{};
      if (modules.isNotEmpty) {
        final current = LocalExtension.fromRow(modules.single);
        final currentRows = await transaction.query(
          _docTypesTable,
          columns: const ['doctype_name', 'metadata_json'],
          where: 'module_id = ?',
          whereArgs: [moduleId],
        );
        for (final row in currentRows) {
          existingByName[row['doctype_name']! as String] = _decodeMap(
            row['metadata_json'],
          );
        }
        if (incomingByName.keys.toSet().containsAll(existingByName.keys) ==
            false) {
          throw const ExtensionStoreException(
            'DESTRUCTIVE_PACKAGE_UPDATE',
            'A package cannot remove an installed DocType or its saved data.',
          );
        }
        final versionOrder = compareSemver(bundle.version, current.version);
        if (versionOrder < 0) {
          throw const ExtensionStoreException(
            'VERSION_DOWNGRADE',
            'Installed extension versions cannot move backwards.',
          );
        }
        for (final entry in existingByName.entries) {
          final next = incomingByName[entry.key]!;
          final previousDefinition = DocTypeDefinition.fromJson(entry.value);
          final nextDefinition = DocTypeDefinition.fromJson(next);
          _validateDefinition(nextDefinition);
          if (nextDefinition.schemaVersion < previousDefinition.schemaVersion) {
            throw const ExtensionStoreException(
              'SCHEMA_VERSION_DOWNGRADE',
              'DocType schema versions cannot move backwards.',
            );
          }
          if (nextDefinition.schemaVersion ==
                  previousDefinition.schemaVersion &&
              canonicalJson(next) != canonicalJson(entry.value)) {
            throw const ExtensionStoreException(
              'SCHEMA_VERSION_REQUIRED',
              'Changed DocType metadata requires a higher schema version.',
            );
          }
          if (nextDefinition.schemaVersion > previousDefinition.schemaVersion) {
            _validateNonDestructiveUpgrade(previousDefinition, nextDefinition);
          }
        }

        if (versionOrder == 0) {
          final unchanged =
              current.displayName == displayName &&
              current.description == description &&
              _sameDependencies(current.dependencies, dependencies) &&
              incomingByName.length == existingByName.length &&
              incomingByName.entries.every(
                (entry) =>
                    existingByName.containsKey(entry.key) &&
                    canonicalJson(entry.value) ==
                        canonicalJson(existingByName[entry.key]),
              );
          if (unchanged) return;
          throw const ExtensionStoreException(
            'VERSION_CONFLICT',
            'Package contents changed without increasing the extension version.',
          );
        }
        if (current.state == ExtensionState.active) {
          throw const ExtensionStoreException(
            'DISABLE_BEFORE_UPDATE',
            'Disable the local extension before installing an update.',
          );
        }
        await _validateDependentsForVersion(
          transaction,
          moduleId,
          bundle.version,
        );
        await transaction.update(
          _extensionsTable,
          {
            'display_name': displayName,
            'description': description,
            'version': bundle.version,
            'dependencies_json': canonicalJson(dependencies),
            'updated_at_utc': now,
          },
          where: 'module_id = ?',
          whereArgs: [moduleId],
        );
      } else {
        await transaction.insert(_extensionsTable, {
          'module_id': moduleId,
          'display_name': displayName,
          'description': description,
          'version': bundle.version,
          'dependencies_json': canonicalJson(dependencies),
          'state': ExtensionState.draft.databaseValue,
          'created_at_utc': now,
          'updated_at_utc': now,
        });
      }

      final knownNames = <String>{
        ...existingByName.keys,
        ...incomingByName.keys,
      };
      for (final entry in incomingByName.entries) {
        final definition = DocTypeDefinition.fromJson(entry.value);
        _validateDefinition(definition);
        if (definition.fields.any(
          (field) =>
              field.type == 'reference' &&
              !knownNames.contains(field.referenceTo),
        )) {
          throw ExtensionStoreException(
            'UNKNOWN_RELATION_TARGET',
            '${definition.name} refers to a DocType outside the installed package.',
          );
        }
        final previous = existingByName[entry.key];
        if (previous == null) {
          await transaction.insert(_docTypesTable, {
            'module_id': moduleId,
            'doctype_name': entry.key,
            'schema_version': definition.schemaVersion,
            'metadata_json': canonicalJson(entry.value),
          });
        } else if (canonicalJson(previous) != canonicalJson(entry.value)) {
          await transaction.update(
            _docTypesTable,
            {
              'schema_version': definition.schemaVersion,
              'metadata_json': canonicalJson(entry.value),
            },
            where: 'module_id = ? AND doctype_name = ?',
            whereArgs: [moduleId, entry.key],
          );
          await transaction.update(
            _recordsTable,
            {'schema_version': definition.schemaVersion, 'updated_at_utc': now},
            where: 'module_id = ? AND doctype_name = ?',
            whereArgs: [moduleId, entry.key],
          );
        }
      }
    });
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
      if (current.pendingCommandId != null) {
        throw const ExtensionStoreException(
          'RECORD_COMMAND_PENDING',
          'Wait for the current Host command to resolve before editing this record again.',
        );
      }
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
          'pending_command_id': null,
          'authority_state': 'LOCAL_ONLY',
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
        hostRevision: current.hostRevision,
        authorityState: 'LOCAL_ONLY',
      );
    });
  }

  Future<void> markRecordPending({
    required String recordId,
    required RecordScope scope,
    required String commandId,
  }) async {
    _ensureOpen();
    scope.validate();
    if (commandId.isEmpty || commandId.length > 80) {
      throw ArgumentError.value(commandId, 'commandId');
    }
    final changed = await _database.update(
      _recordsTable,
      {'pending_command_id': commandId, 'authority_state': 'PENDING'},
      where: '''record_id = ? AND organization_id = ? AND company_id = ?
        AND branch_id = ? AND (pending_command_id IS NULL OR pending_command_id = ?)''',
      whereArgs: [
        recordId,
        scope.organizationId,
        scope.companyId,
        scope.branchId,
        commandId,
      ],
    );
    if (changed != 1) {
      throw const ExtensionStoreException(
        'RECORD_SYNC_STATE_CHANGED',
        'The local record changed before its pending Host command was recorded.',
      );
    }
  }

  Future<void> applyHostReceipt({
    required String recordId,
    required RecordScope scope,
    required String commandId,
    required CommandReceipt receipt,
  }) async {
    _ensureOpen();
    scope.validate();
    if (receipt.commandId != commandId) {
      throw const FormatException('Host receipt command ID mismatch.');
    }
    final rows = await _database.query(
      _recordsTable,
      where: '''record_id = ? AND organization_id = ? AND company_id = ?
        AND branch_id = ?''',
      whereArgs: [
        recordId,
        scope.organizationId,
        scope.companyId,
        scope.branchId,
      ],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final current = LocalExtensionRecord.fromRow(rows.single);
    if (receipt.status == 'ACCEPTED') {
      final hostRevision = receipt.hostRevision;
      if (hostRevision == null || hostRevision < 1) {
        throw const FormatException('Accepted Host receipt has no revision.');
      }
      if (current.hostRevision != null &&
          hostRevision < current.hostRevision!) {
        return;
      }
      final hasNewerPending =
          current.pendingCommandId != null &&
          current.pendingCommandId != commandId;
      await _database.update(
        _recordsTable,
        {
          'host_revision': hostRevision,
          if (!hasNewerPending) 'pending_command_id': null,
          'authority_state': hasNewerPending ? 'PENDING' : 'HOST_ACCEPTED',
        },
        where: '''record_id = ? AND organization_id = ? AND company_id = ?
          AND branch_id = ?''',
        whereArgs: [
          recordId,
          scope.organizationId,
          scope.companyId,
          scope.branchId,
        ],
      );
      return;
    }
    if (receipt.status != 'CONFLICT' && receipt.status != 'REJECTED') return;
    if (current.pendingCommandId != null &&
        current.pendingCommandId != commandId) {
      return;
    }
    final hostRevision = receipt.status == 'CONFLICT'
        ? receipt.currentRevision
        : null;
    await _database.update(
      _recordsTable,
      {
        'pending_command_id': null,
        'authority_state': receipt.status,
        if (hostRevision != null && hostRevision > 0)
          'host_revision': hostRevision,
      },
      where: '''record_id = ? AND organization_id = ? AND company_id = ?
        AND branch_id = ?''',
      whereArgs: [
        recordId,
        scope.organizationId,
        scope.companyId,
        scope.branchId,
      ],
    );
  }

  Future<void> applyHostRecord({
    required String moduleId,
    required String docTypeName,
    required RecordScope scope,
    required String recordId,
    required int revision,
    required Map<String, dynamic> values,
    required DateTime updatedAtUtc,
  }) async {
    _ensureOpen();
    scope.validate();
    if (recordId.trim().isEmpty || revision < 1) {
      throw const FormatException('Invalid Host record identity.');
    }
    await _database.transaction((transaction) async {
      final definition = DocTypeDefinition.fromJson(
        await _loadActiveDocType(transaction, moduleId, docTypeName),
      );
      _requireOperation(definition, 'read');
      _validatePayload(definition, values);
      final where = '''record_id = ? AND module_id = ? AND doctype_name = ?
        AND organization_id = ? AND company_id = ? AND branch_id = ?''';
      final whereArgs = [
        recordId,
        moduleId,
        docTypeName,
        scope.organizationId,
        scope.companyId,
        scope.branchId,
      ];
      final rows = await transaction.query(
        _recordsTable,
        where: where,
        whereArgs: whereArgs,
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final current = LocalExtensionRecord.fromRow(rows.single);
        if (current.pendingCommandId != null ||
            current.authorityState == 'CONFLICT' ||
            current.authorityState == 'REJECTED' ||
            (current.hostRevision != null &&
                current.hostRevision! > revision) ||
            (current.authorityState == 'LOCAL_ONLY' &&
                current.hostRevision != null &&
                current.revision > revision)) {
          return;
        }
        await transaction.update(
          _recordsTable,
          {
            'data_json': canonicalJson(values),
            'schema_version': definition.schemaVersion,
            'revision': revision,
            'host_revision': revision,
            'pending_command_id': null,
            'authority_state': 'HOST_ACCEPTED',
            'updated_at_utc': updatedAtUtc.toUtc().toIso8601String(),
          },
          where: where,
          whereArgs: whereArgs,
        );
        return;
      }
      final timestamp = updatedAtUtc.toUtc().toIso8601String();
      await transaction.insert(_recordsTable, {
        'record_id': recordId,
        'module_id': moduleId,
        'doctype_name': docTypeName,
        'organization_id': scope.organizationId,
        'company_id': scope.companyId,
        'branch_id': scope.branchId,
        'data_json': canonicalJson(values),
        'schema_version': definition.schemaVersion,
        'revision': revision,
        'sync_state': 'LOCAL_ONLY',
        'host_revision': revision,
        'pending_command_id': null,
        'authority_state': 'HOST_ACCEPTED',
        'created_at_utc': timestamp,
        'updated_at_utc': timestamp,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
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
    String? filterField,
    String filterContains = '',
    String? sortField,
    bool ascending = true,
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
    final fieldNames = definition.fields.map((field) => field.name).toSet();
    if ((filterField != null && !fieldNames.contains(filterField)) ||
        (sortField != null && !fieldNames.contains(sortField))) {
      throw ArgumentError(
        'Filter and sort fields must belong to this DocType.',
      );
    }

    final conditions = <String>[
      'module_id = ? AND doctype_name = ? AND organization_id = ? '
          'AND company_id = ? AND branch_id = ?',
    ];
    final parameters = <Object?>[
      moduleId,
      docTypeName,
      scope.organizationId,
      scope.companyId,
      scope.branchId,
    ];
    String jsonPath(String fieldName) => r'$."' + fieldName + r'"';
    String likePattern(String value) =>
        '%${value.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%';

    final query = search.trim().toLowerCase();
    if (query.isNotEmpty) {
      conditions.add(
        '(${definition.fields.map((_) => "lower(CAST(json_extract(data_json, ?) AS TEXT)) LIKE ? ESCAPE '\\'").join(' OR ')})',
      );
      for (final field in definition.fields) {
        parameters
          ..add(jsonPath(field.name))
          ..add(likePattern(query));
      }
    }
    final filterValue = filterContains.trim().toLowerCase();
    if (filterField != null && filterValue.isNotEmpty) {
      conditions.add(
        "lower(CAST(json_extract(data_json, ?) AS TEXT)) LIKE ? ESCAPE '\\'",
      );
      parameters
        ..add(jsonPath(filterField))
        ..add(likePattern(filterValue));
    }

    final orderExpression = sortField == null
        ? 'updated_at_utc'
        : 'json_extract(data_json, ?)';
    if (sortField != null) parameters.add(jsonPath(sortField));
    parameters.add(limit);
    final rows = await _database.rawQuery('''SELECT * FROM $_recordsTable
        WHERE ${conditions.join(' AND ')}
        ORDER BY $orderExpression ${ascending ? 'ASC' : 'DESC'}, record_id ASC
        LIMIT ?''', parameters);
    final records = rows
        .map(LocalExtensionRecord.fromRow)
        .toList(growable: false);
    return List.unmodifiable(records);
  }

  Future<List<LocalExtensionRecord>> listUnqueuedRecords({
    required RecordScope scope,
    int limit = 1000,
  }) async {
    _ensureOpen();
    scope.validate();
    if (limit < 1 || limit > 1000) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 1000');
    }
    final rows = await _database.query(
      _recordsTable,
      where: '''organization_id = ? AND company_id = ? AND branch_id = ?
        AND authority_state = 'LOCAL_ONLY' AND pending_command_id IS NULL''',
      whereArgs: [scope.organizationId, scope.companyId, scope.branchId],
      orderBy: 'updated_at_utc ASC, record_id ASC',
      limit: limit,
    );
    return List.unmodifiable(rows.map(LocalExtensionRecord.fromRow));
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
