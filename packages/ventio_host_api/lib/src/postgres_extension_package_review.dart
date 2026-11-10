import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

import 'authentication.dart';
import 'extension_packages.dart';
import 'postgres_connections.dart';
import 'recovery_authority.dart';

const extensionPackageReviewPermission = 'extension.package.review';

/// Authenticated review operations use the restricted Identity API login.
/// PostgreSQL revalidates the scoped grant, candidate digest, submitter, and
/// decision inside the same Recovery Authority-admitted transaction.
class PostgresExtensionPackageReviewGateway
    implements AuthoritativeExtensionPackageReviewGateway {
  const PostgresExtensionPackageReviewGateway({
    this.connect,
    this.pool,
    required this.admission,
    this.platformApiVersion = currentPlatformApiVersion,
  }) : assert((connect == null) != (pool == null));

  final Future<pg.Connection> Function()? connect;
  final pg.Pool<dynamic>? pool;
  final RecoveryAuthority admission;
  final String platformApiVersion;

  @override
  Future<Map<String, dynamic>> listPending({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required int limit,
  }) async {
    final digest = _authorize(session, companyId, branchId);
    if (limit < 1 || limit > 3) {
      throw const ContractError('INVALID_PAGE', 'Invalid candidate page size.');
    }
    return withPostgresConnection(
      connect: connect,
      pool: pool,
      action: (connection) async {
        await _configure(connection);
        return connection.runTx((tx) async {
          await admission.admit(tx);
          final rows = await tx.execute(
            pg.Sql.named('''
              SELECT ventio_security.list_extension_submissions(
                @digest,@tenant,@company,@branch,@limit)::text
            '''),
            parameters: {
              'digest': digest,
              'tenant': session.principal.tenantId,
              'company': companyId,
              'branch': branchId,
              'limit': limit,
            },
          );
          final result = _decode(rows.single[0], 'extension review list');
          if (result['status'] == 'REJECTED' &&
              result['reasonCode'] is String) {
            throw ExtensionPackageReviewException(
              result['reasonCode'] as String,
            );
          }
          return result;
        });
      },
    );
  }

  @override
  Future<Map<String, dynamic>> review({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String moduleId,
    required String version,
    required String packageSha256,
    required String decision,
    String? reason,
  }) async {
    final digest = _authorize(session, companyId, branchId);
    semverParts(version);
    if (!_safeModule(moduleId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(packageSha256) ||
        !const {'APPROVE', 'REJECT'}.contains(decision) ||
        (decision == 'REJECT' &&
            (reason == null || reason.trim().isEmpty || reason.length > 500)) ||
        (decision == 'APPROVE' && reason != null && reason.isNotEmpty)) {
      throw const ContractError(
        'INVALID_REVIEW',
        'Invalid extension review request.',
      );
    }
    return withPostgresConnection(
      connect: connect,
      pool: pool,
      action: (connection) async {
        await _configure(connection);
        Map<String, dynamic>? reviewed;
        ExtensionPackageReviewException? reviewError;
        await admission.change(connection, (tx) async {
          final candidateRows = await tx.execute(
            pg.Sql.named('''
                SELECT ventio_security.get_extension_submission_scoped(
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
          final candidate = _decodeNullable(
            candidateRows.single[0],
            'extension review candidate',
          );
          if (candidate == null || candidate['package'] is! Map) {
            reviewError = const ExtensionPackageReviewException(
              'CANDIDATE_NOT_FOUND',
            );
            return;
          }
          try {
            _validateCandidate(
              candidate,
              moduleId: moduleId,
              version: version,
              packageSha256: packageSha256,
            );
          } on ExtensionPackageReviewException catch (error) {
            reviewError = error;
            return;
          }
          final rows = await tx.execute(
            pg.Sql.named('''
                SELECT ventio_security.review_extension_submission(
                  @digest,@tenant,@company,@branch,@module,@version,@sha256,
                  @decision,@reason)::text
              '''),
            parameters: {
              'digest': digest,
              'tenant': session.principal.tenantId,
              'company': companyId,
              'branch': branchId,
              'module': moduleId,
              'version': version,
              'sha256': packageSha256,
              'decision': decision,
              'reason': reason?.trim(),
            },
          );
          reviewed = _decode(rows.single[0], 'extension review decision');
          if (reviewed!['status'] == 'REJECTED' &&
              reviewed!['reasonCode'] is String) {
            reviewError = ExtensionPackageReviewException(
              reviewed!['reasonCode'] as String,
            );
          }
        }, requireAdmissionProof: true);
        if (reviewError != null) throw reviewError!;
        return reviewed!;
      },
    );
  }

  String _authorize(
    AuthenticatedSession session,
    String companyId,
    String branchId,
  ) {
    final digest = session.credentialDigest;
    if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const ExtensionPackageReviewException('PERMISSION_DENIED');
    }
    if (!session.principal.allowsInScope(
      extensionPackageReviewPermission,
      companyId,
      branchId,
    )) {
      throw const ExtensionPackageReviewException('PERMISSION_DENIED');
    }
    return digest;
  }

  Future<void> _configure(pg.Connection connection) async {
    await connection.execute("SET statement_timeout = '30s'");
    await connection.execute("SET lock_timeout = '10s'");
  }

  void _validateCandidate(
    Map<String, dynamic> candidate, {
    required String moduleId,
    required String version,
    required String packageSha256,
  }) {
    final raw = candidate['package'];
    if (candidate['status'] != 'SUBMITTED' || raw is! Map) {
      throw const ExtensionPackageReviewException('CANDIDATE_CHANGED');
    }
    final bundle = ExtensionBundle.fromJson(Map<String, dynamic>.from(raw));
    final computed = sha256
        .convert(utf8.encode(canonicalJson(bundle.toJson())))
        .toString();
    if (bundle.moduleId != moduleId ||
        bundle.version != version ||
        candidate['packageSha256'] != packageSha256 ||
        computed != packageSha256) {
      throw const ExtensionPackageReviewException('PACKAGE_INTEGRITY_FAILED');
    }
    if (compareSemver(platformApiVersion, bundle.manifest.minPlatformApi) < 0) {
      throw const ExtensionPackageReviewException(
        'PLATFORM_VERSION_UNSUPPORTED',
      );
    }
  }
}

class ExtensionPackageReviewException implements Exception {
  const ExtensionPackageReviewException(this.code);

  final String code;
}

Map<String, dynamic> _decode(dynamic value, String label) {
  final result = _decodeNullable(value, label);
  if (result == null) throw StateError('Host returned an empty $label.');
  return result;
}

Map<String, dynamic>? _decodeNullable(dynamic value, String label) {
  if (value == null) return null;
  final decoded = value is String ? jsonDecode(value) : value;
  if (decoded is! Map) throw StateError('Host returned invalid $label data.');
  return Map<String, dynamic>.from(decoded);
}

bool _safeModule(String value) =>
    value.length <= 128 &&
    RegExp(r'^[a-z][a-z0-9]*([._-][a-z0-9]+)*$').hasMatch(value);
