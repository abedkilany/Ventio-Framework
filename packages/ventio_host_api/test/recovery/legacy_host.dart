// Historical identity/crash fixture for unconfigured isolated test databases only.
import 'dart:async';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

/// Persistent identity launcher. No development identity file or bypass.
/// Binding remains hard-coded to loopback; public deployment is unsupported.
Future<void> main() async {
  if (Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
      Uri.parse(Platform.environment['VENTIO_HOST_DATABASE_URL'] ?? '').path !=
          '/ventio_host_test' ||
      Platform.environment['VENTIO_ENABLE_LOCAL_HOST'] != 'yes') {
    stderr.writeln('Local Host requires explicit opt-in.');
    exitCode = 2;
    return;
  }
  HostApi api;
  try {
    final url = Platform.environment['VENTIO_HOST_DATABASE_URL'];
    if (url == null || url.isEmpty)
      throw StateError('Missing database configuration');
    final parsed = Uri.parse(url);
    final boundedUrl = parsed.replace(queryParameters: {
      ...parsed.queryParameters,
      'connect_timeout': '5',
      'query_timeout': '20'
    }).toString();
    Future<pg.Connection> connect() => pg.Connection.openFromUrl(boundedUrl);
    final probe = await connect();
    try {
      await verifyRuntimeConnection(probe);
    } finally {
      await probe.close();
    }
    final prototype = bootstrapMaintenancePrototype('../../spec/v1.2');
    api = await HostApi.bind(
      port: int.parse(Platform.environment['VENTIO_HOST_PORT'] ?? '8080'),
      authenticator: PersistentTokenAuthenticator(connect: connect),
      executor: PersistentCommandExecutor(
          connect: connect,
          modules: prototype.modules,
          docTypes: prototype.docTypes,
          bindings: const [
            TrustedCommandBinding('maintenance.create', 1, 'MaintenanceRequest')
          ]),
    );
    stdout.writeln('Persistent local Host listening on 127.0.0.1:${api.port}');
  } catch (_) {
    stderr.writeln(
        'Local Host startup failed. Check private server configuration.');
    exitCode = 2;
    return;
  }
  final shutdown = Completer<void>();
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  for (final signal in [
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm
  ]) {
    subscriptions.add(signal.watch().listen((_) {
      if (!shutdown.isCompleted) shutdown.complete();
    }));
  }
  await shutdown.future;
  await api.close();
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
}
