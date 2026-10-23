import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host/ventio_host.dart';
import 'package:ventio_postgres/ventio_postgres.dart';

int _counter = 0;
String _nextId() =>
    '00000000-0000-4000-8000-${(++_counter).toString().padLeft(12, '0')}';

CommandEnvelope _command(Map<String, dynamic> source, String tenant,
    {String? id,
    String? record,
    List<String>? dependencies,
    String? company,
    String? branch}) {
  final json = Map<String, dynamic>.from(source);
  json['commandId'] = id ?? _nextId();
  json['tenantId'] = tenant;
  json['companyId'] = company ?? 'test-company';
  json['branchId'] = branch ?? 'test-branch';
  json['aggregateId'] = record ?? 'record-${_counter.toString()}';
  json['dependsOn'] = dependencies ?? <String>[];
  return CommandEnvelope.fromJson(json);
}

Principal _principal(CommandEnvelope command, {bool permission = true}) =>
    Principal(
      tenantId: command.tenantId,
      actorId: command.actorId,
      deviceId: command.deviceId,
      companyIds: {command.companyId},
      branchIds: {command.branchId},
      permissions: permission
          ? {
              'maintenance.create',
              'maintenance.read',
              'inspection.create',
              'inspection.read'
            }
          : <String>{},
    );

Future<int> _count(
    pg.Connection connection, String table, String tenant) async {
  final rows = await connection.execute(
      pg.Sql.named('SELECT count(*) FROM $table WHERE tenant_id = @tenant'),
      parameters: {'tenant': tenant});
  return rows.single[0] as int;
}

