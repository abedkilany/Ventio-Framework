import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host/ventio_host.dart';

import 'authentication.dart';
import 'host_api.dart';
import 'identity_store.dart';
import 'extension_records.dart';
import 'postgres_connections.dart';
import 'recovery_authority.dart';

/// Refuses owners, superusers, bypass roles, extra memberships and excess ACLs.
Future<void> verifyRuntimeConnection(pg.Connection connection) async {
  await connection.execute('SELECT ventio_security.assert_runtime()');
}

Future<void> _configure(pg.Connection connection) async {
  await verifyRuntimeConnection(connection);
  await connection.execute("SET statement_timeout = '15s'");
  await connection.execute("SET lock_timeout = '5s'");
}

String _recordQueryFingerprint({
  required String tenantId,
  required String companyId,
  required String branchId,
  required String moduleId,
  required String version,
  required String docType,
  required String search,
  required Map<String, dynamic> filters,
  required String? filterField,
  required String filterContains,
  required String? sortField,
  required bool descending,
  required int limit,
}) => sha256
    .convert(
      utf8.encode(
        canonicalJson({
          'tenantId': tenantId,
          'companyId': companyId,
          'branchId': branchId,
          'moduleId': moduleId,
          'version': version,
          'docType': docType,
          'search': search,
          'filters': filters,
          'filterField': filterField,
          'filterContains': filterContains,
          'sortField': sortField,
          'descending': descending,
          'limit': limit,
        }),
      ),
    )
    .toString();

Map<String, dynamic> _decodeRecordQueryCursor(
  String cursor,
  String fingerprint,
) {
  String decodeBase64Url(String value) {
    final remainder = value.length % 4;
    if (remainder == 1) throw const FormatException();
    final padded = '$value${'=' * ((4 - remainder) % 4)}';
    return utf8.decode(base64Url.decode(padded));
  }

  try {
    if (cursor.isEmpty ||
        cursor.length > 1024 * 1024 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(cursor)) {
      throw const FormatException();
    }
    final decoded = jsonDecode(decodeBase64Url(cursor)) as Map;
    final value = Map<String, dynamic>.from(decoded);
    if (value.keys.toSet().difference(const {
          'version',
          'fingerprint',
          'sortValue',
          'recordId',
        }).isNotEmpty ||
        value.length != 4 ||
        value['version'] != 1 ||
        value['fingerprint'] != fingerprint ||
        (value['sortValue'] != null &&
            (value['sortValue'] is! String ||
                ((value['sortValue'] as String).isNotEmpty &&
                    !RegExp(
                      r'^[A-Za-z0-9_-]+$',
                    ).hasMatch(value['sortValue'])))) ||
        value['recordId'] is! String ||
        (value['recordId'] as String).isEmpty ||
        (value['recordId'] as String).length > 128) {
      throw const FormatException();
    }
    if (value['sortValue'] is String) {
      value['sortValue'] = decodeBase64Url(value['sortValue'] as String);
    }
    return value;
  } on Object {
    throw const FormatException('Invalid or mismatched record cursor.');
  }
}

String _encodeRecordQueryCursor({
  required String fingerprint,
  required String? sortValue,
  required String recordId,
}) => base64Url
    .encode(
      utf8.encode(
        canonicalJson({
          'version': 1,
          'fingerprint': fingerprint,
          'sortValue': sortValue == null
              ? null
              : base64Url.encode(utf8.encode(sortValue)).replaceAll('=', ''),
          'recordId': recordId,
        }),
      ),
    )
    .replaceAll('=', '');

/// Resolves an opaque token from PostgreSQL on EVERY HTTP request. There is no
/// in-memory permission cache or development-identity fallback on DB failure.
class PersistentTokenAuthenticator implements PersistentHostAuthenticator {
  final Future<pg.Connection> Function()? connect;
  final pg.Pool<dynamic>? pool;
  final RecoveryAuthority? admission;
  const PersistentTokenAuthenticator({this.connect, this.pool, this.admission})
    : assert((connect == null) != (pool == null));

