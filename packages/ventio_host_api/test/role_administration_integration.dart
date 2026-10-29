import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart';

class _RoleTestExecutor implements AuthoritativeCommandExecutor {
  @override
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session,
  ) async =>
      CommandReceipt(commandId: command.commandId, status: 'ACCEPTED').toJson();
}

Future<void> main() async {
  final auditUrl = Platform.environment['VENTIO_TEST_DATABASE_URL'];
  final runtimeUrl = Platform.environment['VENTIO_TEST_RUNTIME_DATABASE_URL'];
  final adminUrl = Platform.environment['VENTIO_TEST_ADMIN_DATABASE_URL'];
  final apiAdminUrl =
      Platform.environment['VENTIO_TEST_API_ADMIN_DATABASE_URL'];
  if (auditUrl == null ||
      runtimeUrl == null ||
      adminUrl == null ||
      apiAdminUrl == null ||
      Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
      Uri.parse(
            runtimeUrl,
          ).pathSegments.where((part) => part.isNotEmpty).lastOrNull !=
          'ventio_host_test') {
    stderr.writeln(
      'Role administration integration requires the disposable ventio_host_test database and explicit test opt-in.',
    );
    exitCode = 2;
    return;
  }

  var assertions = 0;
  void check(bool condition, String label) {
    if (!condition) throw StateError('FAIL: $label');
    assertions++;
    stdout.writeln('PASS: $label');
  }

  final adminConnection = await pg.Connection.openFromUrl(adminUrl);
  final auditConnection = await pg.Connection.openFromUrl(auditUrl);
  final temporary = await createPrivateTestDirectory('ventio-role-api-');
  final authority = RecoveryAuthority('${temporary.path}/authority.json');
  final tenant = 'role-api-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  const companyA = 'company-a';
  const branchA = 'branch-a';
  const companyB = 'company-b';
  const branchB = 'branch-b';
  HostApi? api;
  try {
    await authority.resetForReenrollment(
      adminConnection,
      'role-api-test-reset',
    );
    final operator = IdentityAdministration(
      connection: adminConnection,
      tenantId: tenant,
      operatorLabel: 'role-api-test-operator',
      authority: authority,
    );
    await operator.registerBranch(companyA, branchA);
    await operator.registerBranch(companyB, branchB);

    Future<String> provision({
      required String actorId,
      required String deviceId,
      required String credentialId,
      required List<Map<String, Object?>> scopes,
      required List<(String, String, String)> directGrants,
    }) async {
      await operator.createUser(actorId);
      await operator.registerDevice(actorId, deviceId);
      for (final (company, branch, permission) in directGrants) {
        await operator.grant(actorId, company, branch, permission);
      }
      final path = '${temporary.path}/$credentialId.json';
      await operator.provisionToFile(
        actorId: actorId,
        deviceId: deviceId,
        credentialId: credentialId,
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        allowedScopes: scopes,
        outputPath: path,
      );
      return (jsonDecode(await PrivateFiles.read(path)) as Map)['token']
          as String;
    }

    final directManagerToken = await provision(
      actorId: 'manager-a',
      deviceId: 'manager-a-device',
      credentialId: 'manager-a-credential',
      scopes: [
        {
          'companyId': companyA,
          'branchId': branchA,
          'permissions': ['identity.roles.manage'],
        },
      ],
      directGrants: [(companyA, branchA, 'identity.roles.manage')],
    );
    final allBranchManagerToken = await provision(
      actorId: 'manager-all',
      deviceId: 'manager-all-device',
      credentialId: 'manager-all-credential',
      scopes: [
        {
          'companyId': companyA,
          'branchId': branchA,
          'permissions': ['identity.roles.manage'],
        },
        {
          'companyId': companyB,
          'branchId': branchB,
          'permissions': ['identity.roles.manage'],
        },
      ],
      directGrants: [
        (companyA, branchA, 'identity.roles.manage'),
        (companyB, branchB, 'identity.roles.manage'),
      ],
    );
    final readerToken = await provision(
      actorId: 'branch-reader',
      deviceId: 'branch-reader-device',
      credentialId: 'branch-reader-credential',
      scopes: [
        {
          'companyId': companyA,
          'branchId': branchA,
          'permissions': ['extension.example.item.read'],
        },
      ],
      directGrants: [(companyA, branchA, 'extension.example.item.read')],
    );
    final statusReaderToken = await provision(
      actorId: 'status-reader',
      deviceId: 'status-reader-device',
      credentialId: 'status-reader-credential',
      scopes: [
        {
          'companyId': companyA,
          'branchId': branchA,
          'permissions': [hostStatusReadPermission],
        },
      ],
      directGrants: [(companyA, branchA, hostStatusReadPermission)],
    );

    Future<pg.Connection> connectRuntime() =>
        pg.Connection.openFromUrl(runtimeUrl);
    Future<pg.Connection> connectAdministration() =>
        pg.Connection.openFromUrl(apiAdminUrl);
    final runtimeProbe = await connectRuntime();
    try {
      await verifyRuntimeConnection(runtimeProbe);
    } finally {
      await runtimeProbe.close();
    }
    final adminProbe = await connectAdministration();
    try {
      await verifyIdentityAdministrationConnection(adminProbe);
    } finally {
      await adminProbe.close();
    }
    var trustedLocalProfileRejected = false;
    try {
      await verifyIdentityAdministrationConnection(adminConnection);
    } on StateError {
      trustedLocalProfileRejected = true;
    }
    check(
      trustedLocalProfileRejected,
      'The broad trusted local operator profile is rejected by the persistent API verifier',
    );
    api = await HostApi.bind(
      authenticator: PersistentTokenAuthenticator(
        connect: connectRuntime,
        admission: authority,
      ),
      executor: _RoleTestExecutor(),
      identityRoleAdministration: PostgresIdentityRoleAdministrationGateway(
        connectRuntime: connectRuntime,
        connectAdministration: connectAdministration,
        admission: authority,
      ),
      readinessProvider: PostgresHostReadinessProvider(
        connect: connectRuntime,
        recoveryAuthority: authority,
      ),
    );

    Future<Reply> roles(
      String token,
      String action, {
      String company = companyA,
      String branch = branchA,
      Map<String, Object?> fields = const {},
    }) => send(
      api!,
      token: token,
      path: '/api/v1/identity/roles/$action',
      body: {'companyId': company, 'branchId': branch, ...fields},
    );

    final session = await send(
      api,
      path: '/api/v1/session',
      method: 'GET',
      token: directManagerToken,
    );
    final identity = session.body['identity'] as Map<String, dynamic>;
    check(
      session.status == 200 &&
          identity['roleAdministrationAvailable'] == true &&
          (identity['scopes'] as List).any(
            (scope) =>
                scope['companyId'] == companyA &&
                scope['branchId'] == branchA &&
                (scope['permissions'] as List).contains(
                  'identity.roles.manage',
                ),
          ),
      'Session discovery advertises role administration and its exact granted branch',
    );
    final noAccess = await roles(readerToken, 'list', fields: const {});
    check(
      noAccess.status == 403 &&
          noAccess.body['error']['code'] == 'PERMISSION_DENIED',
      'A data reader without a direct management grant cannot list roles',
    );
    Future<Reply> readiness(
      String token, {
      String company = companyA,
      String branch = branchA,
    }) => send(
      api!,
      token: token,
      path: HostManagementRoutes.readiness,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
      },
    );
    final deniedReadiness = await readiness(readerToken);
    check(
      deniedReadiness.status == 403 &&
          deniedReadiness.body['error']['code'] == 'PERMISSION_DENIED',
      'A general data reader cannot inspect Host readiness',
    );
    final crossBranchReadiness = await readiness(
      statusReaderToken,
      branch: branchB,
    );
    check(
      crossBranchReadiness.status == 403,
      'Readiness checks cannot cross the credential exact-scope boundary',
    );
    final ready = await readiness(statusReaderToken);
    final readySnapshot = HostReadinessSnapshot.fromJson(
      ready.body['readiness'],
    );
    check(
      ready.status == 200 &&
          readySnapshot.overallState == ManagementHealthState.ready &&
          ready.body['correlationId'] ==
              ready.headers.value('X-Correlation-ID'),
      'Persistent scoped identity receives actual PostgreSQL and recovery readiness',
    );
    final crossBranch = await roles(
      directManagerToken,
      'list',
      company: companyA,
      branch: branchB,
    );
    check(
      crossBranch.status == 403,
      'A branch manager cannot enumerate roles through a company/branch cross-product',
    );
    final listed = await roles(directManagerToken, 'list');
    check(
      listed.status == 200 &&
          (listed.body['identityRoles'] as Map)['roles'] is List,
      'A direct manager can read roles for the explicitly granted branch',
    );

    final created = await roles(
      directManagerToken,
      'create',
      fields: const {'roleId': 'branch-editor', 'displayName': 'Branch editor'},
    );
    check(
      created.status == 200,
      'Direct branch manager creates a Host role '
      '(${created.status}: ${jsonEncode(created.body)})',
    );
    final granted = await roles(
      directManagerToken,
      'grant-permission',
      fields: const {
        'roleId': 'branch-editor',
        'permission': 'extension.example.item.read',
      },
    );
    check(
      granted.status == 200,
      'Manager adds an extension permission to a role',
    );
    final escalated = await roles(
      directManagerToken,
      'grant-permission',
      fields: const {
        'roleId': 'branch-editor',
        'permission': 'identity.roles.manage',
      },
    );
    check(
      escalated.status == 403,
      'Role managers cannot delegate their own reserved management capability',
    );

    await operator.createUser('reader-a');
    await operator.createUser('reader-b');
    final assignmentA = await roles(
      directManagerToken,
      'assign',
      fields: const {'roleId': 'branch-editor', 'actorId': 'reader-a'},
    );
    check(
      assignmentA.status == 200,
      'Manager assigns a role in the exact branch',
    );
    await operator.assignRole(
      actorId: 'reader-b',
      roleId: 'branch-editor',
      companyId: companyB,
      branchId: branchB,
    );
    final sharedRoleChange = await roles(
      directManagerToken,
      'grant-permission',
      fields: const {
        'roleId': 'branch-editor',
        'permission': 'extension.example.item.update',
      },
    );
    check(
      sharedRoleChange.status == 403,
      'A shared role cannot change permissions outside the manager exact scopes',
    );
    final branchSnapshot = await roles(directManagerToken, 'list');
    final snapshot =
        branchSnapshot.body['identityRoles'] as Map<String, dynamic>;
    final role = (snapshot['roles'] as List).cast<Map>().single;
    final assignedInBranch = role['assignedActorIds'] as List;
    check(
      branchSnapshot.status == 200 &&
          (role['permissions'] as List).length == 1 &&
          assignedInBranch.length == 1 &&
          assignedInBranch.single == 'reader-a',
      'Rejected shared-role mutation leaves permission and other-branch assignments isolated',
    );

    final allBranches = await roles(
      allBranchManagerToken,
      'grant-permission',
      fields: const {
        'roleId': 'branch-editor',
        'permission': 'extension.example.item.update',
      },
    );
    check(
      allBranches.status == 200,
      'A manager with explicit grants in every affected branch may change a shared role',
    );
    await operator.registerDevice('reader-a', 'reader-a-device');
    final readerAPath = '${temporary.path}/reader-a.json';
    await operator.provisionToFile(
      actorId: 'reader-a',
      deviceId: 'reader-a-device',
      credentialId: 'reader-a-credential',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': companyA,
          'branchId': branchA,
          'permissions': [
            'extension.example.item.read',
            'extension.example.item.update',
          ],
        },
      ],
      outputPath: readerAPath,
    );
    final readerAToken =
        (jsonDecode(await PrivateFiles.read(readerAPath)) as Map)['token']
            as String;
    final readerSession = await send(
      api,
      path: '/api/v1/session',
      method: 'GET',
      token: readerAToken,
    );
    final readerIdentity =
        readerSession.body['identity'] as Map<String, dynamic>;
    check(
      (readerIdentity['scopes'] as List).any(
        (scope) =>
            scope['companyId'] == companyA &&
            scope['branchId'] == branchA &&
            (scope['permissions'] as List).cast<String>().toSet().containsAll([
              'extension.example.item.read',
              'extension.example.item.update',
            ]),
      ),
      'The role grants permissions to its assigned user only in the assigned branch',
    );
    final foreignUserUpdate = await roles(
      readerToken,
      'assign',
      fields: const {'roleId': 'branch-editor', 'actorId': 'other-user'},
    );
    check(
      foreignUserUpdate.status == 403,
      'A role assignee cannot manage other identity roles',
    );

    final crossScopeRoleChange = await roles(
      allBranchManagerToken,
      'rename',
      company: companyB,
      branch: branchB,
      fields: const {
        'roleId': 'branch-editor',
        'displayName': 'Cross scope editor',
      },
    );
    check(
      crossScopeRoleChange.status == 200,
      'Role metadata remains manageable from an explicitly granted branch',
    );

    await operator.revokeGrant(
      'manager-a',
      companyA,
      branchA,
      'identity.roles.manage',
    );
    final revokedManager = await roles(directManagerToken, 'list');
    check(
      revokedManager.status == 403,
      'Revoking the direct management grant takes effect on the next request',
    );
    final roleAudit = await auditConnection.execute(
      pg.Sql.named('''
        SELECT action, subject_id, details::text, database_actor
        FROM ventio_identity_audit
        WHERE tenant_id = @tenant AND action LIKE 'ROLE_%'
      '''),
      parameters: {'tenant': tenant},
    );
    final roleActions = roleAudit.map((row) => row[0] as String).toSet();
    final assignmentWasAudited = roleAudit.any((row) {
      final details = jsonDecode(row[2] as String) as Map<String, dynamic>;
      return row[0] == 'ROLE_ASSIGNED' &&
          row[1] == 'reader-a' &&
          details['roleId'] == 'branch-editor' &&
          details['companyId'] == companyA &&
          details['branchId'] == branchA;
    });
    check(
      roleActions.containsAll({
            'ROLE_CREATED',
            'ROLE_RENAMED',
            'ROLE_PERMISSION_GRANTED',
            'ROLE_ASSIGNED',
          }) &&
          assignmentWasAudited &&
          roleAudit.every((row) => (row[3] as String).isNotEmpty),
      'Role changes are durably audited with exact assignment scope and database actor',
    );
    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    await api?.close();
    await auditConnection.close();
    await adminConnection.close();
    await temporary.delete(recursive: true);
  }
}
