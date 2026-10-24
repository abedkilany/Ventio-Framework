import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

import 'authentication.dart';
import 'extension_packages.dart';
import 'recovery_authority.dart';

/// Persistent package transfer backed by Host-owned security-definer functions.
/// Shared approval is intentionally a separate operator action.
class PostgresExtensionPackageGateway
    implements AuthoritativeExtensionPackageGateway {
  final Future<pg.Connection> Function() connect;
  final RecoveryAuthority admission;

  const PostgresExtensionPackageGateway({
    required this.connect,
    required this.admission,
  });

  @override
  Future<Map<String, dynamic>> submit({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required ExtensionBundle bundle,
  }) async {
    final digest = _authorizeSnapshot(
      session,
      companyId,
      branchId,
      'extension.package.submit',
    );
    final package = bundle.toJson();
    final source = canonicalJson(package);
    if (utf8.encode(source).length > ExtensionBundle.maxEncodedBytes) {
      throw const ContractError(
        'EXTENSION_TOO_LARGE',
        'An extension package cannot exceed 1 MiB.',
      );
    }
    final hash = sha256.convert(utf8.encode(source)).toString();
    final connection = await connect();
    try {
      await _configure(connection);
      final response = await connection.runTx((tx) async {
        await admission.admit(tx);
        final rows = await tx.execute(
          pg.Sql.named('''
          SELECT ventio_security.submit_extension_package(
            @digest,@tenant,@company,@branch,@module,@version,@sha256,
            CAST(@package AS jsonb))::text
        '''),
          parameters: {
            'digest': digest,
            'tenant': session.principal.tenantId,
            'company': companyId,
            'branch': branchId,
            'module': bundle.moduleId,
            'version': bundle.version,
            'sha256': hash,
            'package': jsonEncode(package),
          },
        );
        return _decodeFunctionResult(rows.single[0], 'package submission');
      });
      return response;
    } finally {
      await connection.close();
    }
  }

  @override
  Future<Map<String, dynamic>> readApproved({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String moduleId,
    required String version,
  }) async {
    final digest = _authorizeSnapshot(
      session,
      companyId,
      branchId,
      'extension.package.read',
    );
    semverParts(version);
    final connection = await connect();
    try {
      await _configure(connection);
      return await connection.runTx((tx) async {
        await admission.admit(tx);
        final rows = await tx.execute(
          pg.Sql.named('''
          SELECT ventio_security.read_approved_extension_package(
            @digest,@tenant,@company,@branch,@module,@version)::text
        '''),
          parameters: {
            'digest': digest,
            'tenant': session.principal.tenantId,
            'company': companyId,
            'branch': branchId,
            'module': moduleId,
            'version': version,
          },
        );
        final result = _decodeFunctionResult(rows.single[0], 'package read');
        if (result['status'] == 'APPROVED') {
          final json = result['package'];
          if (json is! Map) {
            throw StateError('Approved extension metadata is unavailable.');
          }
          final bundle = ExtensionBundle.fromJson(
            Map<String, dynamic>.from(json),
          );
          final source = canonicalJson(bundle.toJson());
          final actualHash = sha256.convert(utf8.encode(source)).toString();
          if (bundle.moduleId != moduleId ||
              bundle.version != version ||
              result['packageSha256'] != actualHash) {
            throw StateError('Approved extension integrity check failed.');
          }
          result['package'] = bundle.toJson();
        }
        return result;
      });
    } finally {
      await connection.close();
    }
  }

  @override
  Future<Map<String, dynamic>> listApproved({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required int limit,
    String? afterModuleId,
    String? afterVersion,
  }) async {
    final digest = _authorizeSnapshot(
      session,
      companyId,
      branchId,
      'extension.package.read',
    );
    if (limit < 1 ||
        limit > 50 ||
        (afterModuleId == null) != (afterVersion == null)) {
      throw const ContractError('INVALID_PAGE', 'Invalid package page cursor.');
    }
    final connection = await connect();
    try {
      await _configure(connection);
      return await connection.runTx((tx) async {
        await admission.admit(tx);
        final rows = await tx.execute(
          pg.Sql.named('''
          SELECT ventio_security.list_approved_extension_packages(
            @digest,@tenant,@company,@branch,@after_module,@after_version,@limit)::text
        '''),
          parameters: {
            'digest': digest,
            'tenant': session.principal.tenantId,
            'company': companyId,
            'branch': branchId,
            'after_module': afterModuleId,
            'after_version': afterVersion,
            'limit': limit,
          },
        );
        return _decodeFunctionResult(rows.single[0], 'package registry read');
      });
    } finally {
      await connection.close();
    }
  }
}

String _authorizeSnapshot(
  AuthenticatedSession session,
  String companyId,
  String branchId,
  String permission,
) {
  final digest = session.credentialDigest;
  if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
    throw const ContractError(
      'PERSISTENT_IDENTITY_REQUIRED',
      'Extension package transfer requires a persistent Host identity.',
    );
  }
  if (!session.principal.allowsInScope(permission, companyId, branchId)) {
    throw const ContractError('PERMISSION_DENIED', 'Permission denied.');
  }
  return digest;
}

Future<void> _configure(pg.Connection connection) async {
  await connection.execute('SELECT ventio_security.assert_runtime()');
  await connection.execute("SET statement_timeout = '15s'");
  await connection.execute("SET lock_timeout = '5s'");
}

Map<String, dynamic> _decodeFunctionResult(Object? raw, String action) {
  if (raw is! String) throw StateError('Host $action returned no result.');
  final decoded = jsonDecode(raw);
  if (decoded is! Map) throw StateError('Host $action returned no result.');
  return Map<String, dynamic>.from(decoded);
}
