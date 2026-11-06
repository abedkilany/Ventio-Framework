import 'package:postgres/postgres.dart' as pg;

import 'authentication.dart';
import 'recovery_authority.dart';

/// One-time pairing issued after explicit local Windows administrator approval.
/// The pairing code is returned only to the trusted local caller and is never
/// stored in PostgreSQL or Host diagnostics.
class TrustedWindowsPairing {
  const TrustedWindowsPairing({
    required this.pairingId,
    required this.actorId,
    required this.companyId,
    required this.branchId,
    required this.permissions,
    required this.code,
    required this.expiresAtUtc,
  });

  final String pairingId;
  final String actorId;
  final String companyId;
  final String branchId;
  final List<String> permissions;
  final String code;
  final DateTime expiresAtUtc;

  Map<String, Object?> toJson() => {
    'pairingId': pairingId,
    'actorId': actorId,
    'companyId': companyId,
    'branchId': branchId,
    'permissions': permissions,
    'code': code,
    'expiresAtUtc': expiresAtUtc.toUtc().toIso8601String(),
  };
}

class TrustedWindowsPairingException implements Exception {
  const TrustedWindowsPairingException(this.code);

  /// Safe stable code. Never contains database text or request data.
  final String code;

  @override
  String toString() => 'Trusted pairing failed: $code';
}

/// Database half of the local Windows operator path. Callers must be the
/// Host service's administrator-only named-pipe broker, never an HTTP route.
/// PostgreSQL independently verifies the operator's live pairing credential,
/// exact branch authority, target grants and Recovery Authority admission.
class TrustedWindowsPairingGateway {
  const TrustedWindowsPairingGateway({
    required this.connection,
    required this.tenantId,
    required this.authority,
    required this.windowsAdminTag,
  });

  final pg.Connection connection;
  final String tenantId;
  final RecoveryAuthority authority;
  final String windowsAdminTag;

  Future<TrustedWindowsPairing> create({
    required String operatorCredentialDigest,
    required String operatorActorId,
    required String targetActorId,
    required String companyId,
    required String branchId,
    required String requestId,
    required List<String> permissions,
  }) async {
    _identifier(tenantId);
    for (final value in [operatorActorId, targetActorId, companyId, branchId]) {
      _identifier(value);
    }
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId) ||
        !RegExp(r'^[0-9a-f]{16}$').hasMatch(windowsAdminTag) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(operatorCredentialDigest)) {
      throw const TrustedWindowsPairingException('INVALID_REQUEST');
    }
    if (permissions.isEmpty ||
        permissions.length > 64 ||
        permissions.toSet().length != permissions.length ||
        permissions.any(
          (permission) =>
              !_permissionPattern.hasMatch(permission) ||
              _reservedPermission.hasMatch(permission),
        )) {
      throw const TrustedWindowsPairingException('INVALID_REQUEST');
    }
    final sortedPermissions = permissions.toList()..sort();
    final code = OpaqueToken.generate();
    final pairingId = 'pair_$requestId';
    final pairingDigest = OpaqueToken.digest(code);
    DateTime? mutationExpiry;
    try {
      await authority.changeMeasured(connection, (tx) async {
        final rows = await tx.execute(
          pg.Sql.named('''
              SELECT ventio_security.trusted_windows_pairing_create(
                @operatorDigest,@tenant,@operatorActor,@company,@branch,
                @targetActor,@pairingId,@pairingDigest,@permissions,
                @windowsAdminTag)
            '''),
          parameters: {
            'operatorDigest': operatorCredentialDigest,
            'tenant': tenantId,
            'operatorActor': operatorActorId,
            'company': companyId,
            'branch': branchId,
            'targetActor': targetActorId,
            'pairingId': pairingId,
            'pairingDigest': pairingDigest,
            'permissions': sortedPermissions,
            'windowsAdminTag': windowsAdminTag,
          },
        );
        final expiresAt = rows.single[0];
        if (expiresAt is! DateTime) {
          throw const TrustedWindowsPairingException('INVALID_OUTCOME');
        }
        mutationExpiry = expiresAt.toUtc();
      }, requireAdmissionProof: true);
      return TrustedWindowsPairing(
        pairingId: pairingId,
        actorId: targetActorId,
        companyId: companyId,
        branchId: branchId,
        permissions: List.unmodifiable(sortedPermissions),
        code: code,
        expiresAtUtc: mutationExpiry!,
      );
    } on TrustedWindowsPairingException {
      rethrow;
    } on RecoveryAdmissionUnavailable {
      throw const TrustedWindowsPairingException(
        'RECOVERY_AUTHORITY_UNAVAILABLE',
      );
    } on RecoveryAuthorityBusy {
      throw const TrustedWindowsPairingException('RECOVERY_AUTHORITY_BUSY');
    } on RecoveryMutationOutcomeUnknown {
      throw const TrustedWindowsPairingException('OUTCOME_UNKNOWN');
    } on pg.ServerException catch (error) {
      final safeCode = switch (error.code) {
        '42501' => 'OPERATOR_OR_PERMISSION_DENIED',
        'P0002' => 'TARGET_UNAVAILABLE',
        'P0001' => 'PAIRING_CODE_UNAVAILABLE',
        '23505' => 'REQUEST_ALREADY_USED',
        '54000' => 'PAIRING_RATE_LIMITED',
        '22023' => 'INVALID_REQUEST',
        _ => 'DATABASE_UNAVAILABLE',
      };
      throw TrustedWindowsPairingException(safeCode);
    } on Object {
      throw const TrustedWindowsPairingException('OUTCOME_UNKNOWN');
    }
  }

  static final _permissionPattern = RegExp(r'^[a-z][a-z0-9_.]{0,255}$');
  static final _reservedPermission = RegExp(
    r'^(identity|host|system|security|recovery|authorization)\.',
  );

  static void _identifier(String value) {
    if (value.trim().isEmpty ||
        value.length > 256 ||
        value.trim() != value ||
        value.runes.any((character) => character < 0x20 || character == 0x7f)) {
      throw const TrustedWindowsPairingException('INVALID_REQUEST');
    }
  }
}
