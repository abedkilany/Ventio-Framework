import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host/ventio_host.dart';
import 'package:ventio_postgres/ventio_postgres.dart';

int _counter = 0;
String _nextId() =>
    '00000000-0000-4000-8000-${(++_counter).toString().padLeft(12, '0')}';

CommandEnvelope _command(
  Map<String, dynamic> source,
  String tenant, {
  String? id,
  String? record,
  List<String>? dependencies,
  String? company,
  String? branch,
}) {
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
              'inspection.read',
            }
          : <String>{},
    );

Future<int> _count(
  pg.Connection connection,
  String table,
  String tenant,
) async {
  final rows = await connection.execute(
    pg.Sql.named('SELECT count(*) FROM $table WHERE tenant_id = @tenant'),
    parameters: {'tenant': tenant},
  );
  return rows.single[0] as int;
}

Future<bool> _hasRecord(
  pg.Connection connection, {
  required String tenant,
  required String company,
  required String branch,
  required String module,
  required String docType,
  required String record,
}) async {
  final rows = await connection.execute(
    pg.Sql.named('''
      SELECT record_id FROM ventio_records
      WHERE tenant_id = @tenant AND company_id = @company
        AND branch_id = @branch AND module_id = @module
        AND doc_type = @doctype AND record_id = @record
    '''),
    parameters: {
      'tenant': tenant,
      'company': company,
      'branch': branch,
      'module': module,
      'doctype': docType,
      'record': record,
    },
  );
  return rows.isNotEmpty;
}