  @override
  Future<AuthenticatedSession?> authenticate(String token) async {
    if (!OpaqueToken.isValid(token)) return null;
    final digest = OpaqueToken.digest(token);
    return withPostgresConnection(
      connect: connect,
      pool: pool,
      action: (connection) async {
        await _configure(connection);
        final principal = await connection.runTx(
          (tx) async {
            await admission?.admit(tx);
            return const PostgresIdentityStore().resolve(tx, digest);
          },
          settings: pg.TransactionSettings(
            isolationLevel: pg.IsolationLevel.readCommitted,
          ),
        );
        if (principal == null) return null;
        return AuthenticatedSession.persistent(principal, digest);
      },
    );
  }
}

/// Identity and permissions are re-read and locked INSIDE the command's own
/// transaction, before journal access. This closes the authentication-to-command
/// race and applies equally to fresh commands and accepted-receipt retries.
class PersistentCommandExecutor implements AuthoritativeCommandExecutor {
  final Future<pg.Connection> Function()? connect;
  final pg.Pool<dynamic>? pool;
  final ModuleRegistry modules;
  final DocTypeRegistry docTypes;
  final List<TrustedCommandBinding> bindings;
  final RecoveryAuthority? admission;

  PersistentCommandExecutor({
    this.connect,
    this.pool,
    required this.modules,
    required this.docTypes,
    this.admission,
    required Iterable<TrustedCommandBinding> bindings,
  }) : bindings = List.unmodifiable(bindings),
       assert((connect == null) != (pool == null));

  @override
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session, {
    bool requireJobAuthorization = false,
  }) async {
    final digest = session.credentialDigest;
    if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      return CommandReceipt(
        commandId: command.commandId,
        status: 'REJECTED',
        reasonCode: 'AUTHENTICATION_REQUIRED',
      ).toJson();
    }
    return withPostgresConnection(
      connect: connect,
      pool: pool,
      action: (connection) async {
        await _configure(connection);
        final host = DurableCommandHost(
          connection: connection,
          modules: modules,
          docTypes: docTypes,
        );
        for (final binding in bindings) {
          host.registerTrustedCreateBinding(binding);
        }
        ExtensionBundleAuthorization? resolvedBundle;
        return host.executeAuthorized(
          command,
          (tx) async {
            await admission?.admit(tx);
            if (command.type == ExtensionRecordCommand.createType ||
                command.type == ExtensionRecordCommand.updateType ||
                command.type == ExtensionRecordCommand.deleteType ||
                command.type == ExtensionBusinessOperationCommand.commandType) {
              final resolved = await const PostgresIdentityStore()
                  .resolveExtensionCommand(tx, digest, command);
              if (resolved == null ||
                  (requireJobAuthorization &&
                      !resolved.principal.allowsInScope(
                        wave2JobsRunPermission,
                        command.companyId,
                        command.branchId,
                      )))
                return null;
              resolvedBundle = resolved.bundle != null
                  ? ExtensionBundleAuthorization.approved(
                      resolved.bundle!,
                      failureReasonCode: resolved.failureReasonCode,
                    )
                  : ExtensionBundleAuthorization.denied(
                      resolved.failureReasonCode ?? 'EXTENSION_NOT_APPROVED',
                    );
              return resolved.principal;
            }
            return const PostgresIdentityStore().resolve(
              tx,
              digest,
              command: command,
            );
          },
          resolveExtensionBundle: (_, __) async =>
              resolvedBundle ??
              const ExtensionBundleAuthorization.denied(
                'EXTENSION_NOT_APPROVED',
              ),
          admissionGuard: (tx, _) async {
            final result = await tx.execute(
              pg.Sql.named('''
              SELECT ventio_security.wave2_command_admission(@digest,@company,@branch,@job)
            '''),
              parameters: {
                'digest': digest,
                'company': command.companyId,
                'branch': command.branchId,
                'job': requireJobAuthorization,
              },
            );
            return result.single[0] as String?;
          },
        );
      },
    );
  }
}

