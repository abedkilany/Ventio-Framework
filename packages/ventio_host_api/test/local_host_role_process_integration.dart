import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
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
  const moduleId = 'com.example.windows_records';
  const packageVersion = '1.0.0';
  const readPermission = 'extension.com_example_windows_records.item.read';
  const createPermission = 'extension.com_example_windows_records.item.create';
  const updatePermission = 'extension.com_example_windows_records.item.update';
  const publisherPermissions = [
    'identity.roles.manage',
    'extension.package.submit',
    'extension.package.read',
    readPermission,
    createPermission,
    updatePermission,
  ];
  const readerPermissions = ['extension.package.read', readPermission];
  final authority = RecoveryAuthority(witnessPath, readerSid: sid);
  final administrationConnection = await pg.Connection.openFromUrl(
    administrationUrl,
  );
  _RunningHost? runningHost;
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
    for (final permission in publisherPermissions) {
      await identity.grant(actor, company, branch, permission);
    }
    await identity.provisionToFile(
      actorId: actor,
      deviceId: device,
      credentialId: 'host-process-credential',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': company,
          'branchId': branch,
          'permissions': publisherPermissions,
        },
      ],
      outputPath: credentialPath,
    );
    await identity.createUser('host-reader');
    await identity.registerDevice('host-reader', 'windows-reader-device');
    for (final permission in readerPermissions) {
      await identity.grant('host-reader', company, branch, permission);
    }
    final readerCredentialPath =
        '${directory.path}${Platform.pathSeparator}reader-credential.json';
    await identity.provisionToFile(
      actorId: 'host-reader',
      deviceId: 'windows-reader-device',
      credentialId: 'host-reader-credential',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': company,
          'branchId': branch,
          'permissions': readerPermissions,
        },
      ],
      outputPath: readerCredentialPath,
    );
    final credential =
        jsonDecode(await PrivateFiles.read(credentialPath))
            as Map<String, dynamic>;
    final token = credential['token'] as String;
    final readerCredential =
        jsonDecode(await PrivateFiles.read(readerCredentialPath))
            as Map<String, dynamic>;
    final readerToken = readerCredential['token'] as String;

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
    runningHost = await _startHost(processEnvironment);
    final port = runningHost.port;
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

    final bundle = ExtensionBundle.fromJson(_bundleJson());
    final submitted = await _request(
      client,
      port,
      'POST',
      '/api/v1/extensions/submit',
      token: token,
      body: {
        'companyId': company,
        'branchId': branch,
        'package': bundle.toJson(),
      },
    );
    check(
      submitted.status == 202 &&
          (submitted.body['packageResult'] as Map)['status'] == 'SUBMITTED',
      'Windows Host persists a submitted declarative extension package',
    );

    final packageDigest = sha256
        .convert(utf8.encode(canonicalJson(bundle.toJson())))
        .toString();
    final packageAdministration = ExtensionPackageAdministration(
      connection: administrationConnection,
      tenantId: tenant,
      operatorLabel: 'windows-process-integration',
      authority: authority,
    );
    await packageAdministration.approve(
      moduleId: moduleId,
      version: packageVersion,
      packageSha256: packageDigest,
    );
    final approved = await _request(
      client,
      port,
      'POST',
      '/api/v1/extensions/read',
      token: token,
      body: {
        'companyId': company,
        'branchId': branch,
        'moduleId': moduleId,
        'version': packageVersion,
      },
    );
    check(
      approved.status == 200 &&
          (approved.body['packageResult'] as Map)['packageSha256'] ==
              packageDigest,
      'Windows Host serves only the operator-approved package digest',
    );

    final command = ExtensionRecordCommand.create(
      commandId: '71000000-0000-4000-8000-000000000001',
      tenantId: tenant,
      companyId: company,
      branchId: branch,
      recordId: 'host-item-1',
      actorId: actor,
      deviceId: device,
      moduleId: moduleId,
      moduleVersion: packageVersion,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'Before update'},
    );
    final recordCreated = await _request(
      client,
      port,
      'POST',
      '/api/v1/commands',
      token: token,
      body: command.envelope.original,
    );
    final createReceipt = recordCreated.body['receipt'] as Map<String, dynamic>;
    check(
      recordCreated.status == 200 &&
          createReceipt['status'] == 'ACCEPTED' &&
          createReceipt['hostRevision'] == 1,
      'Windows Host creates a Host-authoritative dynamic record',
    );

    final query = await _request(
      client,
      port,
      'POST',
      '/api/v1/extensions/records/query',
      token: readerToken,
      body: _recordQuery(company, branch),
    );
    final queryResult = query.body['recordResult'] as Map<String, dynamic>;
    final queriedRows = queryResult['records'] as List;
    check(
      query.status == 200 &&
          queriedRows.length == 1 &&
          queriedRows.single['recordId'] == 'host-item-1' &&
          queriedRows.single['values']['title'] == 'Before update',
      'Second authenticated device reads the same Host record',
    );

    final wrongBranchRead = await _request(
      client,
      port,
      'POST',
      '/api/v1/extensions/records/query',
      token: readerToken,
      body: _recordQuery(company, 'another-branch'),
    );
    check(
      wrongBranchRead.status == 403,
      'Windows Host rejects dynamic record reads from another branch',
    );

    final updatedCommand = ExtensionRecordCommand.update(
      commandId: '71000000-0000-4000-8000-000000000002',
      tenantId: tenant,
      companyId: company,
      branchId: branch,
      recordId: 'host-item-1',
      expectedRevision: 1,
      actorId: actor,
      deviceId: device,
      moduleId: moduleId,
      moduleVersion: packageVersion,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'After update'},
    );
    final recordUpdated = await _request(
      client,
      port,
      'POST',
      '/api/v1/commands',
      token: token,
      body: updatedCommand.envelope.original,
    );
    final updateReceipt = recordUpdated.body['receipt'] as Map<String, dynamic>;
    check(
      recordUpdated.status == 200 &&
          updateReceipt['status'] == 'ACCEPTED' &&
          updateReceipt['hostRevision'] == 2,
      'Windows Host advances a dynamic record with expected-revision checking',
    );

    final afterUpdate = await _request(
      client,
      port,
      'POST',
      '/api/v1/extensions/records/query',
      token: readerToken,
      body: _recordQuery(company, branch),
    );
    final updatedRows =
        (afterUpdate.body['recordResult'] as Map<String, dynamic>)['records']
            as List;
    check(
      afterUpdate.status == 200 &&
          updatedRows.single['values']['title'] == 'After update' &&
          updatedRows.single['revision'] == 2,
      'Second authenticated device receives the Host-updated record',
    );

    await runningHost.stop();
    runningHost = await _startHost(processEnvironment);
    final restartedPort = runningHost.port;
    final restartedHealth = await _request(
      client,
      restartedPort,
      'GET',
      '/healthz',
    );
    check(
      restartedHealth.status == 200,
      'Persistent Windows Host restarts against the same database and witness',
    );

    final restartedRoles = await _request(
      client,
      restartedPort,
      'POST',
      '/api/v1/identity/roles/list',
      token: token,
      body: {'companyId': company, 'branchId': branch},
    );
    final restartedRoleList =
        (restartedRoles.body['identityRoles'] as Map<String, dynamic>)['roles']
            as List;
    check(
      restartedRoles.status == 200 &&
          restartedRoleList.any(
            (entry) =>
                entry['roleId'] == 'smoke.reader' &&
                (entry['permissions'] as List).contains('extension.smoke.read'),
          ),
      'Scoped role configuration survives a Host process restart',
    );

    final restartedPackage = await _request(
      client,
      restartedPort,
      'POST',
      '/api/v1/extensions/read',
      token: token,
      body: {
        'companyId': company,
        'branchId': branch,
        'moduleId': moduleId,
        'version': packageVersion,
      },
    );
    check(
      restartedPackage.status == 200 &&
          (restartedPackage.body['packageResult'] as Map)['packageSha256'] ==
              packageDigest,
      'Approved extension metadata survives a Host process restart',
    );

    final restartedRecord = await _request(
      client,
      restartedPort,
      'POST',
      '/api/v1/extensions/records/query',
      token: readerToken,
      body: _recordQuery(company, branch),
    );
    final restartedRows =
        (restartedRecord.body['recordResult']
                as Map<String, dynamic>)['records']
            as List;
    check(
      restartedRecord.status == 200 &&
          restartedRows.length == 1 &&
          restartedRows.single['values']['title'] == 'After update' &&
          restartedRows.single['revision'] == 2,
      'Host record values and revision survive a process restart',
    );

    const clientUpgradeVersion = '1.0.1';
    final clientUpgradeBundle = ExtensionBundle.fromJson(
      _bundleJson(version: clientUpgradeVersion),
    );
    final clientUpgradeSubmission = await _request(
      client,
      restartedPort,
      'POST',
      '/api/v1/extensions/submit',
      token: token,
      body: {
        'companyId': company,
        'branchId': branch,
        'package': clientUpgradeBundle.toJson(),
      },
    );
    check(
      clientUpgradeSubmission.status == 202 &&
          (clientUpgradeSubmission.body['packageResult'] as Map)['status'] ==
              'SUBMITTED',
      'Persistent Host stores the next client integration package candidate',
    );
    final clientUpgradeDigest = sha256
        .convert(utf8.encode(canonicalJson(clientUpgradeBundle.toJson())))
        .toString();
    await packageAdministration.approve(
      moduleId: moduleId,
      version: clientUpgradeVersion,
      packageSha256: clientUpgradeDigest,
    );

    final clientDirectory = Directory(
      '${Directory.current.parent.path}${Platform.pathSeparator}'
      'ventio_native_client',
    );
    final clientFlow = await Process.run(
      'flutter',
      [
        'test',
        'test/host_backed_extension_flow_test.dart',
        '--reporter',
        'expanded',
      ],
      workingDirectory: clientDirectory.path,
      environment: {
        ...Platform.environment,
        'VENTIO_CLIENT_HOST_ENDPOINT': 'http://127.0.0.1:$restartedPort',
        'VENTIO_CLIENT_HOST_WRITER_TOKEN': token,
        'VENTIO_CLIENT_HOST_READER_TOKEN': readerToken,
        'VENTIO_CLIENT_HOST_TENANT': tenant,
        'VENTIO_CLIENT_HOST_COMPANY': company,
        'VENTIO_CLIENT_HOST_BRANCH': branch,
      },
      runInShell: true,
    );
    stdout.write(clientFlow.stdout);
    if (clientFlow.exitCode != 0) stderr.write(clientFlow.stderr);
    check(
      clientFlow.exitCode == 0,
      'Flutter client syncs through real Host, offline retry, second device and upgrade',
    );
    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    client?.close(force: true);
    await runningHost?.stop();
    await administrationConnection.close();
    await directory.delete(recursive: true);
  }
}

