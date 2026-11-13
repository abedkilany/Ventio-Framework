import 'dart:async';
import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

import 'authentication.dart';
import 'extension_packages.dart';
import 'identity_store.dart';
import 'persistent_identity.dart';
import 'postgres_connections.dart';
import 'recovery_authority.dart';
import 'role_administration.dart';

abstract interface class AuthoritativeWave2Gateway {
  Future<Map<String, dynamic>> handle(
    String action,
    Map<String, dynamic> request,
    AuthenticatedSession session,
  );
}

/// Thin orchestration over existing authoritative query/command paths. The
/// PostgreSQL functions reauthorize scope and protect private control state.
class PostgresWave2Gateway implements AuthoritativeWave2Gateway {
  PostgresWave2Gateway({
    required this.runtimePool,
    required this.administrationPool,
    required this.admission,
    required this.packages,
    required this.records,
  });
  final pg.Pool<dynamic> runtimePool;
  final pg.Pool<dynamic> administrationPool;
  final RecoveryAuthority admission;
  final ExtensionPackageGateway packages;
  final PostgresExtensionRecordQueryGateway records;

  @override
  Future<Map<String, dynamic>> handle(
    String action,
    Map<String, dynamic> request,
    AuthenticatedSession session,
  ) async {
    final digest = session.credentialDigest;
    if (digest == null) return _denied;
    if (request['contractVersion'] != wave2ContractVersion) {
      throw const ContractError(
        'UNSUPPORTED_VERSION',
        'Unsupported Wave 2 contract.',
      );
    }
    final company = requireString(request, 'companyId');
    final branch = requireString(request, 'branchId');
    if (!session.principal.hasScope(company, branch)) return _denied;
    final common = <String>{'contractVersion', 'companyId', 'branchId'};
    final parameters = <String, dynamic>{
      'digest': digest,
      'company': company,
      'branch': branch,
    };
    switch (action) {
      case 'definitions/list':
        wave2Keys(request, {...common, 'kind'});
        parameters['kind'] = requireString(request, 'kind');
        return _runtime(
          'SELECT ventio_security.wave2_definitions(@digest,@company,@branch,@kind)::text',
          parameters,
        );
      case 'definitions/save':
        wave2Keys(request, {
          ...common,
          'kind',
          'id',
          'expectedRevision',
          'requestId',
          'body',
        });
        final kind = requireString(request, 'kind');
        final body = requireMap(request['body'], 'body');
        validateWave2Definition(kind, body);
        if (kind == 'customization') {
          final overlay = MetadataCustomization.fromJson(body);
          final approved = await packages.readApproved(
            session: session,
            companyId: company,
            branchId: branch,
            moduleId: overlay.moduleId,
            version: overlay.moduleVersion,
          );
          if (approved['status'] != 'APPROVED' ||
              approved['packageSha256'] != overlay.baseSha256) {
            return const {
              'status': 'CONFLICT',
              'reasonCode': 'CUSTOMIZATION_BASE_CHANGED',
            };
          }
          overlay.merge(
            ExtensionBundle.fromJson(
              requireMap(approved['package'], 'package'),
            ),
          );
        }
        parameters.addAll({
          'kind': kind,
          'id': requireString(request, 'id'),
          'expected': requireInt(request, 'expectedRevision'),
          'request': requireString(request, 'requestId'),
          'body': canonicalJson(body),
        });
        Map<String, dynamic>? result;
        await administrationPool.withConnection((connection) async {
          await verifyIdentityAdministrationConnection(connection);
          await connection.execute("SET statement_timeout = '15s'");
          await connection.execute("SET lock_timeout = '5s'");
          await admission.change(connection, (tx) async {
            result = await _function(
              tx,
              'SELECT ventio_security.wave2_save_definition(@digest,@company,@branch,@kind,@id,@expected,@request,CAST(@body AS jsonb))::text',
              parameters,
            );
          }, requireAdmissionProof: true);
        });
        return result!;
      case 'metadata/effective':
      case 'imports/preview':
        wave2Keys(request, {
          ...common,
          'moduleId',
          'moduleVersion',
          'docType',
          if (action == 'imports/preview') ...{
            'csv',
            'mapping',
            'recordIdHeader',
          },
        });
        return runtimePool.withConnection((connection) async {
          await verifyRuntimeConnection(connection);
          return connection.runTx((tx) async {
            await admission.admit(tx);
            final resolved = await const PostgresIdentityStore()
                .resolveExtensionRead(
                  tx,
                  digest,
                  companyId: company,
                  branchId: branch,
                  moduleId: requireString(request, 'moduleId'),
                  version: requireString(request, 'moduleVersion'),
                  docType: requireString(request, 'docType'),
                );
            if (resolved?.bundle == null) return _denied;
            final bundle = resolved!.bundle!;
            final definition = bundle.docTypes.singleWhere(
              (item) => item.name == request['docType'],
            );
            if (action == 'metadata/effective') {
              return {
                'status': 'METADATA',
                'package': bundle.toJson(),
                'baseSha256': resolved.basePackageSha256,
              };
            }
            final principal = resolved.principal;
            final permission = definition.permissions['create'];
            if (permission == null ||
                !principal.allowsInScope(permission, company, branch))
              return _denied;
            final allowed = definition.fields
                .where(
                  (field) =>
                      !field.readOnly &&
                      field.calculation == null &&
                      (field.writePermission == null ||
                          principal.allowsInScope(
                            field.writePermission!,
                            company,
                            branch,
                          )),
                )
                .map((field) => field.name)
                .toSet();
            final rawMapping = requireMap(request['mapping'], 'mapping');
            final rows = previewCsvImport(
              source: requireString(request, 'csv'),
              definition: definition,
              mapping: rawMapping.map(
                (key, value) =>
                    MapEntry(key, requireString({'value': value}, 'value')),
              ),
              recordIdHeader: requireString(request, 'recordIdHeader'),
              writableFields: allowed,
            );
            final existingRows = rows.isEmpty
                ? <String>{}
                : (await tx.execute(
                    pg.Sql.named('''
              SELECT record_id FROM public.ventio_records WHERE tenant_id=@tenant AND company_id=@company
                AND branch_id=@branch AND module_id=@module AND doc_type=@doc AND record_id=ANY(CAST(@ids AS text[]))
            '''),
                    parameters: {
                      'tenant': principal.tenantId,
                      'company': company,
                      'branch': branch,
                      'module': bundle.moduleId,
                      'doc': definition.name,
                      'ids': rows.map((row) => row.recordId).toList(),
                    },
                  )).map((row) => row[0] as String).toSet();
            final preview = rows
                .map(
                  (row) => existingRows.contains(row.recordId)
                      ? ImportPreviewRow(
                          row.rowNumber,
                          row.recordId,
                          row.values,
                          [...row.errors, 'RECORD_ALREADY_EXISTS'],
                        )
                      : row,
                )
                .toList();
            return {
              'status': 'PREVIEW',
              'baseSha256': resolved.basePackageSha256,
              'schemaVersion': definition.schemaVersion,
              'rows': preview.map((row) => row.toJson()).toList(),
              'validRows': preview.where((row) => row.errors.isEmpty).length,
            };
          });
        });
      case 'records/query':
      case 'exports/page':
        wave2Keys(request, {
          ...common,
          'moduleId',
          'moduleVersion',
          'docType',
          'columns',
          'search',
          'filters',
          'sortField',
          'descending',
          'cursor',
          'limit',
          if (action == 'records/query') 'recordId',
        });
        final columns = strings(requireList(request, 'columns'), 'columns');
        if (columns.isEmpty ||
            columns.length > 100 ||
            columns.toSet().length != columns.length) {
          throw const ContractError(
            'INVALID_EXPORT',
            'Export columns must be unique and bounded.',
          );
        }
        final result = await records.query(
          session: session,
          companyId: company,
          branchId: branch,
          moduleId: requireString(request, 'moduleId'),
          version: requireString(request, 'moduleVersion'),
          docType: requireString(request, 'docType'),
          recordId: optionalString(request, 'recordId'),
          search: request['search'] as String? ?? '',
          filters: requireMap(request['filters'] ?? {}, 'filters'),
          filterField: null,
          filterContains: '',
          sortField: optionalString(request, 'sortField'),
          descending: request['descending'] == true,
          cursor: optionalString(request, 'cursor'),
          offset: 0,
          limit: requireInt(request, 'limit', min: 1),
          includeCustomizations: true,
        );
        if (result['status'] != 'RECORDS') return result;
        final readable = strings(
          requireList(result, 'readableFields'),
          'readableFields',
        ).toSet();
        if (!columns.every(readable.contains)) return _denied;
        if (action == 'records/query') return result;
        final rows = requireList(
          result,
          'records',
        ).map((raw) => requireMap(raw, 'record'));
        final csv = StructuredCsv.encode([
          ['recordId', ...columns],
          for (final row in rows)
            [
              row['recordId'],
              for (final column in columns)
                requireMap(row['values'], 'values')[column],
            ],
        ]);
        return {
          'status': 'EXPORT',
          'csv': csv,
          'hasMore': result['hasMore'],
          'nextCursor': result['nextCursor'],
          'baseSha256': result['packageSha256'],
        };
      case 'jobs/submit':
        wave2Keys(request, {...common, 'jobId', 'commands'});
        final rawCommands = requireList(request, 'commands');
        if (rawCommands.isEmpty ||
            rawCommands.length > 25 ||
            utf8.encode(canonicalJson(rawCommands)).length > 49152) {
          throw const ContractError(
            'INVALID_JOB',
            'Jobs contain 1 to 25 commands within 48 KiB.',
          );
        }
        for (final raw in rawCommands) {
          final command = CommandEnvelope.fromJson(requireMap(raw, 'command'));
          if (!session.principal.withinScope(
                tenantId: command.tenantId,
                companyId: command.companyId,
                branchId: command.branchId,
                actorId: command.actorId,
                deviceId: command.deviceId,
              ) ||
              command.companyId != company ||
              command.branchId != branch ||
              command.dependsOn.isNotEmpty)
            return _denied;
          if (command.type == ExtensionBusinessOperationCommand.commandType) {
            ExtensionBusinessOperationCommand.fromEnvelope(command);
          } else {
            final parsed = ExtensionRecordCommand.fromEnvelope(command);
            if (parsed.operation == 'delete') return _denied;
          }
        }
        parameters.addAll({
          'job': requireString(request, 'jobId'),
          'commands': canonicalJson(rawCommands),
        });
        return _runtime(
          'SELECT ventio_security.wave2_submit_job(@digest,@company,@branch,@job,CAST(@commands AS jsonb))::text',
          parameters,
        );
      case 'jobs/list':
        wave2Keys(request, common);
        return _runtime(
          'SELECT ventio_security.wave2_jobs_list(@digest,@company,@branch)::text',
          parameters,
        );
      case 'jobs/cancel':
        wave2Keys(request, {...common, 'jobId'});
        parameters['job'] = requireString(request, 'jobId');
        return _runtime(
          'SELECT ventio_security.wave2_cancel_job(@digest,@company,@branch,@job)::text',
          parameters,
        );
      case 'history/list':
        wave2Keys(request, {
          ...common,
          'moduleId',
          'moduleVersion',
          'docType',
          'recordId',
        });
        parameters.addAll({
          'module': requireString(request, 'moduleId'),
          'version': requireString(request, 'moduleVersion'),
          'doc': requireString(request, 'docType'),
          'record': requireString(request, 'recordId'),
        });
        return _runtime(
          'SELECT ventio_security.wave2_history(@digest,@company,@branch,@module,@version,@doc,@record)::text',
          parameters,
        );
      default:
        throw const ContractError(
          'UNSUPPORTED_OPERATION',
          'Unsupported Wave 2 operation.',
        );
    }
  }

