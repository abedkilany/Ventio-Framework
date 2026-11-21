import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../ventio_core/test/support/wave2_cases.dart';
import '../recovery/support.dart' show TestHost;

// Uses the existing OS-separated production Host process. No transport failure
// is converted to the expected 503 and no polling/retry masks the first result.
Future<void> wave2ManifestRegression({
  required TestHost host,
  required String token,
  required Map<String, dynamic> Function() nextCommand,
  required Future<void> Function() insertUnknown,
  required Future<void> Function() deleteUnknown,
  required Future<bool> Function() witnessMatches,
  required Future<List<int>> Function(Map<String, dynamic>) effectCounts,
}) async {
  final cases = W2Cases();
  Future<(int?, Map<String, dynamic>?, String?)> probe(
    Map<String, dynamic> command,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${host.port}/api/v1/commands'),
      );
      request.headers
        ..contentType = ContentType.json
        ..set('Authorization', 'Bearer $token');
      request.write(jsonEncode(command));
      final response = await request.close().timeout(
        const Duration(seconds: 35),
      );
      final body =
          jsonDecode(
                await utf8.decoder
                    .bind(response)
                    .join()
                    .timeout(const Duration(seconds: 5)),
              )
              as Map<String, dynamic>;
      return (response.statusCode, body, null);
    } on SocketException {
      return (null, null, 'SocketException');
    } on HttpException {
      return (null, null, 'HttpException');
    } on TimeoutException {
      return (null, null, 'TimeoutException');
    } finally {
      client.close(force: true);
    }
  }

  await cases.run(
    'W2-R001',
    'B02,D09,J04',
    'WB-CI-02: a changed manifest returns an actual 503 HOST_UNAVAILABLE without transport substitution or effects',
    () async {
      await insertUnknown();
      try {
        w2Expect(
          await witnessMatches(),
          'Manifest test changed the recovery witness inconsistently',
        );
        final command = nextCommand();
        final (status, body, failure) = await probe(command);
        final processExit = await Future.any<int?>([
          host.process.exitCode.then<int?>((code) => code),
          Future<int?>.delayed(const Duration(milliseconds: 50), () => null),
        ]);
        w2Expect(
          status == 503 &&
              (body?['error'] as Map?)?['code'] == 'HOST_UNAVAILABLE',
          'Manifest denial differed: http=$status transport=$failure processExit=$processExit',
        );
        w2Expect(
          processExit == null,
          'Host process exited instead of denying safely',
        );
        w2Expect(
          (await effectCounts(command)).every((count) => count == 0),
          'Rejected command produced durable effects',
        );
      } finally {
        await deleteUnknown();
      }
    },
  );
  await cases.run(
    'W2-R002',
    'B02,D09',
    'WB-CI-02: removing the fixture mutation restores admission on the same process',
    () async {
      w2Expect(
        await witnessMatches(),
        'Cleanup left inconsistent recovery evidence',
      );
      final (status, body, failure) = await probe(nextCommand());
      w2Expect(
        status == 200 &&
            (body?['receipt'] as Map?)?['status'] == 'ACCEPTED' &&
            failure == null,
        'Same running Host did not recover admission',
      );
    },
  );
}
