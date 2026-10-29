import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

import 'authentication.dart';
import 'postgres_connections.dart';
import 'recovery_authority.dart';
import 'role_administration.dart';

abstract interface class IdentityDeviceAdministrationGateway {
  Future<Map<String, dynamic>> list({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
  });

  Future<void> revoke({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String deviceId,
  });
}

abstract interface class AuthoritativeIdentityDeviceAdministrationGateway
    implements IdentityDeviceAdministrationGateway {}

/// Device inventory reads through a restricted runtime login. Revocation uses
/// the scoped API login and a Recovery Authority-admitted SQL operation.
class PostgresIdentityDeviceAdministrationGateway
    implements AuthoritativeIdentityDeviceAdministrationGateway {
  const PostgresIdentityDeviceAdministrationGateway({
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
        await connection.execute('SELECT ventio_security.assert_runtime()');
        await connection.execute("SET statement_timeout = '15s'");
        return connection.runTx((tx) async {
          await admission.admit(tx);
          final rows = await tx.execute(
            pg.Sql.named('''
              SELECT ventio_security.identity_devices_snapshot(
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
            throw const IdentityDeviceAdministrationException(
              'PERMISSION_DENIED',
              statusCode: 403,
            );
          }
          final decoded = jsonDecode(raw);
          if (decoded is! Map) {
            throw StateError('Host returned an invalid device response.');
          }
          final snapshot = Map<String, dynamic>.from(decoded);
          if (snapshot['tenantId'] != session.principal.tenantId ||
              snapshot['companyId'] != companyId ||
              snapshot['branchId'] != branchId ||
              snapshot['items'] is! List ||
              (snapshot['items'] as List).length > 1000) {
            throw StateError('Host returned an invalid device scope.');
          }
          return snapshot;
        });
      },
    );
  }

  @override
  Future<void> revoke({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String deviceId,
  }) async {
    final digest = _authorize(session, companyId, branchId);
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$').hasMatch(deviceId) ||
        RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(deviceId)) {
      throw const IdentityDeviceAdministrationException(
        'INVALID_REQUEST',
        statusCode: 400,
      );
    }
    return withPostgresConnection(
      connect: connectAdministration,
      pool: administrationPool,
      action: (connection) async {
        await verifyIdentityAdministrationConnection(connection);
        await connection.execute("SET statement_timeout = '15s'");
        await connection.execute("SET lock_timeout = '5s'");
        try {
          await admission.change(connection, (tx) async {
            final rows = await tx.execute(
              pg.Sql.named('''
                SELECT ventio_security.scoped_device_revoke(
                  @digest,@company,@branch,@device)
              '''),
              parameters: {
                'digest': digest,
                'company': companyId,
                'branch': branchId,
                'device': deviceId,
              },
            );
            if (rows.single[0] != true) {
              throw StateError('Host returned an invalid device operation.');
            }
          }, requireAdmissionProof: true);
        } on pg.ServerException catch (error) {
          switch (error.code) {
            case '42501':
              throw const IdentityDeviceAdministrationException(
                'PERMISSION_DENIED',
                statusCode: 403,
              );
            case 'P0002':
              throw const IdentityDeviceAdministrationException(
                'DEVICE_NOT_FOUND',
                statusCode: 404,
              );
            case '22023':
            case '23514':
              throw const IdentityDeviceAdministrationException(
                'INVALID_REQUEST',
                statusCode: 400,
              );
            default:
              rethrow;
          }
        }
      },
    );
  }
}

String _authorize(
  AuthenticatedSession session,
  String companyId,
  String branchId,
) {
  final digest = session.credentialDigest;
  final principal = session.principal;
  if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
    throw const IdentityDeviceAdministrationException(
      'PERSISTENT_IDENTITY_REQUIRED',
      statusCode: 403,
    );
  }
  if (!principal.withinScope(
        tenantId: principal.tenantId,
        companyId: companyId,
        branchId: branchId,
        actorId: principal.actorId,
        deviceId: principal.deviceId,
      ) ||
      !principal.allowsInScope(
        identityDevicesManagePermission,
        companyId,
        branchId,
      )) {
    throw const IdentityDeviceAdministrationException(
      'PERMISSION_DENIED',
      statusCode: 403,
    );
  }
  return digest;
}

class IdentityDeviceAdministrationException implements Exception {
  const IdentityDeviceAdministrationException(
    this.code, {
    required this.statusCode,
  });

  final String code;
  final int statusCode;
}
