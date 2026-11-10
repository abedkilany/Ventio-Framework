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
  final apiAdministrationUrl =
      Platform.environment['VENTIO_TEST_API_ADMIN_DATABASE_URL'];
  if (runtimeUrl == null ||
      administrationUrl == null ||
      apiAdministrationUrl == null) {
    throw StateError(
      'Separate local and scoped API Host database logins are required.',
    );
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
  const pairingTargetActor = 'client-enrollment-target';
  const moduleId = 'com.example.windows_records';
  const packageVersion = '1.0.0';
  const readPermission = 'extension.com_example_windows_records.item.read';
  const createPermission = 'extension.com_example_windows_records.item.create';
  const updatePermission = 'extension.com_example_windows_records.item.update';
  const publisherPermissions = [
    'identity.roles.manage',
    'extension.package.submit',
    'extension.package.read',
    hostStatusReadPermission,
    hostDiagnosticsReadPermission,
    identityUsersManagePermission,
    identityDevicesManagePermission,
    identityPairingManagePermission,
    readPermission,
    createPermission,
    updatePermission,
    'maintenance.create',
  ];
  const readerPermissions = [
    'extension.package.read',
    readPermission,
    updatePermission,
  ];
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
      credentialId: 'host-proc-cred-001',
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
      credentialId: 'host-reader-cred-001',
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
    await identity.createUser(pairingTargetActor);
    await identity.grant(pairingTargetActor, company, branch, readPermission);
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
      'VENTIO_HOST_IDENTITY_ADMIN_DATABASE_URL': '',
      'VENTIO_HOST_IDENTITY_API_DATABASE_URL': apiAdministrationUrl,
      'VENTIO_HOST_BIND_ADDRESS': '127.0.0.1',
      'VENTIO_HOST_PORT': '0',
      'VENTIO_RECOVERY_AUTHORITY_FILE': witnessPath,
      'VENTIO_RECOVERY_AUTHORITY_OWNER_SID': sid,
      'VENTIO_RECOVERY_AUTHORITY_READER_SID': sid,
      'VENTIO_RECOVERY_AUTHORITY_HOST_WRITES': 'yes',
      'VENTIO_HOST_DIAGNOSTICS_FILE':
          '${directory.path}${Platform.pathSeparator}host-diagnostics.json',
    };
    if (Platform.environment['VENTIO_HOST_DIAGNOSTICS_PROCESS_TEST'] == 'yes') {
      await _verifyDiagnosticProcessLifecycle(
        processEnvironment: processEnvironment,
        runtimeUrl: runtimeUrl,
        tenant: tenant,
        company: company,
        branch: branch,
        authorizedToken: token,
        unauthorizedToken: readerToken,
      );
      stdout.writeln('RESULT: $assertions passed, 0 failed');
      return;
    }
    runningHost = await _startHost(processEnvironment);
    final port = runningHost.port;
    check(
      port > 0 &&
          runningHost.scheme == 'http' &&
          runningHost.address == '127.0.0.1',
      'Windows persistent Host process binds loopback HTTP by default',
    );

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

    final unauthorizedUserRead = await _request(
      client,
      port,
      'POST',
      '/api/v1/management/users/list',
      token: readerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
      },
    );
    check(
      unauthorizedUserRead.status == 403 &&
          (unauthorizedUserRead.body['error'] as Map)['code'] ==
              'PERMISSION_DENIED',
      'Persistent Host denies user administration without its scoped permission',
    );

    final crossScopeUserRead = await _request(
      client,
      port,
      'POST',
      '/api/v1/management/users/list',
      token: token,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': 'branch-outside-grant',
      },
    );
    check(
      crossScopeUserRead.status == 403 &&
          (crossScopeUserRead.body['error'] as Map)['code'] == 'SCOPE_DENIED',
      'Persistent Host denies user administration outside the authenticated branch',
    );

    if (Platform.environment['VENTIO_HOST_ADMIN_UI_ONLY'] == 'yes') {
      final userProbeCreate = await _request(
        client,
        port,
        'POST',
        '/api/v1/management/users/create',
        token: token,
        body: {
          'managementApiVersion': managementApiVersion,
          'companyId': company,
          'branchId': branch,
        },
      );
      final userProbeId =
          ((userProbeCreate.body['userOperation'] as Map)['actorId']) as String;
      final userProbeGrant = await _request(
        client,
        port,
        'POST',
        '/api/v1/management/users/grant',
        token: token,
        body: {
          'managementApiVersion': managementApiVersion,
          'companyId': company,
          'branchId': branch,
          'actorId': userProbeId,
          'permission': 'maintenance.read',
        },
      );
      final userProbeInventory = await _request(
        client,
        port,
        'POST',
        '/api/v1/management/users/list',
        token: token,
        body: {
          'managementApiVersion': managementApiVersion,
          'companyId': company,
          'branchId': branch,
        },
      );
      final userProbe =
          ((userProbeInventory.body['users'] as Map)['items'] as List)
              .cast<Map>()
              .singleWhere((user) => user['actorId'] == userProbeId);
      check(
        userProbeCreate.status == 200 &&
            userProbeGrant.status == 200 &&
            (userProbe['directPermissions'] as List).contains(
              'maintenance.read',
            ),
        'Persistent Host lists a direct permission after its real API grant',
      );
      final hostUiFlow = await _runFlutterHostAdministrationUiFlow(
        endpoint: 'http://127.0.0.1:$port',
        writerToken: token,
        readerToken: readerToken,
        tenant: tenant,
        company: company,
        branch: branch,
        actor: actor,
        device: device,
      );
      stdout.write(hostUiFlow.stdout);
      if (hostUiFlow.exitCode != 0) stderr.write(hostUiFlow.stderr);
      check(
        hostUiFlow.exitCode == 0,
        'Native Windows Flutter administration UI reads the real Host and gates navigation by exact permissions',
      );
      stdout.writeln('RESULT: $assertions passed, 0 failed');
      return;
    }

    final legacyBusinessCommand = await _request(
      client,
      port,
      'POST',
      '/api/v1/commands',
      token: token,
      body: {
        'protocolVersion': 0,
        'commandId': '72000000-0000-4000-8000-000000000001',
        'type': 'maintenance.create',
        'typeVersion': 1,
        'tenantId': tenant,
        'companyId': company,
        'branchId': branch,
        'aggregateId': 'legacy-maintenance-1',
        'expectedRevision': null,
        'dependsOn': <String>[],
        'payload': <String, Object?>{'title': 'Legacy command'},
        'clientContext': {
          'deviceId': device,
          'actorId': actor,
          'moduleVersion': '1.0.0',
          'docTypeVersion': 1,
        },
      },
    );
    final legacyReceipt =
        legacyBusinessCommand.body['receipt'] as Map<String, dynamic>;
    check(
      legacyBusinessCommand.status == 422 &&
          legacyReceipt['status'] == 'REJECTED' &&
          legacyReceipt['reasonCode'] == 'UNKNOWN_COMMAND',
      'Production Host does not expose the old maintenance demo command '
      '(HTTP ${legacyBusinessCommand.status}, '
      '${legacyReceipt['status']}/${legacyReceipt['reasonCode']})',
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

    final clientFlow = await _runFlutterClientFlow(
      scheme: 'http',
      port: restartedPort,
      writerToken: token,
      readerToken: readerToken,
      tenant: tenant,
      company: company,
      branch: branch,
    );
    stdout.write(clientFlow.stdout);
    if (clientFlow.exitCode != 0) stderr.write(clientFlow.stderr);
    check(
      clientFlow.exitCode == 0,
      'Flutter client syncs through real Host, offline retry, second device and upgrade',
    );

    await runningHost.stop();
    final networkAddress = await _localIpv4Address();
    final tlsFiles = await _createHostTlsFiles(directory, networkAddress);
    final tlsEnvironment = {
      ...processEnvironment,
      'VENTIO_HOST_BIND_ADDRESS': networkAddress,
      'VENTIO_HOST_TLS_CERTIFICATE_FILE': tlsFiles.certificatePath,
      'VENTIO_HOST_TLS_PRIVATE_KEY_FILE': tlsFiles.privateKeyPath,
    };
    runningHost = await _startHost(tlsEnvironment);
    final tlsPort = runningHost.port;
    check(
      tlsPort > 0 &&
          runningHost.scheme == 'https' &&
          runningHost.address == networkAddress,
      'Persistent Windows Host serves HTTPS on a non-loopback interface',
    );

    final tlsClientFlow = await _runFlutterClientFlow(
      scheme: 'https',
      hostAddress: networkAddress,
      port: tlsPort,
      writerToken: token,
      readerToken: readerToken,
      tenant: tenant,
      company: company,
      branch: branch,
      trustedCertificatePath: tlsFiles.certificatePath,
    );
    stdout.write(tlsClientFlow.stdout);
    if (tlsClientFlow.exitCode != 0) stderr.write(tlsClientFlow.stderr);
    check(
      tlsClientFlow.exitCode == 0,
      'Flutter client validates the trusted certificate over the network address',
    );

    final certificateProbe = await SecureSocket.connect(
      networkAddress,
      tlsPort,
      timeout: const Duration(seconds: 5),
      onBadCertificate: (_) => true,
    );
    final peerCertificate = certificateProbe.peerCertificate;
    if (peerCertificate == null) {
      certificateProbe.destroy();
      throw StateError('The test Host did not present its TLS certificate.');
    }
    final certificateFingerprint = sha256
        .convert(peerCertificate.der)
        .toString();
    certificateProbe.destroy();

    final pairingContext = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(tlsFiles.certificatePath);
    final pairingApiClient = HttpClient(context: pairingContext)
      ..connectionTimeout = const Duration(seconds: 5);
    late final _HttpResult pairingCreated;
    try {
      pairingCreated = await _requestAtEndpoint(
        pairingApiClient,
        scheme: 'https',
        hostAddress: networkAddress,
        port: tlsPort,
        method: 'POST',
        path: HostManagementRoutes.pairingCreate,
        token: token,
        body: {
          'managementApiVersion': managementApiVersion,
          'companyId': company,
          'branchId': branch,
          'actorId': pairingTargetActor,
        },
      );
    } finally {
      pairingApiClient.close(force: true);
    }
    if (pairingCreated.status != HttpStatus.created ||
        pairingCreated.body['pairing'] is! Map<String, dynamic>) {
      final rawError = pairingCreated.body['error'];
      final errorCode = rawError is Map ? rawError['code'] : null;
      throw StateError(
        'Host denied the disposable Client pairing request (${errorCode is String ? errorCode : 'unknown'}).',
      );
    }
    final pairing = pairingCreated.body['pairing'] as Map<String, dynamic>;
    final pairingCode = pairing['code'] as String;
    check(
      pairingCreated.status == 201 &&
          pairing['actorId'] == pairingTargetActor &&
          pairing['deviceRole'] == 'CLIENT' &&
          pairing['companyId'] == company &&
          pairing['branchId'] == branch &&
          RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(pairingCode),
      'Live Host issues a single-scope Client enrollment code for the selected user',
    );

    final enrollmentUiFlow = await _runFlutterHostClientEnrollmentUiFlow(
      endpoint: 'https://$networkAddress:$tlsPort',
      pairingCode: pairingCode,
      certificateFingerprint: certificateFingerprint,
      certificatePath: tlsFiles.certificatePath,
      tenant: tenant,
      actor: pairingTargetActor,
      company: company,
      branch: branch,
    );
    stdout.write(enrollmentUiFlow.stdout);
    if (enrollmentUiFlow.exitCode != 0) stderr.write(enrollmentUiFlow.stderr);
    check(
      enrollmentUiFlow.exitCode == 0,
      'Native Flutter Client pairing UI enrolls a new Client against the live Host over pinned HTTPS',
    );

    if (Platform.environment['VENTIO_RUN_ANDROID_HOST_INTEGRATION'] == 'yes') {
      final androidPort = runningHost.port;
      check(
        androidPort > 0 &&
            runningHost.scheme == 'https' &&
            runningHost.address == networkAddress,
        'Windows Host remains on TLS at its selected network interface for Android client access',
      );

      final emulatorId = await _connectedAndroidEmulator();
      final androidFlow = await _runAndroidFlutterClientFlow(
        emulatorId: emulatorId,
        hostAddress: networkAddress,
        port: androidPort,
        writerToken: token,
        readerToken: readerToken,
        tenant: tenant,
        company: company,
        branch: branch,
        trustedCertificatePath: tlsFiles.certificatePath,
        definitionsPath:
            '${directory.path}${Platform.pathSeparator}'
            'android-host-test-defines.json',
      );
      stdout.write(androidFlow.stdout);
      if (androidFlow.exitCode != 0) stderr.write(androidFlow.stderr);
      check(
        androidFlow.exitCode == 0,
        'Android emulator reaches the Windows Host network address over TLS, retries offline work, and reads accepted data',
      );
    }

    await runningHost.stop();
    final dualListenerPort = await _unusedTcpPort();
    final dualListenerEnvironment = {
      ...processEnvironment,
      'VENTIO_HOST_LAN_BIND_ADDRESS': '0.0.0.0',
      'VENTIO_HOST_LAN_PORT': '$dualListenerPort',
      'VENTIO_HOST_TLS_CERTIFICATE_FILE': tlsFiles.certificatePath,
      'VENTIO_HOST_TLS_PRIVATE_KEY_FILE': tlsFiles.privateKeyPath,
    };
    runningHost = await _startHost(dualListenerEnvironment);
    check(
      runningHost.scheme == 'http' &&
          runningHost.address == '127.0.0.1' &&
          runningHost.port > 0,
      'Host keeps its local administration listener on loopback HTTP',
    );
    await _waitForTcpEndpoint(networkAddress, dualListenerPort);
    final trustedContext = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(tlsFiles.certificatePath);
    final lanClient = HttpClient(context: trustedContext)
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final lanSession = await _requestAtEndpoint(
        lanClient,
        scheme: 'https',
        hostAddress: networkAddress,
        port: dualListenerPort,
        method: 'GET',
        path: '/api/v1/session',
        token: token,
      );
      final lanIdentity = lanSession.body['identity'] as Map<String, dynamic>;
      check(
        lanSession.status == 200 && lanIdentity['actorId'] == actor,
        'LAN HTTPS listener shares authenticated Host identity while local admin remains available',
      );
      final localSession = await _request(
        lanClient,
        runningHost.port,
        'GET',
        '/api/v1/session',
        token: token,
      );
      check(
        localSession.status == 200,
        'Loopback administration remains available alongside LAN HTTPS',
      );
    } finally {
      lanClient.close(force: true);
    }
    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    client?.close(force: true);
    await runningHost?.stop();
    await administrationConnection.close();
    await directory.delete(recursive: true);
  }
}

