import 'dart:convert';
import 'dart:math' as math;

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

import 'authentication.dart';
import 'postgres_connections.dart';
import 'recovery_authority.dart';
import 'role_administration.dart';

abstract interface class IdentityPairingGateway {
  Future<Map<String, dynamic>> create({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String actorId,
  });

  Future<Map<String, dynamic>> redeem({
    required String code,
    required String deviceId,
  });
}

/// Required before pairing can be served outside a loopback-only test Host.
abstract interface class AuthoritativeIdentityPairingGateway
    implements IdentityPairingGateway {}

/// Pairing mutations use the restricted identity API login and a Recovery
/// Authority admitted transaction. Codes and bearer credentials are returned
/// once; only SHA-256 digests are sent to PostgreSQL.
class PostgresIdentityPairingGateway
    implements AuthoritativeIdentityPairingGateway {
  const PostgresIdentityPairingGateway({
    this.connectAdministration,
    this.administrationPool,
    required this.admission,
  }) : assert((connectAdministration == null) != (administrationPool == null));

  final Future<pg.Connection> Function()? connectAdministration;
  final pg.Pool<dynamic>? administrationPool;
  final RecoveryAuthority admission;

  @override
  Future<Map<String, dynamic>> create({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String actorId,
  }) async {
    final digest = _authorize(session, companyId, branchId);
    final code = OpaqueToken.generate();
    final pairingId = 'pair_${_randomHex(16)}';
    final pairingDigest = OpaqueToken.digest(code);
    try {
      final expiresAt = await _mutate((tx) async {
        final rows = await tx.execute(
          pg.Sql.named('''
            SELECT ventio_security.scoped_pairing_create(
              @digest,@company,@branch,@actor,@pairingId,@pairingDigest)
          '''),
          parameters: {
            'digest': digest,
            'company': companyId,
            'branch': branchId,
            'actor': actorId,
            'pairingId': pairingId,
            'pairingDigest': pairingDigest,
          },
        );
        final raw = rows.single[0];
        if (raw is! DateTime) {
          throw StateError('Host returned an invalid pairing expiry.');
        }
        return raw.toUtc();
      });
      return {
        'pairingId': pairingId,
        'actorId': actorId,
        'deviceRole': HostDeviceRole.client.wireValue,
        'code': code,
        'companyId': companyId,
        'branchId': branchId,
        'expiresAtUtc': expiresAt.toIso8601String(),
      };
    } on pg.ServerException catch (error) {
      throw _mapCreateError(error);
    }
  }

  @override
  Future<Map<String, dynamic>> redeem({
    required String code,
    required String deviceId,
  }) async {
    if (!OpaqueToken.isValid(code) ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(deviceId) ||
        RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(deviceId)) {
      throw const IdentityPairingException('INVALID_REQUEST', statusCode: 400);
    }
    final credential = OpaqueToken.generate();
    final credentialId = 'cred_${_randomHex(16)}';
    final pairingDigest = OpaqueToken.digest(code);
    final credentialDigest = OpaqueToken.digest(credential);
    try {
      final enrollment = await _mutate((tx) async {
        final rows = await tx.execute(
          pg.Sql.named('''
            SELECT ventio_security.scoped_pairing_redeem(
              @pairingDigest,@deviceId,@credentialId,@credentialDigest)::text
          '''),
          parameters: {
            'pairingDigest': pairingDigest,
            'deviceId': deviceId,
            'credentialId': credentialId,
            'credentialDigest': credentialDigest,
          },
        );
        final raw = rows.single[0];
        if (raw is! String) {
          throw StateError('Host returned an invalid enrollment result.');
        }
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          throw StateError('Host returned an invalid enrollment result.');
        }
        final value = Map<String, dynamic>.from(decoded);
        if (value['deviceId'] != deviceId ||
            value['credentialId'] != credentialId ||
            value['deviceRole'] != HostDeviceRole.client.wireValue ||
            value['tenantId'] is! String ||
            value['actorId'] is! String ||
            value['companyId'] is! String ||
            value['branchId'] is! String ||
            value['expiresAtUtc'] is! String) {
          throw StateError('Host returned an invalid enrollment scope.');
        }
        return value;
      });
      return {...enrollment, 'credential': credential};
    } on pg.ServerException catch (error) {
      throw _mapRedeemError(error);
    }
  }

  Future<T> _mutate<T>(Future<T> Function(pg.TxSession tx) action) async {
    return withPostgresConnection(
      connect: connectAdministration,
      pool: administrationPool,
      action: (connection) async {
        await verifyIdentityAdministrationConnection(connection);
        await connection.execute("SET statement_timeout = '15s'");
        await connection.execute("SET lock_timeout = '5s'");
        late T result;
        await admission.change(
          connection,
          (tx) async => result = await action(tx),
          requireAdmissionProof: true,
        );
        return result;
      },
    );
  }

  String _authorize(
    AuthenticatedSession session,
    String companyId,
    String branchId,
  ) {
    final principal = session.principal;
    final digest = session.credentialDigest;
    if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const IdentityPairingException(
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
          identityPairingManagePermission,
          companyId,
          branchId,
        )) {
      throw const IdentityPairingException(
        'PERMISSION_DENIED',
        statusCode: 403,
      );
    }
    return digest;
  }

  IdentityPairingException _mapCreateError(pg.ServerException error) =>
      switch (error.code) {
        '42501' => const IdentityPairingException(
          'PERMISSION_DENIED',
          statusCode: 403,
        ),
        'P0002' => const IdentityPairingException(
          'PAIRING_TARGET_UNAVAILABLE',
          statusCode: 404,
        ),
        '54000' => const IdentityPairingException(
          'PAIRING_RATE_LIMITED',
          statusCode: 429,
          retryable: true,
          retryAfterSeconds: 900,
        ),
        '23505' => const IdentityPairingException(
          'PAIRING_CONFLICT',
          statusCode: 409,
        ),
        '22023' || '23514' => const IdentityPairingException(
          'INVALID_REQUEST',
          statusCode: 400,
        ),
        _ => IdentityPairingException(
          'PAIRING_STORAGE_FAILURE',
          statusCode: 503,
          retryable: true,
          protectedTechnicalCode: error.code,
        ),
      };

  IdentityPairingException _mapRedeemError(pg.ServerException error) =>
      switch (error.code) {
        'P0002' => const IdentityPairingException(
          'PAIRING_INVALID_OR_EXPIRED',
          statusCode: 410,
        ),
        '23505' => const IdentityPairingException(
          'DEVICE_ALREADY_REGISTERED',
          statusCode: 409,
        ),
        '22023' || '23514' => const IdentityPairingException(
          'INVALID_REQUEST',
          statusCode: 400,
        ),
        _ => IdentityPairingException(
          'PAIRING_STORAGE_FAILURE',
          statusCode: 503,
          retryable: true,
          protectedTechnicalCode: error.code,
        ),
      };
}

class IdentityPairingException implements Exception {
  const IdentityPairingException(
    this.code, {
    required this.statusCode,
    this.retryable = false,
    this.retryAfterSeconds,
    this.protectedTechnicalCode,
  });

  final String code;
  final int statusCode;
  final bool retryable;
  final int? retryAfterSeconds;
  final String? protectedTechnicalCode;
}

String _randomHex(int byteCount) {
  final random = math.Random.secure();
  return List<int>.generate(
    byteCount,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
