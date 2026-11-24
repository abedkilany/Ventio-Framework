import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

/// Fixed helper invoked by the existing administrator-only local named pipe.
/// No network route, command-line password, credential file, or password log.
Future<void> main() async {
  pg.Connection? connection;
  try {
    final bytes = <int>[];
    await for (final chunk in stdin) {
      if (bytes.length + chunk.length > 8192) throw const FormatException();
      bytes.addAll(chunk);
    }
    final request = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(bytes)) as Map,
    );
    bytes.fillRange(0, bytes.length, 0);
    if (request.keys.toSet().difference({
          'tenantId',
          'companyId',
          'branchId',
          'actorId',
          'mode',
          'username',
          'password',
          'windowsAdminTag',
          'windowsAdminSid',
        }).isNotEmpty ||
        request.length != 9 ||
        request['password'] is! String ||
        request['username'] is! String ||
        !AccountPassword.validUsername(request['username'] as String))
      throw const FormatException();
    final hash = await AccountPassword.hash(
      request.remove('password') as String,
    );
    request['passwordHash'] = hash;
    for (final field in ['companyId', 'branchId', 'actorId']) {
      if (request[field] == '') request[field] = null;
    }
    final random = Random.secure();
    final pairingId =
        'pair_${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final code = OpaqueToken.generate();
    request['tokenDigest'] = OpaqueToken.digest(code);
    request['credentialId'] = pairingId;
    final database =
        Platform.environment['VENTIO_HOST_IDENTITY_API_DATABASE_URL'];
    final authorityPath =
        Platform.environment['VENTIO_RECOVERY_AUTHORITY_FILE'];
    if (!Platform.isWindows ||
        database == null ||
        authorityPath == null ||
        Platform.environment['VENTIO_RECOVERY_AUTHORITY_HOST_WRITES'] != 'yes')
      throw StateError('Configuration required');
    connection = await pg.Connection.openFromUrl(database);
    await verifyIdentityAdministrationConnection(connection);
    final authority = RecoveryAuthority(
      authorityPath,
      trustedOwnerSid:
          Platform.environment['VENTIO_RECOVERY_AUTHORITY_OWNER_SID'],
      readerSid: Platform.environment['VENTIO_RECOVERY_AUTHORITY_READER_SID'],
      allowHostMutations: true,
    );
    String? raw;
    await authority.change(connection, (tx) async {
      raw =
          (await tx.execute(
                pg.Sql.named(
                  'SELECT ventio_security.local_owner_recover(CAST(@body AS jsonb))::text',
                ),
                parameters: {'body': jsonEncode(request)},
              )).single[0]
              as String;
    }, requireAdmissionProof: true);
    stdout.writeln(
      jsonEncode({
        'status': 'created',
        'owner': {
          ...Map<String, dynamic>.from(jsonDecode(raw!) as Map),
          'pairingId': pairingId,
          'code': code,
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 5))
              .toIso8601String(),
        },
      }),
    );
  } catch (_) {
    stdout.writeln('{"status":"failed","failureCode":"OWNER_RECOVERY_DENIED"}');
    exitCode = 2;
  } finally {
    await connection?.close();
  }
}