Future<void> _verifyDiagnosticProcessLifecycle({
  required Map<String, String> processEnvironment,
  required String runtimeUrl,
  required String tenant,
  required String company,
  required String branch,
  required String authorizedToken,
  required String unauthorizedToken,
}) async {
  final diagnosticsPath = processEnvironment['VENTIO_HOST_DIAGNOSTICS_FILE']!;
  final rejectedDatabaseUrl = runtimeUrl.replaceFirst(
    'runtime_test_only',
    'invalid_runtime_test_only',
  );
  if (rejectedDatabaseUrl == runtimeUrl) {
    throw StateError('Could not prepare a disposable database failure case.');
  }

  var startupFailed = false;
  try {
    await _startHost({
      ...processEnvironment,
      'VENTIO_HOST_DATABASE_URL': rejectedDatabaseUrl,
    });
  } on StateError {
    startupFailed = true;
  }
  check(startupFailed, 'Injected database failure stops Host startup safely');
  check(
    await File(diagnosticsPath).exists(),
    'Host safely initializes the missing protected diagnostics log before recording its startup failure',
  );

  final persistedLog = await ProtectedManagementDiagnosticLog.open(
    diagnosticsPath,
  );
  final startupEvents = persistedLog.recent(limit: 100);
  final startupEvent = startupEvents.firstWhere(
    (event) => event.code == 'HOST_STARTUP_FAILED',
  );
  check(
    startupEvent.category == ManagementDiagnosticCategory.hostStartup &&
        startupEvent.protectedFailureType != null &&
        startupEvent.correlationId.startsWith('cor_'),
    'Failed Host process persisted a correlated protected startup event',
  );
  final publicStartupEvent = jsonEncode(startupEvent.toJson());
  check(
    !publicStartupEvent.contains('protectedFailureType') &&
        !publicStartupEvent.contains('ServerException'),
    'Public Host startup event omits protected failure details',
  );

  for (final processGeneration in [1, 2]) {
    final host = await _startHost(processEnvironment);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final response = await _request(
        client,
        host.port,
        'POST',
        HostManagementRoutes.diagnosticsRecent,
        token: authorizedToken,
        body: {
          'managementApiVersion': managementApiVersion,
          'companyId': company,
          'branchId': branch,
          'limit': 20,
        },
      );
      final events = response.body['events'] as List;
      final restoredEvent = events.cast<Map<String, dynamic>>().firstWhere(
        (event) => event['code'] == 'HOST_STARTUP_FAILED',
      );
      check(
        response.status == 200 &&
            restoredEvent['correlationId'] == startupEvent.correlationId &&
            !jsonEncode(response.body).contains('protectedFailureType') &&
            !jsonEncode(response.body).contains('ServerException') &&
            !jsonEncode(response.body).contains('invalid_runtime_test_only'),
        'Host process $processGeneration retrieves the persisted safe event after restart',
      );

      final denied = await _request(
        client,
        host.port,
        'POST',
        HostManagementRoutes.diagnosticsRecent,
        token: unauthorizedToken,
        body: {
          'managementApiVersion': managementApiVersion,
          'companyId': company,
          'branchId': branch,
          'limit': 20,
        },
      );
      check(
        denied.status == 403 &&
            denied.body['error']['code'] == 'PERMISSION_DENIED',
        'Host process $processGeneration refuses diagnostics without an exact-scope grant',
      );

      final outOfScope = await _request(
        client,
        host.port,
        'POST',
        HostManagementRoutes.diagnosticsRecent,
        token: authorizedToken,
        body: {
          'managementApiVersion': managementApiVersion,
          'companyId': company,
          'branchId': 'branch-outside-grant',
          'limit': 20,
        },
      );
      check(
        outOfScope.status == 403 &&
            outOfScope.body['error']['code'] == 'SCOPE_DENIED',
        'Host process $processGeneration refuses diagnostic reads outside the credential scope',
      );
    } finally {
      client.close(force: true);
      await host.stop();
    }
  }

  final uiHost = await _startHost(processEnvironment);
  try {
    final uiResult = await _runFlutterHostDiagnosticsUiFlow(
      endpoint: '${uiHost.scheme}://${uiHost.address}:${uiHost.port}',
      token: authorizedToken,
      tenant: tenant,
      company: company,
      branch: branch,
      expectedCorrelation: startupEvent.correlationId,
    );
    stdout.write(uiResult.stdout);
    if (uiResult.exitCode != 0) stderr.write(uiResult.stderr);
    check(
      uiResult.exitCode == 0,
      'Native Flutter Diagnostics Center retrieves the protected Host failure and exports sanitized local/Host events',
    );
  } finally {
    await uiHost.stop();
  }
}

