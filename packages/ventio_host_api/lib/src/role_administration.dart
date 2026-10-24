import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;

import 'authentication.dart';
import 'recovery_authority.dart';

abstract interface class IdentityRoleAdministrationGateway {
  Future<Map<String, dynamic>> list({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
  });

  Future<void> change({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required Map<String, Object?> change,
  });
}

/// Required before role administration may be served outside loopback.
abstract interface class AuthoritativeIdentityRoleAdministrationGateway
    implements IdentityRoleAdministrationGateway {}

/// Role reads use the restricted runtime login. Mutations use a dedicated
/// identity-admin login, but the database function revalidates the caller's
/// direct branch grant and credential ceiling inside the admitted transaction.
class PostgresIdentityRoleAdministrationGateway
    implements AuthoritativeIdentityRoleAdministrationGateway {
  const PostgresIdentityRoleAdministrationGateway({
    required this.connectRuntime,
    required this.connectAdministration,
    required this.admission,
  });

  final Future<pg.Connection> Function() connectRuntime;
  final Future<pg.Connection> Function() connectAdministration;
  final RecoveryAuthority admission;

  @override
  Future<Map<String, dynamic>> list({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
  }) async {
    final digest = _authorizeSnapshot(session, companyId, branchId);
    final connection = await connectRuntime();
    try {
      await _configureRuntime(connection);
      return await connection.runTx((tx) async {
        await admission.admit(tx);
        final rows = await tx.execute(
          pg.Sql.named('''
            SELECT ventio_security.identity_roles_snapshot(
              @digest,@company,@branch)::text
          '''),
          parameters: {
            'digest': digest,
            'company': companyId,
            'branch': branchId,
          },
        );
        final raw = rows.single[0];
        if (raw is! String) {
          throw const IdentityRoleAdministrationException(
            'PERMISSION_DENIED',
            statusCode: 403,
          );
        }
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          throw StateError('Host returned an invalid identity-role response.');
        }
        final result = Map<String, dynamic>.from(decoded);
        if (result['tenantId'] != session.principal.tenantId ||
            result['companyId'] != companyId ||
            result['branchId'] != branchId ||
            result['roles'] is! List) {
          throw StateError('Host returned an invalid identity-role scope.');
        }
        return result;
      });
    } finally {
      await connection.close();
    }
  }

  @override
  Future<void> change({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required Map<String, Object?> change,
  }) async {
    final digest = _authorizeSnapshot(session, companyId, branchId);
    final connection = await connectAdministration();
    try {
      await verifyIdentityAdministrationConnection(connection);
      await connection.execute("SET statement_timeout = '15s'");
      await connection.execute("SET lock_timeout = '5s'");
      await admission.change(connection, (tx) async {
        await tx.execute(
          pg.Sql.named('''
            SELECT ventio_security.scoped_admin_change(
              @digest,@company,@branch,CAST(@change AS jsonb))
          '''),
          parameters: {
            'digest': digest,
            'company': companyId,
            'branch': branchId,
            'change': jsonEncode(change),
          },
        );
      }, requireAdmissionProof: true);
    } on pg.ServerException catch (error) {
      switch (error.code) {
        case '42501':
          throw const IdentityRoleAdministrationException(
            'PERMISSION_DENIED',
            statusCode: 403,
          );
        case 'P0002':
          throw const IdentityRoleAdministrationException(
            'ROLE_NOT_FOUND',
            statusCode: 404,
          );
        case '23505':
          throw const IdentityRoleAdministrationException(
            'ROLE_ALREADY_EXISTS',
            statusCode: 409,
          );
        case '23503':
          throw const IdentityRoleAdministrationException(
            'ROLE_HAS_ASSIGNMENTS',
            statusCode: 409,
          );
        case 'P0001':
          throw const IdentityRoleAdministrationException(
            'ROLE_CHANGE_REJECTED',
            statusCode: 409,
          );
        case '22023':
        case '23514':
        case '54000':
          throw const IdentityRoleAdministrationException(
            'INVALID_ROLE_CHANGE',
            statusCode: 422,
          );
        default:
          rethrow;
      }
    } finally {
      await connection.close();
    }
  }
}

/// Checks the dedicated login on startup and each administrative connection.
/// The HTTP service must never be handed an owner, superuser, or migrator URL.
Future<void> verifyIdentityAdministrationConnection(
  pg.Connection connection,
) async {
  final rows = await connection.execute('''
    SELECT
      pg_has_role(session_user,'ventio_identity_admin','MEMBER'),
      NOT EXISTS (SELECT FROM pg_catalog.pg_roles r
        WHERE r.rolname=session_user AND
          (r.rolsuper OR r.rolbypassrls OR r.rolcreatedb OR
           r.rolcreaterole OR r.rolreplication)),
      NOT has_database_privilege(session_user,current_database(),'CREATE'),
      NOT has_database_privilege(session_user,current_database(),'TEMP'),
      NOT has_schema_privilege(session_user,'public','CREATE'),
      has_function_privilege(session_user,
        'ventio_security.scoped_admin_change(text,text,text,jsonb)','EXECUTE'),
      NOT has_function_privilege(session_user,
        'ventio_security.identity_snapshot(text,text,text)','EXECUTE'),
      NOT has_any_column_privilege(session_user,
        'public.ventio_identity_roles','SELECT,INSERT,UPDATE,REFERENCES'),
      NOT has_any_column_privilege(session_user,
        'public.ventio_identity_role_permissions','SELECT,INSERT,UPDATE,REFERENCES'),
      NOT has_any_column_privilege(session_user,
        'public.ventio_identity_role_assignments','SELECT,INSERT,UPDATE,REFERENCES')
  ''');
  if (rows.length != 1 || rows.single.any((value) => value != true)) {
    throw StateError('Host identity administration login is not restricted.');
  }
}

class IdentityRoleAdministrationException implements Exception {
  const IdentityRoleAdministrationException(
    this.code, {
    required this.statusCode,
  });

  final String code;
  final int statusCode;
}

String _authorizeSnapshot(
  AuthenticatedSession session,
  String companyId,
  String branchId,
) {
  final digest = session.credentialDigest;
  if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
    throw const IdentityRoleAdministrationException(
      'PERSISTENT_IDENTITY_REQUIRED',
      statusCode: 403,
    );
  }
  if (!session.principal.allowsInScope(
    'identity.roles.manage',
    companyId,
    branchId,
  )) {
    throw const IdentityRoleAdministrationException(
      'PERMISSION_DENIED',
      statusCode: 403,
    );
  }
  return digest;
}

Future<void> _configureRuntime(pg.Connection connection) async {
  await connection.execute('SELECT ventio_security.assert_runtime()');
  await connection.execute("SET statement_timeout = '15s'");
  await connection.execute("SET lock_timeout = '5s'");
}
