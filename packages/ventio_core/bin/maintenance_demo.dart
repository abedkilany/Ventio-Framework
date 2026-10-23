import 'dart:convert';
import 'dart:io';
import 'package:ventio_core/ventio_core.dart';

/// From packages/ventio_core: dart run bin/maintenance_demo.dart
void main(List<String> args) {
  final root = args.isNotEmpty ? args.first : '../../spec/v1.2';
  final prototype = bootstrapMaintenancePrototype(root);
  final command = CommandEnvelope.fromJson(
      loadJsonFile('$root/examples/create_maintenance_command.json'));
  final principal = Principal(
      actorId: command.actorId,
      deviceId: command.deviceId,
      tenantId: command.tenantId,
      companyIds: {command.companyId},
      branchIds: {command.branchId},
      permissions: {'maintenance.create', 'maintenance.read'});
  final accepted = prototype.host.execute(command, principal);
  final retry = prototype.host.execute(command, principal);
  stdout
      .writeln('Module: ${prototype.english.text('maintenance.module.name')}');
  stdout.writeln('First execution: ${jsonEncode(accepted.toJson())}');
  stdout.writeln('Identical retry: ${jsonEncode(retry.toJson())}');
  stdout.writeln('Records: ${prototype.host.recordCount}');
  stdout.writeln('Audit entries: ${prototype.host.auditCount}');
  stdout.writeln('Outbox events: ${prototype.host.outboxCount}');
  if (!accepted.accepted ||
      !identical(accepted, retry) ||
      prototype.host.recordCount != 1 ||
      prototype.host.outboxCount != 1) {
    stderr.writeln('Proof failed');
    exitCode = 1;
  }
}
