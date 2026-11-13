import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:ventio_core/ventio_core.dart';

import 'transport_fixture.dart';

const _table = 'local_commands';

enum HostCommandStatus {
  pending('PENDING'),
  accepted('ACCEPTED'),
  rejected('REJECTED'),
  conflict('CONFLICT'),
  retryLater('RETRY_LATER');

  const HostCommandStatus(this.databaseValue);

  final String databaseValue;

  static HostCommandStatus fromDatabase(Object? value) {
    return HostCommandStatus.values.firstWhere(
      (status) => status.databaseValue == value,
      orElse: () => throw FormatException('Unknown Host status: $value'),
    );
  }

  String get label => switch (this) {
    pending => 'Pending',
    accepted => 'Accepted by Host',
    rejected => 'Rejected by Host',
    conflict => 'Conflict reported by Host',
    retryLater => 'Retry later',
  };
}

class DuplicateCommandIdException implements Exception {
  const DuplicateCommandIdException(this.commandId);

  final String commandId;

  @override
  String toString() => 'Command ID already exists: $commandId';
}

class QueueEntry {
  const QueueEntry({
    required this.envelope,
    required this.hostStatus,
    required this.attemptCount,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.lastAttemptAtUtc,
    this.hostReceipt,
    this.fixtureReceipt,
    this.projectToLocalRecords = true,
  });

  final CommandEnvelope envelope;
  final HostCommandStatus hostStatus;
  final int attemptCount;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
  final DateTime? lastAttemptAtUtc;
  final CommandReceipt? hostReceipt;

  /// A fixture response is stored separately and is never Host confirmation.
  final CommandReceipt? fixtureReceipt;

  /// Effective-metadata forms retain receipts here without changing the
  /// immutable base-package record cache.
  final bool projectToLocalRecords;

  bool get isHostConfirmed =>
      hostStatus == HostCommandStatus.accepted && hostReceipt?.accepted == true;

  bool get isPending =>
      hostStatus == HostCommandStatus.pending ||
      hostStatus == HostCommandStatus.retryLater;

  factory QueueEntry.fromRow(Map<String, Object?> row) {
    final rawEnvelope = jsonDecode(row['envelope_json']! as String);
    final envelope = CommandEnvelope.fromJson(
      requireMap(rawEnvelope, 'envelope'),
    );
    final commandId = row['command_id']! as String;
    if (envelope.commandId != commandId) {
      throw const FormatException('Stored command ID does not match envelope');
    }

    CommandReceipt? parseReceipt(Object? raw, String fieldName) {
      if (raw == null) return null;
      final decoded = jsonDecode(raw as String);
      final receipt = CommandReceipt.fromJson(requireMap(decoded, fieldName));
      if (receipt.commandId != commandId) {
        throw FormatException('$fieldName command ID does not match envelope');
      }
      return receipt;
    }

    DateTime date(Object? value) => DateTime.parse(value! as String).toUtc();

    final hostReceipt = parseReceipt(row['host_receipt_json'], 'hostReceipt');
    final status = HostCommandStatus.fromDatabase(row['host_status']);
    if (status == HostCommandStatus.pending && hostReceipt != null) {
      throw const FormatException(
        'Pending state cannot contain a Host receipt',
      );
    }
    if (status != HostCommandStatus.pending &&
        hostReceipt?.status != status.databaseValue) {
      throw const FormatException(
        'Host state must match its authoritative receipt',
      );
    }

    return QueueEntry(
      envelope: envelope,
      hostStatus: status,
      attemptCount: row['attempt_count']! as int,
      createdAtUtc: date(row['created_at_utc']),
      updatedAtUtc: date(row['updated_at_utc']),
      lastAttemptAtUtc: row['last_attempt_at_utc'] == null
          ? null
          : date(row['last_attempt_at_utc']),
      hostReceipt: hostReceipt,
      projectToLocalRecords: (row['project_local_records'] ?? 1) == 1,
      fixtureReceipt: parseReceipt(
        row['fixture_receipt_json'],
        'fixtureReceipt',
      ),
    );
  }
}

class LocalCommandQueue {
  LocalCommandQueue._(this._database, this._clock);

  final Database _database;
  final DateTime Function() _clock;
  bool _closed = false;

