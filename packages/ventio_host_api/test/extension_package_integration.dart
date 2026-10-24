import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart';

Future<void> main() async {
  final databaseUrl = Platform.environment['VENTIO_TEST_DATABASE_URL'];
  final runtimeUrl = Platform.environment['VENTIO_TEST_RUNTIME_DATABASE_URL'];
  final adminUrl = Platform.environment['VENTIO_TEST_ADMIN_DATABASE_URL'];
  if (databaseUrl == null ||
      runtimeUrl == null ||
      adminUrl == null ||
      Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
      Uri.parse(
            databaseUrl,
          ).pathSegments.where((part) => part.isNotEmpty).lastOrNull !=
          'ventio_host_test') {
    stderr.writeln(
      'Extension package integration requires the disposable ventio_host_test database and explicit test opt-in.',
    );
    exitCode = 2;
    return;
  }

  var assertions = 0;
  void expect(bool condition, String label) {
    if (!condition) throw StateError('FAIL: $label');
    assertions++;
    stdout.writeln('PASS: $label');
  }

  Future<void> mustFail(Future<void> Function() action, String label) async {
    var failed = false;
    try {
      await action();
    } catch (_) {
      failed = true;
    }
    expect(failed, label);
  }

  final adminConnection = await pg.Connection.openFromUrl(adminUrl);
  final runtimeConnection = await pg.Connection.openFromUrl(runtimeUrl);
  final observer = await pg.Connection.openFromUrl(databaseUrl);
  final temporary = await Directory.systemTemp.createTemp('ventio-package-');
  if (Platform.isLinux) {
    final result = await Process.run('chmod', ['700', temporary.path]);
    if (result.exitCode != 0) {
      throw StateError('Could not protect extension test storage.');
    }
  }
  final authority = RecoveryAuthority(temporary.path + '/authority.json');
  final tenant =
      'extension-' + DateTime.now().toUtc().microsecondsSinceEpoch.toString();
  const primaryCompany = 'company-primary';
  const primaryBranch = 'branch-primary';
  const secondaryCompany = 'company-secondary';
  const secondaryBranch = 'branch-secondary';
  HostApi? api;
  try {
    await authority.resetForReenrollment(adminConnection, 'package-test-reset');
    final identityAdmin = IdentityAdministration(
      connection: adminConnection,
      tenantId: tenant,
      operatorLabel: 'package-test-operator',
      authority: authority,
    );

    Future<String> provision({
      required String actor,
      required String device,
      required String credential,
      required String company,
      required String branch,
      required List<String> permissions,
      bool registerBranch = true,
    }) async {
      await identityAdmin.createUser(actor);
      if (registerBranch) await identityAdmin.registerBranch(company, branch);
      await identityAdmin.registerDevice(actor, device);
      for (final permission in permissions) {
        await identityAdmin.grant(actor, company, branch, permission);
      }
      final output = temporary.path + '/' + credential + '.json';
      await identityAdmin.provisionToFile(
        actorId: actor,
        deviceId: device,
        credentialId: credential,
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        allowedScopes: [
          {
            'companyId': company,
            'branchId': branch,
            'permissions': permissions,
          },
        ],
        outputPath: output,
      );
      return (jsonDecode(await PrivateFiles.read(output)) as Map)['token']
          as String;
    }

    final primaryToken = await provision(
      actor: 'publisher',
      device: 'publisher-device',
      credential: 'publisher-credential',
      company: primaryCompany,
      branch: primaryBranch,
      permissions: const [
        'extension.package.submit',
        'extension.package.read',
        'extension.com_example_registry.item.read',
        'extension.com_example_registry.item.create',
        'extension.com_example_registry.item.update',
      ],
    );
    final readerToken = await provision(
      actor: 'reader',
      device: 'reader-device',
      credential: 'reader-credential',
      company: secondaryCompany,
      branch: secondaryBranch,
      permissions: const ['extension.package.read'],
    );
    final updateOnlyToken = await provision(
      actor: 'update-only',
      device: 'update-only-device',
      credential: 'update-only-credential',
      company: primaryCompany,
      branch: primaryBranch,
      permissions: const ['extension.com_example_registry.item.update'],
      registerBranch: false,
    );
    final prototype = bootstrapMaintenancePrototype('../../spec/v1.2');
    api = await HostApi.bind(
      authenticator: PersistentTokenAuthenticator(
        connect: () => pg.Connection.openFromUrl(runtimeUrl),
        admission: authority,
      ),
      executor: PersistentCommandExecutor(
        connect: () => pg.Connection.openFromUrl(runtimeUrl),
        admission: authority,
        modules: prototype.modules,
        docTypes: prototype.docTypes,
        bindings: const [
          TrustedCommandBinding('maintenance.create', 1, 'MaintenanceRequest'),
        ],
      ),
      extensionPackages: PostgresExtensionPackageGateway(
        connect: () => pg.Connection.openFromUrl(runtimeUrl),
        admission: authority,
      ),
    );

    Map<String, dynamic> bundleSource(
      String moduleId,
      String version, {
      Map<String, String> dependencies = const {},
      String title = 'Item',
    }) {
      final slug = moduleId.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]+'),
        '_',
      );
      final namespace = 'extension.' + slug;
      final nameKey = '$namespace.name';
      final typeKey = '$namespace.item';
      final fieldKey = '$namespace.item.title';
      return {
        'manifest': {
          'manifestVersion': 0,
          'moduleId': moduleId,
          'version': version,
          'minPlatformApi': '0.1.0',
          'displayName': title,
          'displayNameKey': nameKey,
          'englishCatalog': 'localization/en.test_package.json',
          'dependencies': dependencies.keys.toList(),
          'docTypes': ['Item'],
          'commands': [],
          'requiredCapabilities': [],
          'offline': {'enabled': false, 'allowedCommands': []},
        },
        'docTypes': [
          {
            'name': 'Item',
            'moduleId': moduleId,
            'schemaVersion': 1,
            'kind': 'operational',
            'label': 'Item',
            'labelKey': typeKey,
            'operations': ['read', 'create', 'update'],
            'permissions': {
              'read': '$typeKey.read',
              'create': '$typeKey.create',
              'update': '$typeKey.update',
            },
            'fields': [
              {
                'name': 'title',
                'type': 'text',
                'required': true,
                'label': title,
                'labelKey': fieldKey,
                'maxLength': 80,
              },
            ],
            'ui': {
              'listColumns': ['title'],
              'formFields': ['title'],
            },
          },
        ],
        'dependencyVersions': dependencies,
        'englishCatalog': {nameKey: title, typeKey: 'Item', fieldKey: title},
      };
    }

    ExtensionBundle bundle(
      String moduleId,
      String version, {
      Map<String, String> dependencies = const {},
      String title = 'Item',
    }) => ExtensionBundle.fromJson(
      bundleSource(moduleId, version, dependencies: dependencies, title: title),
    );

    Future<Reply> submitPackage(
      String token,
      ExtensionBundle package, {
      String company = primaryCompany,
      String branch = primaryBranch,
    }) => send(
      api!,
      token: token,
      path: '/api/v1/extensions/submit',
      body: {
        'companyId': company,
        'branchId': branch,
        'package': package.toJson(),
      },
    );

    Future<Reply> readPackage(
      String token,
      String moduleId,
      String version, {
      String company = primaryCompany,
      String branch = primaryBranch,
    }) => send(
      api!,
      token: token,
      path: '/api/v1/extensions/read',
      body: {
        'companyId': company,
        'branchId': branch,
        'moduleId': moduleId,
        'version': version,
      },
    );

    String hash(ExtensionBundle package) =>
        sha256.convert(utf8.encode(canonicalJson(package.toJson()))).toString();

    final discovered = await send(
      api,
      path: '/api/v1/session',
      method: 'GET',
      token: primaryToken,
    );
    final discoveredIdentity =
        discovered.body['identity'] as Map<String, dynamic>;
    expect(
      discovered.status == 200 &&
          discoveredIdentity['tenantId'] == tenant &&
          discoveredIdentity['persistent'] == true &&
          (discoveredIdentity['scopes'] as List).any(
            (scope) =>
                scope['companyId'] == primaryCompany &&
                scope['branchId'] == primaryBranch &&
                (scope['permissions'] as List).contains(
                  'extension.package.submit',
                ),
          ),
      'Persistent session discovery reports only the current exact branch grants',
    );

    final package = bundle('com.example.registry', '1.0.0');
    expect(
      (await submitPackage(primaryToken, package)).status == 202,
      'Authorized package submission is stored as a pending candidate',
    );
    final duplicate = await submitPackage(primaryToken, package);
    expect(
      duplicate.status == 202 &&
          (await observer.execute(
                pg.Sql.named(
                  "SELECT count(*) FROM ventio_extension_package_events WHERE tenant_id=@tenant AND event_type='SUBMITTED' AND module_id='com.example.registry'",
                ),
                parameters: {'tenant': tenant},
              )).single[0] ==
              1,
      'Identical package retries are idempotent and audited once',
    );
    final changedSameVersion = bundle(
      'com.example.registry',
      '1.0.0',
      title: 'Changed',
    );
    expect(
      (await submitPackage(primaryToken, changedSameVersion)).status == 409,
      'A release version cannot be reused for different metadata',
    );
    expect(
      (await readPackage(
            primaryToken,
            package.moduleId,
            package.version,
          )).status ==
          404,
      'Candidates are unavailable through the approved-package read endpoint',
    );
    expect(
      (await submitPackage(readerToken, package)).status == 403,
      'Read-only scoped identity cannot submit a package',
    );
    expect(
      (await readPackage(
            readerToken,
            package.moduleId,
            package.version,
            company: primaryCompany,
            branch: primaryBranch,
          )).status ==
          403,
      'A user cannot read packages outside the granted company/branch pair',
    );

    final packageAdmin = ExtensionPackageAdministration(
      connection: adminConnection,
      tenantId: tenant,
      operatorLabel: 'package-test-operator',
      authority: authority,
    );
    await packageAdmin.approve(
      moduleId: package.moduleId,
      version: package.version,
      packageSha256: hash(package),
    );
    final approved = await readPackage(
      primaryToken,
      package.moduleId,
      package.version,
    );
    expect(
      approved.status == 200 &&
          approved.body['packageResult']['status'] == 'APPROVED' &&
          approved.body['packageResult']['packageSha256'] == hash(package),
      'Operator approval makes only the reviewed digest available to scoped clients',
    );
    final createRecord = ExtensionRecordCommand.create(
      commandId: '71000000-0000-4000-8000-000000000001',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'registry-item-1',
      actorId: 'publisher',
      deviceId: 'publisher-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'First item'},
    );
    final created = await send(
      api,
      token: primaryToken,
      body: createRecord.envelope.original,
    );
    expect(
      created.status == 200 &&
          created.body['receipt']['status'] == 'ACCEPTED' &&
          created.body['receipt']['hostRevision'] == 1,
      'An approved generic DocType can create a Host-authoritative record',
    );
    final persistedCreate = await observer.execute(
      pg.Sql.named('''
        SELECT module_id, revision, record_data->>'title' AS title
        FROM ventio_records
        WHERE tenant_id=@tenant AND company_id=@company AND branch_id=@branch
          AND module_id=@module AND doc_type='Item' AND record_id=@record
      '''),
      parameters: {
        'tenant': tenant,
        'company': primaryCompany,
        'branch': primaryBranch,
        'module': package.moduleId,
        'record': 'registry-item-1',
      },
    );
    expect(
      persistedCreate.single.toColumnMap()['revision'] == 1 &&
          persistedCreate.single.toColumnMap()['title'] == 'First item',
      'Generic records persist with module-qualified identity and values',
    );
    final replayedCreate = await send(
      api,
      token: primaryToken,
      body: createRecord.envelope.original,
    );
    expect(
      replayedCreate.status == 200 &&
          replayedCreate.body['receipt'] == created.body['receipt'],
      'A retried generic write returns its saved Host receipt without duplication',
    );
    final updateRecord = ExtensionRecordCommand.update(
      commandId: '71000000-0000-4000-8000-000000000002',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'registry-item-1',
      expectedRevision: 1,
      actorId: 'publisher',
      deviceId: 'publisher-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'Updated item'},
    );
    final updated = await send(
      api,
      token: primaryToken,
      body: updateRecord.envelope.original,
    );
    expect(
      updated.status == 200 &&
          updated.body['receipt']['status'] == 'ACCEPTED' &&
          updated.body['receipt']['hostRevision'] == 2,
      'A generic record update honors expected revision and advances Host revision',
    );
    final persistedUpdate = await observer.execute(
      pg.Sql.named('''
        SELECT revision, record_data->>'title' AS title
        FROM ventio_records
        WHERE tenant_id=@tenant AND company_id=@company AND branch_id=@branch
          AND module_id=@module AND doc_type='Item' AND record_id=@record
      '''),
      parameters: {
        'tenant': tenant,
        'company': primaryCompany,
        'branch': primaryBranch,
        'module': package.moduleId,
        'record': 'registry-item-1',
      },
    );
    expect(
      persistedUpdate.single.toColumnMap()['revision'] == 2 &&
          persistedUpdate.single.toColumnMap()['title'] == 'Updated item',
      'Host updates persist the new values and revision',
    );
    final updateWithoutRead = ExtensionRecordCommand.update(
      commandId: '71000000-0000-4000-8000-000000000006',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'registry-item-1',
      expectedRevision: 2,
      actorId: 'update-only',
      deviceId: 'update-only-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'Update without read'},
    );
    final updateWithoutReadReply = await send(
      api,
      token: updateOnlyToken,
      body: updateWithoutRead.envelope.original,
    );
    expect(
      updateWithoutReadReply.status == 403 &&
          updateWithoutReadReply.body['receipt']['reasonCode'] ==
              'PERMISSION_DENIED',
      'Updating a record requires its explicit read permission',
    );
    final staleRecord = ExtensionRecordCommand.update(
      commandId: '71000000-0000-4000-8000-000000000003',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'registry-item-1',
      expectedRevision: 1,
      actorId: 'publisher',
      deviceId: 'publisher-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'Stale write'},
    );
    final stale = await send(
      api,
      token: primaryToken,
      body: staleRecord.envelope.original,
    );
    expect(
      stale.status == 409 &&
          stale.body['receipt']['reasonCode'] == 'REVISION_CONFLICT' &&
          stale.body['receipt']['currentRevision'] == 2,
      'Stale generic writes are rejected with the current Host revision',
    );
    final forgedBranchRecord = ExtensionRecordCommand.create(
      commandId: '71000000-0000-4000-8000-000000000005',
      tenantId: tenant,
      companyId: secondaryCompany,
      branchId: secondaryBranch,
      recordId: 'registry-item-cross-branch',
      actorId: 'publisher',
      deviceId: 'publisher-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'Cross-branch item'},
    );
    final forgedBranchWrite = await send(
      api,
      token: primaryToken,
      body: forgedBranchRecord.envelope.original,
    );
    expect(
      forgedBranchWrite.status == 403 &&
          forgedBranchWrite.body['receipt']['reasonCode'] == 'SCOPE_DENIED',
      'A primary-branch credential cannot forge an approved extension write in another branch',
    );
    final deniedRecord = ExtensionRecordCommand.create(
      commandId: '71000000-0000-4000-8000-000000000004',
      tenantId: tenant,
      companyId: secondaryCompany,
      branchId: secondaryBranch,
      recordId: 'registry-item-forbidden',
      actorId: 'reader',
      deviceId: 'reader-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'Forbidden item'},
    );
    final deniedWrite = await send(
      api,
      token: readerToken,
      body: deniedRecord.envelope.original,
    );
    expect(
      deniedWrite.status == 403 &&
          deniedWrite.body['receipt']['reasonCode'] == 'PERMISSION_DENIED',
      'An approved extension cannot grant create access in an ungranted branch',
    );
    expect(
      (await readPackage(
            readerToken,
            package.moduleId,
            package.version,
            company: secondaryCompany,
            branch: secondaryBranch,
          )).status ==
          200,
      'Package visibility is granted by the reader exact-scope permission',
    );

    final older = bundle('com.example.registry', '0.9.0');
    await submitPackage(primaryToken, older);
    await mustFail(
      () => packageAdmin.approve(
        moduleId: older.moduleId,
        version: older.version,
        packageSha256: hash(older),
      ),
      'Host rejects a release downgrade',
    );
    expect(
      (await readPackage(primaryToken, older.moduleId, older.version)).status ==
          404,
      'A rejected downgrade remains unapproved',
    );

    final dependency = bundle('com.example.dependency', '1.0.0');
    await submitPackage(primaryToken, dependency);
    await packageAdmin.approve(
      moduleId: dependency.moduleId,
      version: dependency.version,
      packageSha256: hash(dependency),
    );
    final dependent = bundle(
      'com.example.dependent',
      '1.0.0',
      dependencies: {dependency.moduleId: dependency.version},
    );
    await submitPackage(primaryToken, dependent);
    await packageAdmin.approve(
      moduleId: dependent.moduleId,
      version: dependent.version,
      packageSha256: hash(dependent),
    );
    await mustFail(
      () => packageAdmin.revoke(
        moduleId: dependency.moduleId,
        version: dependency.version,
        packageSha256: hash(dependency),
        reason: 'Must revoke dependent first.',
      ),
      'Host prevents revoking a dependency while an approved dependent remains',
    );
    await packageAdmin.revoke(
      moduleId: dependent.moduleId,
      version: dependent.version,
      packageSha256: hash(dependent),
      reason: 'Integration test revocation.',
    );
    await packageAdmin.revoke(
      moduleId: dependency.moduleId,
      version: dependency.version,
      packageSha256: hash(dependency),
      reason: 'Integration test revocation.',
    );
    expect(
      (await readPackage(
            primaryToken,
            dependency.moduleId,
            dependency.version,
          )).status ==
          404,
      'Revoked package versions are denied by future Host reads',
    );
    expect(
      (await submitPackage(primaryToken, dependency)).status == 409,
      'A revoked release version cannot be resubmitted',
    );

    var runtimeReadBlocked = false;
    try {
      await runtimeConnection.execute(
        'SELECT package_json FROM public.ventio_extension_packages',
      );
    } on pg.ServerException {
      runtimeReadBlocked = true;
    }
    var adminReadBlocked = false;
    try {
      await adminConnection.execute(
        'SELECT package_json FROM public.ventio_extension_packages',
      );
    } on pg.ServerException {
      adminReadBlocked = true;
    }
    expect(
      runtimeReadBlocked && adminReadBlocked,
      'Runtime and identity-admin logins cannot bypass package functions with direct table reads',
    );
    expect(
      (await observer.execute(
            pg.Sql.named(
              "SELECT count(*) FROM public.ventio_extension_package_events WHERE tenant_id=@tenant AND event_type IN ('APPROVED','REVOKED')",
            ),
            parameters: {'tenant': tenant},
          )).single[0] ==
          5,
      'Approval and revocation events remain in the operator audit ledger',
    );
    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    await api?.close();
    await observer.close();
    await runtimeConnection.close();
    await adminConnection.close();
    await temporary.delete(recursive: true);
  }
}
