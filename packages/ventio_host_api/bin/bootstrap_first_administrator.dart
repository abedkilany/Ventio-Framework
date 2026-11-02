import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_host_api/ventio_host_api.dart';

Future<void> main(List<String> args) async {
  pg.Connection? connection;
  var failureCode = 'HOST_FIRST_ADMIN_REQUEST_INVALID';
  try {
    if (args.isNotEmpty) throw const FormatException();
    final requestBytes = await stdin.fold<List<int>>(<int>[], (buffer, chunk) {
      if (buffer.length + chunk.length > 8192) {
        throw const FormatException();
      }
      return buffer..addAll(chunk);
    });
    final request =
        jsonDecode(utf8.decode(requestBytes)) as Map<String, dynamic>;
    const keys = {
      'formatVersion',
      'requestId',
      'tenantId',
      'companyId',
      'branchId',
      'operatorLabel',
      'actorId',
      'deviceId',
      'credentialId',
      'token',
      'expiresAt',
    };
    if (request.length != keys.length ||
        !request.keys.every(keys.contains) ||
        request['formatVersion'] != 1) {
      throw const FormatException();
    }
    String field(String key) {
      final value = request[key];
      if (value is! String || value.isEmpty || value.length > 256) {
        throw const FormatException();
      }
      return value;
    }

    final requestId = field('requestId');
    final tenantId = field('tenantId');
    final companyId = field('companyId');
    final branchId = field('branchId');
    final operatorLabel = field('operatorLabel');
    final actorId = field('actorId');
    final deviceId = field('deviceId');
    final credentialId = field('credentialId');
    final token = field('token');
    final expiresAt = DateTime.tryParse(field('expiresAt'))?.toUtc();
    if (!OpaqueToken.isValid(requestId) ||
        !OpaqueToken.isValid(token) ||
        expiresAt == null ||
        !expiresAt.isAfter(DateTime.now().toUtc()) ||
        expiresAt.isAfter(
          DateTime.now().toUtc().add(const Duration(days: 30)),
        )) {
      throw const FormatException();
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
      throw const FormatException();
    }

    final authority = RecoveryAuthority(
      authorityPath,
      trustedOwnerSid: ownerSid,
      readerSid: readerSid,
      allowHostMutations: true,
    );
    failureCode = 'HOST_FIRST_ADMIN_DATABASE_CONNECTION_FAILED';
    connection = await pg.Connection.openFromUrl(databaseUrl);
    failureCode = 'HOST_FIRST_ADMIN_RECOVERY_AUTHORITY_FAILED';
    await authority.prepareFirstAdministratorBootstrap(
      connection,
      requestId: requestId,
      tenantId: tenantId,
      actorId: actorId,
      companyId: companyId,
      branchId: branchId,
      deviceId: deviceId,
      credentialId: credentialId,
      token: token,
      expiresAt: expiresAt,
    );
    failureCode = 'HOST_FIRST_ADMIN_IDENTITY_BOOTSTRAP_FAILED';
    final administration = IdentityAdministration(
      connection: connection,
      bootstrapConnection: connection,
      tenantId: tenantId,
      operatorLabel: operatorLabel,
      authority: authority,
    );
    final credential = await administration.bootstrapFirstAdministrator(
      companyId: companyId,
      branchId: branchId,
      deviceId: deviceId,
      credentialId: credentialId,
      expiresAt: expiresAt,
      requestId: requestId,
      credential: InitialHostAdministratorCredential(
        actorId: actorId,
        token: token,
      ),
    );
    failureCode = 'HOST_FIRST_ADMIN_RESULT_INVALID';
    stdout.write(jsonEncode({'success': true, 'actorId': credential.actorId}));
  } catch (_) {
    stderr.writeln(failureCode);
    exitCode = 1;
  } finally {
    try {
      await connection?.close();
    } catch (_) {
      // Closing a committed bootstrap connection must not invalidate success.
    }
  }
}
