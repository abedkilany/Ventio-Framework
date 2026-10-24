import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart';

Future<void> main() async {
  if (!Platform.isWindows ||
      Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes') {
    stderr.writeln(
      'Local Host process integration requires the Windows disposable database runner.',
    );
    exitCode = 2;
    return;
  }
  final runtimeUrl = Platform.environment['VENTIO_TEST_RUNTIME_DATABASE_URL'];
  final administrationUrl =
      Platform.environment['VENTIO_TEST_ADMIN_DATABASE_URL'];
  if (runtimeUrl == null || administrationUrl == null) {
    throw StateError('Restricted Windows Host database logins are required.');
  }

  final sid = await _currentSid();
  final directory = await createPrivateTestDirectory('ventio-local-host-');
  final witnessPath =
      '${directory.path}${Platform.pathSeparator}authority.json';
  final credentialPath =
      '${directory.path}${Platform.pathSeparator}credential.json';
  final tenant = 'local-host-${DateTime.now().microsecondsSinceEpoch}';
  final company = 'company-one';
  final branch = 'branch-one';
  final actor = 'host-operator';
  final device = 'windows-client';
  final authority = RecoveryAuthority(witnessPath, readerSid: sid);
  final administrationConnection = await pg.Connection.openFromUrl(
    administrationUrl,
  );
  Process? host;
  StreamSubscription<String>? outputSubscription;
  StreamSubscription<String>? errorSubscription;
  HttpClient? client;

  try {
    await authority.resetForReenrollment(
      administrationConnection,
      'windows-process-integration',
    );
    final identity = IdentityAdministration(
      connection: administrationConnection,
      tenantId: tenant,
      operatorLabel: 'windows-process-integration',
      authority: authority,
    );
    await identity.createUser(actor);
    await identity.registerBranch(company, branch);
    await identity.registerDevice(actor, device);
    await identity.grant(actor, company, branch, 'identity.roles.manage');
    await identity.provisionToFile(
      actorId: actor,
      deviceId: device,
      credentialId: 'host-process-credential',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': company,
          'branchId': branch,
          'permissions': ['identity.roles.manage'],
        },
      ],
      outputPath: credentialPath,
    );
    final credential =
        jsonDecode(await PrivateFiles.read(credentialPath))
            as Map<String, dynamic>;
    final token = credential['token'] as String;

    final startup = Completer<int>();
    final processEnvironment = <String, String>{
      ...Platform.environment,
      'VENTIO_ENABLE_LOCAL_HOST': 'yes',
      'VENTIO_HOST_DATABASE_URL': runtimeUrl,
      'VENTIO_HOST_IDENTITY_ADMIN_DATABASE_URL': administrationUrl,
      'VENTIO_HOST_BIND_ADDRESS': '127.0.0.1',
      'VENTIO_HOST_PORT': '0',
      'VENTIO_RECOVERY_AUTHORITY_FILE': witnessPath,
      'VENTIO_RECOVERY_AUTHORITY_OWNER_SID': sid,
      'VENTIO_RECOVERY_AUTHORITY_READER_SID': sid,
      'VENTIO_RECOVERY_AUTHORITY_HOST_WRITES': 'yes',
    };
    host = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'bin/local_host.dart'],
      workingDirectory: Directory.current.path,
      environment: processEnvironment,
      runInShell: false,
    );
    outputSubscription = host.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final match = RegExp(
            r'^Persistent Host listening on http://127\.0\.0\.1:(\d+)$',
          ).firstMatch(line);
          if (match != null && !startup.isCompleted) {
            startup.complete(int.parse(match.group(1)!));
          }
        });
    errorSubscription = host.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.contains('Local Host startup failed.') &&
              !startup.isCompleted) {
            startup.completeError(StateError('Local Host startup failed.'));
          }
        });
    unawaited(
      host.exitCode.then((code) {
        if (!startup.isCompleted) {
          startup.completeError(
            StateError('Local Host exited before listening ($code).'),
          );
        }
      }),
    );
    final port = await startup.future.timeout(const Duration(seconds: 45));
    check(port > 0, 'Windows persistent Host process binds loopback');

    client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final health = await _request(client, port, 'GET', '/healthz');
    check(health.status == 200, 'Running Windows Host serves liveness');

    final anonymous = await _request(client, port, 'GET', '/api/v1/session');
    check(
      anonymous.status == 401,
      'Running Host rejects anonymous session access',
    );

    final session = await _request(
      client,
      port,
      'GET',
      '/api/v1/session',
      token: token,
    );
    final sessionIdentity = session.body['identity'] as Map<String, dynamic>;
    final scopes = sessionIdentity['scopes'] as List;
    check(
      session.status == 200 &&
          sessionIdentity['tenantId'] == tenant &&
          sessionIdentity['roleAdministrationAvailable'] == true &&
          scopes.length == 1 &&
          (scopes.single as Map)['companyId'] == company &&
          (scopes.single as Map)['branchId'] == branch,
      'Persistent Windows Host returns the authenticated exact branch scope',
    );

    final deniedScope = await _request(
      client,
      port,
      'POST',
      '/api/v1/identity/roles/list',
      token: token,
      body: {'companyId': company, 'branchId': 'another-branch'},
    );
    check(deniedScope.status == 403, 'Role route denies a different branch');

    final created = await _request(
      client,
      port,
      'POST',
      '/api/v1/identity/roles/create',
      token: token,
      body: {
        'companyId': company,
        'branchId': branch,
        'roleId': 'smoke.reader',
        'displayName': 'Smoke Reader',
      },
    );
    check(
      created.status == 200,
      'Windows Host accepts an authorized role change',
    );

    final granted = await _request(
      client,
      port,
      'POST',
      '/api/v1/identity/roles/grant-permission',
      token: token,
      body: {
        'companyId': company,
        'branchId': branch,
        'roleId': 'smoke.reader',
        'permission': 'extension.smoke.read',
      },
    );
    check(
      granted.status == 200,
      'Windows Host records a scoped role permission',
    );

    final listed = await _request(
      client,
      port,
      'POST',
      '/api/v1/identity/roles/list',
      token: token,
      body: {'companyId': company, 'branchId': branch},
    );
    final roles =
        (listed.body['identityRoles'] as Map<String, dynamic>)['roles'] as List;
    final role = roles.single as Map<String, dynamic>;
    check(
      listed.status == 200 &&
          role['roleId'] == 'smoke.reader' &&
          (role['permissions'] as List).contains('extension.smoke.read'),
      'Windows Host returns the durable role on a subsequent request',
    );
    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    client?.close(force: true);
    if (host != null) {
      host.kill();
      await host.exitCode.timeout(const Duration(seconds: 10));
    }
    await outputSubscription?.cancel();
    await errorSubscription?.cancel();
    await administrationConnection.close();
    await directory.delete(recursive: true);
  }
}

Future<String> _currentSid() async {
  final result = await Process.run('whoami.exe', [
    '/user',
    '/fo',
    'csv',
    '/nh',
  ]);
  if (result.exitCode != 0)
    throw StateError('Cannot resolve current Windows SID');
  final sid = (result.stdout as String)
      .split(',')
      .last
      .trim()
      .replaceAll('"', '');
  if (!RegExp(r'^S-1-\d+(?:-\d+)+$').hasMatch(sid)) {
    throw StateError('Windows returned an invalid current SID');
  }
  return sid;
}

Future<_HttpResult> _request(
  HttpClient client,
  int port,
  String method,
  String path, {
  String? token,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(
    method,
    Uri.parse('http://127.0.0.1:$port$path'),
  );
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  final text = await utf8.decoder.bind(response).join();
  return _HttpResult(
    response.statusCode,
    jsonDecode(text) as Map<String, dynamic>,
  );
}

class _HttpResult {
  const _HttpResult(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
}
