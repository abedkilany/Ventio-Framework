import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;

import 'authentication.dart';
import 'postgres_connections.dart';
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
    this.connectRuntime,
    this.runtimePool,
    this.connectAdministration,
    this.administrationPool,
    required this.admission,
  }) : assert((connectRuntime == null) != (runtimePool == null)),
       assert((connectAdministration == null) != (administrationPool == null));

  final Future<pg.Connection> Function()? connectRuntime;
  final pg.Pool<dynamic>? runtimePool;
  final Future<pg.Connection> Function()? connectAdministration;
  final pg.Pool<dynamic>? administrationPool;
  final RecoveryAuthority admission;

  @override
  Future<Map<String, dynamic>> list({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
  }) async {
    final digest = _authorizeSnapshot(session, companyId, branchId);
    return withPostgresConnection(
      connect: connectRuntime,
      pool: runtimePool,
      action: (connection) async {
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
            throw StateError(
              'Host returned an invalid identity-role response.',
            );
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
      },
    );
  }

  @override
  Future<void> change({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required Map<String, Object?> change,
  }) async {
    final digest = _authorizeSnapshot(session, companyId, branchId);
    return withPostgresConnection(
      connect: connectAdministration,
      pool: administrationPool,
      action: (connection) async {
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
        }
      },
    );
  }
}

/// Checks the dedicated login on startup and each administrative connection.
/// The HTTP service must never be handed an owner, superuser, or migrator URL.
Future<void> verifyIdentityAdministrationConnection(
  pg.Connection connection,
) async {
  final rows = await connection.execute('''
    SELECT
      pg_has_role(session_user,'ventio_identity_api','MEMBER'),
      NOT pg_has_role(session_user,'ventio_identity_admin','MEMBER'),
      NOT pg_has_role(session_user,'ventio_owner','MEMBER'),
      NOT pg_has_role(session_user,'ventio_migrator','MEMBER'),
      NOT pg_has_role(session_user,
        (SELECT datdba::regrole::text FROM pg_catalog.pg_database
          WHERE datname=current_database()),'MEMBER'),
      NOT EXISTS (SELECT FROM pg_catalog.pg_roles r
        WHERE r.rolname=session_user AND
          (r.rolsuper OR r.rolbypassrls OR r.rolcreatedb OR
           r.rolcreaterole OR r.rolreplication)),
      NOT has_database_privilege(session_user,current_database(),'CREATE'),
      NOT has_database_privilege(session_user,current_database(),'TEMP'),
      NOT has_schema_privilege(session_user,'public','CREATE'),
      has_schema_privilege(session_user,'ventio_security','USAGE'),
      NOT has_schema_privilege(session_user,'ventio_security','CREATE'),
      NOT has_schema_privilege(session_user,'ventio_crypto','USAGE'),
      NOT has_schema_privilege(session_user,'ventio_crypto','CREATE'),
      has_function_privilege(session_user,
        'ventio_security.scoped_admin_change(text,text,text,jsonb)','EXECUTE'),
      has_function_privilege(session_user,
        'ventio_security.scoped_user_admin_change(text,text,text,jsonb)','EXECUTE'),
      has_function_privilege(session_user,
        'ventio_security.scoped_pairing_create(text,text,text,text,text,text)','EXECUTE'),
      has_function_privilege(session_user,
        'ventio_security.scoped_pairing_redeem(text,text,text,text)','EXECUTE'),
      has_function_privilege(session_user,
        'ventio_security.admit_recovery(text,text)','EXECUTE'),
      has_function_privilege(session_user,
        'ventio_security.recovery_snapshot()','EXECUTE'),
      NOT has_function_privilege(session_user,
        'ventio_security.admin_change(jsonb)','EXECUTE'),
      NOT has_function_privilege(session_user,
        'ventio_security.reset_recovery(text,text)','EXECUTE'),
      NOT has_function_privilege(session_user,
        'ventio_security.identity_snapshot(text,text,text)','EXECUTE'),
      NOT EXISTS (SELECT FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname IN ('ventio_security','public','ventio_crypto')
          AND has_function_privilege(session_user,p.oid,'EXECUTE')
          AND p.oid NOT IN (
            'ventio_security.scoped_admin_change(text,text,text,jsonb)'::regprocedure,
            'ventio_security.scoped_user_admin_change(text,text,text,jsonb)'::regprocedure,
            'ventio_security.scoped_pairing_create(text,text,text,text,text,text)'::regprocedure,
            'ventio_security.scoped_pairing_redeem(text,text,text,text)'::regprocedure,
            'ventio_security.admit_recovery(text,text)'::regprocedure,
            'ventio_security.recovery_snapshot()'::regprocedure)),
      NOT EXISTS (SELECT FROM pg_catalog.pg_class t
        JOIN pg_catalog.pg_namespace n ON n.oid=t.relnamespace
        WHERE n.nspname IN ('public','ventio_security','ventio_crypto')
          AND t.relkind IN ('r','p','v','m','f')
          AND (has_table_privilege(session_user,t.oid,'SELECT') OR
            has_table_privilege(session_user,t.oid,'INSERT') OR
            has_table_privilege(session_user,t.oid,'UPDATE') OR
            has_table_privilege(session_user,t.oid,'DELETE') OR
            has_table_privilege(session_user,t.oid,'TRUNCATE') OR
            has_table_privilege(session_user,t.oid,'REFERENCES') OR
            has_table_privilege(session_user,t.oid,'TRIGGER'))),
      NOT EXISTS (SELECT FROM pg_catalog.pg_class s
        JOIN pg_catalog.pg_namespace n ON n.oid=s.relnamespace
        WHERE n.nspname IN ('public','ventio_security','ventio_crypto')
          AND s.relkind='S'
          AND (has_sequence_privilege(session_user,s.oid,'USAGE') OR
            has_sequence_privilege(session_user,s.oid,'SELECT') OR
            has_sequence_privilege(session_user,s.oid,'UPDATE')))
  ''');
  if (rows.length != 1 || rows.single.any((value) => value != true)) {
    throw StateError('Host identity API login is not restricted.');
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
