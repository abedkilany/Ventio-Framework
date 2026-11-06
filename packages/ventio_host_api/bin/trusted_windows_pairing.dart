import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_host_api/ventio_host_api.dart';

/// Fixed operation launched only by VentioHostService after its administrator-
/// only named-pipe caller check. Input is supplied through stdin, never argv or
/// environment. Stdout contains only the one-time pairing response; failures
/// are reduced to a safe stable code.
Future<void> main() async {
  pg.Connection? connection;
  try {
    final source = await _readRequest();
    final request = jsonDecode(source);
    if (request is! Map<String, dynamic> ||
        request.keys.toSet().difference({
          'tenantId',
          'operatorActorId',
          'targetActorId',
          'companyId',
          'branchId',
          'requestId',
          'permissions',
          'operatorCredentialDigest',
          'windowsAdminTag',
        }).isNotEmpty ||
        request.keys.length != 9 ||
        request['tenantId'] is! String ||
        request['operatorActorId'] is! String ||
        request['targetActorId'] is! String ||
        request['companyId'] is! String ||
        request['branchId'] is! String ||
        request['requestId'] is! String ||
        request['operatorCredentialDigest'] is! String ||
        request['windowsAdminTag'] is! String ||
        request['permissions'] is! List ||
        (request['permissions'] as List).any((value) => value is! String)) {
      throw const TrustedWindowsPairingException('INVALID_REQUEST');
    }
    final databaseUrl =
        Platform.environment['VENTIO_HOST_IDENTITY_API_DATABASE_URL'];
    final authorityPath =
        Platform.environment['VENTIO_RECOVERY_AUTHORITY_FILE'];
    final ownerSid =
        Platform.environment['VENTIO_RECOVERY_AUTHORITY_OWNER_SID'];
    final readerSid =
        Platform.environment['VENTIO_RECOVERY_AUTHORITY_READER_SID'];
    if (databaseUrl == null ||
        databaseUrl.isEmpty ||
        authorityPath == null ||
        authorityPath.isEmpty ||
        ownerSid == null ||
        readerSid == null ||
        Platform.environment['VENTIO_RECOVERY_AUTHORITY_HOST_WRITES'] !=
            'yes') {
      throw const TrustedWindowsPairingException('HOST_CONFIGURATION_INVALID');
    }
    connection = await pg.Connection.openFromUrl(databaseUrl);
    await verifyIdentityAdministrationConnection(connection);
    final authority = RecoveryAuthority(
      authorityPath,
      trustedOwnerSid: ownerSid,
      readerSid: readerSid,
      allowHostMutations: true,
    );
    final pairing =
        await TrustedWindowsPairingGateway(
          connection: connection,
          tenantId: request['tenantId'] as String,
          authority: authority,
          windowsAdminTag: request['windowsAdminTag'] as String,
        ).create(
          operatorCredentialDigest:
              request['operatorCredentialDigest'] as String,
          operatorActorId: request['operatorActorId'] as String,
          targetActorId: request['targetActorId'] as String,
          companyId: request['companyId'] as String,
          branchId: request['branchId'] as String,
          requestId: request['requestId'] as String,
          permissions: (request['permissions'] as List).cast<String>(),
        );
    stdout.writeln(jsonEncode({'status': 'created', ...pairing.toJson()}));
  } on TrustedWindowsPairingException catch (error) {
    stdout.writeln(jsonEncode({'status': 'failed', 'failureCode': error.code}));
    exitCode = 2;
  } on Object {
    stdout.writeln(
      jsonEncode({'status': 'failed', 'failureCode': 'TRUSTED_PAIRING_FAILED'}),
    );
    exitCode = 2;
  } finally {
    await connection?.close();
  }
}

Future<String> _readRequest() async {
  final output = StringBuffer();
  var bytes = 0;
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    bytes += utf8.encode(line).length + 1;
    if (bytes > 16384) {
      throw const TrustedWindowsPairingException('INVALID_REQUEST');
    }
    if (output.length > 0) {
      throw const TrustedWindowsPairingException('INVALID_REQUEST');
    }
    output.write(line);
  }
  if (bytes == 0 || output.length == 0) {
    throw const TrustedWindowsPairingException('INVALID_REQUEST');
  }
  return output.toString();
}
