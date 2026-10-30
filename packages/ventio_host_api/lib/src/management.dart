import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

import 'persistent_identity.dart';
import 'postgres_connections.dart';
import 'private_files.dart';
import 'recovery_authority.dart';

/// Keep in sync with packages/ventio_host_api/pubspec.yaml.
const String hostApiReleaseVersion = '0.1.0';

abstract interface class HostReadinessProvider {
  Future<HostReadinessSnapshot> checkReadiness();
}

/// Marker required before a readiness provider may be bound to an external
/// listener. It guarantees status comes from trusted Host-owned components.
abstract interface class AuthoritativeHostReadinessProvider
    implements HostReadinessProvider {}

/// Read-only readiness probe backed by the same restricted Host runtime pool.
/// It never attempts to repair schema or recovery state.
class PostgresHostReadinessProvider
    implements AuthoritativeHostReadinessProvider {
  const PostgresHostReadinessProvider({
    this.connect,
    this.pool,
    required this.recoveryAuthority,
  }) : assert((connect == null) != (pool == null));

  final Future<pg.Connection> Function()? connect;
  final pg.Pool<dynamic>? pool;
  final RecoveryAuthority recoveryAuthority;

  @override
  Future<HostReadinessSnapshot> checkReadiness() async {
    final checkedAtUtc = DateTime.now().toUtc();
    var databaseState = ManagementHealthState.unavailable;
    var databaseCode = 'DATABASE_UNAVAILABLE';
    var schemaState = ManagementHealthState.unknown;
    String? schemaCode;
    var recoveryState = ManagementHealthState.unknown;
    String? recoveryCode;

    try {
      await withPostgresConnection(
        connect: connect,
        pool: pool,
        action: (connection) async {
          try {
            await connection.execute('SELECT 1');
            databaseState = ManagementHealthState.ready;
            databaseCode = '';
          } catch (_) {
            return;
          }

          try {
            await verifyRuntimeConnection(connection);
            schemaState = ManagementHealthState.ready;
          } catch (_) {
            schemaState = ManagementHealthState.unavailable;
            schemaCode = 'DATABASE_PROFILE_UNAVAILABLE';
            return;
          }

          try {
            await connection.runTx((tx) => recoveryAuthority.admit(tx));
            recoveryState = ManagementHealthState.ready;
          } catch (_) {
            recoveryState = ManagementHealthState.blocked;
            recoveryCode = 'RECOVERY_ADMISSION_BLOCKED';
          }
        },
      );
    } catch (_) {
      // The snapshot intentionally contains only safe status codes.
    }

    return HostReadinessSnapshot(
      checkedAtUtc: checkedAtUtc,
      hostVersion: hostApiReleaseVersion,
      components: [
        ManagementComponentHealth(
          component: ManagementComponent.api,
          state: ManagementHealthState.ready,
          checkedAtUtc: checkedAtUtc,
        ),
        ManagementComponentHealth(
          component: ManagementComponent.database,
          state: databaseState,
          checkedAtUtc: checkedAtUtc,
          reasonCode: databaseCode.isEmpty ? null : databaseCode,
        ),
        ManagementComponentHealth(
          component: ManagementComponent.schema,
          state: schemaState,
          checkedAtUtc: checkedAtUtc,
          reasonCode: schemaCode,
        ),
        ManagementComponentHealth(
          component: ManagementComponent.recoveryAuthority,
          state: recoveryState,
          checkedAtUtc: checkedAtUtc,
          reasonCode: recoveryCode,
        ),
      ],
    );
  }
}

abstract interface class ManagementDiagnosticSink {
  Future<void> record(ManagementDiagnosticEvent event);
}

abstract interface class ManagementDiagnosticReader {
  List<ManagementDiagnosticEvent> recent({int? limit});
}

/// Process-local bounded buffer used for safe operational event correlation.
/// It stores only structured, user-safe contracts, never exception text.
class ManagementDiagnosticBuffer
    implements ManagementDiagnosticSink, ManagementDiagnosticReader {
  ManagementDiagnosticBuffer({this.capacity = 200}) {
    if (capacity < 1 || capacity > 10000) {
      throw ArgumentError.value(capacity, 'capacity');
    }
  }

  final int capacity;
  final Queue<ManagementDiagnosticEvent> _events = Queue();

  @override
  Future<void> record(ManagementDiagnosticEvent event) async {
    _events.addLast(event);
    while (_events.length > capacity) {
      _events.removeFirst();
    }
  }

  @override
  List<ManagementDiagnosticEvent> recent({int? limit}) {
    final boundedLimit = limit ?? (capacity < 100 ? capacity : 100);
    if (boundedLimit < 1 || boundedLimit > capacity) {
      throw ArgumentError.value(boundedLimit, 'limit');
    }
    return List.unmodifiable(_events.toList().reversed.take(boundedLimit));
  }
}

