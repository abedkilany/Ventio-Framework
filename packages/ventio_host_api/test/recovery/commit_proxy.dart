// Test-only PostgreSQL wire proxy. Never logs or persists protocol payloads.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class CommitProxy {
  final bool forwardCommit;
  final String upstreamHost;
  final int upstreamPort;
  final reached = Completer<void>();
  final List<Socket> _sockets = [];
  late final ServerSocket _server;
  CommitProxy(this.upstreamHost, this.upstreamPort,
      {required this.forwardCommit});
  int get port => _server.port;
  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((client) async {
      final upstream = await Socket.connect(upstreamHost, upstreamPort);
      _sockets.addAll([client, upstream]);
      var startup = true;
      var committing = false;
      var withheld = false;
      var front = <int>[];
      var back = <int>[];
      client.listen((bytes) {
        front.addAll(bytes);
        while (front.length >= (startup ? 4 : 5)) {
          final length = ByteData.sublistView(Uint8List.fromList(front))
              .getUint32(startup ? 0 : 1);
          final total = length + (startup ? 0 : 1);
          if (front.length < total) break;
          final frame = front.sublist(0, total);
          front = front.sublist(total);
          if (!startup &&
              frame[0] == 81 &&
              utf8
                      .decode(frame.sublist(5))
                      .replaceAll('\u0000', '')
                      .trim()
                      .toUpperCase() ==
                  'COMMIT;') {
            committing = true;
            if (!forwardCommit) {
              if (!reached.isCompleted) reached.complete();
              continue;
            }
          }
          startup = false;
          upstream.add(frame);
        }
      }, onError: (Object _) {
        upstream.destroy();
      }, onDone: upstream.destroy);
      upstream.listen((bytes) {
        back.addAll(bytes);
        while (back.length >= 5) {
          final length =
              ByteData.sublistView(Uint8List.fromList(back)).getUint32(1);
          if (back.length < length + 1) break;
          final frame = back.sublist(0, length + 1);
          back = back.sublist(length + 1);
          if (committing &&
              forwardCommit &&
              frame[0] == 67 &&
              utf8.decode(frame.sublist(5)) == 'COMMIT\u0000') {
            withheld = true;
            if (!reached.isCompleted) reached.complete();
          }
          if (!withheld) client.add(frame);
        }
      }, onError: (Object _) {
        client.destroy();
      }, onDone: client.destroy);
    });
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}
