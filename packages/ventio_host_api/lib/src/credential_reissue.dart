import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:postgres/postgres.dart' as pg;
import 'authentication.dart';
import 'postgres_connections.dart';
import 'recovery_authority.dart';
import 'windows_dpapi.dart';

abstract interface class CredentialReissueCipher {
  Uint8List protect(Uint8List plaintext, String operationId);
  Uint8List unprotect(Uint8List ciphertext, String operationId);
}

/// Windows machine DPAPI protects the pending bearer at rest. The Host stores
/// only a digest in identity credentials and this encrypted, short-lived
/// delivery envelope in the Recovery Authority protected transition row.
class WindowsCredentialReissueCipher implements CredentialReissueCipher {
  const WindowsCredentialReissueCipher({
    WindowsDpapi dpapi = const WindowsDpapi(),
  }) : _dpapi = dpapi;

  final WindowsDpapi _dpapi;

  @override
  Uint8List protect(Uint8List plaintext, String operationId) =>
      _dpapi.protect(plaintext, operationId);

  @override
  Uint8List unprotect(Uint8List ciphertext, String operationId) =>
      _dpapi.unprotect(ciphertext, operationId);
}

class CredentialReissueException implements Exception {
  const CredentialReissueException(this.code, {this.statusCode = 409});

  final String code;
  final int statusCode;

  @override
  String toString() => 'Credential reissue failed: $code';
}

class TrustedCredentialReissueGateway {
  const TrustedCredentialReissueGateway({
    required this.connection,
    required this.tenantId,
    required this.authority,
    required this.windowsAdminTag,
    this.cipher = const WindowsCredentialReissueCipher(),
  });

  final pg.Connection connection;
  final String tenantId;
  final RecoveryAuthority authority;
  final String windowsAdminTag;
  final CredentialReissueCipher cipher;

