// Test-only administration process with real pre/post-COMMIT SIGKILL barriers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_host_api/ventio_host_api.dart';

Future<void> main(List<String> args) async {
  final config =
      jsonDecode(await PrivateFiles.read(args.single)) as Map<String, dynamic>;
  final url = config['administrationDatabaseUrl'] as String;
  if (Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
      Uri.parse(url).path != '/ventio_host_test' ||
      !{'localhost', '127.0.0.1'}.contains(Uri.parse(url).host)) exit(2);
  final db = await pg.Connection.openFromUrl(url);
  final backend = (await db.execute('SELECT pg_backend_pid()')).single[0];
  final resume = Completer<void>();
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((_) {
    if (!resume.isCompleted) resume.complete();
  });
  final authority = RecoveryAuthority(config['authorityFile'] as String,
      testBarrier: (stage) async {
    if (stage == config['stage']) {
      stdout.writeln(
          jsonEncode({'event': 'barrier', 'stage': stage, 'backend': backend}));
      await resume.future.timeout(const Duration(seconds: 30));
    }
  });
  final admin = IdentityAdministration(
      connection: db,
      tenantId: config['tenantId'] as String,
      operatorLabel: 'crash-fixture',
      authority: authority);
  try {
    switch (config['action']) {
      case 'provision':
        await admin.provisionToFile(
            actorId: 'user-001',
            deviceId: config['deviceId'] as String,
            credentialId: config['credentialId'] as String,
            expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
            allowedScopes: [
              {
                'companyId': 'company-001',
                'branchId': 'branch-001',
                'permissions': ['maintenance.create']
              }
            ],
            outputPath: config['outputPath'] as String);
      case 'revoke-credential':
        await admin.revokeCredential(config['credentialId'] as String);
      default:
        throw StateError('Unknown test operation');
    }
    stdout.writeln('{"event":"completed"}');
  } catch (_) {
    stderr.writeln('Test administration failed');
    exitCode = 2;
  } finally {
    await db.close();
    exit(exitCode);
  }
}
