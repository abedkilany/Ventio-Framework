import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart';

class FakeExecutor implements CommandExecutor {
  int calls = 0;
  bool fail = false;
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<Map<String, dynamic>> execute(
      CommandEnvelope command, Principal principal) async {
    calls++;
    entered?.complete();
    if (release != null) await release!.future;
    if (fail) throw StateError('sensitive database diagnostic');
    return CommandReceipt(
            commandId: command.commandId,
            status: principal.allows('maintenance.create')
                ? 'ACCEPTED'
                : 'REJECTED',
            reasonCode: principal.allows('maintenance.create')
                ? null
                : 'PERMISSION_DENIED')
        .toJson();
  }
}

Future<void> main() async {
  final executor = FakeExecutor();
  final api = await HostApi.bind(
      authenticator: authenticator('api-test'),
      executor: executor,
      maxBodyBytes: 4096,
      bodyTimeout: const Duration(milliseconds: 200));
  final body = command('api-test');
  Future<Reply> submit({String? token, Object? json}) =>
      send(api, token: token ?? validToken, body: json ?? body);
  try {
    check((await send(api, path: '/healthz', method: 'GET')).status == 200,
        'Liveness is available without credentials');
    check((await send(api, path: '/missing')).status == 404,
        'Unknown route is rejected');
    check((await send(api, method: 'GET')).status == 405,
        'Command route requires POST');
    check(
        (await send(api, path: '/api/v1/commands?token=secret', body: body))
                .status ==
            400,
        'Query credentials are unsupported');
    for (final token in [
      null,
      'invalid',
      List.filled(43, 'z').join(),
      expiredToken,
      revokedToken
    ]) {
      final reply = await send(api, token: token, body: body);
      check(
          reply.status == 401 &&
              reply.headers.value('www-authenticate') == 'Bearer',
          'Missing, malformed, unknown, expired or revoked credential is denied (${assertions + 1})');
    }
    check(executor.calls == 0,
        'Authentication failure never reaches command execution');
    check((await submit()).status == 200,
        'Valid credential dispatches authenticated command');
    final accepted = await submit();
    check(
        accepted.body['receipt']['status'] == 'ACCEPTED' &&
            accepted.headers.value('cache-control') == 'no-store',
        'Receipt is versioned and responses are not cached');
    check((await submit(token: deniedToken)).status == 403,
        'Insufficient permission is denied');
    final calls = executor.calls;
    for (final field in [
      'tenantId',
      'companyId',
      'branchId',
      'actorId',
      'deviceId'
    ]) {
      final forged = command('api-test');
      if (field == 'actorId' || field == 'deviceId') {
        forged['clientContext'][field] = 'forged';
      } else {
        forged[field] = 'forged';
      }
      check((await submit(json: forged)).status == 403,
          'Forged $field is denied');
    }
    check(
        executor.calls == calls, 'Scope denial occurs before executor access');
    check((await submit(json: '{broken')).status == 400,
        'Malformed JSON is rejected');
    check((await submit(json: '[]')).status == 400,
        'Non-object command is rejected');
    final unknown = command('api-test')
      ..['permissions'] = ['maintenance.create'];
    check((await submit(json: unknown)).status == 400,
        'Client cannot add permission claims');
    final unknownContext = command('api-test');
    unknownContext['clientContext']['roles'] = ['admin'];
    check((await submit(json: unknownContext)).status == 400,
        'Unknown context properties are rejected');
    final badVersion = command('api-test')..['protocolVersion'] = 1;
    check((await submit(json: badVersion)).status == 400,
        'Unsupported command protocol is rejected');
    final badId = command('api-test')..['commandId'] = 'invalid';
    check((await submit(json: badId)).status == 400,
        'Invalid command UUID is rejected');
    check(
        (await send(api,
                    token: validToken, body: body, contentType: 'text/plain'))
                .status ==
            415,
        'Non-JSON media type is rejected');
    check(
        (await send(api,
                    token: validToken,
                    body: body,
                    contentType: 'application/json; charset=latin1'))
                .status ==
            415,
        'Unsupported encoding is rejected');
    check((await submit(json: List.filled(5000, 'a').join())).status == 413,
        'Declared oversized body is rejected');
    check(
        (await send(api,
                    token: validToken,
                    body: List.filled(5000, 'a').join(),
                    chunked: true))
                .status ==
            413,
        'Chunked oversized body is rejected');
    check(
        (await submit(
                    json:
                        '${List.filled(40, '[').join()}0${List.filled(40, ']').join()}'))
                .status ==
            400,
        'Deeply nested JSON is bounded');
    final slowSocket = await Socket.connect('127.0.0.1', api.port);
    final rawResponse = utf8.decoder.bind(slowSocket).join();
    slowSocket.write('POST /api/v1/commands HTTP/1.1\r\n'
        'Host: localhost\r\nAuthorization: Bearer $validToken\r\n'
        'Content-Type: application/json\r\nContent-Length: 100\r\n\r\n{');
    await slowSocket.flush();
    final timeoutReply = await rawResponse.timeout(const Duration(seconds: 5));
    check(
        timeoutReply.startsWith('HTTP/1.1 408') &&
            timeoutReply.contains('BODY_TIMEOUT'),
        'Incomplete upload hits total body deadline');
    slowSocket.destroy();
    final unauthenticatedSocket = await Socket.connect('127.0.0.1', api.port);
    final earlyResponse = utf8.decoder.bind(unauthenticatedSocket).join();
    unauthenticatedSocket.write('POST /api/v1/commands HTTP/1.1\r\n'
        'Host: localhost\r\nContent-Length: 1000000\r\n\r\n');
    await unauthenticatedSocket.flush();
    check(
        (await earlyResponse.timeout(const Duration(seconds: 5)))
            .startsWith('HTTP/1.1 401'),
        'Unauthenticated incomplete upload is rejected without draining its body');
    unauthenticatedSocket.destroy();
    executor.fail = true;
    final failed = await submit();
    check(
        failed.status == 503 &&
            failed.body['error']['retryable'] == true &&
            !jsonEncode(failed.body).contains('sensitive'),
        'Execution exception produces no success or diagnostic leak');
  } finally {
    await api.close();
  }

  final gate = FakeExecutor()
    ..entered = Completer<void>()
    ..release = Completer<void>();
  final bounded = await HostApi.bind(
      authenticator: authenticator('api-test'),
      executor: gate,
      maxConcurrentRequests: 1);
  final inFlight = send(bounded, token: validToken, body: body);
  await gate.entered!.future;
  check((await send(bounded, token: validToken, body: body)).status == 503,
      'Admission limit rejects excess concurrent work');
  var closed = false;
  final closing = bounded.close().then((_) => closed = true);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  check(!closed, 'Shutdown waits for admitted command completion');
  gate.release!.complete();
  check((await inFlight).status == 200,
      'In-flight command completes during graceful shutdown');
  await closing;
  await bounded.close();
  check(closed, 'Shutdown completes and is idempotent');

  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    'bin/development_host.dart'
  ], environment: {
    'VENTIO_ENVIRONMENT': 'production',
    'VENTIO_ENABLE_DEVELOPMENT_API': 'yes'
  });
  check(result.exitCode == 2,
      'Development launcher refuses production configuration');
  stdout.writeln('RESULT: $assertions passed, 0 failed');
}
