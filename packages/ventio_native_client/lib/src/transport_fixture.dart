import 'package:ventio_core/ventio_core.dart';

abstract interface class CommandTransport {
  Future<Map<String, dynamic>> send(CommandEnvelope envelope);
}

/// Deterministic local fixture for tests and UI exploration.
///
/// This class performs no HTTP, LAN, tunnel, or Host communication. The queue
/// stores its result separately so the response cannot mark work as accepted
/// by Host.
class DeterministicTransportFixture implements CommandTransport {
  const DeterministicTransportFixture({
    this.serverTimestamp = '2026-10-24T00:00:00Z',
  });

  final String serverTimestamp;

  @override
  Future<Map<String, dynamic>> send(CommandEnvelope envelope) async {
    return CommandReceipt(
      commandId: envelope.commandId,
      status: 'ACCEPTED',
      serverTimestamp: serverTimestamp,
      hostRevision: 1,
      scopeCursor: 'fixture-cursor-${envelope.commandId}',
      output: {'serverRecordId': 'fixture-${envelope.aggregateId}'},
    ).toJson();
  }
}