/// Queries approved dynamic records under PostgreSQL RLS in a fresh
/// authenticated transaction. Filters and sort fields come only from the
/// approved DocType metadata; SQL identifiers are never interpolated.
class PostgresExtensionRecordQueryGateway
    implements AuthoritativeExtensionRecordQueryGateway {
  const PostgresExtensionRecordQueryGateway({
    this.connect,
    this.pool,
    this.admission,
  }) : assert((connect == null) != (pool == null));

  final Future<pg.Connection> Function()? connect;
  final pg.Pool<dynamic>? pool;
  final RecoveryAuthority? admission;

  @override
  Future<Map<String, dynamic>> query({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String moduleId,
    required String version,
    required String docType,
    String? recordId,
    required String search,
    required Map<String, dynamic> filters,
    required String? filterField,
    required String filterContains,
    required String? sortField,
    required bool descending,
    String? cursor,
    required int offset,
    required int limit,
    bool includeCustomizations = false,
  }) async {
    final digest = session.credentialDigest;
    if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      return const {
        'status': 'REJECTED',
        'reasonCode': 'AUTHENTICATION_REQUIRED',
      };
    }
    if (search.length > 256 ||
        filterContains.length > 256 ||
        offset < 0 ||
        offset > 1000000 ||
        limit < 1 ||
        limit > 50 ||
        (cursor != null &&
            (cursor.isEmpty || cursor.length > 1024 * 1024 || offset != 0)) ||
        filters.length > 10) {
      throw const FormatException('Invalid dynamic record query bounds.');
    }
    return withPostgresConnection(
      connect: connect,
      pool: pool,
      action: (connection) async {
        await _configure(connection);
        return await connection.runTx(
          (tx) async {
            await admission?.admit(tx);
            final resolved = await const PostgresIdentityStore()
                .resolveExtensionRead(
                  tx,
                  digest,
                  companyId: companyId,
                  branchId: branchId,
                  moduleId: moduleId,
                  version: version,
                  docType: docType,
                );
            if (resolved == null) {
              return const {
                'status': 'REJECTED',
                'reasonCode': 'AUTHENTICATION_REQUIRED',
              };
            }
            final bundle = resolved.bundle;
            if (bundle == null) {
              return {
                'status': 'REJECTED',
                'reasonCode':
                    resolved.failureReasonCode ?? 'EXTENSION_NOT_APPROVED',
              };
            }
            final principal = resolved.principal;
            if (!principal.withinScope(
              tenantId: principal.tenantId,
              companyId: companyId,
              branchId: branchId,
              actorId: principal.actorId,
              deviceId: principal.deviceId,
            )) {
              return const {'status': 'REJECTED', 'reasonCode': 'SCOPE_DENIED'};
            }
            final matches =
                (includeCustomizations ? bundle : resolved.baseBundle ?? bundle)
                    .docTypes
                    .where(
                      (definition) =>
                          definition.moduleId == moduleId &&
                          definition.name == docType,
                    );
            if (matches.length != 1) {
              return const {
                'status': 'REJECTED',
                'reasonCode': 'EXTENSION_NOT_APPROVED',
              };
            }
            final definition = matches.single;
            final permission = definition.permissions['read'];
            if (!definition.operations.contains('read') ||
                permission == null ||
                !principal.allowsInScope(permission, companyId, branchId)) {
              return const {
                'status': 'REJECTED',
                'reasonCode': 'PERMISSION_DENIED',
              };
            }
            bool allowsFieldPermission(String? fieldPermission) =>
                fieldPermission == null ||
                principal.allowsInScope(fieldPermission, companyId, branchId);
            final readableFields = definition.fields
                .where((field) => allowsFieldPermission(field.readPermission))
                .map((field) => field.name)
                .toSet();
            final updatePermission = definition.permissions['update'];
            final canUpdateDocType =
                definition.operations.contains('update') &&
                updatePermission != null &&
                principal.allowsInScope(updatePermission, companyId, branchId);
            final createPermission = definition.permissions['create'];
            final canCreateDocType =
                definition.operations.contains('create') &&
                createPermission != null &&
                principal.allowsInScope(createPermission, companyId, branchId);
            final writableFields = definition.fields
                .where(
                  (field) =>
                      canUpdateDocType &&
                      allowsFieldPermission(field.writePermission),
                )
                .map((field) => field.name)
                .toSet();
            final creatableFields = definition.fields
                .where(
                  (field) =>
                      canCreateDocType &&
                      allowsFieldPermission(field.writePermission),
                )
                .map((field) => field.name)
                .toSet();
            final fieldNames = definition.fields
                .map((field) => field.name)
                .toSet();
            if (filters.keys.any((field) => !fieldNames.contains(field)) ||
                (filterField != null && !fieldNames.contains(filterField)) ||
                (sortField != null && !fieldNames.contains(sortField)) ||
                filters.values.any(
                  (value) =>
                      value is Map ||
                      value is List ||
                      (value is String && value.length > 256),
                )) {
              throw const FormatException(
                'Filter and sort fields must belong to the approved DocType.',
              );
            }
            if (filters.keys.any((field) => !readableFields.contains(field)) ||
                (filterField != null &&
                    !readableFields.contains(filterField)) ||
                (sortField != null && !readableFields.contains(sortField))) {
              return const {
                'status': 'REJECTED',
                'reasonCode': 'PERMISSION_DENIED',
              };
            }
            final queryFingerprint = _recordQueryFingerprint(
              tenantId: principal.tenantId,
              companyId: companyId,
              branchId: branchId,
              moduleId: moduleId,
              version: version,
              docType: docType,
              search: search,
              filters: filters,
              filterField: filterField,
              filterContains: filterContains,
              sortField: sortField,
              descending: descending,
              limit: limit,
            );
            final cursorPosition = cursor == null
                ? null
                : _decodeRecordQueryCursor(cursor, queryFingerprint);
            final parameters = <String, Object?>{
              'tenant': principal.tenantId,
              'company': companyId,
              'branch': branchId,
              'module': moduleId,
              'doctype': docType,
              'sortField': sortField ?? '',
              'descending': descending,
              'offset': offset,
              'limit': limit + 1,
            };
            final conditions = <String>[];
            if (recordId != null) {
              parameters['recordId'] = recordId;
              conditions.add('record_id = @recordId');
            }
            final readableDefinitions = definition.fields
                .where((field) => readableFields.contains(field.name))
                .toList(growable: false);
            if (search.isNotEmpty && readableDefinitions.isNotEmpty) {
              parameters['search'] = search.toLowerCase();
              final searchClauses = <String>[];
              for (var index = 0; index < readableDefinitions.length; index++) {
                final fieldName = 'searchField$index';
                parameters[fieldName] = readableDefinitions[index].name;
                searchClauses.add(
                  "strpos(lower(coalesce(record_data ->> @$fieldName, '')), @search) > 0",
                );
              }
              conditions.add('(${searchClauses.join(' OR ')})');
            } else if (search.isNotEmpty) {
              conditions.add('false');
            }
            if (filterContains.isNotEmpty && filterField != null) {
              parameters['filterContainsField'] = filterField;
              parameters['filterContains'] = filterContains.toLowerCase();
              conditions.add(
                "strpos(lower(coalesce(record_data ->> @filterContainsField, '')), @filterContains) > 0",
              );
            }
            final sortedFilters = filters.keys.toList()..sort();
            for (var index = 0; index < sortedFilters.length; index++) {
              final fieldName = 'filterField$index';
              final valueName = 'filterValue$index';
              parameters[fieldName] = sortedFilters[index];
              parameters[valueName] = canonicalJson(
                filters[sortedFilters[index]],
              );
              conditions.add(
                'record_data @> jsonb_build_object('
                'CAST(@$fieldName AS text), CAST(@$valueName AS jsonb))',
              );
            }
            if (cursorPosition != null) {
              final cursorSortValue = cursorPosition['sortValue'] as String?;
              parameters['cursorRecordId'] =
                  cursorPosition['recordId'] as String;
              if (cursorSortValue == null) {
                conditions.add(
                  "record_data ->> @sortField IS NULL AND record_id > @cursorRecordId",
                );
              } else {
                parameters['cursorSortValue'] = cursorSortValue;
                conditions.add('''
                  ((record_data ->> @sortField IS NULL)
                   OR (record_data ->> @sortField = @cursorSortValue
                       AND record_id > @cursorRecordId)
                   OR (NOT @descending AND record_data ->> @sortField > @cursorSortValue)
                   OR (@descending AND record_data ->> @sortField < @cursorSortValue))
                ''');
              }
            }
            final queryClause = conditions.isEmpty
                ? ''
                : 'AND ${conditions.join(' AND ')}';
            // Bound serialized page bytes in PostgreSQL before transferring the
            // values to the Host process. The final HTTP limit remains a second
            // line of defense against JSON encoding overhead.
            parameters['maxRecordBytes'] = 512 * 1024;
            final rows = await tx.execute(
              pg.Sql.named('''
            WITH page AS (
              SELECT record_id, revision, updated_at, record_data,
                     record_data ->> @sortField AS sort_value
              FROM ventio_records
              WHERE tenant_id=@tenant AND company_id=@company AND branch_id=@branch
                AND module_id=@module AND doc_type=@doctype $queryClause
              ORDER BY
                CASE WHEN @descending THEN record_data ->> @sortField END DESC NULLS LAST,
                CASE WHEN NOT @descending THEN record_data ->> @sortField END ASC NULLS LAST,
                record_id ASC
              OFFSET @offset LIMIT @limit
            ), serialized_page AS (
              SELECT record_id, revision, updated_at,
                record_data::text AS record_json, sort_value
              FROM page
            ), bounded_page AS (
              SELECT *, sum(octet_length(record_json)) OVER () AS page_bytes
              FROM serialized_page
            )
            SELECT record_id, revision, updated_at::text AS updated_at,
              page_bytes,
              CASE WHEN page_bytes <= @maxRecordBytes
                THEN record_json ELSE NULL END AS record_json,
              sort_value
            FROM bounded_page
          '''),
              parameters: parameters,
            );
            if (rows.isNotEmpty && (rows.first[3] as int) > 512 * 1024) {
              return const {
                'status': 'REJECTED',
                'reasonCode': 'RECORD_PAGE_TOO_LARGE',
              };
            }
            final hasMore = rows.length > limit;
            final pageRows = rows.take(limit).toList(growable: false);
            final records = rows
                .take(limit)
                .map((row) {
                  final values = jsonDecode(row[4] as String);
                  if (values is! Map) {
                    throw const FormatException(
                      'Stored record JSON is invalid.',
                    );
                  }
                  return {
                    'recordId': row[0] as String,
                    'revision': row[1] as int,
                    'updatedAtUtc': row[2] as String,
                    'values': {
                      for (final fieldName in readableFields)
                        if (values.containsKey(fieldName))
                          fieldName: values[fieldName],
                    },
                  };
                })
                .toList(growable: false);
            final nextCursor = hasMore && pageRows.isNotEmpty
                ? _encodeRecordQueryCursor(
                    fingerprint: queryFingerprint,
                    sortValue: pageRows.last[5] as String?,
                    recordId: pageRows.last[0] as String,
                  )
                : null;
            return {
              'status': 'RECORDS',
              'packageSha256':
                  resolved.basePackageSha256 ??
                  sha256
                      .convert(utf8.encode(canonicalJson(bundle.toJson())))
                      .toString(),
              'readableFields': readableFields.toList()..sort(),
              'writableFields': writableFields.toList()..sort(),
              'creatableFields': creatableFields.toList()..sort(),
              'records': records,
              'hasMore': hasMore,
              'nextCursor': nextCursor,
            };
          },
          settings: pg.TransactionSettings(
            isolationLevel: pg.IsolationLevel.readCommitted,
          ),
        );
      },
    );
  }
}