Future<_RunningHost> _startHost(Map<String, String> environment) async {
  final startup = Completer<int>();
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'bin/local_host.dart'],
    workingDirectory: Directory.current.path,
    environment: environment,
    runInShell: false,
  );
  final outputSubscription = process.stdout
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
  final errorSubscription = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line.contains('Local Host startup failed.') &&
            !startup.isCompleted) {
          startup.completeError(StateError('Local Host startup failed.'));
        }
      });
  unawaited(
    process.exitCode.then((code) {
      if (!startup.isCompleted) {
        startup.completeError(
          StateError('Local Host exited before listening ($code).'),
        );
      }
    }),
  );

  try {
    final port = await startup.future.timeout(const Duration(seconds: 45));
    return _RunningHost(
      process: process,
      port: port,
      outputSubscription: outputSubscription,
      errorSubscription: errorSubscription,
    );
  } on Object {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 10));
    await outputSubscription.cancel();
    await errorSubscription.cancel();
    rethrow;
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

Map<String, Object?> _recordQuery(String company, String branch) => {
  'companyId': company,
  'branchId': branch,
  'moduleId': 'com.example.windows_records',
  'version': '1.0.0',
  'docType': 'Item',
  'search': '',
  'filters': <String, Object?>{},
  'filterField': null,
  'filterContains': '',
  'sortField': 'title',
  'descending': false,
  'offset': 0,
  'limit': 10,
};