  static Future<LocalCommandQueue> open({
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
            CREATE TABLE $_table (
              command_id TEXT PRIMARY KEY NOT NULL,
              type TEXT NOT NULL,
              envelope_json TEXT NOT NULL,
              host_status TEXT NOT NULL DEFAULT 'PENDING'
                CHECK (host_status IN ('PENDING', 'ACCEPTED', 'REJECTED', 'CONFLICT', 'RETRY_LATER')),
              host_receipt_json TEXT,
              fixture_receipt_json TEXT,
              attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
              created_at_utc TEXT NOT NULL,
              updated_at_utc TEXT NOT NULL,
              last_attempt_at_utc TEXT,
              project_local_records INTEGER NOT NULL DEFAULT 1 CHECK (project_local_records IN (0,1)),
              CHECK (
                (host_status = 'PENDING' AND host_receipt_json IS NULL) OR
                (host_status <> 'PENDING' AND host_receipt_json IS NOT NULL)
              )
            )
          ''');
          await database.execute('''
            CREATE INDEX local_commands_created_at
            ON $_table(created_at_utc DESC)
          ''');
        },
        onUpgrade: (database, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await database.execute(
              'ALTER TABLE $_table ADD COLUMN project_local_records INTEGER NOT NULL DEFAULT 1 CHECK (project_local_records IN (0,1))',
            );
          }
        },
      ),
    );
    return LocalCommandQueue._(database, clock ?? DateTime.now);
  }

  Future<void> enqueue(
    CommandEnvelope envelope, {
    bool projectToLocalRecords = true,
  }) async {
    _ensureOpen();
    // Validate and persist Core's immutable original envelope, not a second
    // client-specific command representation.
    final validated = CommandEnvelope.fromJson(envelope.original);
    if (validated.commandId != envelope.commandId) {
      throw const FormatException(
        'Command ID does not match original envelope',
      );
    }
    final now = _clock().toUtc().toIso8601String();
    await _database.transaction((transaction) async {
      final existing = await transaction.query(
        _table,
        columns: const ['command_id'],
        where: 'command_id = ?',
        whereArgs: [envelope.commandId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        throw DuplicateCommandIdException(envelope.commandId);
      }
      await transaction.insert(_table, {
        'command_id': envelope.commandId,
        'type': envelope.type,
        'envelope_json': canonicalJson(envelope.original),
        'project_local_records': projectToLocalRecords ? 1 : 0,
        'host_status': HostCommandStatus.pending.databaseValue,
        'host_receipt_json': null,
        'fixture_receipt_json': null,
        'attempt_count': 0,
        'created_at_utc': now,
        'updated_at_utc': now,
        'last_attempt_at_utc': null,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
    });
  }

  Future<void> recordAttempt(String commandId) async {
    _ensureOpen();
    await _database.transaction((transaction) async {
      final rows = await transaction.query(
        _table,
        where: 'command_id = ?',
        whereArgs: [commandId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Unknown command: $commandId');
      final status = rows.single['host_status'];
      if (status != HostCommandStatus.pending.databaseValue &&
          status != HostCommandStatus.retryLater.databaseValue) {
        throw StateError('Only pending or retryable commands can be attempted');
      }
      final now = _clock().toUtc().toIso8601String();
      await transaction.update(
        _table,
        {
          'attempt_count': (rows.single['attempt_count']! as int) + 1,
          'updated_at_utc': now,
          'last_attempt_at_utc': now,
        },
        where: 'command_id = ? AND host_status = ?',
        whereArgs: [commandId, status],
      );
    });
  }

  /// Persists a test fixture response without changing Host status or receipt.
  Future<void> recordFixtureReceipt(
    String commandId,
    TransportResponse response,
  ) async {
    _ensureOpen();
    if (response.source != TransportSource.fixture ||
        response.apiVersion != hostApiVersion) {
      throw const FormatException(
        'Only a matching-version fixture response can be recorded here',
      );
    }
    final receipt = CommandReceipt.fromJson(response.receipt);
    if (receipt.commandId != commandId) {
      throw const FormatException('Fixture receipt command ID mismatch');
    }
    await _database.transaction((transaction) async {
      final rows = await transaction.query(
        _table,
        columns: const ['host_status'],
        where: 'command_id = ?',
        whereArgs: [commandId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Unknown command: $commandId');
      if (rows.single['host_status'] !=
          HostCommandStatus.pending.databaseValue) {
        throw StateError(
          'Fixture results cannot update Host-resolved commands',
        );
      }
      await transaction.update(
        _table,
        {
          'fixture_receipt_json': canonicalJson(receipt.toJson()),
          'updated_at_utc': _clock().toUtc().toIso8601String(),
        },
        where: 'command_id = ? AND host_status = ?',
        whereArgs: [commandId, HostCommandStatus.pending.databaseValue],
      );
    });
  }

  /// Stores an authoritative response returned by the real Host transport.
  /// Fixture responses are deliberately rejected by this path.
  Future<void> recordHostReceipt(
    String commandId,
    TransportResponse response,
  ) async {
    _ensureOpen();
    if (response.source != TransportSource.host ||
        response.apiVersion != hostApiVersion) {
      throw const FormatException(
        'Only a matching-version Host response can resolve a command.',
      );
    }
    final receipt = CommandReceipt.fromJson(
      requireMap(response.receipt, 'hostReceipt'),
    );
    if (receipt.commandId != commandId) {
      throw const FormatException('Host receipt command ID mismatch');
    }
    final status = HostCommandStatus.values.firstWhere(
      (value) => value.databaseValue == receipt.status,
    );
    await _database.transaction((transaction) async {
      final rows = await transaction.query(
        _table,
        columns: const ['attempt_count', 'host_status', 'host_receipt_json'],
        where: 'command_id = ?',
        whereArgs: [commandId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Unknown command: $commandId');
      final row = rows.single;
      final previousStatus = HostCommandStatus.fromDatabase(row['host_status']);
      final encodedReceipt = canonicalJson(receipt.toJson());
      if (previousStatus != HostCommandStatus.pending &&
          previousStatus != HostCommandStatus.retryLater) {
        if (previousStatus == status &&
            row['host_receipt_json'] == encodedReceipt) {
          return;
        }
        throw StateError('A final Host receipt cannot be replaced.');
      }
      if ((row['attempt_count']! as int) < 1) {
        throw StateError('A Host receipt requires a recorded send attempt.');
      }
      final changed = await transaction.update(
        _table,
        {
          'host_status': status.databaseValue,
          'host_receipt_json': encodedReceipt,
          'updated_at_utc': _clock().toUtc().toIso8601String(),
        },
        where: 'command_id = ? AND host_status = ?',
        whereArgs: [commandId, previousStatus.databaseValue],
      );
      if (changed != 1) {
        throw StateError(
          'Command state changed before the Host receipt was saved.',
        );
      }
    });
  }

  Future<QueueEntry?> getById(String commandId) async {
    _ensureOpen();
    final rows = await _database.query(
      _table,
      where: 'command_id = ?',
      whereArgs: [commandId],
      limit: 1,
    );
    return rows.isEmpty ? null : QueueEntry.fromRow(rows.single);
  }

  Future<List<QueueEntry>> list({int limit = 100}) async {
    _ensureOpen();
    if (limit < 1 || limit > 1000) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 1000');
    }
    final rows = await _database.query(
      _table,
      orderBy: 'created_at_utc DESC, command_id ASC',
      limit: limit,
    );
    return List.unmodifiable(rows.map(QueueEntry.fromRow));
  }

  /// Reports whether the durable queue still contains an unresolved command
  /// that targets [moduleId]. Accepted receipts are final; pending, retryable,
  /// conflicted, and rejected commands remain available for recovery/review.
  Future<bool> hasUnresolvedCommandsForModule(String moduleId) async {
    _ensureOpen();
    final rows = await _database.query(
      _table,
      columns: const ['envelope_json'],
      where: 'host_status <> ?',
      whereArgs: [HostCommandStatus.accepted.databaseValue],
    );
    for (final row in rows) {
      final decoded = jsonDecode(row['envelope_json']! as String);
      final envelope = CommandEnvelope.fromJson(
        requireMap(decoded, 'envelope'),
      );
      if (envelope.payload['moduleId'] == moduleId) return true;
    }
    return false;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _database.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Local command queue is closed');
  }
}
