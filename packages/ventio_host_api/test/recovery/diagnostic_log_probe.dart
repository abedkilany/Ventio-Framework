import 'dart:io';

import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 || !Platform.isWindows) {
    stderr.writeln('A Windows protected diagnostic path is required.');
    exitCode = 2;
    return;
  }
  final log = await ProtectedManagementDiagnosticLog.open(
    arguments.single,
    capacity: 2,
  );
  await log.record(
    ManagementDiagnosticEvent(
      code: 'DATABASE_UNAVAILABLE',
      component: 'host.database',
      category: ManagementDiagnosticCategory.database,
      severity: ManagementDiagnosticSeverity.error,
      occurredAtUtc: DateTime.utc(2026, 10, 30),
      correlationId: 'cor_0123456789abcdef0123456789abcdef',
      retryable: true,
      messageKey: 'native.diagnostics.database_unavailable',
      safeExplanation: 'The Host cannot reach its configured database.',
      recommendedAction: 'Check database service status and retry.',
      protectedTechnicalCode: '08006',
      protectedFailureType: 'SocketException',
      protectedFailureSource: 'PostgresPool.connect',
    ),
  );
  stdout.writeln('DIAGNOSTIC_EVENT_PERSISTED');
}