Future<_RunningHost> _startHost(Map<String, String> environment) async {
  final startup = Completer<({String address, String scheme, int port})>();
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
          r'^Persistent Host listening on (https?)://([0-9.]+):(\d+)$',
        ).firstMatch(line);
        if (match != null && !startup.isCompleted) {
          startup.complete((
            scheme: match.group(1)!,
            address: match.group(2)!,
            port: int.parse(match.group(3)!),
          ));
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
    final endpoint = await startup.future.timeout(const Duration(seconds: 45));
    return _RunningHost(
      process: process,
      address: endpoint.address,
      scheme: endpoint.scheme,
      port: endpoint.port,
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

Future<ProcessResult> _runFlutterClientFlow({
  required String scheme,
  String hostAddress = '127.0.0.1',
  required int port,
  required String writerToken,
  required String readerToken,
  required String tenant,
  required String company,
  required String branch,
  String? trustedCertificatePath,
}) {
  final clientDirectory = Directory(
    '${Directory.current.parent.path}${Platform.pathSeparator}'
    'ventio_native_client',
  );
  return Process.run(
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
      'VENTIO_CLIENT_HOST_ENDPOINT': '$scheme://$hostAddress:$port',
      'VENTIO_CLIENT_HOST_WRITER_TOKEN': writerToken,
      'VENTIO_CLIENT_HOST_READER_TOKEN': readerToken,
      'VENTIO_CLIENT_HOST_TENANT': tenant,
      'VENTIO_CLIENT_HOST_COMPANY': company,
      'VENTIO_CLIENT_HOST_BRANCH': branch,
      if (trustedCertificatePath != null)
        'VENTIO_CLIENT_HOST_TRUSTED_CERTIFICATE': trustedCertificatePath,
    },
    runInShell: true,
  );
}

Future<ProcessResult> _runFlutterHostAdministrationUiFlow({
  required String endpoint,
  required String writerToken,
  required String readerToken,
  required String tenant,
  required String company,
  required String branch,
  required String actor,
  required String device,
}) {
  final clientDirectory = Directory(
    '${Directory.current.parent.path}${Platform.pathSeparator}'
    'ventio_native_client',
  );
  return Process.run(
    'flutter',
    [
      'test',
      'integration_test/host_administration_ui_test.dart',
      '--device-id',
      'windows',
      '--no-pub',
      '--reporter',
      'expanded',
    ],
    workingDirectory: clientDirectory.path,
    environment: {
      ...Platform.environment,
      'VENTIO_HOST_UI_ENDPOINT': endpoint,
      'VENTIO_HOST_UI_WRITER_TOKEN': writerToken,
      'VENTIO_HOST_UI_READER_TOKEN': readerToken,
      'VENTIO_HOST_UI_TENANT': tenant,
      'VENTIO_HOST_UI_COMPANY': company,
      'VENTIO_HOST_UI_BRANCH': branch,
      'VENTIO_HOST_UI_ACTOR': actor,
      'VENTIO_HOST_UI_DEVICE': device,
    },
    runInShell: true,
  );
}

Future<ProcessResult> _runFlutterHostDiagnosticsUiFlow({
  required String endpoint,
  required String token,
  required String tenant,
  required String company,
  required String branch,
  required String expectedCorrelation,
}) {
  final clientDirectory = Directory(
    '${Directory.current.parent.path}${Platform.pathSeparator}'
    'ventio_native_client',
  );
  return Process.run(
    'flutter',
    [
      'test',
      'integration_test/host_diagnostics_ui_test.dart',
      '--device-id',
      'windows',
      '--no-pub',
      '--reporter',
      'expanded',
    ],
    workingDirectory: clientDirectory.path,
    environment: {
      ...Platform.environment,
      'VENTIO_DIAGNOSTICS_ENDPOINT': endpoint,
      'VENTIO_DIAGNOSTICS_TOKEN': token,
      'VENTIO_DIAGNOSTICS_TENANT': tenant,
      'VENTIO_DIAGNOSTICS_COMPANY': company,
      'VENTIO_DIAGNOSTICS_BRANCH': branch,
      'VENTIO_DIAGNOSTICS_EXPECTED_CORRELATION': expectedCorrelation,
    },
    runInShell: true,
  );
}

Future<ProcessResult> _runFlutterHostClientEnrollmentUiFlow({
  required String endpoint,
  required String pairingCode,
  required String certificateFingerprint,
  required String certificatePath,
  required String tenant,
  required String actor,
  required String company,
  required String branch,
}) {
  final clientDirectory = Directory(
    '${Directory.current.parent.path}${Platform.pathSeparator}'
    'ventio_native_client',
  );
  return Process.run(
    'flutter',
    [
      'test',
      'integration_test/host_client_enrollment_ui_test.dart',
      '--device-id',
      'windows',
      '--no-pub',
      '--reporter',
      'expanded',
    ],
    workingDirectory: clientDirectory.path,
    environment: {
      ...Platform.environment,
      'VENTIO_CLIENT_PAIRING_ENDPOINT': endpoint,
      'VENTIO_CLIENT_PAIRING_CODE': pairingCode,
      'VENTIO_CLIENT_PAIRING_FINGERPRINT': certificateFingerprint,
      'VENTIO_CLIENT_PAIRING_CERTIFICATE': certificatePath,
      'VENTIO_CLIENT_PAIRING_TENANT': tenant,
      'VENTIO_CLIENT_PAIRING_ACTOR': actor,
      'VENTIO_CLIENT_PAIRING_COMPANY': company,
      'VENTIO_CLIENT_PAIRING_BRANCH': branch,
    },
    runInShell: true,
  );
}

Future<ProcessResult> _runAndroidFlutterClientFlow({
  required String emulatorId,
  required String hostAddress,
  required int port,
  required String writerToken,
  required String readerToken,
  required String tenant,
  required String company,
  required String branch,
  required String trustedCertificatePath,
  required String definitionsPath,
}) async {
  final certificate = await File(trustedCertificatePath).readAsString();
  final certificateBase64 = base64.encode(utf8.encode(certificate));
  final definitions = {
    'VENTIO_ANDROID_HOST_ENDPOINT': 'https://$hostAddress:$port',
    'VENTIO_ANDROID_WRITER_TOKEN': writerToken,
    'VENTIO_ANDROID_READER_TOKEN': readerToken,
    'VENTIO_ANDROID_TENANT': tenant,
    'VENTIO_ANDROID_COMPANY': company,
    'VENTIO_ANDROID_BRANCH': branch,
    'VENTIO_ANDROID_HOST_CERTIFICATE_PEM_B64': certificateBase64,
  };
  await File(definitionsPath).writeAsString(jsonEncode(definitions));

  final clientDirectory = Directory(
    '${Directory.current.parent.path}${Platform.pathSeparator}'
    'ventio_native_client',
  );
  try {
    return await Process.run(
      'flutter',
      [
        'test',
        'integration_test/android_host_sync_test.dart',
        '-d',
        emulatorId,
        '--no-pub',
        '--reporter',
        'expanded',
        '--dart-define-from-file=$definitionsPath',
      ],
      workingDirectory: clientDirectory.path,
      environment: Platform.environment,
      runInShell: true,
    );
  } finally {
    final file = File(definitionsPath);
    if (await file.exists()) await file.delete();
  }
}

Future<String> _connectedAndroidEmulator() async {
  final localAppData = Platform.environment['LOCALAPPDATA'];
  final sdkCandidates = [
    Platform.environment['ANDROID_SDK_ROOT'],
    Platform.environment['ANDROID_HOME'],
    if (localAppData != null) '$localAppData\\Android\\Sdk',
  ].whereType<String>();
  final adbPath = sdkCandidates
      .map(
        (root) =>
            '$root${Platform.pathSeparator}platform-tools'
            '${Platform.pathSeparator}adb.exe',
      )
      .firstWhere((path) => File(path).existsSync(), orElse: () => 'adb.exe');
  final result = await Process.run(adbPath, ['devices']);
  if (result.exitCode != 0) {
    throw StateError('Android emulator discovery failed: ${result.stderr}');
  }
  final devices = (result.stdout as String)
      .split(RegExp(r'\r?\n'))
      .skip(1)
      .map((line) => line.trim().split(RegExp(r'\s+')))
      .where(
        (parts) =>
            parts.length >= 2 &&
            parts[0].startsWith('emulator-') &&
            parts[1] == 'device',
      )
      .map((parts) => parts[0])
      .toList();
  if (devices.length != 1) {
    throw StateError(
      'Expected one connected Android emulator, found ${devices.length}.',
    );
  }
  return devices.single;
}

Future<String> _localIpv4Address() async {
  if (Platform.isWindows) {
    const command = r'''
$ErrorActionPreference = 'Stop'
$config = Get-NetIPConfiguration |
  Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
  Select-Object -First 1
if ($null -ne $config) {
  $config.IPv4Address |
    ForEach-Object { $_.IPAddress } |
    Where-Object { $_ -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' } |
    Select-Object -First 1
}

''';
    final routed = await Process.run('powershell.exe', [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      command,
    ], runInShell: false);
    if (routed.exitCode == 0) {
      final address = (routed.stdout as String).trim();
      if (address.isNotEmpty && _isPrivateIpv4(address)) return address;
    }
  }

  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  final addresses = interfaces
      .expand((interface) => interface.addresses)
      .map((address) => address.address)
      .where(
        (address) =>
            !address.startsWith('169.254.') &&
            !address.startsWith('0.') &&
            !address.startsWith('224.'),
      )
      .toList();
  if (addresses.isEmpty) {
    throw StateError('No usable non-loopback IPv4 address is available.');
  }
  return addresses.where(_isPrivateIpv4).firstOrNull ?? addresses.first;
}

Future<int> _unusedTcpPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _waitForTcpEndpoint(String address, int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final socket = await Socket.connect(
        address,
        port,
        timeout: const Duration(seconds: 1),
      );
      socket.destroy();
      return;
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } on TimeoutException {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  throw TimeoutException('Host LAN listener did not accept a TCP connection.');
}

bool _isPrivateIpv4(String address) =>
    address.startsWith('10.') ||
    address.startsWith('192.168.') ||
    RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(address);

Future<_TestTlsFiles> _createHostTlsFiles(
  Directory directory,
  String hostAddress,
) async {
  final powershell = r'''
$ErrorActionPreference = 'Stop'
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
try {
  $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
    'CN=127.0.0.1', $rsa,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
  $san = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
  $san.AddIpAddress([System.Net.IPAddress]::Parse($env:VENTIO_TEST_HOST_ADDRESS))
  $san.AddIpAddress([System.Net.IPAddress]::Parse('127.0.0.1'))
  $san.AddDnsName('localhost')
  $request.CertificateExtensions.Add($san.Build())
  $request.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
  $keyUsage = [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
    [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment
  $request.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new($keyUsage, $true))
  $oids = [System.Security.Cryptography.OidCollection]::new()
  $null = $oids.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
  $request.CertificateExtensions.Add(
    [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids, $false))
  $certificate = $request.CreateSelfSigned(
    [DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(2))
  try {
    [Console]::Out.WriteLine([Convert]::ToBase64String(
      $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)))
    [Console]::Out.WriteLine([Convert]::ToBase64String($rsa.ExportPkcs8PrivateKey()))
  } finally {
    $certificate.Dispose()
  }
} finally {
  $rsa.Dispose()
}
''';
  final generated = await Process.run(
    'pwsh',
    ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', powershell],
    environment: {
      ...Platform.environment,
      'VENTIO_TEST_HOST_ADDRESS': hostAddress,
    },
  );
  if (generated.exitCode != 0) {
    throw StateError(
      'Could not generate the ephemeral Host TLS test certificate.',
    );
  }
  final encoded = (generated.stdout as String).trim().split(RegExp(r'\r?\n'));
  if (encoded.length != 2) {
    throw StateError('The ephemeral Host TLS certificate output is invalid.');
  }
  String toPem(String label, String value) {
    final lines = <String>[];
    for (var offset = 0; offset < value.length; offset += 64) {
      final end = offset + 64 < value.length ? offset + 64 : value.length;
      lines.add(value.substring(offset, end));
    }
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
  }

  final certificatePath =
      '${directory.path}${Platform.pathSeparator}host-certificate.pem';
  final privateKeyPath =
      '${directory.path}${Platform.pathSeparator}host-private-key.pem';
  await PrivateFiles.create(certificatePath, {'pending': true});
  await File(certificatePath).writeAsString(toPem('CERTIFICATE', encoded[0]));
  await PrivateFiles.create(privateKeyPath, {'pending': true});
  await File(privateKeyPath).writeAsString(toPem('PRIVATE KEY', encoded[1]));
  await PrivateFiles.verifyPrivateFile(privateKeyPath);
  return _TestTlsFiles(certificatePath, privateKeyPath);
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
  return _requestAtEndpoint(
    client,
    scheme: 'http',
    hostAddress: '127.0.0.1',
    port: port,
    method: method,
    path: path,
    token: token,
    body: body,
  );
}

Future<_HttpResult> _requestAtEndpoint(
  HttpClient client, {
  required String scheme,
  required String hostAddress,
  required int port,
  required String method,
  required String path,
  String? token,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(
    method,
    Uri(scheme: scheme, host: hostAddress, port: port, path: path),
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

Map<String, dynamic> _bundleJson({String version = '1.0.0'}) {
  final schemaVersion = version == '1.0.1' ? 2 : 1;
  final hasNotesField = schemaVersion >= 2;
  return {
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
        'schemaVersion': schemaVersion,
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
          if (hasNotesField)
            {
              'name': 'notes',
              'type': 'text',
              'required': false,
              'label': 'Notes',
              'labelKey': 'extension.com_example_windows_records.item.notes',
              'maxLength': 200,
            },
        ],
        'ui': {
          'listColumns': ['title'],
          'formFields': ['title', if (hasNotesField) 'notes'],
        },
      },
    ],
    'dependencyVersions': <String, String>{},
    'englishCatalog': {
      'extension.com_example_windows_records.module.name':
          'Windows Record Registry',
      'extension.com_example_windows_records.item': 'Item',
      'extension.com_example_windows_records.item.title': 'Title',
      if (hasNotesField)
        'extension.com_example_windows_records.item.notes': 'Notes',
    },
  };
}

class _HttpResult {
  const _HttpResult(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
}

class _RunningHost {
  _RunningHost({
    required this.process,
    required this.address,
    required this.scheme,
    required this.port,
    required this.outputSubscription,
    required this.errorSubscription,
  });

  final Process process;
  final String address;
  final String scheme;
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

class _TestTlsFiles {
  const _TestTlsFiles(this.certificatePath, this.privateKeyPath);

  final String certificatePath;
  final String privateKeyPath;
}
