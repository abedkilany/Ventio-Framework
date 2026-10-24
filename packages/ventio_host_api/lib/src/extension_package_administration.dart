import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

import 'recovery_authority.dart';

/// Local operator workflow for shared package trust changes. Approval and
/// revocation advance the independent recovery witness around the DB commit.
class ExtensionPackageAdministration {
  final pg.Connection connection;
  final String tenantId;
  final String operatorLabel;
  final RecoveryAuthority authority;
  final String platformApiVersion;

  ExtensionPackageAdministration({
    required this.connection,
    required this.tenantId,
    required this.operatorLabel,
    required this.authority,
    this.platformApiVersion = '0.1.0',
  }) {
    _identifier(tenantId);
    _identifier(operatorLabel);
    semverParts(platformApiVersion);
  }

  Future<void> approve({
    required String moduleId,
    required String version,
    required String packageSha256,
  }) async {
    _module(moduleId);
    semverParts(version);
    _hash(packageSha256);
    final rows = await connection.execute(
      pg.Sql.named('''
      SELECT ventio_security.read_extension_submission(@tenant,@module,@version)::text
    '''),
      parameters: {'tenant': tenantId, 'module': moduleId, 'version': version},
    );
    final raw = rows.single[0];
    if (raw is! String) {
      throw StateError('No submitted package exists for that release.');
    }
    final candidate = jsonDecode(raw);
    if (candidate is! Map || candidate['package'] is! Map) {
      throw StateError('Submitted package is not valid declarative metadata.');
    }
    final bundle = ExtensionBundle.fromJson(
      Map<String, dynamic>.from(candidate['package'] as Map),
    );
    final computedHash = sha256
        .convert(utf8.encode(canonicalJson(bundle.toJson())))
        .toString();
    if (bundle.moduleId != moduleId ||
        bundle.version != version ||
        candidate['packageSha256'] != packageSha256 ||
        computedHash != packageSha256) {
      throw StateError('Submitted package identity or digest changed.');
    }
    if (compareSemver(platformApiVersion, bundle.manifest.minPlatformApi) < 0) {
      throw StateError('Package requires a newer Ventio platform version.');
    }
    await _change('EXTENSION_PACKAGE_APPROVED', {
      'moduleId': moduleId,
      'version': version,
      'packageSha256': packageSha256,
    });
  }

  Future<void> revoke({
    required String moduleId,
    required String version,
    required String packageSha256,
    required String reason,
  }) async {
    _module(moduleId);
    semverParts(version);
    _hash(packageSha256);
    if (reason.trim().isEmpty || reason.length > 500) {
      throw ArgumentError(
        'A revocation reason up to 500 characters is required.',
      );
    }
    await _change('EXTENSION_PACKAGE_REVOKED', {
      'moduleId': moduleId,
      'version': version,
      'packageSha256': packageSha256,
      'reason': reason.trim(),
    });
  }

  Future<void> _change(String action, Map<String, Object?> fields) async {
    await authority.change(connection, (tx) async {
      await tx.execute(
        pg.Sql.named(
          'SELECT ventio_security.admin_change(CAST(@change AS jsonb))',
        ),
        parameters: {
          'change': jsonEncode({
            'tenantId': tenantId,
            'operatorLabel': operatorLabel,
            'action': action,
            ...fields,
          }),
        },
      );
    });
  }
}

void _identifier(String value) {
  if (value.trim().isEmpty || value.length > 256) {
    throw ArgumentError('Invalid extension administration identifier.');
  }
}

void _module(String value) {
  if (value.length > 128 ||
      !RegExp(r'^[a-z][a-z0-9]*([._-][a-z0-9]+)*$').hasMatch(value)) {
    throw ArgumentError('Invalid extension module ID.');
  }
}

void _hash(String value) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw ArgumentError('Invalid extension package digest.');
  }
}