/// Durable ring buffer for protected Host diagnostics.
///
/// The file must live in a directory already protected for the Host service
/// identity. Public exports must be produced from [ManagementDiagnosticEvent.toJson],
/// which omits the protected technical fields stored here.
class ProtectedManagementDiagnosticLog
    implements ManagementDiagnosticSink, ManagementDiagnosticReader {
  ProtectedManagementDiagnosticLog._({
    required this.path,
    required this.capacity,
    required Iterable<ManagementDiagnosticEvent> initialEvents,
  }) : _events = Queue.of(initialEvents);

  static const _formatVersion = 1;

  final String path;
  final int capacity;
  final Queue<ManagementDiagnosticEvent> _events;
  Future<void> _pendingWrite = Future<void>.value();

  static Future<ProtectedManagementDiagnosticLog> open(
    String path, {
    int capacity = 200,
  }) async {
    if (!File(path).isAbsolute || capacity < 1 || capacity > 500) {
      throw ArgumentError('Invalid protected diagnostic log settings.');
    }
    final file = File(path);
    if (!await file.exists()) {
      try {
        await PrivateFiles.create(path, {
          'formatVersion': _formatVersion,
          'events': const <Object?>[],
        });
      } on FileSystemException {
        // A concurrent Host startup may have created the protected file.
        if (!await file.exists()) rethrow;
      }
    }
    final source = await PrivateFiles.read(path);
    final decoded = jsonDecode(source);
    if (decoded is! Map ||
        decoded.length != 2 ||
        decoded['formatVersion'] != _formatVersion ||
        decoded['events'] is! List ||
        (decoded['events'] as List).length > capacity) {
      throw const FormatException('Protected diagnostic log is invalid.');
    }
    final events = (decoded['events'] as List)
        .map(_readProtectedEvent)
        .toList(growable: false);
    return ProtectedManagementDiagnosticLog._(
      path: path,
      capacity: capacity,
      initialEvents: events,
    );
  }

  @override
  List<ManagementDiagnosticEvent> recent({int? limit}) {
    final boundedLimit = limit ?? (capacity < 100 ? capacity : 100);
    if (boundedLimit < 1 || boundedLimit > capacity) {
      throw ArgumentError.value(boundedLimit, 'limit');
    }
    return List.unmodifiable(_events.toList().reversed.take(boundedLimit));
  }

  @override
  Future<void> record(ManagementDiagnosticEvent event) {
    final write = _pendingWrite.then((_) async {
      _events.addLast(event);
      while (_events.length > capacity) {
        _events.removeFirst();
      }
      final contents = jsonEncode({
        'formatVersion': _formatVersion,
        'events': _events.map(_writeProtectedEvent).toList(growable: false),
      });
      if (utf8.encode(contents).length > 1024 * 1024) {
        throw StateError('Protected diagnostic log exceeds its size limit.');
      }
      await PrivateFiles.replace(path, jsonDecode(contents));
    });
    _pendingWrite = write.catchError((Object _) {});
    return write;
  }
}

Map<String, Object?> _writeProtectedEvent(ManagementDiagnosticEvent event) => {
  ...event.toJson(),
  if (event.protectedTechnicalCode != null)
    'protectedTechnicalCode': event.protectedTechnicalCode,
  if (event.protectedFailureType != null)
    'protectedFailureType': event.protectedFailureType,
  if (event.protectedFailureSource != null)
    'protectedFailureSource': event.protectedFailureSource,
};

ManagementDiagnosticEvent _readProtectedEvent(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Protected diagnostic event is invalid.');
  }
  const required = {
    'managementApiVersion',
    'code',
    'component',
    'category',
    'severity',
    'occurredAtUtc',
    'correlationId',
    'retryable',
    'messageKey',
    'safeExplanation',
    'recommendedAction',
  };
  const protected = {
    'protectedTechnicalCode',
    'protectedFailureType',
    'protectedFailureSource',
  };
  if (!value.keys.toSet().containsAll(required) ||
      value.keys.any(
        (key) => !required.contains(key) && !protected.contains(key),
      ) ||
      value['managementApiVersion'] != managementApiVersion ||
      value['retryable'] is! bool) {
    throw const FormatException('Protected diagnostic event is invalid.');
  }
  final occurredAt = DateTime.tryParse(value['occurredAtUtc'] as String? ?? '');
  if (occurredAt == null || !occurredAt.isUtc) {
    throw const FormatException('Diagnostic timestamp must be UTC.');
  }
  for (final key in protected) {
    if (value.containsKey(key) && value[key] is! String) {
      throw const FormatException('Protected diagnostic detail is invalid.');
    }
  }
  return ManagementDiagnosticEvent(
    code: value['code'] as String? ?? '',
    component: value['component'] as String? ?? '',
    category: ManagementDiagnosticCategory.parse(value['category']),
    severity: ManagementDiagnosticSeverity.parse(value['severity']),
    occurredAtUtc: occurredAt,
    correlationId: value['correlationId'] as String? ?? '',
    retryable: value['retryable'] as bool,
    messageKey: value['messageKey'] as String? ?? '',
    safeExplanation: value['safeExplanation'] as String? ?? '',
    recommendedAction: value['recommendedAction'] as String? ?? '',
    protectedTechnicalCode: value['protectedTechnicalCode'] as String?,
    protectedFailureType: value['protectedFailureType'] as String?,
    protectedFailureSource: value['protectedFailureSource'] as String?,
  );
}
