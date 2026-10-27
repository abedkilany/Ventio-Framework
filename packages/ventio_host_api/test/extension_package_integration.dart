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
  final temporary = await createPrivateTestDirectory('ventio-package-');
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
    await identityAdmin.createRole(
      'recovery-witness-role',
      'Recovery witness role',
    );
    await identityAdmin.grantRolePermission(
      'recovery-witness-role',
      'extension.package.read',
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
    final secondaryPublisherToken = await provision(
      actor: 'secondary-publisher',
      device: 'secondary-publisher-device',
      credential: 'secondary-publisher-credential',
      company: secondaryCompany,
      branch: primaryBranch,
      permissions: const [
        'extension.package.read',
        'extension.com_example_registry.item.read',
        'extension.com_example_registry.item.create',
        'extension.com_example_registry.item.update',
      ],
    );
    final branchPublisherToken = await provision(
      actor: 'branch-publisher',
      device: 'branch-publisher-device',
      credential: 'branch-publisher-credential',
      company: primaryCompany,
      branch: secondaryBranch,
      permissions: const [
        'extension.package.read',
        'extension.com_example_registry.item.read',
        'extension.com_example_registry.item.create',
        'extension.com_example_registry.item.update',
      ],
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
    const protectedTitleRead =
        'extension.com_example_field_policy.item.title_read';
    const protectedTitleWrite =
        'extension.com_example_field_policy.item.title_write';
    final fieldReaderToken = await provision(
      actor: 'field-reader',
      device: 'field-reader-device',
      credential: 'field-reader-credential',
      company: primaryCompany,
      branch: primaryBranch,
      permissions: const [
        'extension.package.read',
        'extension.com_example_field_policy.item.read',
        protectedTitleRead,
      ],
      registerBranch: false,
    );
    final fieldBlindToken = await provision(
      actor: 'field-blind',
      device: 'field-blind-device',
      credential: 'field-blind-credential',
      company: primaryCompany,
      branch: primaryBranch,
      permissions: const [
        'extension.package.read',
        'extension.com_example_field_policy.item.read',
      ],
      registerBranch: false,
    );
    final restrictedEditorToken = await provision(
      actor: 'restricted-editor',
      device: 'restricted-editor-device',
      credential: 'restricted-editor-credential',
      company: primaryCompany,
      branch: primaryBranch,
      permissions: const [
        'extension.package.read',
        'extension.com_example_field_policy.item.read',
        'extension.com_example_field_policy.item.update',
        protectedTitleRead,
      ],
      registerBranch: false,
    );
    final fieldWriterToken = await provision(
      actor: 'field-writer',
      device: 'field-writer-device',
      credential: 'field-writer-credential',
      company: primaryCompany,
      branch: primaryBranch,
      permissions: const [
        'extension.package.read',
        'extension.com_example_field_policy.item.read',
        'extension.com_example_field_policy.item.create',
        'extension.com_example_field_policy.item.update',
        protectedTitleRead,
        protectedTitleWrite,
      ],
      registerBranch: false,
    );
    final fieldNoWriteCreatorToken = await provision(
      actor: 'field-no-write-creator',
      device: 'field-no-write-creator-device',
      credential: 'field-no-write-creator-credential',
      company: primaryCompany,
      branch: primaryBranch,
      permissions: const [
        'extension.package.read',
        'extension.com_example_field_policy.item.read',
        'extension.com_example_field_policy.item.create',
      ],
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
      extensionRecordQueries: PostgresExtensionRecordQueryGateway(
        connect: () => pg.Connection.openFromUrl(runtimeUrl),
        admission: authority,
      ),
    );

    Map<String, dynamic> bundleSource(
      String moduleId,
      String version, {
      Map<String, String> dependencies = const {},
      String title = 'Item',
      bool protectTitle = false,
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
          'minPlatformApi': protectTitle ? '0.3.0' : '0.1.0',
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
                if (protectTitle) 'readPermission': '$typeKey.title_read',
                if (protectTitle) 'writePermission': '$typeKey.title_write',
              },
              {
                'name': 'parent',
                'type': 'reference',
                'referenceTo': 'Item',
                'required': false,
                'label': 'Parent item',
                'labelKey': '$typeKey.parent',
              },
            ],
            'ui': {
              'listColumns': ['title'],
              'formFields': ['title'],
            },
          },
        ],
        'dependencyVersions': dependencies,
        'englishCatalog': {
          nameKey: title,
          typeKey: 'Item',
          fieldKey: title,
          '$typeKey.parent': 'Parent item',
        },
      };
    }

    ExtensionBundle bundle(
      String moduleId,
      String version, {
      Map<String, String> dependencies = const {},
      String title = 'Item',
      bool protectTitle = false,
    }) => ExtensionBundle.fromJson(
      bundleSource(
        moduleId,
        version,
        dependencies: dependencies,
        title: title,
        protectTitle: protectTitle,
      ),
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

    Future<Reply> listPackages(
      String token, {
      String company = primaryCompany,
      String branch = primaryBranch,
      int limit = 50,
      String? afterModuleId,
      String? afterVersion,
    }) => send(
      api!,
      token: token,
      path: '/api/v1/extensions/approved',
      body: {
        'companyId': company,
        'branchId': branch,
        'limit': limit,
        if (afterModuleId != null) 'afterModuleId': afterModuleId,
        if (afterVersion != null) 'afterVersion': afterVersion,
      },
    );

    Future<Reply> queryRecords(
      String token, {
      String company = primaryCompany,
      String branch = primaryBranch,
      String version = '1.0.0',
      String moduleId = 'com.example.registry',
      String docType = 'Item',
      String? recordId,
      String search = '',
      Map<String, dynamic> filters = const {},
      String? filterField,
      String filterContains = '',
      String? sortField = 'title',
      bool descending = false,
      int offset = 0,
      int limit = 10,
    }) => send(
      api!,
      token: token,
      path: '/api/v1/extensions/records/query',
      body: {
        'companyId': company,
        'branchId': branch,
        'moduleId': moduleId,
        'version': version,
        'docType': docType,
        if (recordId != null) 'recordId': recordId,
        'search': search,
        'filters': filters,
        'filterField': filterField,
        'filterContains': filterContains,
        'sortField': sortField,
        'descending': descending,
        'offset': offset,
        'limit': limit,
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
    final candidateRegistry = await listPackages(primaryToken, limit: 10);
    expect(
      candidateRegistry.status == 200 &&
          (candidateRegistry.body['packageResult']['packages'] as List).isEmpty,
      'Submitted candidates stay hidden from the approved package registry',
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
    final secondPackage = bundle('com.example.registry_extra', '1.0.0');
    expect(
      (await submitPackage(primaryToken, secondPackage)).status == 202,
      'A second distinct package can be submitted independently',
    );
    await packageAdmin.approve(
      moduleId: secondPackage.moduleId,
      version: secondPackage.version,
      packageSha256: hash(secondPackage),
    );
    final approvedRegistry = await listPackages(primaryToken, limit: 1);
    final registryPackages =
        approvedRegistry.body['packageResult']['packages'] as List;
    expect(
      approvedRegistry.status == 200 &&
          registryPackages.length == 1 &&
          registryPackages.single['moduleId'] == package.moduleId &&
          registryPackages.single['version'] == package.version &&
          registryPackages.single['packageSha256'] == hash(package) &&
          approvedRegistry.body['packageResult']['hasMore'] == true,
      'The exact approved digest is discoverable in the first bounded registry page',
    );
    final nextRegistryPage = await listPackages(
      primaryToken,
      limit: 1,
      afterModuleId: package.moduleId,
      afterVersion: package.version,
    );
    final nextRegistryPackages =
        nextRegistryPage.body['packageResult']['packages'] as List;
    expect(
      nextRegistryPage.status == 200 &&
          nextRegistryPackages.length == 1 &&
          nextRegistryPackages.single['moduleId'] == secondPackage.moduleId &&
          nextRegistryPackages.single['packageSha256'] == hash(secondPackage) &&
          nextRegistryPage.body['packageResult']['hasMore'] == false,
      'The Host registry cursor returns the next approved summary without overlap',
    );
    expect(
      (await listPackages(
            readerToken,
            company: primaryCompany,
            branch: primaryBranch,
          )).status ==
          403,
      'The registry refuses users without package-read permission in the exact branch',
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
    final secondRecord = ExtensionRecordCommand.create(
      commandId: '71000000-0000-4000-8000-000000000002',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'registry-item-2',
      actorId: 'publisher',
      deviceId: 'publisher-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'Second item', 'parent': 'registry-item-1'},
    );
    expect(
      (await send(
            api,
            token: primaryToken,
            body: secondRecord.envelope.original,
          )).body['receipt']['status'] ==
          'ACCEPTED',
      'A second generic record is accepted under the same approved DocType',
    );
    final missingReference = ExtensionRecordCommand.create(
      commandId: '71000000-0000-4000-8000-000000000008',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'registry-item-missing-parent',
      actorId: 'publisher',
      deviceId: 'publisher-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'Missing parent', 'parent': 'not-present'},
    );
    final missingReferenceReply = await send(
      api,
      token: primaryToken,
      body: missingReference.envelope.original,
    );
    final uncommittedMissingReferenceRecord = await observer.execute(
      pg.Sql.named('''
        SELECT count(*) FROM ventio_records
        WHERE tenant_id=@tenant AND company_id=@company AND branch_id=@branch
          AND module_id=@module AND doc_type='Item' AND record_id=@record
      '''),
      parameters: {
        'tenant': tenant,
        'company': primaryCompany,
        'branch': primaryBranch,
        'module': package.moduleId,
        'record': 'registry-item-missing-parent',
      },
    );
    expect(
      missingReferenceReply.status == 422 &&
          missingReferenceReply.body['receipt']['reasonCode'] ==
              'INVALID_REFERENCE' &&
          uncommittedMissingReferenceRecord.single[0] == 0,
      'Host rejects a missing reference without writing the record',
    );

    final foreignBranchTarget = ExtensionRecordCommand.create(
      commandId: '72000000-0000-4000-8000-000000000001',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: secondaryBranch,
      recordId: 'secondary-branch-item',
      actorId: 'branch-publisher',
      deviceId: 'branch-publisher-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'Private branch item'},
    );
    final foreignTargetReply = await send(
      api,
      token: branchPublisherToken,
      body: foreignBranchTarget.envelope.original,
    );
    expect(
      foreignTargetReply.status == 200 &&
          foreignTargetReply.body['receipt']['status'] == 'ACCEPTED',
      'A reference target can exist independently in another branch of the same company',
    );

    final crossBranchReference = ExtensionRecordCommand.create(
      commandId: '71000000-0000-4000-8000-000000000009',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'registry-item-cross-branch-reference',
      actorId: 'publisher',
      deviceId: 'publisher-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {
        'title': 'Foreign branch parent',
        'parent': 'secondary-branch-item',
      },
    );
    final crossBranchReferenceReply = await send(
      api,
      token: primaryToken,
      body: crossBranchReference.envelope.original,
    );
    final uncommittedReferenceRecord = await observer.execute(
      pg.Sql.named('''
        SELECT count(*) FROM ventio_records
        WHERE tenant_id=@tenant AND company_id=@company AND branch_id=@branch
          AND module_id=@module AND doc_type='Item' AND record_id=@record
      '''),
      parameters: {
        'tenant': tenant,
        'company': primaryCompany,
        'branch': primaryBranch,
        'module': package.moduleId,
        'record': 'registry-item-cross-branch-reference',
      },
    );
    expect(
      crossBranchReferenceReply.status == 422 &&
          crossBranchReferenceReply.body['receipt']['reasonCode'] ==
              'INVALID_REFERENCE' &&
          uncommittedReferenceRecord.single[0] == 0,
      'Host rejects a cross-branch reference without writing the record',
    );

    final foreignCompanyTarget = ExtensionRecordCommand.create(
      commandId: '72000000-0000-4000-8000-000000000002',
      tenantId: tenant,
      companyId: secondaryCompany,
      branchId: primaryBranch,
      recordId: 'secondary-company-item',
      actorId: 'secondary-publisher',
      deviceId: 'secondary-publisher-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'Private company item'},
    );
    final foreignCompanyReply = await send(
      api,
      token: secondaryPublisherToken,
      body: foreignCompanyTarget.envelope.original,
    );
    expect(
      foreignCompanyReply.status == 200 &&
          foreignCompanyReply.body['receipt']['status'] == 'ACCEPTED',
      'A reference target can exist independently in another company at the same branch ID',
    );

    final crossCompanyReference = ExtensionRecordCommand.create(
      commandId: '71000000-0000-4000-8000-000000000010',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'registry-item-cross-company-reference',
      actorId: 'publisher',
      deviceId: 'publisher-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {
        'title': 'Foreign company parent',
        'parent': 'secondary-company-item',
      },
    );
    final crossCompanyReferenceReply = await send(
      api,
      token: primaryToken,
      body: crossCompanyReference.envelope.original,
    );
    final uncommittedCompanyReferenceRecord = await observer.execute(
      pg.Sql.named('''
        SELECT count(*) FROM ventio_records
        WHERE tenant_id=@tenant AND company_id=@company AND branch_id=@branch
          AND module_id=@module AND doc_type='Item' AND record_id=@record
      '''),
      parameters: {
        'tenant': tenant,
        'company': primaryCompany,
        'branch': primaryBranch,
        'module': package.moduleId,
        'record': 'registry-item-cross-company-reference',
      },
    );
    expect(
      crossCompanyReferenceReply.status == 422 &&
          crossCompanyReferenceReply.body['receipt']['reasonCode'] ==
              'INVALID_REFERENCE' &&
          uncommittedCompanyReferenceRecord.single[0] == 0,
      'Host rejects a cross-company reference without writing the record',
    );
    final querySession = await PersistentTokenAuthenticator(
      connect: () => pg.Connection.openFromUrl(runtimeUrl),
      admission: authority,
    ).authenticate(primaryToken);
    if (querySession == null) {
      throw StateError('Could not authenticate the integration query user.');
    }
    final directFilteredRecords =
        await PostgresExtensionRecordQueryGateway(
          connect: () => pg.Connection.openFromUrl(runtimeUrl),
          admission: authority,
        ).query(
          session: querySession,
          companyId: primaryCompany,
          branchId: primaryBranch,
          moduleId: package.moduleId,
          version: package.version,
          docType: 'Item',
          search: 'first',
          filters: const {'title': 'First item'},
          filterField: null,
          filterContains: '',
          sortField: null,
          descending: false,
          offset: 0,
          limit: 50,
        );
    if (directFilteredRecords['status'] != 'RECORDS') {
      throw StateError(
        'Direct filtered Host query failed: $directFilteredRecords',
      );
    }
    expect(
      (directFilteredRecords['records'] as List).single['recordId'] ==
          'registry-item-1',
      'PostgreSQL record gateway uses metadata equality filters',
    );
    final equalityFilterPlan = await observer.runTx((tx) async {
      await tx.execute('SET LOCAL enable_seqscan = off');
      return tx.execute(
        pg.Sql.named('''
          EXPLAIN SELECT record_id FROM public.ventio_records
          WHERE record_data @> jsonb_build_object(
            CAST(@field AS text), CAST(@value AS jsonb))
        '''),
        parameters: {'field': 'title', 'value': canonicalJson('First item')},
      );
    });
    final equalityFilterPlanText = equalityFilterPlan
        .map((row) => row[0] as String)
        .join('\n');
    expect(
      equalityFilterPlanText.contains('ventio_records_record_data_gin_idx'),
      'Dynamic JSON equality filters can use the shared GIN index',
    );
    final queriedRecords = await queryRecords(
      primaryToken,
      search: 'first',
      filters: const {'title': 'First item'},
    );
    if (queriedRecords.status != 200) {
      throw StateError(
        'Filtered Host query failed: ${queriedRecords.status} '
        '${queriedRecords.body}',
      );
    }
    final recordResult =
        queriedRecords.body['recordResult'] as Map<String, dynamic>;
    final recordRows = recordResult['records'] as List;
    expect(
      queriedRecords.status == 200 &&
          recordRows.length == 1 &&
          recordResult['hasMore'] == false &&
          recordResult['packageSha256'] == hash(package) &&
          recordRows.single['recordId'] == 'registry-item-1' &&
          recordRows.single['values']['title'] == 'First item',
      'Approved dynamic record reads honor metadata filters and return Host values',
    );
    final exactRecord = await queryRecords(
      primaryToken,
      recordId: 'registry-item-2',
      limit: 1,
      sortField: null,
    );
    final exactResult =
        exactRecord.body['recordResult'] as Map<String, dynamic>;
    expect(
      exactRecord.status == 200 &&
          exactResult['hasMore'] == false &&
          (exactResult['records'] as List).length == 1 &&
          (exactResult['records'] as List).single['recordId'] ==
              'registry-item-2',
      'Host can securely return one exact record for conflict review',
    );
    final invalidExactRecordQuery = await queryRecords(
      primaryToken,
      recordId: 'registry-item-2',
      search: 'item',
      limit: 1,
    );
    expect(
      invalidExactRecordQuery.status == 400,
      'Exact record reads reject mixed search and paging parameters',
    );
    final firstPage = await queryRecords(
      primaryToken,
      search: 'item',
      limit: 1,
    );
    final firstPageResult =
        firstPage.body['recordResult'] as Map<String, dynamic>;
    final nextPage = await queryRecords(
      primaryToken,
      search: 'item',
      offset: 1,
      limit: 1,
    );
    final nextPageResult =
        nextPage.body['recordResult'] as Map<String, dynamic>;
    expect(
      firstPage.status == 200 &&
          firstPageResult['hasMore'] == true &&
          (firstPageResult['records'] as List).single['recordId'] ==
              'registry-item-1' &&
          nextPage.status == 200 &&
          nextPageResult['hasMore'] == false &&
          (nextPageResult['records'] as List).single['recordId'] ==
              'registry-item-2',
      'Host dynamic record queries apply bounded ordering and offset paging',
    );
    await observer.execute(
      pg.Sql.named('''
        INSERT INTO ventio_records
          (tenant_id, company_id, branch_id, module_id, doc_type, record_id,
           revision, record_data)
        VALUES (@tenant, @company, @branch, @module, 'Item', 'oversize-record',
                1, CAST(@data AS jsonb))
      '''),
      parameters: {
        'tenant': tenant,
        'company': primaryCompany,
        'branch': primaryBranch,
        'module': package.moduleId,
        'data': jsonEncode({
          'title': 'oversize-sentinel${List.filled(750000, '\u0001').join()}',
        }),
      },
    );
    final oversizedPage = await queryRecords(
      primaryToken,
      filterField: 'title',
      filterContains: 'oversize-sentinel',
      sortField: null,
    );
    final oversizedResult = oversizedPage.body['recordResult'];
    expect(
      oversizedPage.status == 413 &&
          oversizedResult is Map &&
          oversizedResult['reasonCode'] == 'RECORD_PAGE_TOO_LARGE',
      'Host rejects oversized dynamic record pages before serializing record values',
    );
    final unreadableRecords = await queryRecords(updateOnlyToken);
    expect(
      unreadableRecords.status == 403 &&
          unreadableRecords.body['recordResult']['reasonCode'] ==
              'PERMISSION_DENIED',
      'An update-only grant cannot read extension records',
    );
    final forgedBranchRead = await queryRecords(
      primaryToken,
      company: secondaryCompany,
      branch: secondaryBranch,
    );
    expect(
      forgedBranchRead.status == 403 &&
          forgedBranchRead.body['error']['code'] == 'SCOPE_DENIED',
      'A scoped credential cannot query records in a different branch',
    );
    final replayedCreate = await send(
      api,
      token: primaryToken,
      body: createRecord.envelope.original,
    );
    expect(
      replayedCreate.status == 200 &&
          canonicalJson(replayedCreate.body['receipt']) ==
              canonicalJson(created.body['receipt']),
      'A retried generic write returns its saved Host receipt without duplication',
    );
    final updateRecord = ExtensionRecordCommand.update(
      commandId: '71000000-0000-4000-8000-000000000007',
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

    final readBinding = pg.Sql.named(
      'SELECT ventio_security.resolve_extension_read_identity('
      '@digest,@company,@branch,@module,@version,\'Item\')',
    );
    final readBindingParameters = {
      'digest': OpaqueToken.digest(primaryToken),
      'company': primaryCompany,
      'branch': primaryBranch,
      'module': package.moduleId,
      'version': package.version,
    };
    final scopedReadParameters = {
      'tenant': tenant,
      'company': primaryCompany,
      'branch': primaryBranch,
      'module': package.moduleId,
    };
    final admittedRead = await runtimeConnection.runTx((tx) async {
      await authority.admit(tx);
      final resolved = await tx.execute(
        readBinding,
        parameters: readBindingParameters,
      );
      final visibleRows = await tx.execute(
        pg.Sql.named(
          'SELECT record_id FROM public.ventio_records WHERE tenant_id=@tenant '
          'AND company_id=@company AND branch_id=@branch AND module_id=@module '
          "AND doc_type='Item'",
        ),
        parameters: scopedReadParameters,
      );
      final proof = await tx.execute(
        "SELECT current_setting('ventio.recovery_fingerprint'), "
        "current_setting('ventio.recovery_proof')",
      );
      final authorizationCache = await tx.execute(
        "SELECT current_setting('ventio.extension_identity_snapshot',true), "
        "current_setting('ventio.extension_policy_snapshot',true), "
        "current_setting('ventio.extension_context_proof',true)",
      );
      return {
        'resolved': resolved.single[0] != null,
        'visibleRows': visibleRows.length,
        'fingerprint': proof.single[0] as String,
        'proof': proof.single[1] as String,
        'authorizationCache':
            authorizationCache.single[0] is String &&
            (authorizationCache.single[0] as String).isNotEmpty &&
            authorizationCache.single[1] is String &&
            (authorizationCache.single[1] as String).isNotEmpty &&
            authorizationCache.single[2] is String &&
            (authorizationCache.single[2] as String).isNotEmpty,
      };
    });
    expect(
      admittedRead['resolved'] == true &&
          admittedRead['visibleRows']! as int > 0,
      'An admitted transaction receives a recovery proof and scoped RLS rows',
    );
    expect(
      admittedRead['authorizationCache'] == true,
      'The trusted extension resolver binds a transaction-scoped RLS authorization cache',
    );

    final tamperedAuthorizationRows = await runtimeConnection.runTx((tx) async {
      await authority.admit(tx);
      await tx.execute(readBinding, parameters: readBindingParameters);
      await tx.execute(
        "SELECT set_config('ventio.extension_context_proof','00',true)",
      );
      return (await tx.execute(
            pg.Sql.named(
              'SELECT count(*) FROM public.ventio_records WHERE tenant_id=@tenant '
              'AND company_id=@company AND branch_id=@branch AND module_id=@module '
              "AND doc_type='Item'",
            ),
            parameters: scopedReadParameters,
          )).single[0]
          as int;
    });
    expect(
      tamperedAuthorizationRows == 0,
      'RLS denies rows after its signed extension authorization cache is tampered with',
    );

    Future<int> rowsWithRecoveryGucs(String proof) => runtimeConnection.runTx((
      tx,
    ) async {
      await tx.execute(
        pg.Sql.named(
          "SELECT set_config('ventio.recovery_fingerprint',@fingerprint,true), "
          "set_config('ventio.recovery_proof',@proof,true)",
        ),
        parameters: {
          'fingerprint': admittedRead['fingerprint'],
          'proof': proof,
        },
      );
      await tx.execute(readBinding, parameters: readBindingParameters);
      return (await tx.execute(
            pg.Sql.named(
              'SELECT count(*) FROM public.ventio_records WHERE tenant_id=@tenant '
              'AND company_id=@company AND branch_id=@branch AND module_id=@module '
              "AND doc_type='Item'",
            ),
            parameters: scopedReadParameters,
          )).single[0]
          as int;
    });
    expect(
      await rowsWithRecoveryGucs(admittedRead['proof']! as String) == 0,
      'A signed recovery proof cannot be replayed in another transaction',
    );
    expect(
      await rowsWithRecoveryGucs(admittedRead['fingerprint']! as String) == 0,
      'A caller cannot forge recovery admission by setting custom GUCs',
    );
    var privateHmacDenied = false;
    try {
      await runtimeConnection.execute(
        "SELECT ventio_crypto.hmac(decode('00','hex'),decode('00','hex'),'sha256')",
      );
    } on pg.ServerException {
      privateHmacDenied = true;
    }
    expect(
      privateHmacDenied,
      'Runtime cannot call the private recovery proof primitive directly',
    );

    // Recreate the previously failing 1k-user / 20k-audit workload on the
    // disposable database. The recovery check should stay bounded while the
    // identity history grows, and current RLS still has to return scoped rows.
    const benchmarkTenant = 'benchmark-recovery-scale';
    await authority.change(observer, (tx) async {
      await tx.execute(
        "INSERT INTO public.ventio_identity_branches(tenant_id,company_id,branch_id) "
        "VALUES ('$benchmarkTenant','benchmark-company','benchmark-branch')",
      );
      await tx.execute(
        "INSERT INTO public.ventio_identity_users(tenant_id,actor_id) "
        "SELECT '$benchmarkTenant','fixture-user-'||i FROM generate_series(1,1000) AS s(i)",
      );
      await tx.execute(
        "INSERT INTO public.ventio_identity_devices(tenant_id,actor_id,device_id) "
        "SELECT '$benchmarkTenant','fixture-user-'||i,'fixture-device-'||i "
        "FROM generate_series(1,1000) AS s(i)",
      );
      await tx.execute(
        "INSERT INTO public.ventio_identity_credentials(tenant_id,actor_id,device_id,credential_id,token_digest,expires_at) "
        "SELECT '$benchmarkTenant','fixture-user-'||i,'fixture-device-'||i,'fixture-credential-'||i, "
        "encode(sha256(convert_to('non-deliverable-fixture:'||i,'UTF8')),'hex'),clock_timestamp()+interval '1 hour' "
        'FROM generate_series(1,1000) AS s(i)',
      );
      await tx.execute(
        "INSERT INTO public.ventio_identity_grants(tenant_id,actor_id,company_id,branch_id,permission) "
        "SELECT '$benchmarkTenant','fixture-user-'||i,'benchmark-company','benchmark-branch','extension.test.read' "
        'FROM generate_series(1,1000) AS s(i)',
      );
      await tx.execute(
        "INSERT INTO public.ventio_identity_audit(tenant_id,operator_label,action,subject_id,details) "
        "SELECT '$benchmarkTenant','benchmark','HISTORY_FIXTURE','history-'||i,'{}'::jsonb "
        'FROM generate_series(1,20000) AS s(i)',
      );
      await tx.execute(
        pg.Sql.named(
          'INSERT INTO public.ventio_records(tenant_id,company_id,branch_id,module_id,doc_type,record_id,revision,record_data) '
          "SELECT @tenant,@company,@branch,@module,'Item','perf-'||i,1,jsonb_build_object('title','fixture-'||i) "
          'FROM generate_series(1,32) AS s(i)',
        ),
        parameters: {
          'tenant': tenant,
          'company': primaryCompany,
          'branch': primaryBranch,
          'module': package.moduleId,
        },
      );
    });

    final fingerprintSamples = <double>[];
    for (var sample = 0; sample < 5; sample++) {
      final watch = Stopwatch()..start();
      await RecoveryAuthority.snapshot(observer);
      fingerprintSamples.add(watch.elapsedMicroseconds / 1000);
    }
    final fingerprintSorted = [...fingerprintSamples]..sort();
    final fingerprintMedianMs = fingerprintSorted[2];
    final rlsSamples = <double>[];
    final rlsTransactionSamples = <double>[];
    var benchmarkRows = 0;
    for (var sample = 0; sample < 5; sample++) {
      final watch = Stopwatch()..start();
      var queryMs = 0.0;
      benchmarkRows = await runtimeConnection.runTx((tx) async {
        await authority.admit(tx);
        await tx.execute(readBinding, parameters: readBindingParameters);
        final queryWatch = Stopwatch()..start();
        final rows = await tx.execute(
          pg.Sql.named(
            'SELECT record_id FROM public.ventio_records WHERE tenant_id=@tenant '
            'AND company_id=@company AND branch_id=@branch AND module_id=@module '
            "AND doc_type='Item' ORDER BY record_id LIMIT 20",
          ),
          parameters: scopedReadParameters,
        );
        queryWatch.stop();
        queryMs = queryWatch.elapsedMicroseconds / 1000;
        return rows.length;
      });
      rlsSamples.add(queryMs);
      rlsTransactionSamples.add(watch.elapsedMicroseconds / 1000);
    }
    final rlsSorted = [...rlsSamples]..sort();
    final rlsMedianMs = rlsSorted[2];
    final rlsTransactionSorted = [...rlsTransactionSamples]..sort();
    final rlsTransactionMedianMs = rlsTransactionSorted[2];
    final uncachedRlsSamples = <double>[];
    var uncachedRows = 0;
    for (var sample = 0; sample < 5; sample++) {
      uncachedRows = await runtimeConnection.runTx((tx) async {
        await authority.admit(tx);
        await tx.execute(readBinding, parameters: readBindingParameters);
        await tx.execute(
          "SELECT set_config('ventio.extension_identity_snapshot','',true), "
          "set_config('ventio.extension_policy_snapshot','',true), "
          "set_config('ventio.extension_context_proof','',true)",
        );
        final queryWatch = Stopwatch()..start();
        final rows = await tx.execute(
          pg.Sql.named(
            'SELECT record_id FROM public.ventio_records WHERE tenant_id=@tenant '
            'AND company_id=@company AND branch_id=@branch AND module_id=@module '
            "AND doc_type='Item' ORDER BY record_id LIMIT 20",
          ),
          parameters: scopedReadParameters,
        );
        queryWatch.stop();
        uncachedRlsSamples.add(queryWatch.elapsedMicroseconds / 1000);
        return rows.length;
      });
    }
    final uncachedRlsSorted = [...uncachedRlsSamples]..sort();
    final uncachedRlsMedianMs = uncachedRlsSorted[2];
    final hostQuerySamples = <double>[];
    var hostQueryRows = 0;
    for (var sample = 0; sample < 5; sample++) {
      final watch = Stopwatch()..start();
      final response = await queryRecords(primaryToken, limit: 20);
      hostQueryRows =
          ((response.body['recordResult'] as Map<String, dynamic>)['records']
                  as List)
              .length;
      hostQuerySamples.add(watch.elapsedMicroseconds / 1000);
      if (response.status != 200) {
        throw StateError('Scaled Host query failed with ${response.status}');
      }
    }
    final hostQuerySorted = [...hostQuerySamples]..sort();
    final hostQueryMedianMs = hostQuerySorted[2];
    final benchmarkResult = <String, Object?>{
      'fixtureUsers': 1000,
      'fixtureAuditRows': 20000,
      'snapshotMedianMs': fingerprintMedianMs,
      'rlsRows': benchmarkRows,
      'rlsCachedQueryMedianMs': rlsMedianMs,
      'rlsUncachedQueryMedianMs': uncachedRlsMedianMs,
      'rlsTransactionMedianMs': rlsTransactionMedianMs,
      'hostQueryRows': hostQueryRows,
      'hostQueryMedianMs': hostQueryMedianMs,
      'samples': 5,
    };
    stdout.writeln('RECOVERY_BENCHMARK: ${jsonEncode(benchmarkResult)}');
    expect(
      fingerprintMedianMs < 1000,
      'Recovery fingerprint stays below 1 second at 1k users and 20k audit rows',
    );
    expect(
      benchmarkRows == 20 && uncachedRows == 20 && rlsMedianMs < 5000,
      'Signed-cache and live-lookup RLS paths both return 20 authorized rows',
    );
    expect(
      rlsMedianMs < uncachedRlsMedianMs,
      'Transaction-scoped authorization cache is faster than per-row identity lookup',
    );
    expect(
      hostQueryRows == 20 && hostQueryMedianMs < 5000,
      'Authenticated Host query returns 20 rows below 5 seconds at the 1k/20k profile',
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

    ExtensionBundle schemaRelease(String version, {required bool removeField}) {
      final source =
          jsonDecode(jsonEncode(package.toJson())) as Map<String, dynamic>;
      (source['manifest'] as Map<String, dynamic>)['version'] = version;
      final type = (source['docTypes'] as List).single as Map<String, dynamic>;
      type['schemaVersion'] = 2;
      final fields = type['fields'] as List;
      if (removeField) {
        fields.removeWhere(
          (field) => (field as Map<String, dynamic>)['name'] == 'parent',
        );
      } else {
        final slug = package.moduleId.toLowerCase().replaceAll(
          RegExp(r'[^a-z0-9]+'),
          '_',
        );
        final notesKey = 'extension.$slug.item.notes';
        fields.add({
          'name': 'notes',
          'type': 'text',
          'required': false,
          'label': 'Notes',
          'labelKey': notesKey,
          'maxLength': 120,
        });
        (source['englishCatalog'] as Map<String, dynamic>)[notesKey] = 'Notes';
      }
      return ExtensionBundle.fromJson(source);
    }

    final destructiveSchema = schemaRelease('1.0.1', removeField: true);
    expect(
      (await submitPackage(primaryToken, destructiveSchema)).status == 202,
      'A destructive schema release can be submitted for operator review',
    );
    await mustFail(
      () => packageAdmin.approve(
        moduleId: destructiveSchema.moduleId,
        version: destructiveSchema.version,
        packageSha256: hash(destructiveSchema),
      ),
      'Host refuses to approve a release that removes a DocType field',
    );
    expect(
      (await readPackage(
            primaryToken,
            destructiveSchema.moduleId,
            destructiveSchema.version,
          )).status ==
          404,
      'A destructive schema release remains unavailable to clients',
    );

    final additiveSchema = schemaRelease('1.0.2', removeField: false);
    expect(
      (await submitPackage(primaryToken, additiveSchema)).status == 202,
      'A versioned additive schema release can be submitted',
    );
    await packageAdmin.approve(
      moduleId: additiveSchema.moduleId,
      version: additiveSchema.version,
      packageSha256: hash(additiveSchema),
    );
    final releaseReason = await observer.execute(
      pg.Sql.named(
        'SELECT ventio_security.extension_release_reason(@tenant,@module,@version)',
      ),
      parameters: {
        'tenant': tenant,
        'module': package.moduleId,
        'version': package.version,
      },
    );
    expect(
      releaseReason.single[0] == 'UPGRADE_REQUIRED',
      'Release gate returns its superseded-version reason: ${releaseReason.single[0]}',
    );
    expect(
      (await readPackage(
            primaryToken,
            additiveSchema.moduleId,
            additiveSchema.version,
          )).status ==
          200,
      'Host approves an additive optional-field schema release',
    );

    final replayedAfterUpgrade = await send(
      api,
      token: primaryToken,
      body: createRecord.envelope.original,
    );
    expect(
      replayedAfterUpgrade.status == 200 &&
          canonicalJson(replayedAfterUpgrade.body['receipt']) ==
              canonicalJson(created.body['receipt']),
      'An accepted old-release command still returns its saved receipt after upgrade: ${replayedAfterUpgrade.status} ${replayedAfterUpgrade.body}',
    );

    final oldVersionQuery = await queryRecords(
      primaryToken,
      version: package.version,
      recordId: 'registry-item-1',
      limit: 1,
    );
    expect(
      oldVersionQuery.status == 422 &&
          oldVersionQuery.body['recordResult']['reasonCode'] ==
              'UPGRADE_REQUIRED',
      'The Host refuses dynamic reads through an approved but superseded release: ${oldVersionQuery.status} ${oldVersionQuery.body}',
    );
    final oldVersionUpdate = ExtensionRecordCommand.update(
      commandId: '71000000-0000-4000-8000-000000000010',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'registry-item-1',
      expectedRevision: 2,
      actorId: 'publisher',
      deviceId: 'publisher-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'Superseded update'},
    );
    final oldVersionUpdateReply = await send(
      api,
      token: primaryToken,
      body: oldVersionUpdate.envelope.original,
    );
    expect(
      oldVersionUpdateReply.status == 422 &&
          oldVersionUpdateReply.body['receipt']['reasonCode'] ==
              'UPGRADE_REQUIRED',
      'The Host refuses record writes through an approved but superseded release',
    );
    final oldVersionCreate = ExtensionRecordCommand.create(
      commandId: '71000000-0000-4000-8000-000000000012',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'registry-item-old-release-create',
      actorId: 'publisher',
      deviceId: 'publisher-device',
      moduleId: package.moduleId,
      moduleVersion: package.version,
      docType: 'Item',
      schemaVersion: 1,
      values: {'title': 'Superseded create'},
    );
    final oldVersionCreateReply = await send(
      api,
      token: primaryToken,
      body: oldVersionCreate.envelope.original,
    );
    expect(
      oldVersionCreateReply.status == 422 &&
          oldVersionCreateReply.body['receipt']['reasonCode'] ==
              'UPGRADE_REQUIRED',
      'The Host refuses new records created through an approved but superseded release',
    );
    final currentVersionUpdate = ExtensionRecordCommand.update(
      commandId: '73000000-0000-4000-8000-000000000001',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'registry-item-1',
      expectedRevision: 2,
      actorId: 'publisher',
      deviceId: 'publisher-device',
      moduleId: additiveSchema.moduleId,
      moduleVersion: additiveSchema.version,
      docType: 'Item',
      schemaVersion: 2,
      values: {'title': 'Current schema update', 'notes': 'Kept on Host'},
    );
    final currentVersionUpdateReply = await send(
      api,
      token: primaryToken,
      body: currentVersionUpdate.envelope.original,
    );
    expect(
      currentVersionUpdateReply.status == 200 &&
          currentVersionUpdateReply.body['receipt']['status'] == 'ACCEPTED' &&
          currentVersionUpdateReply.body['receipt']['hostRevision'] == 3,
      'The active release can update records with its additive schema',
    );
    final currentVersionQuery = await queryRecords(
      primaryToken,
      version: additiveSchema.version,
      recordId: 'registry-item-1',
      limit: 1,
    );
    expect(
      currentVersionQuery.status == 200 &&
          currentVersionQuery
                  .body['recordResult']['records']
                  .single['values']['notes'] ==
              'Kept on Host',
      'The active release reads and retains fields introduced by its schema',
    );

    ExtensionBundle nextSchemaRelease(
      String version,
      void Function(Map<String, dynamic> source, Map<String, dynamic> type)
      change,
    ) {
      final source =
          jsonDecode(jsonEncode(additiveSchema.toJson()))
              as Map<String, dynamic>;
      (source['manifest'] as Map<String, dynamic>)['version'] = version;
      final type = (source['docTypes'] as List).single as Map<String, dynamic>;
      type['schemaVersion'] = 3;
      change(source, type);
      return ExtensionBundle.fromJson(source);
    }

    final tightenedBounds = nextSchemaRelease('1.0.3', (source, type) {
      final title = (type['fields'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((field) => field['name'] == 'title');
      title['maxLength'] = 40;
    });
    await submitPackage(primaryToken, tightenedBounds);
    await mustFail(
      () => packageAdmin.approve(
        moduleId: tightenedBounds.moduleId,
        version: tightenedBounds.version,
        packageSha256: hash(tightenedBounds),
      ),
      'Host refuses an upgrade that tightens a saved text-field bound',
    );

    final requiredAddition = nextSchemaRelease('1.0.4', (source, type) {
      final slug = package.moduleId.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]+'),
        '_',
      );
      final statusKey = 'extension.$slug.item.status';
      final displayNameKey = 'extension.$slug.item.display_name';
      final fields = (type['fields'] as List).cast<Map<String, dynamic>>();
      final title = fields.singleWhere((field) => field['name'] == 'title');
      final displayName = Map<String, dynamic>.from(title)
        ..['name'] = 'display_name'
        ..['label'] = 'Display name'
        ..['labelKey'] = displayNameKey;
      fields[fields.indexOf(title)] = displayName;
      fields.add({
        'name': 'status',
        'type': 'text',
        'required': true,
        'label': 'Status',
        'labelKey': statusKey,
        'maxLength': 40,
      });
      final ui = type['ui'] as Map<String, dynamic>;
      ui['listColumns'] = ['display_name'];
      ui['formFields'] = ['display_name', 'status'];
      type['migrations'] = [
        {
          'fromVersion': 2,
          'toVersion': 3,
          'steps': [
            {'op': 'renameField', 'from': 'title', 'to': 'display_name'},
            {'op': 'setDefault', 'field': 'status', 'value': 'Unspecified'},
          ],
        },
      ];
      (source['englishCatalog'] as Map<String, dynamic>)[statusKey] = 'Status';
      (source['englishCatalog'] as Map<String, dynamic>)[displayNameKey] =
          'Display name';
    });
    await submitPackage(primaryToken, requiredAddition);
    await packageAdmin.approve(
      moduleId: requiredAddition.moduleId,
      version: requiredAddition.version,
      packageSha256: hash(requiredAddition),
    );
    final migratedRecord = await queryRecords(
      primaryToken,
      version: requiredAddition.version,
      recordId: 'registry-item-1',
      sortField: 'display_name',
      limit: 1,
    );
    expect(
      migratedRecord.status == 200 &&
          migratedRecord
                  .body['recordResult']['records']
                  .single['values']['display_name'] ==
              'Current schema update' &&
          migratedRecord
                  .body['recordResult']['records']
                  .single['values']['status'] ==
              'Unspecified' &&
          !migratedRecord.body['recordResult']['records'].single['values']
              .containsKey('title'),
      'Host atomically renames saved fields and fills a new required field: ${migratedRecord.status} ${migratedRecord.body}',
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
    await packageAdmin.revoke(
      moduleId: requiredAddition.moduleId,
      version: requiredAddition.version,
      packageSha256: hash(requiredAddition),
      reason: 'Integration test revocation of the active release.',
    );
    final oldVersionAfterRevocation = await queryRecords(
      primaryToken,
      version: package.version,
      recordId: 'registry-item-1',
      limit: 1,
    );
    expect(
      oldVersionAfterRevocation.status == 422 &&
          oldVersionAfterRevocation.body['recordResult']['reasonCode'] ==
              'EXTENSION_REVOKED',
      'Revoking the newest release does not silently reactivate an older version',
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
    final compatibilityGuardPrivileges = await observer.execute('''
      SELECT has_function_privilege('ventio_identity_admin',
        'public.ventio_validate_extension_schema_upgrade(text,text,text)', 'EXECUTE'),
        has_function_privilege('ventio_runtime',
        'public.ventio_validate_extension_schema_upgrade(text,text,text)', 'EXECUTE')
    ''');
    expect(
      compatibilityGuardPrivileges.single[0] == true &&
          compatibilityGuardPrivileges.single[1] == false,
      'Only the restricted operator login can execute the schema compatibility guard',
    );
    expect(
      (await observer.execute(
            pg.Sql.named(
              "SELECT count(*) FROM public.ventio_extension_package_events WHERE tenant_id=@tenant AND event_type IN ('APPROVED','REVOKED')",
            ),
            parameters: {'tenant': tenant},
          )).single[0] ==
          9,
      'Approval and revocation events remain in the operator audit ledger',
    );
    final fieldPackage = bundle(
      'com.example.field_policy',
      '1.0.0',
      protectTitle: true,
      title: 'Protected item',
    );
    expect(
      (await submitPackage(primaryToken, fieldPackage)).status == 202,
      'A field-protected package can be submitted with the enforcing platform API version',
    );
    await packageAdmin.approve(
      moduleId: fieldPackage.moduleId,
      version: fieldPackage.version,
      packageSha256: hash(fieldPackage),
    );
    final protectedCreate = ExtensionRecordCommand.create(
      commandId: '73000000-0000-4000-8000-000000000003',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'field-policy-item-1',
      actorId: 'field-writer',
      deviceId: 'field-writer-device',
      moduleId: fieldPackage.moduleId,
      moduleVersion: fieldPackage.version,
      docType: 'Item',
      schemaVersion: 1,
      values: const {'title': 'CONFIDENTIAL FIELD SENTINEL'},
    );
    final protectedCreateReply = await send(
      api,
      token: fieldWriterToken,
      body: protectedCreate.envelope.original,
    );
    expect(
      protectedCreateReply.status == 200 &&
          protectedCreateReply.body['receipt']['status'] == 'ACCEPTED',
      'A role with the field grant can create the protected value',
    );
    final blindQuery = await queryRecords(
      fieldBlindToken,
      moduleId: fieldPackage.moduleId,
      search: 'CONFIDENTIAL FIELD SENTINEL',
      sortField: null,
    );
    final blindResult = blindQuery.body['recordResult'] as Map<String, dynamic>;
    expect(
      blindQuery.status == 200 &&
          !(blindResult['readableFields'] as List).contains('title') &&
          (blindResult['records'] as List).isEmpty,
      'Host field masks and search prevent an ungranted user from reading a protected value',
    );
    final redactedFieldQuery = await queryRecords(
      fieldBlindToken,
      moduleId: fieldPackage.moduleId,
      recordId: 'field-policy-item-1',
      sortField: null,
      limit: 1,
    );
    final redactedFieldRecord =
        (redactedFieldQuery.body['recordResult']['records'] as List).single
            as Map<String, dynamic>;
    expect(
      redactedFieldQuery.status == 200 &&
          !(redactedFieldRecord['values'] as Map).containsKey('title'),
      'Host omits protected values from direct record reads',
    );
    final unauthorizedCreate = ExtensionRecordCommand.create(
      commandId: '71000000-0000-4000-8000-000000000011',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'field-policy-unwritable-create',
      actorId: 'field-no-write-creator',
      deviceId: 'field-no-write-creator-device',
      moduleId: fieldPackage.moduleId,
      moduleVersion: fieldPackage.version,
      docType: 'Item',
      schemaVersion: 1,
      values: const {'title': 'UNAUTHORIZED CREATE'},
    );
    final unauthorizedCreateReply = await send(
      api,
      token: fieldNoWriteCreatorToken,
      body: unauthorizedCreate.envelope.original,
    );
    final unauthorizedCreateReadback = await queryRecords(
      fieldReaderToken,
      moduleId: fieldPackage.moduleId,
      recordId: 'field-policy-unwritable-create',
      sortField: null,
      limit: 1,
    );
    expect(
      unauthorizedCreateReply.status == 403 &&
          unauthorizedCreateReply.body['receipt']['status'] == 'REJECTED' &&
          unauthorizedCreateReply.body['receipt']['reasonCode'] ==
              'PERMISSION_DENIED' &&
          (unauthorizedCreateReadback.body['recordResult']['records'] as List)
              .isEmpty,
      'Host rejects an ungranted protected-field create without storing a row '
      '(reply ${unauthorizedCreateReply.status}: '
      '${unauthorizedCreateReply.body}; readback '
      '${unauthorizedCreateReadback.status}: '
      '${unauthorizedCreateReadback.body})',
    );
    final blindFieldFilter = await queryRecords(
      fieldBlindToken,
      moduleId: fieldPackage.moduleId,
      filterField: 'title',
      filterContains: 'CONFIDENTIAL',
      sortField: null,
    );
    expect(
      blindFieldFilter.status == 403 &&
          blindFieldFilter.body['recordResult']['reasonCode'] ==
              'PERMISSION_DENIED',
      'Host rejects filters on fields the principal cannot read',
    );
    final blindFieldSort = await queryRecords(
      fieldBlindToken,
      moduleId: fieldPackage.moduleId,
      sortField: 'title',
    );
    expect(
      blindFieldSort.status == 403 &&
          blindFieldSort.body['recordResult']['reasonCode'] ==
              'PERMISSION_DENIED',
      'Host rejects sorting on fields the principal cannot read',
    );
    final fieldReadOnly = await queryRecords(
      fieldReaderToken,
      moduleId: fieldPackage.moduleId,
      recordId: 'field-policy-item-1',
      sortField: null,
      limit: 1,
    );
    final readOnlyResult =
        fieldReadOnly.body['recordResult'] as Map<String, dynamic>;
    expect(
      fieldReadOnly.status == 200 &&
          (readOnlyResult['records'] as List).single['values']['title'] ==
              'CONFIDENTIAL FIELD SENTINEL' &&
          !(readOnlyResult['writableFields'] as List).contains('title'),
      'Host independently reports read-only field access to a field reader',
    );
    final forbiddenFieldUpdate = ExtensionRecordCommand.update(
      commandId: '73000000-0000-4000-8000-000000000004',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'field-policy-item-1',
      expectedRevision: 1,
      actorId: 'restricted-editor',
      deviceId: 'restricted-editor-device',
      moduleId: fieldPackage.moduleId,
      moduleVersion: fieldPackage.version,
      docType: 'Item',
      schemaVersion: 1,
      values: const {'title': 'UNAUTHORIZED CHANGE'},
    );
    final forbiddenReply = await send(
      api,
      token: restrictedEditorToken,
      body: forbiddenFieldUpdate.envelope.original,
    );
    final unchangedProtectedValue = await queryRecords(
      fieldReaderToken,
      moduleId: fieldPackage.moduleId,
      recordId: 'field-policy-item-1',
      sortField: null,
      limit: 1,
    );
    expect(
      forbiddenReply.status == 403 &&
          forbiddenReply.body['receipt']['status'] == 'REJECTED' &&
          forbiddenReply.body['receipt']['reasonCode'] == 'PERMISSION_DENIED' &&
          (unchangedProtectedValue.body['recordResult']['records'] as List)
                  .single['values']['title'] ==
              'CONFIDENTIAL FIELD SENTINEL',
      'Host rejects a forged write without the field grant and preserves the value '
      '(reply ${forbiddenReply.status}: ${forbiddenReply.body}; '
      'readback ${unchangedProtectedValue.body})',
    );
    final publicFieldUpdate = ExtensionRecordCommand.update(
      commandId: '73000000-0000-4000-8000-000000000005',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'field-policy-item-1',
      expectedRevision: 1,
      actorId: 'restricted-editor',
      deviceId: 'restricted-editor-device',
      moduleId: fieldPackage.moduleId,
      moduleVersion: fieldPackage.version,
      docType: 'Item',
      schemaVersion: 1,
      values: const {'parent': 'field-policy-item-1'},
    );
    final publicFieldUpdateReply = await send(
      api,
      token: restrictedEditorToken,
      body: publicFieldUpdate.envelope.original,
    );
    final preservedProtectedValue = await queryRecords(
      fieldReaderToken,
      moduleId: fieldPackage.moduleId,
      recordId: 'field-policy-item-1',
      sortField: null,
      limit: 1,
    );
    expect(
      publicFieldUpdateReply.status == 200 &&
          publicFieldUpdateReply.body['receipt']['status'] == 'ACCEPTED' &&
          (preservedProtectedValue.body['recordResult']['records'] as List)
                  .single['values']['title'] ==
              'CONFIDENTIAL FIELD SENTINEL' &&
          (preservedProtectedValue.body['recordResult']['records'] as List)
                  .single['values']['parent'] ==
              'field-policy-item-1',
      'A permitted partial update preserves protected fields absent from its patch',
    );
    final authorizedFieldUpdate = ExtensionRecordCommand.update(
      commandId: '73000000-0000-4000-8000-000000000006',
      tenantId: tenant,
      companyId: primaryCompany,
      branchId: primaryBranch,
      recordId: 'field-policy-item-1',
      expectedRevision: 2,
      actorId: 'field-writer',
      deviceId: 'field-writer-device',
      moduleId: fieldPackage.moduleId,
      moduleVersion: fieldPackage.version,
      docType: 'Item',
      schemaVersion: 1,
      values: const {'title': 'AUTHORIZED CHANGE'},
    );
    final authorizedUpdateReply = await send(
      api,
      token: fieldWriterToken,
      body: authorizedFieldUpdate.envelope.original,
    );
    expect(
      authorizedUpdateReply.status == 200 &&
          authorizedUpdateReply.body['receipt']['status'] == 'ACCEPTED',
      'Host accepts the same field update from a principal with the field grant',
    );
    await observer.execute(
      pg.Sql.named(
        'UPDATE public.ventio_identity_role_permissions '
        'SET permission=@nextPermission '
        'WHERE tenant_id=@tenant AND role_id=@role AND permission=@permission',
      ),
      parameters: {
        'nextPermission': 'extension.package.submit',
        'tenant': tenant,
        'role': 'recovery-witness-role',
        'permission': 'extension.package.read',
      },
    );
    var staleWitnessDenied = false;
    try {
      await runtimeConnection.runTx(authority.admit);
    } on pg.ServerException {
      staleWitnessDenied = true;
    }
    expect(
      staleWitnessDenied,
      'A privileged out-of-band role permission edit invalidates recovery admission',
    );
    final generationBeforeRollbackAttempt =
        (await observer.execute(
              'SELECT generation FROM ventio_security.recovery_state WHERE singleton',
            )).single[0]
            as int;
    await observer.execute(
      'UPDATE ventio_security.recovery_state SET generation=0 WHERE singleton',
    );
    final generationAfterRollbackAttempt =
        (await observer.execute(
              'SELECT generation FROM ventio_security.recovery_state WHERE singleton',
            )).single[0]
            as int;
    expect(
      generationAfterRollbackAttempt == generationBeforeRollbackAttempt + 1,
      'A direct recovery-state update cannot roll its generation backward',
    );
    var recoveryTruncateDenied = false;
    try {
      await observer.execute('TRUNCATE ventio_security.recovery_state');
    } on pg.ServerException {
      recoveryTruncateDenied = true;
    }
    expect(
      recoveryTruncateDenied,
      'The recovery authority state cannot be truncated',
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