class PostgresExtensionReportQueryGateway
    implements AuthoritativeExtensionReportQueryGateway {
  const PostgresExtensionReportQueryGateway({
    this.connect,
    this.pool,
    this.admission,
  }) : assert((connect == null) != (pool == null));

  final Future<pg.Connection> Function()? connect;
  final pg.Pool<dynamic>? pool;
  final RecoveryAuthority? admission;

  @override
  Future<Map<String, dynamic>> queryReport({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String moduleId,
    required String version,
    required String docType,
    required String reportId,
    required Map<String, dynamic> filters,
  }) async {
    final digest = session.credentialDigest;
    if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      return const {
        'status': 'REJECTED',
        'reasonCode': 'AUTHENTICATION_REQUIRED',
      };
    }
    if (filters.length > ReportDefinition.maxFilters ||
        filters.values.any(
          (value) =>
              value == null ||
              value is Map ||
              value is List ||
              (value is String && value.length > 256) ||
              (value is num && !value.isFinite),
        )) {
      throw const FormatException('Invalid report filter bounds.');
    }
    return withPostgresConnection(
      connect: connect,
      pool: pool,
      action: (connection) async {
        await _configure(connection);
        return connection.runTx(
          (tx) async {
            await admission?.admit(tx);
            final resolved = await const PostgresIdentityStore()
                .resolveExtensionRead(
                  tx,
                  digest,
                  companyId: companyId,
                  branchId: branchId,
                  moduleId: moduleId,
                  version: version,
                  docType: docType,
                );
            if (resolved == null) {
              return const {
                'status': 'REJECTED',
                'reasonCode': 'AUTHENTICATION_REQUIRED',
              };
            }
            final bundle = resolved.bundle;
            if (bundle == null) {
              return {
                'status': 'REJECTED',
                'reasonCode':
                    resolved.failureReasonCode ?? 'EXTENSION_NOT_APPROVED',
              };
            }
            final principal = resolved.principal;
            if (!principal.withinScope(
              tenantId: principal.tenantId,
              companyId: companyId,
              branchId: branchId,
              actorId: principal.actorId,
              deviceId: principal.deviceId,
            )) {
              return const {'status': 'REJECTED', 'reasonCode': 'SCOPE_DENIED'};
            }
            final matches = bundle.reports.where(
              (report) => report.id == reportId && report.docType == docType,
            );
            if (matches.length != 1) {
              return const {
                'status': 'REJECTED',
                'reasonCode': 'REPORT_NOT_FOUND',
              };
            }
            final report = matches.single;
            final definitions = bundle.docTypes.where(
              (type) => type.moduleId == moduleId && type.name == docType,
            );
            if (definitions.length != 1) {
              return const {
                'status': 'REJECTED',
                'reasonCode': 'REPORT_NOT_FOUND',
              };
            }
            final definition = definitions.single;
            final readPermission = definition.permissions['read'];
            if (!definition.operations.contains('read') ||
                readPermission == null ||
                !principal.allowsInScope(readPermission, companyId, branchId)) {
              return const {
                'status': 'REJECTED',
                'reasonCode': 'PERMISSION_DENIED',
              };
            }
            if (filters.keys.any(
              (field) => !report.filterFields.contains(field),
            )) {
              return const {
                'status': 'REJECTED',
                'reasonCode': 'INVALID_REPORT_FILTER',
              };
            }
            final fields = {
              for (final field in definition.fields) field.name: field,
            };
            final usedFields = <String>{
              if (report.groupBy != null) report.groupBy!,
              for (final field in filters.keys) field,
              for (final aggregate in report.aggregates)
                if (aggregate.operation == 'sum') aggregate.field!,
            };
            if (usedFields.any((name) {
              final permission = fields[name]?.readPermission;
              return permission != null &&
                  !principal.allowsInScope(permission, companyId, branchId);
            })) {
              return const {
                'status': 'REJECTED',
                'reasonCode': 'PERMISSION_DENIED',
              };
            }

            const maxRows = 10000;
            const maxProjectedBytes = 512 * 1024;
            final projectedFields = usedFields.toList()..sort();
            final parameters = <String, Object?>{
              'tenant': principal.tenantId,
              'company': companyId,
              'branch': branchId,
              'module': moduleId,
              'doctype': docType,
              'row_limit': maxRows + 1,
              'max_rows': maxRows,
              'max_bytes': maxProjectedBytes,
            };
            final aliases = <String, String>{};
            final projection = <String>[];
            for (var index = 0; index < projectedFields.length; index++) {
              final alias = 'value$index';
              aliases[projectedFields[index]] = alias;
              parameters['projection_key$index'] = alias;
              parameters['projection_field$index'] = projectedFields[index];
              projection
                ..add('CAST(@projection_key$index AS text)')
                ..add('record_data -> CAST(@projection_field$index AS text)');
            }
            final conditions = <String>[];
            final sortedFilters = filters.keys.toList()..sort();
            for (var index = 0; index < sortedFilters.length; index++) {
              parameters['filter_key$index'] = sortedFilters[index];
              parameters['filter_value$index'] = canonicalJson(
                filters[sortedFilters[index]],
              );
              conditions.add(
                'record_data @> jsonb_build_object('
                'CAST(@filter_key$index AS text), '
                'CAST(@filter_value$index AS jsonb))',
              );
            }
            final whereFilters = conditions.isEmpty
                ? ''
                : 'AND ${conditions.join(' AND ')}';
            final projected = projection.isEmpty
                ? "'{}'::jsonb"
                : 'jsonb_build_object(${projection.join(', ')})';
            final rows = await tx.execute(
              pg.Sql.named('''
                WITH matching AS MATERIALIZED (
                  SELECT $projected AS projected_values
                  FROM public.ventio_records
                  WHERE tenant_id=@tenant AND company_id=@company
                    AND branch_id=@branch AND module_id=@module
                    AND doc_type=@doctype AND deleted_at IS NULL
                    $whereFilters
                  LIMIT @row_limit
                ), statistics AS (
                  SELECT count(*)::bigint AS row_count,
                    coalesce(sum(octet_length(projected_values::text)),0)::bigint
                      AS projected_bytes
                  FROM matching
                )
                SELECT statistics.row_count, statistics.projected_bytes,
                  CASE WHEN statistics.row_count <= @max_rows
                         AND statistics.projected_bytes <= @max_bytes
                       THEN matching.projected_values::text
                       ELSE NULL END AS projected_json
                FROM statistics
                LEFT JOIN matching ON statistics.row_count <= @max_rows
                  AND statistics.projected_bytes <= @max_bytes
              '''),
              parameters: parameters,
            );
            if (rows.isEmpty) {
              throw StateError(
                'Report candidate query returned no statistics.',
              );
            }
            final rowCount = (rows.first[0] as int);
            final projectedBytes = (rows.first[1] as int);
            if (rowCount > maxRows || projectedBytes > maxProjectedBytes) {
              return const {
                'status': 'REJECTED',
                'reasonCode': 'REPORT_TOO_LARGE',
              };
            }
            final fieldScales = <String, int>{
              for (final aggregate in report.aggregates)
                if (aggregate.operation == 'sum')
                  aggregate.field!: fields[aggregate.field!]!.type == 'integer'
                      ? 0
                      : (fields[aggregate.field!]!.precision ?? 9),
            };
            final groups = <String, _ReportGroupState>{};
            for (final aggregate in report.aggregates) {
              if (aggregate.operation == 'sum') {
                for (final group in groups.values) {
                  group.sums.putIfAbsent(aggregate.id, () => BigInt.zero);
                }
              }
            }
            for (final row in rows) {
              final rawJson = row[2];
              if (rawJson is! String) continue;
              final rawValues = jsonDecode(rawJson);
              if (rawValues is! Map) {
                throw const FormatException('Invalid projected report values.');
              }
              final values = Map<String, dynamic>.from(rawValues);
              final groupValue = report.groupBy == null
                  ? null
                  : values[aliases[report.groupBy!]!];
              final groupKey = canonicalJson(groupValue);
              final group = groups.putIfAbsent(
                groupKey,
                () => _ReportGroupState(groupValue),
              );
              group.count++;
              for (final aggregate in report.aggregates) {
                if (aggregate.operation != 'sum') continue;
                final value = values[aliases[aggregate.field!]!];
                if (value == null) continue;
                if (value is! num || !value.isFinite) {
                  return const {
                    'status': 'REJECTED',
                    'reasonCode': 'INVALID_REPORT_DATA',
                  };
                }
                try {
                  group.sums.update(
                    aggregate.id,
                    (total) =>
                        total +
                        ExactDecimal.toScaledInteger(
                          value,
                          fieldScales[aggregate.field!]!,
                        ),
                    ifAbsent: () => ExactDecimal.toScaledInteger(
                      value,
                      fieldScales[aggregate.field!]!,
                    ),
                  );
                } on FormatException {
                  return const {
                    'status': 'REJECTED',
                    'reasonCode': 'INVALID_REPORT_DATA',
                  };
                }
              }
              if (groups.length > 100) {
                return const {
                  'status': 'REJECTED',
                  'reasonCode': 'REPORT_TOO_LARGE',
                };
              }
            }
            if (report.groupBy == null && groups.isEmpty) {
              groups['null'] = _ReportGroupState(null);
            }
            final aggregateById = {
              for (final aggregate in report.aggregates)
                aggregate.id: aggregate,
            };
            int compareValues(Object? left, Object? right) {
              if (identical(left, right)) return 0;
              if (left == null) return -1;
              if (right == null) return 1;
              if (left is num && right is num) return left.compareTo(right);
              if (left is bool && right is bool) {
                return (left ? 1 : 0).compareTo(right ? 1 : 0);
              }
              return left.toString().compareTo(right.toString());
            }

            final sortedGroups = groups.entries.toList();
            final sortBy = report.sortBy;
            sortedGroups.sort((left, right) {
              var order = 0;
              if (sortBy == report.groupBy && sortBy != null) {
                order = compareValues(left.value.key, right.value.key);
                if (report.descending) order = -order;
              } else if (sortBy != null) {
                final aggregate = aggregateById[sortBy]!;
                if (aggregate.operation == 'count') {
                  order = left.value.count.compareTo(right.value.count);
                } else {
                  order = left.value.sums
                      .putIfAbsent(sortBy, () => BigInt.zero)
                      .compareTo(
                        right.value.sums.putIfAbsent(sortBy, () => BigInt.zero),
                      );
                }
                if (report.descending) order = -order;
              }
              return order == 0 ? left.key.compareTo(right.key) : order;
            });
            final outputGroups = sortedGroups
                .map((entry) {
                  final outputs = <String, String>{};
                  for (final aggregate in report.aggregates) {
                    outputs[aggregate.id] = aggregate.operation == 'count'
                        ? entry.value.count.toString()
                        : _scaledReportDecimal(
                            entry.value.sums.putIfAbsent(
                              aggregate.id,
                              () => BigInt.zero,
                            ),
                            fieldScales[aggregate.field!]!,
                          );
                  }
                  return {'key': entry.value.key, 'aggregates': outputs};
                })
                .toList(growable: false);
            return {
              'status': 'REPORT',
              'reportId': report.id,
              'packageSha256':
                  resolved.basePackageSha256 ??
                  sha256
                      .convert(utf8.encode(canonicalJson(bundle.toJson())))
                      .toString(),
              'rowCount': rowCount,
              'groups': outputGroups,
            };
          },
          settings: pg.TransactionSettings(
            isolationLevel: pg.IsolationLevel.readCommitted,
          ),
        );
      },
    );
  }
}

class _ReportGroupState {
  _ReportGroupState(this.key);

  final Object? key;
  int count = 0;
  final Map<String, BigInt> sums = {};
}

String _scaledReportDecimal(BigInt value, int scale) {
  if (scale == 0) return value.toString();
  final negative = value.isNegative;
  final absolute = value.abs();
  final factor = BigInt.from(10).pow(scale);
  final whole = absolute ~/ factor;
  var fraction = (absolute % factor).toString().padLeft(scale, '0');
  fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
  return '${negative ? '-' : ''}$whole${fraction.isEmpty ? '' : '.$fraction'}';
}