Future<void> main() async {
  final url = Platform.environment['VENTIO_TEST_DATABASE_URL'];
  final permitted = Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'];
  if (url == null ||
      url.isEmpty ||
      permitted != 'yes' ||
      Uri.parse(
            url,
          ).pathSegments.where((segment) => segment.isNotEmpty).lastOrNull !=
          'ventio_host_test') {
    stderr.writeln(
      'Use an isolated ventio_host_test database and set '
      'VENTIO_ALLOW_DATABASE_TESTS=yes.',
    );
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
    await PostgresMigrationRunner(
      conn,
      Directory('../../migrations/postgres'),
    ).apply();
    final prototype = bootstrapMaintenancePrototype('../../spec/v1.2');
    final modules = prototype.modules;
    final docTypes = prototype.docTypes;
    final maintenanceJson = loadJsonFile(
      '../../spec/v1.2/examples/create_maintenance_command.json',
    );
    final inspectionPath = '../../fixtures/inspection';
    modules.registerTrustedCapability(
      Capability.fromJson(loadJsonFile('$inspectionPath/capability.json')),
    );
    final inspectionDocType = loadJsonFile('$inspectionPath/doctype.json');
    (inspectionDocType['fields'] as List).addAll([
      {
        'name': 'relatedInspection',
        'type': 'reference',
        'referenceTo': 'EquipmentInspection',
        'required': false,
        'label': 'Related inspection',
        'labelKey': 'inspection.record.related_inspection',
      },
      {
        'name': 'feeRate',
        'type': 'decimal',
        'required': false,
        'precision': 2,
        'label': 'Fee rate',
        'labelKey': 'inspection.record.fee_rate',
      },
      {
        'name': 'approvalStatus',
        'type': 'text',
        'required': false,
        'maxLength': 40,
        'default': 'Pending',
        'readOnly': true,
        'label': 'Approval status',
        'labelKey': 'inspection.record.approval_status',
        'description': 'Managed by the Host.',
        'descriptionKey': 'inspection.record.approval_status_description',
      },
    ]);
    final inspectionCatalog =
        loadJsonFile('$inspectionPath/localization/en.inspection.json')
          ..['inspection.record.fee_rate'] = 'Fee rate'
          ..['inspection.record.approval_status'] = 'Approval status'
          ..['inspection.record.approval_status_description'] =
              'Managed by the Host.'
          ..['inspection.record.related_inspection'] = 'Related inspection';
    DeclarativeModuleInstaller(
      modules: modules,
      docTypes: docTypes,
      english: prototype.english,
    ).install(
      manifestJson: loadJsonFile('$inspectionPath/manifest.json'),
      docTypeJsons: [inspectionDocType],
      englishCatalog: inspectionCatalog,
    );
    DurableCommandHost host(pg.Connection connection) {
      final result = DurableCommandHost(
        connection: connection,
        modules: modules,
        docTypes: docTypes,
      );
      result.registerTrustedCreateBinding(
        const TrustedCommandBinding(
          'maintenance.create',
          1,
          'MaintenanceRequest',
        ),
      );
      result.registerTrustedCreateBinding(
        const TrustedCommandBinding(
          'inspection.create',
          1,
          'EquipmentInspection',
        ),
      );
      return result;
    }

    final firstHost = host(conn);
    final first = _command(maintenanceJson, scope, record: 'maintenance-1');
    final principal = _principal(first);
    final received = await firstHost.execute(first, principal);
    check(received['status'] == 'ACCEPTED', 'First command is committed');
    check(
      received['scopeCursor'] == 'scope-v1-1',
      'The first accepted command exposes the first scope cursor',
    );
    final storedCursor = await conn.execute(
      pg.Sql.named('''
        SELECT scope_cursor, receipt->>'scopeCursor' AS receipt_cursor
        FROM ventio_command_journal
        WHERE tenant_id = @tenant AND command_id = @command
      '''),
      parameters: {'tenant': scope, 'command': first.commandId},
    );
    check(
      storedCursor.single.toColumnMap()['scope_cursor'] == 1 &&
          storedCursor.single.toColumnMap()['receipt_cursor'] == 'scope-v1-1',
      'The indexed numeric cursor matches its durable receipt',
    );
    check(
      await _count(conn, 'ventio_records', scope) == 1,
      'Business record was committed',
    );
    check(
      await _count(conn, 'ventio_command_journal', scope) == 1,
      'Receipt journal was committed',
    );
    check(
      await _count(conn, 'ventio_audit_entries', scope) == 1,
      'Audit was committed',
    );
    check(
      await _count(conn, 'ventio_outbox', scope) == 1,
      'Outbox was committed',
    );

    final retry = await firstHost.execute(first, principal);
    check(
      canonicalJson(retry) == canonicalJson(received),
      'Identical retry returns saved receipt',
    );
    check(
      await _count(conn, 'ventio_records', scope) == 1 &&
          await _count(conn, 'ventio_audit_entries', scope) == 1 &&
          await _count(conn, 'ventio_outbox', scope) == 1,
      'Retry does not duplicate any effect',
    );
    final secondHost = host(other);
    final replay = await secondHost.execute(first, principal);
    check(
      canonicalJson(replay) == canonicalJson(received),
      'Independent Host instance replays persisted receipt',
    );

    final sameIdDifferentBody = _command(
      maintenanceJson,
      scope,
      id: first.commandId,
      record: 'maintenance-modified',
    );
    check(
      (await firstHost.execute(sameIdDifferentBody, principal))['reasonCode'] ==
          'COMMAND_ID_REUSED',
      'Reusing a command ID with different data is rejected',
    );
    check(
      (await firstHost.execute(
            first,
            _principal(first, permission: false),
          ))['reasonCode'] ==
          'PERMISSION_DENIED',
      'Permission is rechecked even for stored receipts',
    );
    final crossTenant = _command(
      maintenanceJson,
      'different-tenant',
      id: first.commandId,
      record: 'forbidden',
    );
    check(
      (await firstHost.execute(crossTenant, principal))['reasonCode'] ==
          'SCOPE_DENIED',
      'Cross-tenant command is denied before reading journal',
    );

    final duplicate = _command(maintenanceJson, scope, record: 'maintenance-1');
    check(
      (await firstHost.execute(
            duplicate,
            _principal(duplicate),
          ))['reasonCode'] ==
          'RECORD_ALREADY_EXISTS',
      'A different command cannot duplicate a record',
    );
    check(
      await _count(conn, 'ventio_command_journal', scope) == 1,
      'Rejected record conflict does not persist a journal reservation',
    );
    final badJson = Map<String, dynamic>.from(maintenanceJson);
    badJson['payload'] = {'unknownProperty': 123};
    final invalid = _command(badJson, scope, record: 'invalid');
    check(
      (await firstHost.execute(invalid, _principal(invalid)))['reasonCode'] ==
          'INVALID_PAYLOAD',
      'Invalid DocType payload is rejected',
    );
    check(
      await _count(conn, 'ventio_records', scope) == 1,
      'Invalid payload leaves no business record',
    );

    final dependent = _command(
      maintenanceJson,
      scope,
      record: 'dependent',
      dependencies: [first.commandId],
    );
    final dependentReceipt = await firstHost.execute(
      dependent,
      _principal(dependent),
    );
    check(
      dependentReceipt['status'] == 'ACCEPTED',
      'Accepted dependencies permit later commands',
    );
    check(
      dependentReceipt['scopeCursor'] == 'scope-v1-2',
      'The accepted scope cursor advances in commit order',
    );
    check(
      canonicalJson(
            await firstHost.execute(dependent, _principal(dependent)),
          ) ==
          canonicalJson(dependentReceipt),
      'A successful retry retains its original scope cursor',
    );
    final pending = _command(
      maintenanceJson,
      scope,
      record: 'pending',
      dependencies: [_nextId()],
    );
    check(
      (await firstHost.execute(pending, _principal(pending)))['status'] ==
          'RETRY_LATER',
      'Missing dependencies return retry later',
    );

    final inspectionJson = loadJsonFile('$inspectionPath/create_command.json');
    final inspection = _command(inspectionJson, scope, record: 'inspection-1');
    final inspectionReceipt = await secondHost.execute(
      inspection,
      _principal(inspection),
    );
    check(
      inspectionReceipt['status'] == 'ACCEPTED',
      'A separate business module uses the same transaction engine',
    );
    final storedInspection = await conn.execute(
      pg.Sql.named('''
        SELECT record_data->>'approvalStatus' AS approval_status
        FROM ventio_records
        WHERE tenant_id = @tenant AND module_id = @module
          AND doc_type = @doctype AND record_id = @record
      '''),
      parameters: {
        'tenant': scope,
        'module': 'com.ventio.inspection',
        'doctype': 'EquipmentInspection',
        'record': inspection.aggregateId,
      },
    );
    check(
      storedInspection.single.toColumnMap()['approval_status'] == 'Pending',
      'PostgreSQL Host stores the declared default for an omitted field',
    );
    final precisionJson = Map<String, dynamic>.from(inspectionJson)
      ..['payload'] = Map<String, dynamic>.from(
        inspectionJson['payload'] as Map<String, dynamic>,
      )
      ..['payload']['feeRate'] = 1.234;
    final invalidPrecision = _command(
      precisionJson,
      scope,
      record: 'inspection-invalid-precision',
    );
    check(
      (await secondHost.execute(
            invalidPrecision,
            _principal(invalidPrecision),
          ))['reasonCode'] ==
          'INVALID_PAYLOAD',
      'PostgreSQL Host rejects a decimal outside its declared precision',
    );
    final readOnlyJson = Map<String, dynamic>.from(inspectionJson)
      ..['payload'] = Map<String, dynamic>.from(
        inspectionJson['payload'] as Map<String, dynamic>,
      )
      ..['payload']['approvalStatus'] = 'Approved';
    final readOnlyOverride = _command(
      readOnlyJson,
      scope,
      record: 'inspection-readonly-override',
    );
    check(
      (await secondHost.execute(
            readOnlyOverride,
            _principal(readOnlyOverride),
          ))['reasonCode'] ==
          'READ_ONLY_FIELD',
      'PostgreSQL Host rejects a client override of a read-only field',
    );
    check(
      inspectionReceipt['scopeCursor'] == 'scope-v1-3',
      'The cursor is shared by accepted commands across modules in one scope',
    );

    final validReferenceJson = Map<String, dynamic>.from(inspectionJson)
      ..['payload'] = Map<String, dynamic>.from(
        inspectionJson['payload'] as Map<String, dynamic>,
      )
      ..['payload']['relatedInspection'] = inspection.aggregateId;
    final validReference = _command(
      validReferenceJson,
      scope,
      record: 'inspection-with-reference',
    );
    check(
      (await secondHost.execute(
            validReference,
            _principal(validReference),
          ))['status'] ==
          'ACCEPTED',
      'PostgreSQL Host accepts a reference in the same module and exact scope',
    );

    Future<void> rejectsReferenceTo(
      String targetId, {
      required String label,
    }) async {
      final invalidReferenceJson = Map<String, dynamic>.from(inspectionJson)
        ..['payload'] = Map<String, dynamic>.from(
          inspectionJson['payload'] as Map<String, dynamic>,
        )
        ..['payload']['relatedInspection'] = targetId;
      final invalidReference = _command(
        invalidReferenceJson,
        scope,
        record: 'inspection-invalid-reference-${_counter}',
      );
      final response = await secondHost.execute(
        invalidReference,
        _principal(invalidReference),
      );
      check(
        response['reasonCode'] == 'INVALID_REFERENCE' &&
            !await _hasRecord(
              conn,
              tenant: scope,
              company: invalidReference.companyId,
              branch: invalidReference.branchId,
              module: 'com.ventio.inspection',
              docType: 'EquipmentInspection',
              record: invalidReference.aggregateId,
            ),
        label,
      );
    }

    await rejectsReferenceTo(
      'missing-inspection',
      label:
          'PostgreSQL Host rejects missing references without storing the record',
    );

    final otherBranch = _command(
      inspectionJson,
      scope,
      record: 'inspection-other-branch',
      branch: 'other-branch',
    );
    check(
      (await secondHost.execute(
            otherBranch,
            _principal(otherBranch),
          ))['status'] ==
          'ACCEPTED',
      'PostgreSQL Host stores the reference target in another branch',
    );
    await rejectsReferenceTo(
      otherBranch.aggregateId,
      label: 'PostgreSQL Host rejects a cross-branch reference',
    );

    final otherCompany = _command(
      inspectionJson,
      scope,
      record: 'inspection-other-company',
      company: 'other-company',
    );
    check(
      (await secondHost.execute(
            otherCompany,
            _principal(otherCompany),
          ))['status'] ==
          'ACCEPTED',
      'PostgreSQL Host stores the reference target in another company',
    );
    await rejectsReferenceTo(
      otherCompany.aggregateId,
      label: 'PostgreSQL Host rejects a cross-company reference',
    );

    final otherTenant = _command(
      inspectionJson,
      'other-tenant',
      record: 'inspection-other-tenant',
    );
    check(
      (await secondHost.execute(
            otherTenant,
            _principal(otherTenant),
          ))['status'] ==
          'ACCEPTED',
      'PostgreSQL Host stores the reference target in another tenant',
    );
    await rejectsReferenceTo(
      otherTenant.aggregateId,
      label: 'PostgreSQL Host rejects a cross-tenant reference',
    );

    final failCommand = _command(maintenanceJson, scope, record: 'rollback');
    final journalCountBeforeFailure =
        await _count(conn, 'ventio_command_journal', scope);
    final auditCountBeforeFailure =
        await _count(conn, 'ventio_audit_entries', scope);
    final outboxCountBeforeFailure =
        await _count(conn, 'ventio_outbox', scope);
    final failingHost = DurableCommandHost(
      connection: conn,
      modules: modules,
      docTypes: docTypes,
      testFaultInjector: (stage) {
        if (stage == 'before_commit')
          throw StateError('Injected crash before commit');
      },
    );
    failingHost.registerTrustedCreateBinding(
      const TrustedCommandBinding(
        'maintenance.create',
        1,
        'MaintenanceRequest',
      ),
    );
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
              branchId: 'test-branch',
            ),
            moduleId: 'com.ventio.maintenance',
            docType: 'MaintenanceRequest',
            recordId: 'rollback',
          )) ==
          null,
      'Failed transaction rolls back the record',
    );
    check(
      await _count(conn, 'ventio_command_journal', scope) ==
              journalCountBeforeFailure &&
          await _count(conn, 'ventio_audit_entries', scope) ==
              auditCountBeforeFailure &&
          await _count(conn, 'ventio_outbox', scope) ==
              outboxCountBeforeFailure,
      'Failed transaction rolls back journal, audit and outbox',
    );
    final retryAfterRollback = await firstHost.execute(
      failCommand,
      _principal(failCommand),
    );
    check(
      retryAfterRollback['status'] == 'ACCEPTED',
      'Same command can safely retry after transaction rollback',
    );
    check(
      retryAfterRollback['scopeCursor'] == 'scope-v1-5',
      'A rolled-back transaction does not consume a cursor',
    );

    final concurrent = _command(maintenanceJson, scope, record: 'concurrent-1');
    final parallel = await Future.wait([
      firstHost.execute(concurrent, _principal(concurrent)),
      secondHost.execute(concurrent, _principal(concurrent)),
    ]);
    check(
      canonicalJson(parallel[0]) == canonicalJson(parallel[1]),
      'Concurrent identical retries receive one committed receipt',
    );
    final competingA = _command(
      maintenanceJson,
      scope,
      record: 'shared-record',
    );
    final competingB = _command(
      maintenanceJson,
      scope,
      record: 'shared-record',
    );
    final competing = await Future.wait([
      firstHost.execute(competingA, _principal(competingA)),
      secondHost.execute(competingB, _principal(competingB)),
    ]);
    check(
      competing.where((result) => result['status'] == 'ACCEPTED').length == 1 &&
          competing.where((result) => result['status'] == 'CONFLICT').length ==
              1,
      'Concurrent distinct commands cannot create the same record twice',
    );
    check(
      await _count(conn, 'ventio_records', scope) == 9 &&
          await _count(conn, 'ventio_command_journal', scope) == 9 &&
          await _count(conn, 'ventio_audit_entries', scope) == 9 &&
          await _count(conn, 'ventio_outbox', scope) == 9,
      'Record, journal, audit and outbox counts agree after concurrency',
    );
    final committedCursors = await conn.execute(
      pg.Sql.named('''
        SELECT array_agg(scope_cursor ORDER BY scope_cursor)
        FROM ventio_command_journal
        WHERE tenant_id = @tenant AND company_id = 'test-company'
          AND branch_id = 'test-branch' AND scope_cursor IS NOT NULL
      '''),
      parameters: {'tenant': scope},
    );
    check(
      canonicalJson(committedCursors.single[0]) == '[1,2,3,4,5,6,7]',
      'Only committed accepted commands advance the durable cursor sequence',
    );
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
        parameters: {'tenant': scope},
      );
    }
    await other.close();
    await conn.close();
  }
}
