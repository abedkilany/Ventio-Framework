import 'local_command_queue.dart';
import 'transport_fixture.dart';

/// Sends durable local intent to the Host and persists only real Host receipts.
/// If transport fails after dispatch, the queue entry stays retryable with the
/// same command ID so the Host's idempotency journal can reconcile the outcome.
class HostSyncService {
  const HostSyncService({required this.queue, required this.transport});

  final LocalCommandQueue queue;
  final CommandTransport transport;

  Future<int> syncPending({int limit = 100}) async {
    final entries = await queue.list(limit: limit);
    var resolved = 0;
    for (final entry in entries.reversed.where((entry) => entry.isPending)) {
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