Future<void> main() async {
  final url = Platform.environment['VENTIO_TEST_DATABASE_URL'];
  final permitted = Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'];
  if (url == null ||
      url.isEmpty ||
      permitted != 'yes' ||
      Uri.parse(url)
              .pathSegments
              .where((segment) => segment.isNotEmpty)
              .lastOrNull !=
          'ventio_host_test') {
    stderr.writeln('Use an isolated ventio_host_test database and set '
        'VENTIO_ALLOW_DATABASE_TESTS=yes.');
    exitCode = 2;
    return;
  }
  final conn = await pg.Connection.openFromUrl(url);
  final other = await pg.Connection.openFromUrl(url);
  final scope = 'durable-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  var assertions = 0;
  void check(bool value, String label) {
    if (!value) throw StateError('FAIL: $label');
    assertions++;
    stdout.writeln('PASS: $label');
  }

  try {
    await PostgresMigrationRunner(conn, Directory('../../migrations/postgres'))
        .apply();
    final prototype = bootstrapMaintenancePrototype('../../spec/v1.2');
    final modules = prototype.modules;
    final docTypes = prototype.docTypes;
    final maintenanceJson = loadJsonFile(
        '../../spec/v1.2/examples/create_maintenance_command.json');
    final inspectionPath = '../../fixtures/inspection';
    modules.registerTrustedCapability(
        Capability.fromJson(loadJsonFile('$inspectionPath/capability.json')));
    DeclarativeModuleInstaller(
            modules: modules, docTypes: docTypes, english: prototype.english)
        .install(
      manifestJson: loadJsonFile('$inspectionPath/manifest.json'),
      docTypeJsons: [loadJsonFile('$inspectionPath/doctype.json')],
      englishCatalog:
          loadJsonFile('$inspectionPath/localization/en.inspection.json'),
    );
    DurableCommandHost host(pg.Connection connection) {
      final result = DurableCommandHost(
          connection: connection, modules: modules, docTypes: docTypes);
      result.registerTrustedCreateBinding(const TrustedCommandBinding(
          'maintenance.create', 1, 'MaintenanceRequest'));
      result.registerTrustedCreateBinding(const TrustedCommandBinding(
          'inspection.create', 1, 'EquipmentInspection'));
      return result;
    }

    final firstHost = host(conn);
    final first = _command(maintenanceJson, scope, record: 'maintenance-1');
    final principal = _principal(first);
    final received = await firstHost.execute(first, principal);
    check(received['status'] == 'ACCEPTED', 'First command is committed');
    check(received['scopeCursor'] == null,
        'No unsafe commit-order cursor exposed');
    check(await _count(conn, 'ventio_records', scope) == 1,
        'Business record was committed');
    check(await _count(conn, 'ventio_command_journal', scope) == 1,
        'Receipt journal was committed');
    check(await _count(conn, 'ventio_audit_entries', scope) == 1,
        'Audit was committed');
    check(await _count(conn, 'ventio_outbox', scope) == 1,
        'Outbox was committed');

    final retry = await firstHost.execute(first, principal);
    check(canonicalJson(retry) == canonicalJson(received),
        'Identical retry returns saved receipt');
    check(
        await _count(conn, 'ventio_records', scope) == 1 &&
            await _count(conn, 'ventio_audit_entries', scope) == 1 &&
            await _count(conn, 'ventio_outbox', scope) == 1,
        'Retry does not duplicate any effect');
    final secondHost = host(other);
    final replay = await secondHost.execute(first, principal);
    check(canonicalJson(replay) == canonicalJson(received),
        'Independent Host instance replays persisted receipt');

    final sameIdDifferentBody = _command(maintenanceJson, scope,
        id: first.commandId, record: 'maintenance-modified');
    check(
        (await firstHost.execute(
                sameIdDifferentBody, principal))['reasonCode'] ==
            'COMMAND_ID_REUSED',
        'Reusing a command ID with different data is rejected');
    check(
        (await firstHost.execute(
                first, _principal(first, permission: false)))['reasonCode'] ==
            'PERMISSION_DENIED',
        'Permission is rechecked even for stored receipts');
    final crossTenant = _command(maintenanceJson, 'different-tenant',
        id: first.commandId, record: 'forbidden');
    check(
        (await firstHost.execute(crossTenant, principal))['reasonCode'] ==
            'SCOPE_DENIED',
        'Cross-tenant command is denied before reading journal');

    final duplicate = _command(maintenanceJson, scope, record: 'maintenance-1');
    check(
        (await firstHost.execute(
                duplicate, _principal(duplicate)))['reasonCode'] ==
            'RECORD_ALREADY_EXISTS',
        'A different command cannot duplicate a record');
    check(await _count(conn, 'ventio_command_journal', scope) == 1,
        'Rejected record conflict does not persist a journal reservation');
    final badJson = Map<String, dynamic>.from(maintenanceJson);
    badJson['payload'] = {'unknownProperty': 123};
    final invalid = _command(badJson, scope, record: 'invalid');
    check(
        (await firstHost.execute(invalid, _principal(invalid)))['reasonCode'] ==
            'INVALID_PAYLOAD',
        'Invalid DocType payload is rejected');
    check(await _count(conn, 'ventio_records', scope) == 1,
        'Invalid payload leaves no business record');

    final dependent = _command(maintenanceJson, scope,
        record: 'dependent', dependencies: [first.commandId]);
    check(
        (await firstHost.execute(dependent, _principal(dependent)))['status'] ==
            'ACCEPTED',
        'Accepted dependencies permit later commands');
    final pending = _command(maintenanceJson, scope,
        record: 'pending', dependencies: [_nextId()]);
    check(
        (await firstHost.execute(pending, _principal(pending)))['status'] ==
            'RETRY_LATER',
        'Missing dependencies return retry later');

    final inspectionJson = loadJsonFile('$inspectionPath/create_command.json');
    final inspection = _command(inspectionJson, scope, record: 'inspection-1');
    check(
        (await secondHost.execute(
                inspection, _principal(inspection)))['status'] ==
            'ACCEPTED',
        'A separate business module uses the same transaction engine');

    final failCommand = _command(maintenanceJson, scope, record: 'rollback');
    final failingHost = DurableCommandHost(
        connection: conn,
        modules: modules,
        docTypes: docTypes,
        testFaultInjector: (stage) {
          if (stage == 'before_commit')
            throw StateError('Injected crash before commit');
        });
    failingHost.registerTrustedCreateBinding(const TrustedCommandBinding(
        'maintenance.create', 1, 'MaintenanceRequest'));
    var threw = false;
    try {
      await failingHost.execute(failCommand, _principal(failCommand));
    } on StateError {
      threw = true;
    }
    check(threw, 'Injected failure interrupts command acceptance');
    check(
        (await PostgresRecordRepository(conn).find(
                RecordScope(
                    tenantId: scope,
                    companyId: 'test-company',
                    branchId: 'test-branch'),
                docType: 'MaintenanceRequest',
                recordId: 'rollback')) ==
            null,
        'Failed transaction rolls back the record');
    check(
        await _count(conn, 'ventio_command_journal', scope) == 3 &&
            await _count(conn, 'ventio_audit_entries', scope) == 3 &&
            await _count(conn, 'ventio_outbox', scope) == 3,
        'Failed transaction rolls back journal, audit and outbox');
    check(
        (await firstHost.execute(
                failCommand, _principal(failCommand)))['status'] ==
            'ACCEPTED',
        'Same command can safely retry after transaction rollback');

    final concurrent = _command(maintenanceJson, scope, record: 'concurrent-1');
    final parallel = await Future.wait([
      firstHost.execute(concurrent, _principal(concurrent)),
      secondHost.execute(concurrent, _principal(concurrent)),
    ]);
    check(canonicalJson(parallel[0]) == canonicalJson(parallel[1]),
        'Concurrent identical retries receive one committed receipt');
    final competingA =
        _command(maintenanceJson, scope, record: 'shared-record');
    final competingB =
        _command(maintenanceJson, scope, record: 'shared-record');
    final competing = await Future.wait([
      firstHost.execute(competingA, _principal(competingA)),
      secondHost.execute(competingB, _principal(competingB)),
    ]);
    check(
        competing.where((result) => result['status'] == 'ACCEPTED').length ==
                1 &&
            competing
                    .where((result) => result['status'] == 'CONFLICT')
                    .length ==
                1,
        'Concurrent distinct commands cannot create the same record twice');
    check(
        await _count(conn, 'ventio_records', scope) == 6 &&
            await _count(conn, 'ventio_command_journal', scope) == 6 &&
            await _count(conn, 'ventio_audit_entries', scope) == 6 &&
            await _count(conn, 'ventio_outbox', scope) == 6,
        'Record, journal, audit and outbox counts agree after concurrency');
    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    for (final table in [
      'ventio_outbox',
      'ventio_audit_entries',
      'ventio_command_journal',
      'ventio_records',
    ]) {
      await conn.execute(
          pg.Sql.named('DELETE FROM $table WHERE tenant_id = @tenant'),
          parameters: {'tenant': scope});
    }
    await other.close();
    await conn.close();
  }
}
