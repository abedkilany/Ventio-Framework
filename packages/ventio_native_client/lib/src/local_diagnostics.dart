import 'dart:convert';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:ventio_core/ventio_core.dart';

import 'app_database.dart';

const int localDiagnosticsRetentionLimit = 500;

Future<LocalDiagnosticsStore> openDefaultLocalDiagnosticsStore() async {
  final directory = await getApplicationSupportDirectory();
  return LocalDiagnosticsStore.open(
    factory: databaseFactoryForCurrentPlatform(),
    path: p.join(directory.path, 'ventio_diagnostics.sqlite3'),
  );
}

abstract interface class DiagnosticEventSource {
  Future<List<ManagementDiagnosticEvent>> recent({int limit = 100});

  Future<String> exportJson({int limit = 100});
}

/// Local, authentication-independent diagnostic persistence for failures that
/// can happen before the Client reaches an authenticated Host.
///
/// Only the allowlisted fields from [ManagementDiagnosticEvent] are stored.
/// Technical exceptions, request bodies, SQL parameters, credentials, and
/// filesystem paths are not accepted by this API.
class LocalDiagnosticsStore implements DiagnosticEventSource {
  LocalDiagnosticsStore._(this._database, this._clock);

  final Database _database;
  final DateTime Function() _clock;
  bool _closed = false;

