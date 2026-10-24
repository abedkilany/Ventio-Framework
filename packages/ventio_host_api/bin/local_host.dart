import 'dart:async';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

/// Persistent identity launcher. No development identity file or bypass.
/// Cleartext remains loopback-only; external listeners require TLS files.
Future<void> main() async {
  if (Platform.environment['VENTIO_ENABLE_LOCAL_HOST'] != 'yes') {
    stderr.writeln('Local Host requires explicit opt-in.');
    exitCode = 2;
    return;
  }
  HostApi api;
  try {
    final url = Platform.environment['VENTIO_HOST_DATABASE_URL'];
    if (url == null || url.isEmpty)
      throw StateError('Missing database configuration');
    final witness = Platform.environment['VENTIO_RECOVERY_AUTHORITY_FILE'];
    if (witness == null)
      throw StateError('Independent recovery authority required');
    final writerUid = int.tryParse(
      Platform.environment['VENTIO_RECOVERY_AUTHORITY_OWNER_UID'] ?? '',
    );
    if (writerUid == null || writerUid < 0)
      throw StateError('Trusted witness owner UID required');
    final admission = RecoveryAuthority(witness, trustedOwnerUid: writerUid);
    final parsed = Uri.parse(url);
    final boundedUrl = parsed
        .replace(
          queryParameters: {
            ...parsed.queryParameters,
            'connect_timeout': '5',
            'query_timeout': '20',
          },
        )
        .toString();
    Future<pg.Connection> connect() => pg.Connection.openFromUrl(boundedUrl);
    final probe = await connect();
    try {
      await verifyRuntimeConnection(probe);
      await probe.runTx((tx) => admission.admit(tx));
    } finally {
      await probe.close();
    }
    final prototype = bootstrapMaintenancePrototype('../../spec/v1.2');
    final addressText =
        Platform.environment['VENTIO_HOST_BIND_ADDRESS'] ?? '127.0.0.1';
    final address = InternetAddress.tryParse(addressText);
    if (address == null) throw StateError('Invalid Host bind address');
    SecurityContext? tlsContext;
    if (!address.isLoopback) {
      final certificate =
          Platform.environment['VENTIO_HOST_TLS_CERTIFICATE_FILE'];
      final privateKey =
          Platform.environment['VENTIO_HOST_TLS_PRIVATE_KEY_FILE'];
      if (certificate == null ||
          privateKey == null ||
          !File(certificate).isAbsolute ||
          !File(privateKey).isAbsolute) {
        throw StateError('External Host requires absolute TLS certificate files');
      }
      await PrivateFiles.verifyPrivateFile(privateKey);
      tlsContext = SecurityContext()
        ..useCertificateChain(certificate)
        ..usePrivateKey(privateKey);
    }
    api = await HostApi.bind(
      port: int.parse(Platform.environment['VENTIO_HOST_PORT'] ?? '8080'),
      listenAddress: address,
      tlsContext: tlsContext,
      authenticator: PersistentTokenAuthenticator(
        connect: connect,
        admission: admission,
      ),
      executor: PersistentCommandExecutor(
        connect: connect,
        admission: admission,
        modules: prototype.modules,
        docTypes: prototype.docTypes,
        bindings: const [
          TrustedCommandBinding('maintenance.create', 1, 'MaintenanceRequest'),
        ],
      ),
    );
    final scheme = address.isLoopback ? 'http' : 'https';
    stdout.writeln(
      'Persistent Host listening on $scheme://$addressText:${api.port}',
    );
  } catch (_) {
    stderr.writeln(
      'Local Host startup failed. Check private server configuration.',
    );
    exitCode = 2;
    return;
  }
  final shutdown = Completer<void>();
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  for (final signal in [
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ]) {
    subscriptions.add(
      signal.watch().listen((_) {
        if (!shutdown.isCompleted) shutdown.complete();
      }),
    );
  }
  await shutdown.future;
  await api.close();
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
}
