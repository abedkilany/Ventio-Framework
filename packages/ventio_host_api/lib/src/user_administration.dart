import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

import 'authentication.dart';
import 'postgres_connections.dart';
import 'recovery_authority.dart';
import 'role_administration.dart';

abstract interface class IdentityUserAdministrationGateway {
  Future<Map<String, dynamic>> list({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
  });

  Future<Map<String, dynamic>> audit({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
  });

  Future<String?> change({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required Map<String, Object?> change,
  });
}

/// Marker required before user administration may be served externally.
abstract interface class AuthoritativeIdentityUserAdministrationGateway
    implements IdentityUserAdministrationGateway {}

/// User reads use the restricted runtime login. Mutations use the dedicated
/// API login and the narrow SQL function, which rechecks direct
/// authority, credential scope, and recovery admission inside the transaction.
class PostgresIdentityUserAdministrationGateway
    implements AuthoritativeIdentityUserAdministrationGateway {
  const PostgresIdentityUserAdministrationGateway({
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
    final digest = _authorize(session, companyId, branchId);

    return withPostgresConnection(
      connect: connectRuntime,
      pool: runtimePool,
      action: (connection) async {
        await _configureRuntime(connection);
        return connection.runTx((tx) async {
          await admission.admit(tx);
          final rows = await tx.execute(
            pg.Sql.named('''
              SELECT ventio_security.identity_users_snapshot(
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
            throw const IdentityUserAdministrationException(
              'PERMISSION_DENIED',
              statusCode: 403,
            );
          }
          final decoded = jsonDecode(raw);
          if (decoded is! Map) {
            throw StateError('Host returned an invalid user response.');
          }
          final result = Map<String, dynamic>.from(decoded);
          if (result['tenantId'] != session.principal.tenantId ||
              result['companyId'] != companyId ||
              result['branchId'] != branchId ||
              result['items'] is! List) {
            throw StateError('Host returned an invalid user scope.');
          }
          return result;
        });
      },
    );
  }

  @override
  Future<Map<String, dynamic>> audit({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
  }) async {
    final digest = _authorize(session, companyId, branchId);
    return withPostgresConnection(
      connect: connectRuntime,
      pool: runtimePool,
      action: (connection) async {
        await _configureRuntime(connection);
        return connection.runTx((tx) async {
          await admission.admit(tx);
          final rows = await tx.execute(
            pg.Sql.named('''
              SELECT ventio_security.identity_users_audit_snapshot(
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
            throw const IdentityUserAdministrationException(
              'PERMISSION_DENIED',
              statusCode: 403,
            );
          }
          final decoded = jsonDecode(raw);
          if (decoded is! Map) {
            throw StateError('Host returned an invalid audit response.');
          }
          final result = Map<String, dynamic>.from(decoded);
          if (result['tenantId'] != session.principal.tenantId ||
              result['companyId'] != companyId ||
              result['branchId'] != branchId ||
              result['events'] is! List ||
              (result['events'] as List).length > 100) {
            throw StateError('Host returned an invalid audit scope.');
          }
          return result;
        });
      },
    );
  }

  @override
  Future<String?> change({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required Map<String, Object?> change,
  }) async {
    final digest = _authorize(session, companyId, branchId);
    return withPostgresConnection(
      connect: connectAdministration,
      pool: administrationPool,
      action: (connection) async {
        try {
          await verifyScopedUserAdministrationConnection(connection);
          await connection.execute("SET statement_timeout = '15s'");
          await connection.execute("SET lock_timeout = '5s'");
          String? createdActorId;
          await admission.change(connection, (tx) async {
            final rows = await tx.execute(
              pg.Sql.named('''
                SELECT ventio_security.scoped_user_admin_change(
                  @digest,@company,@branch,CAST(@change AS jsonb))
              '''),
              parameters: {
                'digest': digest,
                'company': companyId,
                'branch': branchId,
                'change': jsonEncode(change),
              },
            );
            final actorId = rows.single[0];
            if (change['action'] == 'USER_CREATED') {
              if (actorId is! String ||
                  !RegExp(r'^usr_[0-9a-f]{32}$').hasMatch(actorId)) {
                throw StateError('Host returned an invalid generated user ID.');
              }
              createdActorId = actorId;
              return;
            }
            if (actorId != null) {
              throw StateError('Host returned an unexpected user ID.');
            }
            return;
          }, requireAdmissionProof: true);
          return createdActorId;
        } on pg.ServerException catch (error) {
          switch (error.code) {
            case '42501':
              throw const IdentityUserAdministrationException(
                'PERMISSION_DENIED',
                statusCode: 403,
              );
            case 'P0002':
              throw const IdentityUserAdministrationException(
                'USER_NOT_FOUND',
                statusCode: 404,
              );
            case '23505':
              throw const IdentityUserAdministrationException(
                'USER_CHANGE_CONFLICT',
                statusCode: 409,
              );
            case '22023':
            case '23514':
              throw const IdentityUserAdministrationException(
                'INVALID_USER_CHANGE',
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

/// Confirms the API's administration connection can execute only the scoped
/// function and has no direct identity-table privileges.
Future<void> verifyScopedUserAdministrationConnection(
  pg.Connection connection,
) async {
  await verifyIdentityAdministrationConnection(connection);
}

class IdentityUserAdministrationException implements Exception {
  const IdentityUserAdministrationException(
    this.code, {
    required this.statusCode,
  });

  final String code;
  final int statusCode;
}

String _authorize(
  AuthenticatedSession session,
  String companyId,
  String branchId,
) {
  final digest = session.credentialDigest;
  if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
    throw const IdentityUserAdministrationException(
      'PERSISTENT_IDENTITY_REQUIRED',
      statusCode: 403,
    );
  }
  if (!session.principal.allowsInScope(
    identityUsersManagePermission,
    companyId,
    branchId,
  )) {
    throw const IdentityUserAdministrationException(
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
