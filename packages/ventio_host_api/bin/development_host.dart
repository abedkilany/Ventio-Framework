import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

/// Explicitly enabled local development entry point. No built-in credentials.
Future<void> main() async {
  if (Platform.environment['VENTIO_ENABLE_DEVELOPMENT_API'] != 'yes' ||
      Platform.environment['VENTIO_ENVIRONMENT'] != 'development') {
    stderr.writeln(
        'The loopback API requires explicit development configuration.');
    exitCode = 2;
    return;
  }
  HostApi? api;
  try {
    final path = Platform.environment['VENTIO_DEVELOPMENT_IDENTITY_FILE'];
    final url = Platform.environment['VENTIO_HOST_DATABASE_URL'];
    if (path == null || url == null) throw StateError('Missing configuration');
    final identity =
        requireMap(jsonDecode(await File(path).readAsString()), 'identity');
    final principal = Principal(
      actorId: requireString(identity, 'actorId'),
      deviceId: requireString(identity, 'deviceId'),
      tenantId: requireString(identity, 'tenantId'),
      companyIds:
          strings(requireList(identity, 'companyIds'), 'companyIds').toSet(),
      branchIds:
          strings(requireList(identity, 'branchIds'), 'branchIds').toSet(),
      permissions:
          strings(requireList(identity, 'permissions'), 'permissions').toSet(),
    );
    final credential = DevelopmentCredential(
        tokenDigest: requireString(identity, 'tokenDigest'),
        principal: principal,
        expiresAt: DateTime.parse(requireString(identity, 'expiresAt')));
    final prototype = bootstrapMaintenancePrototype('../../spec/v1.2');
    api = await HostApi.bind(
      port: int.parse(Platform.environment['VENTIO_HOST_PORT'] ?? '8080'),
      authenticator: DevelopmentTokenAuthenticator([credential]),
      executor: PostgresCommandExecutor(
          connect: () => pg.Connection.openFromUrl(url),
          modules: prototype.modules,
          docTypes: prototype.docTypes,
          bindings: const [
            TrustedCommandBinding('maintenance.create', 1, 'MaintenanceRequest')
          ]),
    );
    stdout.writeln('Development Host listening on 127.0.0.1:${api.port}');
  } catch (_) {
    stderr.writeln(
        'Development Host startup failed. Check private configuration.');
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
