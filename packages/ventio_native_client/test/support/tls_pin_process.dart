import 'dart:io';

import 'package:ventio_native_client/src/host_credentials.dart';

class _NoCredentialAccess implements HostCredentialBackend {
  @override
  Future<String?> read(String key) => throw StateError('No credential access');
  @override
  Future<void> write(String key, String value) =>
      throw StateError('No credential access');
  @override
  Future<void> delete(String key) => throw StateError('No credential access');
}

Future<void> main(List<String> args) async {
  final vault = HostCredentialVault(_NoCredentialAccess());
  final port = int.parse(args[0]);
  final endpoint = Uri.parse('https://localhost:$port');
  for (final attempt in [
    (endpoint, '0' * 64),
    (Uri.parse('https://127.0.0.1:$port'), args[1]),
  ]) {
    var denied = false;
    try {
      await vault.verifyAndFetchCertificate(attempt.$1, attempt.$2);
    } on TlsException {
      denied = true;
    }
    if (!denied) throw StateError('Wrong pin or endpoint name was admitted');
  }
  await vault.verifyAndFetchCertificate(endpoint, args[1]);
  stdout.writeln('TLS_PIN_AND_HOSTNAME_VALIDATED');
  // Natural process exit is part of the assertion. No exit(), mock sockets,
  // credential backend or OS certificate trust changes hide leaked handles.
}
