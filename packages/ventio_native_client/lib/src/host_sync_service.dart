import 'package:ventio_core/ventio_core.dart';

import 'local_command_queue.dart';
import 'transport_fixture.dart';

/// Authenticated Host owner and exact scope expected for queued commands.
class HostSyncIdentity {
  const HostSyncIdentity({
    required this.tenantId,
    required this.companyId,
    required this.branchId,
    required this.actorId,
    required this.deviceId,
  });

  final String tenantId;
  final String companyId;
  final String branchId;
  final String actorId;
  final String deviceId;

  bool owns(CommandEnvelope envelope) =>
      envelope.tenantId == tenantId &&
      envelope.companyId == companyId &&
      envelope.branchId == branchId &&
      envelope.actorId == actorId &&
      envelope.deviceId == deviceId;
}

class HostSyncIdentityMismatchException implements Exception {
  const HostSyncIdentityMismatchException();

  @override
  String toString() =>
      'HOST_QUEUE_IDENTITY_MISMATCH: pending work belongs to another Host identity or scope.';
}

/// Sends durable local intent to the Host and persists only real Host receipts.
/// If transport fails after dispatch, the queue entry stays retryable with the
/// same command ID so the Host's idempotency journal can reconcile the outcome.
class HostSyncService {
  const HostSyncService({
    required this.queue,
    required this.transport,
    required this.identity,
  });

  final LocalCommandQueue queue;
  final CommandTransport transport;
  final HostSyncIdentity identity;

  Future<int> syncPending({int limit = 100}) async {
    final entries = await queue.list(limit: limit);
    final pending = entries.reversed.where((entry) => entry.isPending).toList();
    if (pending.any((entry) => !identity.owns(entry.envelope))) {
      throw const HostSyncIdentityMismatchException();
    }
    var resolved = 0;
    for (final entry in pending) {
      await queue.recordAttempt(entry.envelope.commandId);
      final response = await transport.send(entry.envelope);
      if (response.source != TransportSource.host) {
        throw const FormatException(
          'A fixture response cannot resolve a queued Host command.',
        );
      }
      await queue.recordHostReceipt(entry.envelope.commandId, response);
      resolved++;
    }
    return resolved;
  }
}
