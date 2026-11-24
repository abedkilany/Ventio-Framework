import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Real loopback HTTP fault injector: drops the response only AFTER the actual
// PostgreSQL Host has returned an ACCEPTED receipt. It never invents a receipt.
class W2CommitDropProxy {
  W2CommitDropProxy._(this.server, this.target) {
    server.listen((request) {
      late Future<void> active;
      active = forward(request).whenComplete(() => pending.remove(active));
      pending.add(active);
    });
  }
  final HttpServer server;
  final Uri target;
  final pending = <Future<void>>{};
  bool dropNextAccepted = true;
  int committedResponsesDropped = 0;
  Uri get endpoint => Uri.parse('http://127.0.0.1:${server.port}');
  static Future<W2CommitDropProxy> start(Uri target) async {
    if (target.scheme != 'http' || target.host != '127.0.0.1') {
      throw ArgumentError('Disposable loopback Host required');
    }
    return W2CommitDropProxy._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      target,
    );
  }

  Future<void> forward(HttpRequest incoming) async {
    final client = HttpClient();
    try {
      final outgoing = await client.openUrl(
        incoming.method,
        target.replace(path: incoming.uri.path),
      );
      outgoing.followRedirects = false;
      outgoing.headers.contentType = ContentType.json;
      final bearer = incoming.headers.value(HttpHeaders.authorizationHeader);
      if (bearer != null) {
        outgoing.headers.set(HttpHeaders.authorizationHeader, bearer);
      }
      await outgoing.addStream(incoming);
      final response = await outgoing.close();
      final bytes = await response.fold<List<int>>(
        [],
        (data, chunk) => data..addAll(chunk),
      );
      final decoded = jsonDecode(utf8.decode(bytes)) as Map;
      if (dropNextAccepted &&
          response.statusCode == 200 &&
          (decoded['receipt'] as Map?)?['status'] == 'ACCEPTED') {
        dropNextAccepted = false;
        committedResponsesDropped++;
        final socket = await incoming.response.detachSocket(
          writeHeaders: false,
        );
        socket.destroy();
        return;
      }
      incoming.response.statusCode = response.statusCode;
      incoming.response.headers.contentType = ContentType.json;
      incoming.response.add(bytes);
      await incoming.response.close();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> close() async {
    await server.close(force: true);
    await Future.wait(pending.toList());
  }
}
