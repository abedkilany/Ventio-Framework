import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

class ResolvedExtensionCommand {
  const ResolvedExtensionCommand({
    required this.principal,
    this.bundle,
    this.failureReasonCode,
  });

  final Principal principal;
  final ExtensionBundle? bundle;
  final String? failureReasonCode;
}

/// The runtime cannot read or lock identity tables directly. The vetted database
/// function owns those operations and binds a transaction-local proof context.
class PostgresIdentityStore {
  const PostgresIdentityStore();

  Future<Principal?> resolve(
    pg.TxSession tx,
    String digest, {
    CommandEnvelope? command,
  }) async {
    final rows = await tx.execute(
      pg.Sql.named('''
      SELECT ventio_security.resolve_identity(@digest, @company, @branch,
        @type, @version, @command, @aggregate)::text
    '''),
      parameters: {
        'digest': digest,
        'company': command?.companyId,
        'branch': command?.branchId,
        'type': command?.type,
        'version': command?.typeVersion,
        'command': command?.commandId,
        'aggregate': command?.aggregateId,
      },
    );
    if (rows.single[0] == null) return null;
    final identity =
        jsonDecode(rows.single[0] as String) as Map<String, dynamic>;
    return _principalFrom(identity);
  }

  Future<ResolvedExtensionCommand?> resolveExtensionCommand(
    pg.TxSession tx,
    String digest,
    CommandEnvelope envelope,
  ) async {
    late final String moduleId;
    late final String docType;
    late final String operation;
    late final Map<String, dynamic> operationInputs;
    if (envelope.type == ExtensionBusinessOperationCommand.commandType) {
      final command = ExtensionBusinessOperationCommand.fromEnvelope(envelope);
      moduleId = command.moduleId;
      docType = command.docType;
      operation = '${command.operationId}@${command.operationVersion}';
      operationInputs = command.inputs;
    } else {
      final command = ExtensionRecordCommand.fromEnvelope(envelope);
      moduleId = command.moduleId;
      docType = command.docType;
      operation = command.operation;
      operationInputs = const {};
    }
    final rows = await tx.execute(
      pg.Sql.named('''
      SELECT ventio_security.resolve_extension_identity(
        @digest,@company,@branch,@type,@version,@command,@aggregate,
        @module,@module_version,@doc_type,@operation,@expected_revision,
        CAST(@operation_inputs AS jsonb))::text
    '''),
      parameters: {
        'digest': digest,
        'company': envelope.companyId,
        'branch': envelope.branchId,
        'type': envelope.type,
        'version': envelope.typeVersion,
        'command': envelope.commandId,
        'aggregate': envelope.aggregateId,
        'module': moduleId,
        'module_version': envelope.moduleVersion,
        'doc_type': docType,
        'operation': operation,
        'expected_revision': envelope.expectedRevision,
        'operation_inputs': jsonEncode(operationInputs),
      },
    );
    final raw = rows.single[0];
    if (raw == null) return null;
    final result = jsonDecode(raw as String) as Map<String, dynamic>;
    final identity = result['identity'];
    if (identity is! Map) return null;
    final principal = _principalFrom(Map<String, dynamic>.from(identity));
    final rawPackage = result['package'];
    if (rawPackage is! Map) {
      final reason = result['reasonCode'];
      return ResolvedExtensionCommand(
        principal: principal,
        failureReasonCode: reason is String ? reason : 'EXTENSION_NOT_APPROVED',
      );
    }
    final bundle = ExtensionBundle.fromJson(
      Map<String, dynamic>.from(rawPackage),
    );
    final source = canonicalJson(bundle.toJson());
    final hash = sha256.convert(utf8.encode(source)).toString();
    if (bundle.moduleId != moduleId ||
        bundle.version != envelope.moduleVersion ||
        result['packageSha256'] != hash) {
      throw StateError('Approved extension integrity check failed.');
    }
    final reason = result['reasonCode'];
    return ResolvedExtensionCommand(
      principal: principal,
      bundle: bundle,
      failureReasonCode: reason is String ? reason : null,
    );
  }

  Future<ResolvedExtensionCommand?> resolveExtensionRead(
    pg.TxSession tx,
    String digest, {
    required String companyId,
    required String branchId,
    required String moduleId,
    required String version,
    required String docType,
  }) async {
    final rows = await tx.execute(
      pg.Sql.named('''
      SELECT ventio_security.resolve_extension_read_identity(
        @digest,@company,@branch,@module,@module_version,@doc_type)::text
    '''),
      parameters: {
        'digest': digest,
        'company': companyId,
        'branch': branchId,
        'module': moduleId,
        'module_version': version,
        'doc_type': docType,
      },
    );
    final raw = rows.single[0];
    if (raw == null) return null;
    final result = jsonDecode(raw as String) as Map<String, dynamic>;
    final identity = result['identity'];
    if (identity is! Map) return null;
    final principal = _principalFrom(Map<String, dynamic>.from(identity));
    final rawPackage = result['package'];
    if (rawPackage is! Map) {
      final reason = result['reasonCode'];
      return ResolvedExtensionCommand(
        principal: principal,
        failureReasonCode: reason is String ? reason : 'EXTENSION_NOT_APPROVED',
      );
    }
    final bundle = ExtensionBundle.fromJson(
      Map<String, dynamic>.from(rawPackage),
    );
    final source = canonicalJson(bundle.toJson());
    final hash = sha256.convert(utf8.encode(source)).toString();
    if (bundle.moduleId != moduleId ||
        bundle.version != version ||
        result['packageSha256'] != hash) {
      throw StateError('Approved extension integrity check failed.');
    }
    return ResolvedExtensionCommand(principal: principal, bundle: bundle);
  }

  Principal _principalFrom(Map<String, dynamic> identity) {
    final grantsByScope = <(String, String), Set<String>>{};
    for (final rawGrant in identity['scopeGrants'] as List) {
      final grant = rawGrant as Map<String, dynamic>;
      final companyId = grant['companyId'] as String;
      final branchId = grant['branchId'] as String;
      final permission = grant['permission'] as String;
      grantsByScope.putIfAbsent((companyId, branchId), () => <String>{})
        ..add(permission);
    }
    return Principal(
      tenantId: identity['tenantId'] as String,
      actorId: identity['actorId'] as String,
      deviceId: identity['deviceId'] as String,
      companyIds: (identity['companyIds'] as List).cast<String>().toSet(),
      branchIds: (identity['branchIds'] as List).cast<String>().toSet(),
      permissions: (identity['permissions'] as List).cast<String>().toSet(),
      scopeGrants: grantsByScope.entries.map(
        (entry) => PrincipalScope(
          companyId: entry.key.$1,
          branchId: entry.key.$2,
          permissions: entry.value,
        ),
      ),
    );
  }
}