  /// Called only by the service's local named-pipe/UAC workflow. It returns
  /// transition metadata, never the replacement bearer.
  Future<Map<String, dynamic>> prepare({
    required String operatorCredentialDigest,
    required String operatorActorId,
    required String companyId,
    required String branchId,
    required String deviceId,
    required String targetActorId,
    required String sourceCredentialId,
    required String operationId,
    required List<String> permissions,
    required List<String> approvedRemovals,
  }) async {
    if (!_hex64Pattern.hasMatch(operatorCredentialDigest) ||
        !_safeId.hasMatch(operatorActorId) ||
        !_safeId.hasMatch(companyId) ||
        !_safeId.hasMatch(branchId) ||
        !_safeDeviceId(deviceId) ||
        !_safeId.hasMatch(targetActorId) ||
        !_safeCredentialId(sourceCredentialId) ||
        !_operationId.hasMatch(operationId) ||
        !_safeId.hasMatch(tenantId) ||
        !RegExp(r'^[0-9a-f]{16}$').hasMatch(windowsAdminTag) ||
        permissions.isEmpty ||
        permissions.length > 128 ||
        permissions.toSet().length != permissions.length ||
        permissions.any((p) => !_safePermission.hasMatch(p)) ||
        approvedRemovals.length > 128 ||
        approvedRemovals.toSet().length != approvedRemovals.length ||
        approvedRemovals.any((p) => !_safePermission.hasMatch(p))) {
      throw const CredentialReissueException(
        'INVALID_REQUEST',
        statusCode: 400,
      );
    }
    final sortedPermissions = permissions.toList()..sort();
    final sortedRemovals = approvedRemovals.toList()..sort();
    final replacementToken = OpaqueToken.generate();
    final replacementId = 'cred_${_randomHex(16)}';
    final digest = OpaqueToken.digest(replacementToken);
    final plainBytes = Uint8List.fromList(utf8.encode(replacementToken));
    Uint8List? encrypted;
    try {
      encrypted = cipher.protect(plainBytes, operationId);
      late Map<String, dynamic> result;
      await authority.changeMeasured(connection, (tx) async {
        final rows = await tx.execute(
          pg.Sql.named('''
              SELECT ventio_security.trusted_windows_credential_reissue_prepare(
                @operatorDigest,@tenant,@operatorActor,@company,@branch,
                @device,@targetActor,@sourceCredentialId,@operationId,@replacementId,
                @replacementDigest,@ciphertext,@permissions,@approvedRemovals,
                @windowsAdminTag)::text
            '''),
          parameters: {
            'operatorDigest': operatorCredentialDigest,
            'tenant': tenantId,
            'operatorActor': operatorActorId,
            'company': companyId,
            'branch': branchId,
            'device': deviceId,
            'targetActor': targetActorId,
            'sourceCredentialId': sourceCredentialId,
            'operationId': operationId,
            'replacementId': replacementId,
            'replacementDigest': digest,
            'ciphertext': encrypted,
            'permissions': sortedPermissions,
            'approvedRemovals': sortedRemovals,
            'windowsAdminTag': windowsAdminTag,
          },
        );
        final raw = rows.single[0];
        if (raw is! String) {
          throw const CredentialReissueException('INVALID_OUTCOME');
        }
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          throw const CredentialReissueException('INVALID_OUTCOME');
        }
        result = Map<String, dynamic>.from(decoded);
        if (result['operationId'] != operationId ||
            result['tenantId'] != tenantId ||
            result['actorId'] != targetActorId ||
            result['deviceId'] != deviceId ||
            result['companyId'] != companyId ||
            result['branchId'] != branchId ||
            result['credentialId'] is! String ||
            result['permissions'] is! List) {
          throw const CredentialReissueException('INVALID_OUTCOME');
        }
      }, requireAdmissionProof: true);
      return result;
    } on CredentialReissueException {
      rethrow;
    } on RecoveryAdmissionUnavailable {
      throw const CredentialReissueException(
        'RECOVERY_AUTHORITY_UNAVAILABLE',
        statusCode: 503,
      );
    } on RecoveryAuthorityBusy {
      throw const CredentialReissueException(
        'RECOVERY_AUTHORITY_BUSY',
        statusCode: 503,
      );
    } on RecoveryMutationOutcomeUnknown {
      throw const CredentialReissueException(
        'OUTCOME_UNKNOWN',
        statusCode: 503,
      );
    } on pg.ServerException catch (error) {
      final mapping = switch (error.code) {
        '42501' => ('PERMISSION_OR_GRANT_DENIED', 403),
        'P0002' => ('TARGET_UNAVAILABLE', 404),
        '23505' => ('OPERATION_REFERENCE_CONFLICT', 409),
        '55P03' => ('REISSUE_ALREADY_PENDING', 409),
        '22023' => ('INVALID_REQUEST', 400),
        _ => ('DATABASE_UNAVAILABLE', 503),
      };
      throw CredentialReissueException(mapping.$1, statusCode: mapping.$2);
    } on Object {
      throw const CredentialReissueException(
        'OUTCOME_UNKNOWN',
        statusCode: 503,
      );
    } finally {
      plainBytes.fillRange(0, plainBytes.length, 0);
      encrypted?.fillRange(0, encrypted.length, 0);
    }
  }

  static final _hex64Pattern = RegExp(r'^[0-9a-f]{64}$');
  static final _operationId = RegExp(r'^reissue_[0-9a-f]{32}$');
  static final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$');
  static final _safePermission = RegExp(r'^[a-z][a-z0-9_.]{0,255}$');

  static bool _safeDeviceId(String value) =>
      _safeId.hasMatch(value) &&
      !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(value);

  static bool _safeCredentialId(String value) =>
      _safeId.hasMatch(value) &&
      !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(value);

  static String _randomHex(int count) {
    final random = math.Random.secure();
    return List<int>.generate(
      count,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// Authenticated Client side of a prepared transition. Claim requires the
/// still-valid source credential for this exact actor/device. Acknowledge
/// requires the new token and a Recovery Authority-admitted transaction.
abstract interface class AuthoritativeIdentityCredentialReissueGateway {
  Future<Map<String, dynamic>> claim({
    required AuthenticatedSession session,
    String? operationId,
  });

  Future<Map<String, dynamic>> acknowledge({
    required String replacementToken,
    required String operationId,
  });
}

class IdentityCredentialReissueGateway
    implements AuthoritativeIdentityCredentialReissueGateway {
  const IdentityCredentialReissueGateway({
    required this.connectApi,
    required this.apiPool,
    required this.authority,
    this.cipher = const WindowsCredentialReissueCipher(),
  }) : assert((connectApi == null) != (apiPool == null));

  final Future<pg.Connection> Function()? connectApi;
  final pg.Pool<dynamic>? apiPool;
  final RecoveryAuthority authority;
  final CredentialReissueCipher cipher;

  @override
  Future<Map<String, dynamic>> claim({
    required AuthenticatedSession session,
    String? operationId,
  }) async {
    final digest = session.credentialDigest;
    final principal = session.principal;
    if (digest == null ||
        !_hex64Pattern.hasMatch(digest) ||
        (operationId != null && !_operationId.hasMatch(operationId))) {
      throw const CredentialReissueException(
        'INVALID_REQUEST',
        statusCode: 400,
      );
    }
    try {
      final envelope = await withPostgresConnection(
        connect: connectApi,
        pool: apiPool,
        action: (connection) async {
          await connection.execute('SELECT ventio_security.assert_schema()');
          await connection.execute("SET statement_timeout = '20s'");
          return connection.runTx((tx) async {
            final rows = operationId == null
                ? await tx.execute(
                    pg.Sql.named('''
                      SELECT ventio_security.credential_reissue_pending_claim(
                        @sourceDigest)::text
                    '''),
                    parameters: {'sourceDigest': digest},
                  )
                : await tx.execute(
                    pg.Sql.named('''
                      SELECT ventio_security.credential_reissue_claim(
                        @sourceDigest,@operationId)::text
                    '''),
                    parameters: {
                      'sourceDigest': digest,
                      'operationId': operationId,
                    },
                  );
            final raw = rows.single[0];
            if (raw is! String)
              throw const CredentialReissueException('INVALID_OUTCOME');
            final decoded = jsonDecode(raw);
            if (decoded is! Map)
              throw const CredentialReissueException('INVALID_OUTCOME');
            return Map<String, dynamic>.from(decoded);
          });
        },
      );
      final ciphertextValue = envelope.remove('deliveryCiphertext');
      if (envelope['state'] == 'NONE') return const {'state': 'NONE'};
      if (envelope['tenantId'] != principal.tenantId ||
          envelope['actorId'] != principal.actorId ||
          envelope['deviceId'] != principal.deviceId ||
          (operationId != null && envelope['operationId'] != operationId) ||
          envelope['state'] != 'PREPARED' ||
          ciphertextValue is! String) {
        throw const CredentialReissueException(
          'REISSUE_NOT_AVAILABLE',
          statusCode: 404,
        );
      }
      final claimedOperationId = envelope['operationId'];
      if (claimedOperationId is! String ||
          !_operationId.hasMatch(claimedOperationId)) {
        throw const CredentialReissueException(
          'INVALID_OUTCOME',
          statusCode: 503,
        );
      }
      final expiry = envelope['expiresAtUtc'];
      final parsedExpiry = expiry is String ? DateTime.tryParse(expiry) : null;
      final permissions = envelope['permissions'];
      if (envelope['credentialId'] is! String ||
          parsedExpiry == null ||
          !parsedExpiry.isUtc ||
          !parsedExpiry.isAfter(DateTime.now().toUtc()) ||
          permissions is! List ||
          permissions.length > 128 ||
          permissions.any(
            (item) => item is! String || !_permissionPattern.hasMatch(item),
          )) {
        throw const CredentialReissueException(
          'INVALID_OUTCOME',
          statusCode: 503,
        );
      }
      final cipherBytes = base64.decode(ciphertextValue);
      if (cipherBytes.isEmpty || cipherBytes.length > 8192) {
        throw const CredentialReissueException(
          'INVALID_OUTCOME',
          statusCode: 503,
        );
      }
      final clear = cipher.unprotect(
        Uint8List.fromList(cipherBytes),
        claimedOperationId,
      );
      try {
        final token = utf8.decode(clear);
        if (!_tokenPattern.hasMatch(token)) {
          throw const CredentialReissueException(
            'INVALID_OUTCOME',
            statusCode: 503,
          );
        }
        return {...envelope, 'credential': token};
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } on CredentialReissueException {
      rethrow;
    } on pg.ServerException catch (error) {
      throw CredentialReissueException(
        switch (error.code) {
          '42501' => 'REISSUE_NOT_AVAILABLE',
          'P0002' => 'REISSUE_NOT_AVAILABLE',
          '22023' => 'INVALID_REQUEST',
          _ => 'DATABASE_UNAVAILABLE',
        },
        statusCode: error.code == '42501'
            ? 403
            : error.code == 'P0002'
            ? 404
            : 503,
      );
    } on Object {
      throw const CredentialReissueException(
        'DELIVERY_UNAVAILABLE',
        statusCode: 503,
      );
    }
  }

  @override
  Future<Map<String, dynamic>> acknowledge({
    required String replacementToken,
    required String operationId,
  }) async {
    if (!_tokenPattern.hasMatch(replacementToken) ||
        !_operationId.hasMatch(operationId)) {
      throw const CredentialReissueException(
        'INVALID_REQUEST',
        statusCode: 400,
      );
    }
    final digest = OpaqueToken.digest(replacementToken);
    try {
      late Map<String, dynamic> result;
      await withPostgresConnection(
        connect: connectApi,
        pool: apiPool,
        action: (connection) async {
          await connection.execute('SELECT ventio_security.assert_schema()');
          await connection.execute("SET statement_timeout = '60s'");
          await connection.execute("SET lock_timeout = '15s'");
          await authority.changeMeasured(connection, (tx) async {
            final rows = await tx.execute(
              pg.Sql.named('''
                  SELECT ventio_security.credential_reissue_finalize(
                    @replacementDigest,@operationId)::text
                '''),
              parameters: {
                'replacementDigest': digest,
                'operationId': operationId,
              },
            );
            final raw = rows.single[0];
            if (raw is! String)
              throw const CredentialReissueException('INVALID_OUTCOME');
            final decoded = jsonDecode(raw);
            if (decoded is! Map)
              throw const CredentialReissueException('INVALID_OUTCOME');
            result = Map<String, dynamic>.from(decoded);
          }, requireAdmissionProof: true);
        },
      );
      if (result['operationId'] != operationId) {
        throw const CredentialReissueException(
          'INVALID_OUTCOME',
          statusCode: 503,
        );
      }
      return result;
    } on CredentialReissueException {
      rethrow;
    } on RecoveryAdmissionUnavailable {
      throw const CredentialReissueException(
        'RECOVERY_AUTHORITY_UNAVAILABLE',
        statusCode: 503,
      );
    } on RecoveryAuthorityBusy {
      throw const CredentialReissueException(
        'RECOVERY_AUTHORITY_BUSY',
        statusCode: 503,
      );
    } on RecoveryMutationOutcomeUnknown {
      throw const CredentialReissueException(
        'OUTCOME_UNKNOWN',
        statusCode: 503,
      );
    } on pg.ServerException catch (error) {
      throw CredentialReissueException(
        switch (error.code) {
          '42501' => 'REISSUE_NOT_AVAILABLE',
          'P0002' => 'REISSUE_NOT_AVAILABLE',
          '22023' => 'INVALID_REQUEST',
          _ => 'DATABASE_UNAVAILABLE',
        },
        statusCode: error.code == '42501'
            ? 403
            : error.code == 'P0002'
            ? 404
            : 503,
      );
    } on Object {
      throw const CredentialReissueException(
        'OUTCOME_UNKNOWN',
        statusCode: 503,
      );
    }
  }

  static final _operationId = RegExp(r'^reissue_[0-9a-f]{32}$');
  static final _hex64Pattern = RegExp(r'^[0-9a-f]{64}$');
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43,128}$');
  static final _permissionPattern = RegExp(r'^[a-z][a-z0-9_.]{0,255}$');
}
