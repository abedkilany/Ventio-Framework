import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/host_credentials.dart';

void main() {
  test(
    'real TLS pin probes reject wrong trust and release both socket halves',
    () async {
      final fixture = Directory('test/support/tls-loopback');
      final certificate = File('${fixture.path}/localhost.cert.pem');
      final context = SecurityContext()
        ..useCertificateChain(certificate.path)
        ..usePrivateKey('${fixture.path}/public-test-only.key.pem');
      final server = await SecureServerSocket.bind('127.0.0.1', 0, context);
      final peers = <SecureSocket>[];
      final listener = server.listen((peer) {
        peers.add(peer);
        // Keep the peer's send direction open, like an idle HTTP TLS listener.
        // A probe must release its own receiving handle without waiting for it.
        peer.listen((_) {}, onError: (Object _) {});
      }, onError: (Object _) {});
      Process? child;
      try {
        final der = base64Decode(
          certificate.readAsStringSync().replaceAll(
            RegExp(r'-----BEGIN CERTIFICATE-----|-----END CERTIFICATE-----|\s'),
            '',
          ),
        );
        final config = File('.dart_tool/package_config.json').absolute;
        final packages = jsonDecode(config.readAsStringSync()) as Map;
        final flutter = (packages['packages'] as List).cast<Map>().singleWhere(
          (entry) => entry['name'] == 'flutter',
        );
        final root = Uri.directory(
          config.uri.resolve(flutter['rootUri'] as String).toFilePath(),
        );
        final dart = root
            .resolve(
              '../../bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
            )
            .toFilePath();
        child = await Process.start(dart, [
          '--packages=${config.path}',
          'test/support/tls_pin_process.dart',
          '${server.port}',
          HostCredentialVault.certificateFingerprint(der),
        ]);
        final output = utf8.decoder.bind(child.stdout).join();
        final errors = utf8.decoder.bind(child.stderr).join();
        expect(await child.exitCode.timeout(const Duration(seconds: 8)), 0);
        expect(await output, contains('TLS_PIN_AND_HOSTNAME_VALIDATED'));
        expect(await errors, isEmpty);
      } finally {
        child?.kill();
        for (final peer in peers) {
          peer.destroy();
        }
        await listener.cancel();
        await server.close();
      }
    },
  );
}