  static Future<LocalDiagnosticsStore> open({
    required DatabaseFactory factory,
    required String path,
    DateTime Function()? clock,
  }) async {
    final database = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (database) async {
          await database.execute('PRAGMA foreign_keys = ON');
          await database.rawQuery('PRAGMA journal_mode = WAL');
          await database.execute('PRAGMA synchronous = FULL');
        },
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE local_diagnostic_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              code TEXT NOT NULL,
              component TEXT NOT NULL,
              category TEXT NOT NULL,
              severity TEXT NOT NULL,
              occurred_at_utc TEXT NOT NULL,
              correlation_id TEXT NOT NULL,
              retryable INTEGER NOT NULL CHECK (retryable IN (0, 1)),
              message_key TEXT NOT NULL,
              safe_explanation TEXT NOT NULL,
              recommended_action TEXT NOT NULL
            )
          ''');
          await database.execute('''
            CREATE INDEX local_diagnostic_events_recent
            ON local_diagnostic_events(id DESC)
          ''');
        },
      ),
    );
    return LocalDiagnosticsStore._(database, clock ?? DateTime.now);
  }

  Future<ManagementDiagnosticEvent> record(LocalDiagnosticInput input) async {
    _ensureOpen();
    final explanation = sanitizeDiagnosticText(input.safeExplanation);
    final action = sanitizeDiagnosticText(input.recommendedAction);
    final event = ManagementDiagnosticEvent(
      code: input.code,
      component: input.component,
      category: input.category,
      severity: input.severity,
      occurredAtUtc: (input.occurredAtUtc ?? _clock()).toUtc(),
      correlationId: input.correlationId ?? newLocalCorrelationId(),
      retryable: input.retryable,
      messageKey: input.messageKey,
      safeExplanation: explanation,
      recommendedAction: action,
    );
    await _database.insert('local_diagnostic_events', {
      'code': event.code,
      'component': event.component,
      'category': event.category.wireValue,
      'severity': event.severity.wireValue,
      'occurred_at_utc': event.occurredAtUtc.toIso8601String(),
      'correlation_id': event.correlationId,
      'retryable': event.retryable ? 1 : 0,
      'message_key': event.messageKey,
      'safe_explanation': event.safeExplanation,
      'recommended_action': event.recommendedAction,
    });
    await _database.execute(
      '''
      DELETE FROM local_diagnostic_events
      WHERE id NOT IN (
        SELECT id FROM local_diagnostic_events ORDER BY id DESC LIMIT ?
      )
    ''',
      [localDiagnosticsRetentionLimit],
    );
    return event;
  }

  @override
  Future<List<ManagementDiagnosticEvent>> recent({int limit = 100}) async {
    _ensureOpen();
    if (limit < 1 || limit > localDiagnosticsRetentionLimit) {
      throw ArgumentError.value(limit, 'limit', 'Out of range.');
    }
    final rows = await _database.query(
      'local_diagnostic_events',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(_eventFromRow).toList(growable: false);
  }

  /// Exports an allowlisted snapshot only. No database path, Host address,
  /// request payload, exception message, or credential can enter the export.
  @override
  Future<String> exportJson({int limit = 100}) async {
    final events = await recent(limit: limit);
    return const JsonEncoder.withIndent('  ').convert({
      'managementApiVersion': managementApiVersion,
      'exportedAtUtc': _clock().toUtc().toIso8601String(),
      'events': [for (final event in events) event.toJson()],
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _database.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Local diagnostics store is closed.');
  }
}

/// Safe input for a local diagnostic event. This has intentionally no field
/// for raw exceptions or protected technical details.
class LocalDiagnosticInput {
  const LocalDiagnosticInput({
    required this.code,
    required this.component,
    required this.category,
    required this.severity,
    required this.retryable,
    required this.messageKey,
    required this.safeExplanation,
    required this.recommendedAction,
    this.occurredAtUtc,
    this.correlationId,
  });

  final String code;
  final String component;
  final ManagementDiagnosticCategory category;
  final ManagementDiagnosticSeverity severity;
  final bool retryable;
  final String messageKey;
  final String safeExplanation;
  final String recommendedAction;
  final DateTime? occurredAtUtc;
  final String? correlationId;
}

/// A locally generated correlation reference for failures that occur before
/// the Host can issue one. It contains no device, user, or credential data.
String newLocalCorrelationId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return 'cor_${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
}

/// Redacts common credential formats and private Windows paths before text is
/// persisted or exported. Callers should still pass user-safe copy, never raw
/// exception strings.
String sanitizeDiagnosticText(String value) {
  if (value.trim().isEmpty || value.length > 4000) {
    throw ArgumentError('Diagnostic text is empty or too large.');
  }
  var result = value;
  result = result.replaceAll(
    RegExp(r'\bBearer\s+[A-Za-z0-9_-]{16,}', caseSensitive: false),
    'Bearer [redacted]',
  );
  result = result.replaceAll(
    RegExp(
      r'\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b',
    ),
    '[signed token redacted]',
  );
  result = result.replaceAll(
    RegExp(
      r'\b(?:postgres(?:ql)?|https?)://[^\s/@:]+:[^\s/@]+@[^\s]+',
      caseSensitive: false,
    ),
    '[connection string redacted]',
  );
  result = result.replaceAllMapped(
    RegExp(
      r'\b(password|passwd|secret|token|api[_-]?key|client[_-]?secret)\s*[=:]\s*[^\s,;&]+',
      caseSensitive: false,
    ),
    (match) => '[credential redacted]',
  );
  result = result.replaceAll(
    RegExp(
      r'([?&](?:token|password|secret|api[_-]?key)=)[^&#\s]+',
      caseSensitive: false,
    ),
    '[query credential redacted]',
  );
  result = result.replaceAll(
    RegExp(
      r'\b[A-Za-z]:\\(?:Users|ProgramData|Windows)\\[^",;\r\n<>]*',
      caseSensitive: false,
    ),
    '[local path]',
  );
  result = result.replaceAll(
    RegExp(
      r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
    ),
    '[private key redacted]',
  );
  return result.length <= 1000 ? result : '${result.substring(0, 997)}...';
}

ManagementDiagnosticEvent _eventFromRow(Map<String, Object?> row) {
  final category = ManagementDiagnosticCategory.values.singleWhere(
    (value) => value.wireValue == row['category'],
    orElse: () => throw const FormatException('Unknown diagnostic category.'),
  );
  final severity = ManagementDiagnosticSeverity.values.singleWhere(
    (value) => value.wireValue == row['severity'],
    orElse: () => throw const FormatException('Unknown diagnostic severity.'),
  );
  return ManagementDiagnosticEvent(
    code: row['code']! as String,
    component: row['component']! as String,
    category: category,
    severity: severity,
    occurredAtUtc: DateTime.parse(row['occurred_at_utc']! as String),
    correlationId: row['correlation_id']! as String,
    retryable: row['retryable'] == 1,
    messageKey: row['message_key']! as String,
    safeExplanation: row['safe_explanation']! as String,
    recommendedAction: row['recommended_action']! as String,
  );
}
