import 'dart:collection';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

import 'persistent_identity.dart';
import 'postgres_connections.dart';
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

/// Process-local bounded buffer used for safe operational event correlation.
/// It stores only structured, user-safe contracts, never exception text.
class ManagementDiagnosticBuffer implements ManagementDiagnosticSink {
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

  List<ManagementDiagnosticEvent> recent({int limit = 100}) {
    if (limit < 1 || limit > capacity) {
      throw ArgumentError.value(limit, 'limit');
    }
    return List.unmodifiable(_events.toList().reversed.take(limit));
  }
}
