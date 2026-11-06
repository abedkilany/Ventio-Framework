import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

import 'authentication.dart';
import 'extension_packages.dart';
import 'postgres_connections.dart';
import 'recovery_authority.dart';

/// Persistent package transfer backed by Host-owned security-definer functions.
/// Shared approval is intentionally a separate operator action.
class PostgresExtensionPackageGateway
    implements
        AuthoritativeExtensionPackageGateway,
        ExtensionPermissionDenialDiagnosticGateway {
  final Future<pg.Connection> Function()? connect;
  final pg.Pool<dynamic>? pool;
  final Future<pg.Connection> Function()? permissionDiagnosticConnect;
  final pg.Pool<dynamic>? permissionDiagnosticPool;
  final RecoveryAuthority admission;

  const PostgresExtensionPackageGateway({
    this.connect,
    this.pool,
    this.permissionDiagnosticConnect,
    this.permissionDiagnosticPool,
    required this.admission,
  }) : assert((connect == null) != (pool == null)),
       assert(
         (permissionDiagnosticConnect == null) ||
             (permissionDiagnosticPool == null),
       );

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
    return withPostgresConnection(
      connect: connect,
      pool: pool,
      action: (connection) async {
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
      },
    );
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
    return withPostgresConnection(
      connect: connect,
      pool: pool,
      action: (connection) async {
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
      },
    );
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
    return withPostgresConnection(
      connect: connect,
      pool: pool,
      action: (connection) async {
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
      },
    );
  }

  @override
  Future<String> permissionDenialCode({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String permission,
  }) async {
    final digest = session.credentialDigest;
    if (digest == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        (permissionDiagnosticConnect == null &&
            permissionDiagnosticPool == null)) {
      return 'AUTHORIZATION_STATE_UNAVAILABLE';
    }
    try {
      return await withPostgresConnection(
        connect: permissionDiagnosticConnect,
        pool: permissionDiagnosticPool,
        action: (connection) async {
          await connection.execute("SET statement_timeout = '15s'");
          await connection.execute("SET lock_timeout = '5s'");
          return connection.runTx((tx) async {
            await admission.admit(tx);
            final rows = await tx.execute(
              pg.Sql.named('''
                SELECT ventio_security.permission_denial_reason(
                  @digest,@tenant,@company,@branch,@permission)
              '''),
              parameters: {
                'digest': digest,
                'tenant': session.principal.tenantId,
                'company': companyId,
                'branch': branchId,
                'permission': permission,
              },
            );
            final code = rows.single[0];
            return code is String &&
                    const {
                      'CREDENTIAL_CEILING_DENIED',
                      'CREDENTIAL_SCOPE_DENIED',
                      'USER_PERMISSION_DENIED',
                      'AUTHORIZATION_STATE_UNAVAILABLE',
                    }.contains(code)
                ? code
                : 'AUTHORIZATION_STATE_UNAVAILABLE';
          });
        },
      );
    } on Object {
      return 'AUTHORIZATION_STATE_UNAVAILABLE';
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