Map<String, dynamic> _bundleJson({String version = '1.0.0'}) => {
  'manifest': {
    'manifestVersion': 0,
    'moduleId': 'com.example.windows_records',
    'version': version,
    'minPlatformApi': '0.1.0',
    'displayName': 'Windows Record Registry',
    'displayNameKey': 'extension.com_example_windows_records.module.name',
    'englishCatalog': 'localization/en.windows_records.json',
    'dependencies': <String>[],
    'docTypes': ['Item'],
    'commands': <Object>[],
    'requiredCapabilities': <String>[],
    'offline': {'enabled': false, 'allowedCommands': <String>[]},
  },
  'docTypes': [
    {
      'name': 'Item',
      'moduleId': 'com.example.windows_records',
      'schemaVersion': 1,
      'kind': 'operational',
      'label': 'Item',
      'labelKey': 'extension.com_example_windows_records.item',
      'operations': ['read', 'create', 'update'],
      'permissions': {
        'read': 'extension.com_example_windows_records.item.read',
        'create': 'extension.com_example_windows_records.item.create',
        'update': 'extension.com_example_windows_records.item.update',
      },
      'fields': [
        {
          'name': 'title',
          'type': 'text',
          'required': true,
          'label': 'Title',
          'labelKey': 'extension.com_example_windows_records.item.title',
          'maxLength': 100,
        },
      ],
      'ui': {
        'listColumns': ['title'],
        'formFields': ['title'],
      },
    },
  ],
  'dependencyVersions': <String, String>{},
  'englishCatalog': {
    'extension.com_example_windows_records.module.name':
        'Windows Record Registry',
    'extension.com_example_windows_records.item': 'Item',
    'extension.com_example_windows_records.item.title': 'Title',
  },
};

class _HttpResult {
  const _HttpResult(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
}

class _RunningHost {
  _RunningHost({
    required this.process,
    required this.port,
    required this.outputSubscription,
    required this.errorSubscription,
  });

  final Process process;
  final int port;
  final StreamSubscription<String> outputSubscription;
  final StreamSubscription<String> errorSubscription;

  Future<void> stop() async {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 10));
    await outputSubscription.cancel();
    await errorSubscription.cancel();
  }
}
