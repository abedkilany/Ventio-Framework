import 'dart:convert';
import 'dart:math' as math;

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

  Future<Map<String, dynamic>> rotateCredential({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String deviceId,
    required String credentialId,
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
    if (!_safeDeviceId(deviceId)) {
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

  @override
  Future<Map<String, dynamic>> rotateCredential({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String deviceId,
    required String credentialId,
  }) async {
    final digest = _authorize(session, companyId, branchId);
    if (!_safeDeviceId(deviceId) || !_safeCredentialId(credentialId)) {
      throw const IdentityDeviceAdministrationException(
        'INVALID_REQUEST',
        statusCode: 400,
      );
    }
    final token = OpaqueToken.generate();
    final replacementId = 'cred_${_randomHex(16)}';
    final replacementDigest = OpaqueToken.digest(token);
    try {
      return await withPostgresConnection(
        connect: connectAdministration,
        pool: administrationPool,
        action: (connection) async {
          await verifyIdentityAdministrationConnection(connection);
          await connection.execute("SET statement_timeout = '15s'");
          await connection.execute("SET lock_timeout = '5s'");
          late Map<String, dynamic> replacement;
          await admission.change(connection, (tx) async {
            final rows = await tx.execute(
              pg.Sql.named('''
                  SELECT ventio_security.scoped_device_credential_rotate(
                    @digest,@company,@branch,@device,@previousId,@credentialId,
                    @credentialDigest)::text
                '''),
              parameters: {
                'digest': digest,
                'company': companyId,
                'branch': branchId,
                'device': deviceId,
                'previousId': credentialId,
                'credentialId': replacementId,
                'credentialDigest': replacementDigest,
              },
            );
            final raw = rows.single[0];
            if (raw is! String) {
              throw StateError('Host returned an invalid rotation result.');
            }
            final decoded = jsonDecode(raw);
            if (decoded is! Map) {
              throw StateError('Host returned an invalid rotation result.');
            }
            replacement = Map<String, dynamic>.from(decoded);
            final expiry = replacement['expiresAtUtc'];
            if (replacement['tenantId'] != session.principal.tenantId ||
                replacement['deviceId'] != deviceId ||
                replacement['credentialId'] != replacementId ||
                replacement['companyId'] != companyId ||
                replacement['branchId'] != branchId ||
                expiry is! String ||
                DateTime.tryParse(expiry)?.isUtc != true) {
              throw StateError('Host returned an invalid rotation scope.');
            }
          }, requireAdmissionProof: true);
          // This is the only response containing the new bearer. The database,
          // audit trail, diagnostics and credential inventory store its digest
          // or opaque ID only.
          return {...replacement, 'credential': token};
        },
      );
    } on pg.ServerException catch (error) {
      switch (error.code) {
        case '42501':
          throw const IdentityDeviceAdministrationException(
            'PERMISSION_DENIED',
            statusCode: 403,
          );
        case 'P0002':
          throw const IdentityDeviceAdministrationException(
            'DEVICE_CREDENTIAL_NOT_FOUND',
            statusCode: 404,
          );
        case '23505':
          throw const IdentityDeviceAdministrationException(
            'DEVICE_CREDENTIAL_CONFLICT',
            statusCode: 409,
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

bool _safeTypedOpaqueId(String value, String prefix) =>
    value.startsWith(prefix) &&
    RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value.substring(prefix.length));

bool _safeDeviceId(String value) =>
    _safeTypedOpaqueId(value, 'dev_') ||
    (RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$').hasMatch(value) &&
        !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(value));

bool _safeCredentialId(String value) =>
    _safeTypedOpaqueId(value, 'cred_') ||
    (value.isNotEmpty &&
        value.length <= 256 &&
        !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(value));

String _randomHex(int byteCount) {
  final random = math.Random.secure();
  return List<int>.generate(
    byteCount,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

class IdentityDeviceAdministrationException implements Exception {
  const IdentityDeviceAdministrationException(
    this.code, {
    required this.statusCode,
  });

  final String code;
  final int statusCode;
}
