import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host/ventio_host.dart';

import 'authentication.dart';
import 'host_api.dart';
import 'identity_store.dart';
import 'extension_records.dart';
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

/// Resolves an opaque token from PostgreSQL on EVERY HTTP request. There is no
/// in-memory permission cache or development-identity fallback on DB failure.
class PersistentTokenAuthenticator implements PersistentHostAuthenticator {
  final Future<pg.Connection> Function() connect;
  final RecoveryAuthority? admission;
  const PersistentTokenAuthenticator({required this.connect, this.admission});

  @override
  Future<AuthenticatedSession?> authenticate(String token) async {
    if (!OpaqueToken.isValid(token)) return null;
    final digest = OpaqueToken.digest(token);
    final connection = await connect();
    try {
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
    } finally {
      await connection.close();
    }
  }
}

/// Identity and permissions are re-read and locked INSIDE the command's own
/// transaction, before journal access. This closes the authentication-to-command
/// race and applies equally to fresh commands and accepted-receipt retries.
class PersistentCommandExecutor implements AuthoritativeCommandExecutor {
  final Future<pg.Connection> Function() connect;
  final ModuleRegistry modules;
  final DocTypeRegistry docTypes;
  final List<TrustedCommandBinding> bindings;
  final RecoveryAuthority? admission;

  PersistentCommandExecutor({
    required this.connect,
    required this.modules,
    required this.docTypes,
    this.admission,
    required Iterable<TrustedCommandBinding> bindings,
  }) : bindings = List.unmodifiable(bindings);

  @override
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session,
  ) async {
    final digest = session.credentialDigest;
    if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      return CommandReceipt(
        commandId: command.commandId,
        status: 'REJECTED',
        reasonCode: 'AUTHENTICATION_REQUIRED',
      ).toJson();
    }
    final connection = await connect();
    try {
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
      return await host.executeAuthorized(
        command,
        (tx) async {
          await admission?.admit(tx);
          if (command.type == ExtensionRecordCommand.createType ||
              command.type == ExtensionRecordCommand.updateType) {
            final resolved = await const PostgresIdentityStore()
                .resolveExtensionCommand(tx, digest, command);
            if (resolved == null) return null;
            resolvedBundle = resolved.bundle != null
                ? ExtensionBundleAuthorization.approved(resolved.bundle!)
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
            const ExtensionBundleAuthorization.denied('EXTENSION_NOT_APPROVED'),
      );
    } finally {
      await connection.close();
    }
  }
}

/// Queries approved dynamic records under PostgreSQL RLS in a fresh
/// authenticated transaction. Filters and sort fields come only from the
/// approved DocType metadata; SQL identifiers are never interpolated.
class PostgresExtensionRecordQueryGateway
    implements AuthoritativeExtensionRecordQueryGateway {
  const PostgresExtensionRecordQueryGateway({
    required this.connect,
    this.admission,
  });

  final Future<pg.Connection> Function() connect;
  final RecoveryAuthority? admission;

  @override
  Future<Map<String, dynamic>> query({
    required AuthenticatedSession session,
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
    required int offset,
    required int limit,
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
        filters.length > 10) {
      throw const FormatException('Invalid dynamic record query bounds.');
    }
    final connection = await connect();
    try {
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
          final matches = bundle.docTypes.where(
            (definition) =>
                definition.moduleId == moduleId && definition.name == docType,
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
          if (search.isNotEmpty && definition.fields.isNotEmpty) {
            parameters['search'] = search.toLowerCase();
            final searchClauses = <String>[];
            for (var index = 0; index < definition.fields.length; index++) {
              final fieldName = 'searchField$index';
              parameters[fieldName] = definition.fields[index].name;
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
              'record_data -> @$fieldName = CAST(@$valueName AS jsonb)',
            );
          }
          final clause = conditions.isEmpty
              ? ''
              : 'AND ${conditions.join(' AND ')}';
          // Bound serialized page bytes in PostgreSQL before transferring the
          // values to the Host process. The final HTTP limit remains a second
          // line of defense against JSON encoding overhead.
          parameters['maxRecordBytes'] = 512 * 1024;
          final rows = await tx.execute(
            pg.Sql.named('''
            WITH page AS (
              SELECT record_id, revision, updated_at, record_data
              FROM ventio_records
              WHERE tenant_id=@tenant AND company_id=@company AND branch_id=@branch
                AND module_id=@module AND doc_type=@doctype $clause
              ORDER BY
                CASE WHEN @descending THEN record_data ->> @sortField END DESC,
                CASE WHEN NOT @descending THEN record_data ->> @sortField END ASC,
                record_id ASC
              OFFSET @offset LIMIT @limit
            ), serialized_page AS (
              SELECT record_id, revision, updated_at,
                record_data::text AS record_json
              FROM page
            ), bounded_page AS (
              SELECT *, sum(octet_length(record_json)) OVER () AS page_bytes
              FROM serialized_page
            )
            SELECT record_id, revision, updated_at::text AS updated_at,
              page_bytes,
              CASE WHEN page_bytes <= @maxRecordBytes
                THEN record_json ELSE NULL END AS record_json
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
          final records = rows
              .take(limit)
              .map((row) {
                final values = jsonDecode(row[4] as String);
                if (values is! Map) {
                  throw const FormatException('Stored record JSON is invalid.');
                }
                return {
                  'recordId': row[0] as String,
                  'revision': row[1] as int,
                  'updatedAtUtc': row[2] as String,
                  'values': Map<String, dynamic>.from(values),
                };
              })
              .toList(growable: false);
          return {
            'status': 'RECORDS',
            'packageSha256': sha256
                .convert(utf8.encode(canonicalJson(bundle.toJson())))
                .toString(),
            'records': records,
            'hasMore': hasMore,
          };
        },
        settings: pg.TransactionSettings(
          isolationLevel: pg.IsolationLevel.readCommitted,
        ),
      );
    } finally {
      await connection.close();
    }
  }
}
