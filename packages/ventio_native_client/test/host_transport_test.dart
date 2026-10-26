import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/ventio_native_client.dart';

class _MemoryCredentialBackend implements HostCredentialBackend {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Future<CommandEnvelope> _envelope() async {
  final file = File('../../spec/v1.2/examples/create_maintenance_command.json');
  return CommandEnvelope.fromJson(
    jsonDecode(await file.readAsString()) as Map<String, dynamic>,
  );
}

Map<String, dynamic> _response(CommandEnvelope envelope, String status) => {
  'apiVersion': hostApiVersion,
  'receipt': CommandReceipt(
    commandId: envelope.commandId,
    status: status,
    serverTimestamp: '2026-10-24T00:00:00Z',
    reasonCode: status == 'ACCEPTED' ? null : 'INVALID_PAYLOAD',
    messageKey: status == 'ACCEPTED' ? null : 'core.error.invalid_payload',
    hostRevision: status == 'ACCEPTED' ? 1 : null,
    scopeCursor: status == 'ACCEPTED' ? 'branch-cursor-1' : null,
    output: status == 'ACCEPTED'
        ? {'serverRecordId': envelope.aggregateId}
        : null,
  ).toJson(),
};

void main() {
  const token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';

  test(
    'Sends the canonical command with bearer auth and parses a receipt',
    () async {
      final envelope = await _envelope();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = Completer<Map<String, Object?>>();
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        received.complete({
          'method': request.method,
          'path': request.uri.path,
          'authorization': request.headers.value(
            HttpHeaders.authorizationHeader,
          ),
          'contentType': request.headers.contentType?.mimeType,
          'body': body,
        });
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(_response(envelope, 'ACCEPTED')));
        await request.response.close();
      });

      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final backend = _MemoryCredentialBackend();
      final vault = HostCredentialVault(backend);
      await vault.save(endpoint, token);
      final transport = HttpHostCommandTransport(
        endpoint: endpoint,
        credentials: vault,
      );
      final response = await transport.send(envelope);
      final request = await received.future;

      expect(request['method'], 'POST');
      expect(request['path'], '/api/v1/commands');
      expect(request['authorization'], 'Bearer $token');
      expect(request['contentType'], 'application/json');
      expect(request['body'], canonicalJson(envelope.original));
      expect(response.source, TransportSource.host);
      expect(CommandReceipt.fromJson(response.receipt).accepted, isTrue);
    },
  );

  test('A valid Host rejection receipt remains a Host response', () async {
    final envelope = await _envelope();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.unprocessableEntity
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(_response(envelope, 'REJECTED')));
      await request.response.close();
    });

    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final vault = HostCredentialVault(_MemoryCredentialBackend());
    await vault.save(endpoint, token);
    final response = await HttpHostCommandTransport(
      endpoint: endpoint,
      credentials: vault,
    ).send(envelope);

    expect(response.source, TransportSource.host);
    expect(CommandReceipt.fromJson(response.receipt).status, 'REJECTED');
  });

  test('Redirect responses are not followed', () async {
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, '/redirect-target')
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'apiVersion': hostApiVersion,
            'error': {'code': 'REDIRECT_REFUSED', 'retryable': false},
          }),
        );
      await request.response.close();
    });

    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final vault = HostCredentialVault(_MemoryCredentialBackend());
    await vault.save(endpoint, token);
    await expectLater(
      HttpHostCommandTransport(
        endpoint: endpoint,
        credentials: vault,
      ).send(await _envelope()),
      throwsA(
        isA<HostTransportException>().having(
          (error) => error.code,
          'code',
          'REDIRECT_REFUSED',
        ),
      ),
    );
    expect(requests, 1);
  });

  test('Remote cleartext endpoints are rejected before a request', () async {
    expect(
      () => HttpHostCommandTransport(
        endpoint: Uri.parse('http://192.168.1.10:8080'),
        credentials: HostCredentialVault(_MemoryCredentialBackend()),
      ),
      throwsArgumentError,
    );
  });
}