  Future<Map<String, dynamic>> _runtime(
    String sql,
    Map<String, dynamic> parameters,
  ) => withPostgresConnection(
    connect: null,
    pool: runtimePool,
    action: (connection) async {
      await verifyRuntimeConnection(connection);
      await connection.execute("SET statement_timeout = '15s'");
      return connection.runTx((tx) async {
        await admission.admit(tx);
        return _function(tx, sql, parameters);
      });
    },
  );
}

const _denied = {'status': 'REJECTED', 'reasonCode': 'PERMISSION_DENIED'};

Future<Map<String, dynamic>> _function(
  pg.Session tx,
  String sql,
  Map<String, dynamic> parameters,
) async {
  final rows = await tx.execute(pg.Sql.named(sql), parameters: parameters);
  final raw = rows.single[0];
  if (raw is! String) return _denied;
  return requireMap(jsonDecode(raw), 'function result');
}

/// Host-owned scheduler. Each tick claims one durable row, executes through
/// the existing reauthorizing command executor, and persists only a redacted
/// outcome under the fencing lease. It never reads the client's SQLite queue.
class Wave2JobWorker {
  Wave2JobWorker({
    required this.administrationPool,
    required this.admission,
    required this.executor,
    this.interval = const Duration(seconds: 3),
  });
  final pg.Pool<dynamic> administrationPool;
  final RecoveryAuthority admission;
  final PersistentCommandExecutor executor;
  final Duration interval;
  Timer? _timer;
  Future<void>? _pending;
  bool _closing = false;

