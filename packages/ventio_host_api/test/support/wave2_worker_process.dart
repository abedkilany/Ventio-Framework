// Test-owned child process for an actual worker termination/restart scenario.
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import '../recovery/database_fixture.dart';

Future<void> main() async {
  final env = Platform.environment;
  if (env['VENTIO_WAVE2_PREPARED_TESTS'] != 'yes' ||
      env['VENTIO_WAVE2_WORKER_PROCESS'] != 'yes' ||
      {
        'VENTIO-TEST-01',
        'VENTIO-TEST-02',
      }.contains(Platform.localHostname.toUpperCase())) {
    throw StateError('Explicit test-owned worker process fixture required');
  }
  final fixture = await DatabaseFixture.guarded(
    env['VENTIO_TEST_DATABASE_URL']!,
  );
  final runtime = pg.Pool<dynamic>.withUrl(
    env['VENTIO_TEST_RUNTIME_DATABASE_URL']!,
  );
  final api = pg.Pool<dynamic>.withUrl(
    env['VENTIO_TEST_API_ADMIN_DATABASE_URL']!,
  );
  final witness = env['VENTIO_WAVE2_WORKER_WITNESS']!;
  final authority = RecoveryAuthority(witness);
  final prototype = bootstrapMaintenancePrototype('../../spec/v1.2');
  final executor = PersistentCommandExecutor(
    pool: runtime,
    admission: authority,
    modules: prototype.modules,
    docTypes: prototype.docTypes,
    bindings: const [
      TrustedCommandBinding('maintenance.create', 1, 'MaintenanceRequest'),
    ],
  );
  final worker = Wave2JobWorker(
    administrationPool: api,
    admission: authority,
    executor: executor,
    diagnostics: ManagementDiagnosticBuffer(),
    interval: const Duration(milliseconds: 25),
  );
  try {
    worker.start();
    stdout.writeln('W2_WORKER_READY');
    await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  } finally {
    await worker.close();
    await runtime.close();
    await api.close();
    await fixture.close();
  }
}
