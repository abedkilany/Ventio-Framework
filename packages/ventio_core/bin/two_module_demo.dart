import 'dart:io';
import 'package:ventio_core/ventio_core.dart';

void main() {
  final prototype = bootstrapMaintenancePrototype('../../spec/v1.2');
  const root = '../../fixtures/inspection';

  // The Host explicitly approves a built-in capability; the downloaded
  // declarative module itself cannot provide executable code.
  prototype.modules.registerTrustedCapability(
      Capability.fromJson(loadJsonFile('$root/capability.json')));
  DeclarativeModuleInstaller(
    modules: prototype.modules,
    docTypes: prototype.docTypes,
    english: prototype.english,
  ).install(
    manifestJson: loadJsonFile('$root/manifest.json'),
    docTypeJsons: [loadJsonFile('$root/doctype.json')],
    englishCatalog: loadJsonFile('$root/localization/en.inspection.json'),
  );
  prototype.host.registerTrustedCreateBinding(const TrustedCommandBinding(
      'inspection.create', 1, 'EquipmentInspection'));

  final maintenance = CommandEnvelope.fromJson(
      loadJsonFile('../../spec/v1.2/examples/create_maintenance_command.json'));
  final inspection =
      CommandEnvelope.fromJson(loadJsonFile('$root/create_command.json'));
  final principal = Principal(
      tenantId: maintenance.tenantId,
      actorId: maintenance.actorId,
      deviceId: maintenance.deviceId,
      companyIds: {
        maintenance.companyId
      },
      branchIds: {
        maintenance.branchId
      },
      permissions: {
        'maintenance.create',
        'maintenance.read',
        'inspection.create',
        'inspection.read'
      });
  final first = prototype.host.execute(maintenance, principal);
  final second = prototype.host.execute(inspection, principal);
  final replay = prototype.host.execute(inspection, principal);
  stdout.writeln(
      'Installed modules: ${prototype.modules.installedIds.join(', ')}');
  stdout.writeln(
      'English label: ${prototype.english.text('inspection.module.name')}');
  stdout.writeln('Maintenance accepted: ${first.accepted}');
  stdout.writeln('Inspection accepted: ${second.accepted}');
  stdout.writeln('Inspection retry replayed: ${identical(second, replay)}');
  stdout.writeln('Records: ${prototype.host.recordCount}');
  if (!first.accepted ||
      !second.accepted ||
      !identical(second, replay) ||
      prototype.modules.installedIds.length != 2 ||
      prototype.host.recordCount != 2 ||
      prototype.host.auditCount != 2 ||
      prototype.host.outboxCount != 2) {
    stderr.writeln('Two-module proof failed');
    exitCode = 1;
  }
}