  void start() {
    if (_closing || _timer != null)
      throw StateError('Worker already started or closed.');
    _timer = Timer.periodic(interval, (_) {
      if (_pending != null || _closing) return;
      _pending = _tick()
          .catchError((Object _) {
            // The durable lease expires and retries after infrastructure failure.
            // Never log commands, digests, raw database errors or business values.
          })
          .whenComplete(() => _pending = null);
    });
  }

  Future<void> close() async {
    _closing = true;
    _timer?.cancel();
    await _pending;
  }

  Future<void> _tick() async {
    final claim = await administrationPool.withConnection((connection) async {
      await verifyIdentityAdministrationConnection(connection);
      return connection.runTx((tx) async {
        await admission.admit(tx);
        final rows = await tx.execute(
          'SELECT ventio_security.wave2_claim_job()::text',
        );
        return rows.single[0] == null
            ? null
            : requireMap(jsonDecode(rows.single[0] as String), 'claim');
      });
    });
    if (claim == null) return;
    final identity = requireMap(claim['identity'], 'identity');
    final grants = <(String, String), Set<String>>{};
    for (final raw in requireList(identity, 'scopeGrants')) {
      final grant = requireMap(raw, 'grant');
      grants
          .putIfAbsent((
            requireString(grant, 'companyId'),
            requireString(grant, 'branchId'),
          ), () => {})
          .add(requireString(grant, 'permission'));
    }
    final principal = Principal(
      actorId: requireString(identity, 'actorId'),
      deviceId: requireString(identity, 'deviceId'),
      tenantId: requireString(identity, 'tenantId'),
      companyIds: grants.keys.map((key) => key.$1).toSet(),
      branchIds: grants.keys.map((key) => key.$2).toSet(),
      permissions: grants.values.expand((value) => value).toSet(),
      scopeGrants: grants.entries.map(
        (entry) => PrincipalScope(
          companyId: entry.key.$1,
          branchId: entry.key.$2,
          permissions: entry.value,
        ),
      ),
    );
    final command = CommandEnvelope.fromJson(
      requireMap(claim['command'], 'command'),
    );
    Map<String, dynamic> outcome;
    bool retry;
    try {
      final receipt = CommandReceipt.fromJson(
        await executor.execute(
          command,
          AuthenticatedSession.persistent(
            principal,
            requireString(claim, 'credentialDigest'),
          ),
          requireJobAuthorization: true,
        ),
      );
      outcome = {
        'commandId': command.commandId,
        'status': receipt.status,
        if (receipt.reasonCode != null) 'reasonCode': receipt.reasonCode,
      };
      retry = receipt.retryable;
    } catch (_) {
      outcome = {
        'commandId': command.commandId,
        'status': 'RETRY_LATER',
        'reasonCode': 'HOST_EXECUTION_UNAVAILABLE',
      };
      retry = true;
    }
    await administrationPool.withConnection((connection) async {
      await verifyIdentityAdministrationConnection(connection);
      await connection.runTx((tx) async {
        await admission.admit(tx);
        await tx.execute(
          pg.Sql.named(
            'SELECT ventio_security.wave2_finish_job(@tenant,@job,@lease,CAST(@outcome AS jsonb),@retry)',
          ),
          parameters: {
            'tenant': claim['tenantId'],
            'job': claim['jobId'],
            'lease': claim['leaseId'],
            'outcome': jsonEncode(outcome),
            'retry': retry,
          },
        );
      });
    });
  }
}
