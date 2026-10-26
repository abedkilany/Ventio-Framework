import 'package:ventio_core/ventio_core.dart';
import '../../bin/local_host.dart' as local_host;

/// CI-only launcher for the existing trusted maintenance fixture. The regular
/// production launcher remains generic and registers no business commands.
Future<void> main() async {
  final fixture = bootstrapMaintenancePrototype('../../spec/v1.2');
  await local_host.runLocalHost(
    modules: fixture.modules,
    docTypes: fixture.docTypes,
    bindings: [
      const TrustedCommandBinding(
        'maintenance.create',
        1,
        'MaintenanceRequest',
      ),
    ],
  );
}
