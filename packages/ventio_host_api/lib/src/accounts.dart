import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

import 'authentication.dart';
import 'postgres_connections.dart';
import 'recovery_authority.dart';
import 'role_administration.dart';

class AccountException implements Exception {
  const AccountException(this.code, this.status);
  final String code;
  final int status;
}

/// Password authentication issues normal persistent Ventio credentials. The
/// existing enrolled credential stays the device proof, in protected storage.
class PostgresAccounts {
  const PostgresAccounts({this.connect, this.pool, required this.authority})
    : assert((connect == null) != (pool == null));
  final Future<pg.Connection> Function()? connect;
  final pg.Pool<dynamic>? pool;
  final RecoveryAuthority authority;

  Future<Map<String, dynamic>> handle(
    String action,
    String token,
    Map<String, dynamic> body,
  ) async {
    if (!OpaqueToken.isValid(token))
      throw const AccountException('SIGN_IN_DENIED', 401);
    return withPostgresConnection(
      connect: connect,
      pool: pool,
      action: (connection) async {
        try {
          await verifyIdentityAdministrationConnection(connection);
          final digest = OpaqueToken.digest(token);
          Future<Object?> read(String sql, Map<String, Object?> parameters) =>
              connection.runTx((tx) async {
                await authority.admit(tx);
                return (await tx.execute(
                  pg.Sql.named(sql),
                  parameters: parameters,
                )).single[0];
              });
          Future<Object?> change(
            String sql,
            Map<String, Object?> parameters,
          ) async {
            Object? result;
            await authority.change(connection, (tx) async {
              result = (await tx.execute(
                pg.Sql.named(sql),
                parameters: parameters,
              )).single[0];
            }, requireAdmissionProof: true);
            return result;
          }

          if (action == 'login') {
            if (body.keys.toSet().difference({
                  'tenantId',
                  'username',
                  'password',
                }).isNotEmpty ||
                body.length != 3) {
              throw const AccountException('INVALID_ACCOUNT_REQUEST', 422);
            }
            final tenant = body['tenantId'],
                username = body['username'],
                password = body['password'];
            if (tenant is! String ||
                tenant.isEmpty ||
                tenant.length > 256 ||
                username is! String ||
                !AccountPassword.validUsername(username) ||
                password is! String ||
                utf8.encode(password).length > 1024) {
              throw const AccountException('SIGN_IN_DENIED', 401);
            }
            final raw = await read(
              'SELECT ventio_security.account_login_material(@digest,@tenant,@username)::text',
              {'digest': digest, 'tenant': tenant, 'username': username},
            );
            if (raw is! String)
              throw const AccountException('SIGN_IN_DENIED', 401);
            final material = jsonDecode(raw) as Map;
            final expected = material['passwordHash'] as String;
            final verified = await AccountPassword.verify(password, expected);
            final replacement = OpaqueToken.generate();
            final issued = await change(
              'SELECT ventio_security.account_login_issue(@digest,@tenant,@username,@expected,@token,@id,@success)::text',
              {
                'digest': digest,
                'tenant': tenant,
                'username': username,
                'expected': expected,
                'token': OpaqueToken.digest(replacement),
                'id': 'login_${OpaqueToken.generate()}',
                'success': verified,
              },
            );
            if (!verified || issued is! String)
              throw const AccountException('SIGN_IN_DENIED', 401);
            return {
              ...Map<String, dynamic>.from(jsonDecode(issued) as Map),
              'token': replacement,
            };
          }
          if (action != 'manage')
            throw const AccountException('INVALID_ACCOUNT_REQUEST', 422);
          if (body.keys.toSet().difference({
            'action',
            'actorId',
            'username',
            'password',
            'currentPassword',
            'companyId',
            'branchId',
            'enabled',
          }).isNotEmpty) {
            throw const AccountException('INVALID_ACCOUNT_REQUEST', 422);
          }
          final changeBody = <String, Object?>{...body}
            ..remove('password')
            ..remove('currentPassword');
          if (body['action'] == 'SET_LOGIN') {
            final password = body['password'], username = body['username'];
            if (password is! String ||
                !AccountPassword.validPassword(password) ||
                username is! String ||
                !AccountPassword.validUsername(username)) {
              throw const AccountException('INVALID_ACCOUNT_REQUEST', 422);
            }
            final expected = await read(
              'SELECT ventio_security.account_current_hash(@digest)',
              {'digest': digest},
            );
            // Only self-service consumes the current hash. SQL decides whether
            // the caller may reset another account, including Owner protection.
            if (body['currentPassword'] is String && expected is String) {
              if (!await AccountPassword.verify(
                body['currentPassword'] as String,
                expected,
              )) {
                throw const AccountException('CURRENT_PASSWORD_REQUIRED', 403);
              }
              changeBody['expectedHash'] = expected;
            }
            changeBody['passwordHash'] = await AccountPassword.hash(password);
          }
          final result = await change(
            'SELECT ventio_security.account_change(@digest,CAST(@body AS jsonb))::text',
            {'digest': digest, 'body': jsonEncode(changeBody)},
          );
          return Map<String, dynamic>.from(jsonDecode(result as String) as Map);
        } on pg.ServerException catch (error) {
          if (error.code == '23505')
            throw const AccountException('USERNAME_UNAVAILABLE', 409);
          if (error.code == '22023' || error.code == '23514')
            throw const AccountException('INVALID_ACCOUNT_REQUEST', 422);
          if (error.code == '42501')
            throw const AccountException('ACCOUNT_PERMISSION_DENIED', 403);
          rethrow;
        }
      },
    );
  }
}
