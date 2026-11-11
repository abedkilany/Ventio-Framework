import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_host_api/ventio_host_api.dart';

/// Fixed operation launched only by VentioHostService after its protected
/// administrator named-pipe check. Raw replacement credentials are generated,
/// DPAPI-protected and stored only as ciphertext by the reissue gateway.
Future<void> main() async {
  pg.Connection? connection;
  try {
    final source = await _readRequest();
    final request = jsonDecode(source);
    const keys = {
      'tenantId',
      'operatorActorId',
      'companyId',
      'branchId',
      'deviceId',
      'targetActorId',
      'sourceCredentialId',
      'operationId',
      'permissions',
      'approvedRemovals',
      'operatorCredentialDigest',
      'windowsAdminTag',
    };
    if (request is! Map<String, dynamic> ||
        request.length != keys.length ||
        request.keys.any((key) => !keys.contains(key)) ||
        request['tenantId'] is! String ||
        request['operatorActorId'] is! String ||
        request['companyId'] is! String ||
        request['branchId'] is! String ||
        request['deviceId'] is! String ||
        request['targetActorId'] is! String ||
        request['sourceCredentialId'] is! String ||
        request['operationId'] is! String ||
        request['operatorCredentialDigest'] is! String ||
        request['windowsAdminTag'] is! String ||
        request['permissions'] is! List ||
        request['approvedRemovals'] is! List ||
        (request['permissions'] as List).any((value) => value is! String) ||
        (request['approvedRemovals'] as List).any(
          (value) => value is! String,
        )) {
      throw const CredentialReissueException('INVALID_REQUEST');
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
      throw const CredentialReissueException('HOST_CONFIGURATION_INVALID');
    }
    connection = await pg.Connection.openFromUrl(databaseUrl);
    await verifyIdentityAdministrationConnection(connection);
    final authority = RecoveryAuthority(
      authorityPath,
      trustedOwnerSid: ownerSid,
      readerSid: readerSid,
      allowHostMutations: true,
    );
    final result =
        await TrustedCredentialReissueGateway(
          connection: connection,
          tenantId: request['tenantId'] as String,
          authority: authority,
          windowsAdminTag: request['windowsAdminTag'] as String,
        ).prepare(
          operatorCredentialDigest:
              request['operatorCredentialDigest'] as String,
          operatorActorId: request['operatorActorId'] as String,
          companyId: request['companyId'] as String,
          branchId: request['branchId'] as String,
          deviceId: request['deviceId'] as String,
          targetActorId: request['targetActorId'] as String,
          sourceCredentialId: request['sourceCredentialId'] as String,
          operationId: request['operationId'] as String,
          permissions: (request['permissions'] as List).cast<String>(),
          approvedRemovals: (request['approvedRemovals'] as List)
              .cast<String>(),
        );
    stdout.writeln(jsonEncode({'status': 'created', ...result}));
  } on CredentialReissueException catch (error) {
    stdout.writeln(jsonEncode({'status': 'failed', 'failureCode': error.code}));
    exitCode = 2;
  } on Object {
    stdout.writeln(
      jsonEncode({'status': 'failed', 'failureCode': 'REISSUE_FAILED'}),
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
    if (bytes > 65536 || output.isNotEmpty) {
      throw const CredentialReissueException('INVALID_REQUEST');
    }
    output.write(line);
  }
  if (bytes == 0 || output.isEmpty) {
    throw const CredentialReissueException('INVALID_REQUEST');
  }
  return output.toString();
}
