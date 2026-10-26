import 'package:ventio_core/ventio_core.dart';

const int hostApiVersion = 1;

enum TransportSource { fixture, host }

class TransportResponse {
  TransportResponse({
    required this.apiVersion,
    required this.source,
    required Map<String, dynamic> receipt,
  }) : receipt = Map.unmodifiable(CommandReceipt.fromJson(receipt).toJson());

  final int apiVersion;
  final TransportSource source;
  final Map<String, dynamic> receipt;
}

abstract interface class CommandTransport {
  int get apiVersion;

  Future<TransportResponse> send(CommandEnvelope envelope);
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
  int get apiVersion => hostApiVersion;

  @override
  Future<TransportResponse> send(CommandEnvelope envelope) async {
    return TransportResponse(
      apiVersion: apiVersion,
      source: TransportSource.fixture,
      receipt: CommandReceipt(
        commandId: envelope.commandId,
        status: 'ACCEPTED',
        serverTimestamp: serverTimestamp,
        hostRevision: 1,
        scopeCursor: 'fixture-cursor-${envelope.commandId}',
        output: {'serverRecordId': 'fixture-${envelope.aggregateId}'},
      ).toJson(),
    );
  }
}
