import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart';

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
      'User administration integration requires the disposable ventio_host_test database and explicit test opt-in.',
    );
    exitCode = 2;
    return;
  }

  final adminConnection = await pg.Connection.openFromUrl(adminUrl);
  final bootstrapConnection = await pg.Connection.openFromUrl(apiAdminUrl);
  final auditConnection = await pg.Connection.openFromUrl(auditUrl);
  final temporary = await createPrivateTestDirectory('ventio-user-api-');
  final authority = RecoveryAuthority('${temporary.path}/authority.json');
  final tenant = 'user-api-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  const companyA = 'company-a';
  const branchA = 'branch-a';
  const companyB = 'company-b';
  const branchB = 'branch-b';
  var assertions = 0;
  void check(bool condition, String label) {
    if (!condition) throw StateError('FAIL: $label');
    assertions++;
    stdout.writeln('PASS: $label');
  }

  try {
    await authority.resetForReenrollment(
      adminConnection,
      'user-management-test-reset',
    );
    final operator = IdentityAdministration(
      connection: adminConnection,
      tenantId: tenant,
      operatorLabel: 'user-management-test-operator',
      authority: authority,
      bootstrapConnection: bootstrapConnection,
    );
    final operatorWithoutAuthority = IdentityAdministration(
      connection: adminConnection,
      tenantId: '$tenant-no-authority',
      operatorLabel: 'user-management-test-operator',
    );
    var missingAuthorityDenied = false;
    try {
      await operatorWithoutAuthority.bootstrapFirstAdministrator(
        companyId: companyA,
        branchId: branchA,
        deviceId: 'missing-authority-device',
        credentialId: 'missing-authority-credential',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      );
    } on StateError {
      missingAuthorityDenied = true;
    }
    check(
      missingAuthorityDenied,
      'Initial administrator bootstrap refuses to run without Recovery Authority',
    );
    var directApiBootstrapDenied = false;
    try {
      await bootstrapConnection.execute(
        "SELECT ventio_security.bootstrap_first_admin('{}'::jsonb)",
      );
    } on pg.ServerException catch (error) {
      directApiBootstrapDenied = error.code == '28000';
    }
    check(
      directApiBootstrapDenied,
      'Identity API login cannot bootstrap an administrator without Recovery Authority proof',
    );
    final initialBootstrapRequestId = OpaqueToken.generate();
    final initialAdminCredential = InitialHostAdministratorCredential(
      actorId: 'usr_${OpaqueToken.generate()}',
      token: OpaqueToken.generate(),
    );
    final initialAdminExpiresAt = DateTime.now().toUtc().add(
      const Duration(days: 1),
    );
    final initialAdmin = await operator.bootstrapFirstAdministrator(
      companyId: 'initial-host-company',
      branchId: 'initial-host-branch',
      deviceId: 'initial-host-device',
      credentialId: 'initial-host-credential',
      expiresAt: initialAdminExpiresAt,
      requestId: initialBootstrapRequestId,
      credential: initialAdminCredential,
    );
    final initialAdminRows = await auditConnection.execute(
      pg.Sql.named('''
        SELECT c.token_digest,c.allowed_scopes::text,
          (SELECT array_agg(g.permission ORDER BY g.permission)::text
           FROM ventio_identity_grants g
           WHERE g.tenant_id=c.tenant_id AND g.actor_id=c.actor_id
             AND g.company_id='initial-host-company'
             AND g.branch_id='initial-host-branch')
        FROM ventio_identity_credentials c
        WHERE c.tenant_id=@tenant AND c.actor_id=@actor
          AND c.device_id='initial-host-device'
      '''),
      parameters: {'tenant': tenant, 'actor': initialAdmin.actorId},
    );
    final initialAdminScopes =
        jsonDecode(initialAdminRows.single[1] as String) as List;
    check(
      initialAdmin.actorId.startsWith('usr_') &&
          OpaqueToken.isValid(initialAdmin.token) &&
          initialAdminRows.single[0] ==
              OpaqueToken.digest(initialAdmin.token) &&
          (initialAdminRows.single[2] as String).contains(
            'identity.users.manage',
          ) &&
          initialAdminScopes.length == 1 &&
          (initialAdminScopes.single as Map)['companyId'] ==
              'initial-host-company' &&
          ((initialAdminScopes.single as Map)['permissions'] as List).length ==
              initialHostAdministratorPermissions.length,
      'First Host administrator is created atomically with direct management grants and a digest-only scoped device credential',
    );
    final initialAdminAudit = await auditConnection.execute(
      pg.Sql.named('''
        SELECT action,details::text FROM ventio_identity_audit
        WHERE tenant_id=@tenant AND action='INITIAL_ADMIN_BOOTSTRAPPED'
          AND subject_id=@actor
      '''),
      parameters: {'tenant': tenant, 'actor': initialAdmin.actorId},
    );
    check(
      initialAdminAudit.length == 1 &&
          !initialAdminAudit.single[1].toString().contains(
            initialAdmin.token,
          ) &&
          !initialAdminAudit.single[1].toString().contains(
            OpaqueToken.digest(initialAdmin.token),
          ),
      'Initial administrator audit event omits the plaintext token and its digest',
    );
    var repeatedBootstrapDenied = false;
    try {
      await operator.bootstrapFirstAdministrator(
        companyId: 'initial-host-company',
        branchId: 'initial-host-branch',
        deviceId: 'second-host-device',
        credentialId: 'second-host-credential',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      );
    } catch (_) {
      repeatedBootstrapDenied = true;
    }
    check(
      repeatedBootstrapDenied,
      'A different first-administrator request cannot create a second credential for the initial tenant',
    );
    final replayedInitialAdmin = await operator.bootstrapFirstAdministrator(
      companyId: 'initial-host-company',
      branchId: 'initial-host-branch',
      deviceId: 'initial-host-device',
      credentialId: 'initial-host-credential',
      expiresAt: initialAdminExpiresAt,
      requestId: initialBootstrapRequestId,
      credential: initialAdminCredential,
    );
    check(
      replayedInitialAdmin.actorId == initialAdmin.actorId &&
          replayedInitialAdmin.token == initialAdmin.token,
      'The exact first-administrator request can be retried without creating another credential',
    );
    final otherTenantOperator = IdentityAdministration(
      connection: adminConnection,
      tenantId: '$tenant-other',
      operatorLabel: 'user-management-test-operator',
      authority: authority,
      bootstrapConnection: bootstrapConnection,
    );
    var otherTenantBootstrapDenied = false;
    try {
      await otherTenantOperator.bootstrapFirstAdministrator(
        companyId: companyA,
        branchId: branchA,
        deviceId: 'other-tenant-first-device',
        credentialId: 'other-tenant-first-credential',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      );
    } catch (_) {
      otherTenantBootstrapDenied = true;
    }
    check(
      otherTenantBootstrapDenied,
      'A second tenant cannot invoke the one-time first-Host-administrator bootstrap',
    );
    await operator.registerBranch(companyA, branchA);
    await operator.registerBranch(companyB, branchB);

    Future<String> provision({
      required String actorId,
      required String deviceId,
      required String credentialId,
      required List<(String, String, String)> directGrants,
      required List<Map<String, Object?>> scopes,
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

    final managerToken = await provision(
      actorId: 'user-manager-a',
      deviceId: 'client-device-a',
      credentialId: 'user-manager-a-credential',
      directGrants: [(companyA, branchA, identityUsersManagePermission)],
      scopes: [
        {
          'companyId': companyA,
          'branchId': branchA,
          'permissions': [identityUsersManagePermission],
        },
      ],
    );
    final readerToken = await provision(
      actorId: 'ordinary-reader',
      deviceId: 'ordinary-reader-device',
      credentialId: 'ordinary-reader-credential',
      directGrants: [(companyA, branchA, 'maintenance.read')],
      scopes: [
        {
          'companyId': companyA,
          'branchId': branchA,
          'permissions': ['maintenance.read'],
        },
      ],
    );
    final roleManagerToken = await provision(
      actorId: 'identity-role-manager',
      deviceId: 'identity-role-manager-device',
      credentialId: 'identity-role-manager-credential',
      directGrants: [(companyA, branchA, 'identity.roles.manage')],
      scopes: [
        {
          'companyId': companyA,
          'branchId': branchA,
          'permissions': ['identity.roles.manage'],
        },
      ],
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
    final administrationProbe = await connectAdministration();
    try {
      await verifyScopedUserAdministrationConnection(administrationProbe);
    } finally {
      await administrationProbe.close();
    }
    var trustedLocalProfileRejected = false;
    try {
      await verifyScopedUserAdministrationConnection(adminConnection);
    } on StateError {
      trustedLocalProfileRejected = true;
    }
    check(
      trustedLocalProfileRejected,
      'The broad trusted local operator profile is rejected by the persistent API verifier',
    );

    final authenticator = PersistentTokenAuthenticator(
      connect: connectRuntime,
      admission: authority,
    );
    final gateway = PostgresIdentityUserAdministrationGateway(
      connectRuntime: connectRuntime,
      connectAdministration: connectAdministration,
      admission: authority,
    );
    final roleGateway = PostgresIdentityRoleAdministrationGateway(
      connectRuntime: connectRuntime,
      connectAdministration: connectAdministration,
      admission: authority,
    );
    Future<AuthenticatedSession> authenticate(String token) async {
      final session = await authenticator.authenticate(token);
      if (session == null) throw StateError('Test credential was not accepted');
      return session;
    }

    final manager = await authenticate(managerToken);
    final before = await gateway.list(
      session: manager,
      companyId: companyA,
      branchId: branchA,
    );
    check(
      before['tenantId'] == tenant &&
          before['companyId'] == companyA &&
          before['branchId'] == branchA &&
          before['items'] is List,
      'Directly authorized user manager receives the exact scoped inventory',
    );

    final ordinaryReader = await authenticate(readerToken);
    var ordinaryDenied = false;
    try {
      await gateway.list(
        session: ordinaryReader,
        companyId: companyA,
        branchId: branchA,
      );
    } on IdentityUserAdministrationException catch (error) {
      ordinaryDenied = error.statusCode == 403;
    }
    check(
      ordinaryDenied,
      'Ordinary data readers cannot inspect user inventory',
    );

    await operator.registerDevice('user-manager-a', 'limited-manager-device');
    await operator.grant(
      'user-manager-a',
      companyA,
      branchA,
      'maintenance.read',
    );
    final limitedManagerPath = '${temporary.path}/limited-manager.json';
    await operator.provisionToFile(
      actorId: 'user-manager-a',
      deviceId: 'limited-manager-device',
      credentialId: 'limited-manager-credential',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': companyA,
          'branchId': branchA,
          'permissions': ['maintenance.read'],
        },
      ],
      outputPath: limitedManagerPath,
    );
    final limitedManagerToken =
        (jsonDecode(await PrivateFiles.read(limitedManagerPath))
                as Map)['token']
            as String;
    final mismatchedCredentialSession = AuthenticatedSession.persistent(
      manager.principal,
      OpaqueToken.digest(limitedManagerToken),
    );
    var credentialCeilingDenied = false;
    try {
      await gateway.list(
        session: mismatchedCredentialSession,
        companyId: companyA,
        branchId: branchA,
      );
    } on IdentityUserAdministrationException catch (error) {
      credentialCeilingDenied = error.statusCode == 403;
    }
    check(
      credentialCeilingDenied,
      'The database rejects a management permission absent from the live credential ceiling',
    );

    final roleManager = await authenticate(roleManagerToken);
    await roleGateway.change(
      session: roleManager,
      companyId: companyA,
      branchId: branchA,
      change: const {
        'action': 'ROLE_CREATED',
        'roleId': 'safe-domain-role',
        'displayName': 'Safe domain role',
      },
    );
    var roleManagementPermissionDenied = false;
    try {
      await roleGateway.change(
        session: roleManager,
        companyId: companyA,
        branchId: branchA,
        change: const {
          'action': 'ROLE_PERMISSION_GRANTED',
          'roleId': 'safe-domain-role',
          'permission': 'identity.users.manage',
        },
      );
    } on IdentityRoleAdministrationException catch (error) {
      roleManagementPermissionDenied = error.statusCode == 403;
    }
    check(
      roleManagementPermissionDenied,
      'Role administration cannot delegate identity management permissions',
    );

    var callerSuppliedCreateIdDenied = false;
    try {
      await gateway.change(
        session: manager,
        companyId: companyA,
        branchId: branchA,
        change: const {'action': 'USER_CREATED', 'actorId': 'caller-chosen-id'},
      );
    } on IdentityUserAdministrationException catch (error) {
      callerSuppliedCreateIdDenied = error.statusCode == 422;
    }
    check(
      callerSuppliedCreateIdDenied,
      'The database rejects caller-supplied tenant-global user IDs even when bypassing HTTP validation',
    );

    final generatedUserId = await gateway.change(
      session: manager,
      companyId: companyA,
      branchId: branchA,
      change: const {'action': 'USER_CREATED'},
    );
    check(
      generatedUserId != null &&
          RegExp(r'^usr_[0-9a-f]{32}$').hasMatch(generatedUserId),
      'The Host generates an opaque user ID instead of accepting a tenant-global caller ID',
    );
    var snapshot = await gateway.list(
      session: manager,
      companyId: companyA,
      branchId: branchA,
    );
    final newUser = (snapshot['items'] as List).cast<Map>().singleWhere(
      (user) => user['actorId'] == generatedUserId,
    );
    check(
      newUser['state'] == 'ACTIVE' &&
          (newUser['directPermissions'] as List).isEmpty &&
          (newUser['roles'] as List).isEmpty,
      'Remote user creation assigns no authority and records the exact creation scope',
    );

    await gateway.change(
      session: manager,
      companyId: companyA,
      branchId: branchA,
      change: {
        'action': 'PERMISSION_GRANTED',
        'actorId': generatedUserId!,
        'permission': 'maintenance.read',
      },
    );
    snapshot = await gateway.list(
      session: manager,
      companyId: companyA,
      branchId: branchA,
    );
    final granted = (snapshot['items'] as List).cast<Map>().singleWhere(
      (user) => user['actorId'] == generatedUserId,
    );
    check(
      (granted['directPermissions'] as List).contains('maintenance.read'),
      'A user manager can grant a normal permission only in the exact branch',
    );

    var managementGrantDenied = false;
    try {
      await gateway.change(
        session: manager,
        companyId: companyA,
        branchId: branchA,
        change: {
          'action': 'PERMISSION_GRANTED',
          'actorId': generatedUserId,
          'permission': 'identity.roles.manage',
        },
      );
    } on IdentityUserAdministrationException catch (error) {
      managementGrantDenied = error.statusCode == 422;
    }
    check(
      managementGrantDenied,
      'User management cannot delegate identity or Host administration capabilities',
    );

    await gateway.change(
      session: manager,
      companyId: companyA,
      branchId: branchA,
      change: {
        'action': 'PERMISSION_REVOKED',
        'actorId': generatedUserId,
        'permission': 'maintenance.read',
      },
    );
    await gateway.change(
      session: manager,
      companyId: companyA,
      branchId: branchA,
      change: {'action': 'USER_DISABLED', 'actorId': generatedUserId},
    );
    snapshot = await gateway.list(
      session: manager,
      companyId: companyA,
      branchId: branchA,
    );
    final disabled = (snapshot['items'] as List).cast<Map>().singleWhere(
      (user) => user['actorId'] == generatedUserId,
    );
    check(
      disabled['state'] == 'DISABLED' &&
          (disabled['directPermissions'] as List).isEmpty,
      'Permission revocation and safe same-scope disablement are reflected in inventory',
    );

    var selfDisableDenied = false;
    try {
      await gateway.change(
        session: manager,
        companyId: companyA,
        branchId: branchA,
        change: const {'action': 'USER_DISABLED', 'actorId': 'user-manager-a'},
      );
    } on IdentityUserAdministrationException catch (error) {
      selfDisableDenied = error.statusCode == 403;
    }
    check(selfDisableDenied, 'A user manager cannot disable their own account');

    await operator.createUser('other-branch-user');
    await operator.grant(
      'other-branch-user',
      companyB,
      branchB,
      'maintenance.read',
    );
    Future<(int, String?)> attemptScopedChange(
      Map<String, Object?> change,
    ) async {
      try {
        await gateway.change(
          session: manager,
          companyId: companyA,
          branchId: branchA,
          change: change,
        );
        return (200, null);
      } on IdentityUserAdministrationException catch (error) {
        return (error.statusCode, error.code);
      }
    }

    final crossBranchResults = <(int, String?)>[];
    final unknownActorResults = <(int, String?)>[];
    for (final action in ['PERMISSION_GRANTED', 'PERMISSION_REVOKED']) {
      crossBranchResults.add(
        await attemptScopedChange({
          'action': action,
          'actorId': 'other-branch-user',
          'permission': 'maintenance.read',
        }),
      );
      unknownActorResults.add(
        await attemptScopedChange({
          'action': action,
          'actorId': 'unknown-global-id',
          'permission': 'maintenance.read',
        }),
      );
    }
    for (final action in ['USER_DISABLED']) {
      crossBranchResults.add(
        await attemptScopedChange({
          'action': action,
          'actorId': 'other-branch-user',
        }),
      );
      unknownActorResults.add(
        await attemptScopedChange({
          'action': action,
          'actorId': 'unknown-global-id',
        }),
      );
    }
    check(
      crossBranchResults.every((result) => result == (404, 'USER_NOT_FOUND')) &&
          crossBranchResults.toSet().length == 1 &&
          unknownActorResults.every(
            (result) => result == (404, 'USER_NOT_FOUND'),
          ),
      'Grant, revoke, and disable disclose no difference between an unknown ID and a user active only in another branch',
    );

    await provision(
      actorId: 'credential-scope-outside-user',
      deviceId: 'credential-scope-outside-device',
      credentialId: 'credential-scope-outside-credential',
      directGrants: [
        (companyA, branchA, 'maintenance.read'),
        (companyB, branchB, 'maintenance.read'),
      ],
      scopes: [
        {
          'companyId': companyA,
          'branchId': branchA,
          'permissions': ['maintenance.read'],
        },
        {
          'companyId': companyB,
          'branchId': branchB,
          'permissions': ['maintenance.read'],
        },
      ],
    );
    await operator.revokeGrant(
      'credential-scope-outside-user',
      companyB,
      branchB,
      'maintenance.read',
    );
    var credentialScopeDisableDenied = false;
    try {
      await gateway.change(
        session: manager,
        companyId: companyA,
        branchId: branchA,
        change: const {
          'action': 'USER_DISABLED',
          'actorId': 'credential-scope-outside-user',
        },
      );
    } on IdentityUserAdministrationException catch (error) {
      credentialScopeDisableDenied =
          error.statusCode == 404 && error.code == 'USER_NOT_FOUND';
    }
    check(
      credentialScopeDisableDenied,
      'An external credential ceiling blocks disablement without disclosing why',
    );

    await operator.createUser('branch-b-only-user');
    await operator.grant(
      'branch-b-only-user',
      companyB,
      branchB,
      'maintenance.read',
    );
    snapshot = await gateway.list(
      session: manager,
      companyId: companyA,
      branchId: branchA,
    );
    check(
      !(snapshot['items'] as List).cast<Map>().any(
        (user) => user['actorId'] == 'branch-b-only-user',
      ),
      'User inventory does not reveal actors active only in another branch',
    );

    await operator.revokeGrant(
      'user-manager-a',
      companyA,
      branchA,
      identityUsersManagePermission,
    );
    var staleSnapshotDenied = false;
    try {
      await gateway.list(
        session: manager,
        companyId: companyA,
        branchId: branchA,
      );
    } on IdentityUserAdministrationException catch (error) {
      staleSnapshotDenied = error.statusCode == 403;
    }
    check(
      staleSnapshotDenied,
      'Database authorization rechecks a revoked direct grant despite a stale session snapshot',
    );
    await operator.grant(
      'user-manager-a',
      companyA,
      branchA,
      identityUsersManagePermission,
    );

    final auditRows = await auditConnection.execute(
      pg.Sql.named('''
        SELECT action, subject_id, details::text, database_actor
        FROM ventio_identity_audit
        WHERE tenant_id=@tenant AND subject_id=@subject
        ORDER BY id
      '''),
      parameters: {'tenant': tenant, 'subject': generatedUserId},
    );
    final createAudit = auditRows
        .where((row) => row[0] == 'USER_CREATED')
        .single;
    final createdDetails = jsonDecode(createAudit[2] as String) as Map;
    check(
      auditRows.map((row) => row[0]).toSet().containsAll({
            'USER_CREATED',
            'PERMISSION_GRANTED',
            'PERMISSION_REVOKED',
            'USER_DISABLED',
          }) &&
          createdDetails['operatorActorId'] == 'user-manager-a' &&
          createdDetails['companyId'] == companyA &&
          createdDetails['branchId'] == branchA &&
          auditRows.every((row) => (row[3] as String).isNotEmpty),
      'User operations retain exact-scope audit details and database actor evidence',
    );

    await authority.change(auditConnection, (tx) async {
      await tx.execute(
        pg.Sql.named('''
        INSERT INTO ventio_identity_audit
          (tenant_id,operator_label,action,subject_id,details)
        VALUES (@tenant,'Bearer fixture-secret','USER_CREATED',
          'Bearer subject-secret',CAST(@details AS jsonb))
      '''),
        parameters: {
          'tenant': tenant,
          'details': jsonEncode({
            'companyId': companyA,
            'branchId': branchA,
            'operatorActorId': 'Bearer fixture-secret',
            'token': 'fixture-secret',
          }),
        },
      );
    });
    final auditSnapshot = await gateway.audit(
      session: await authenticate(managerToken),
      companyId: companyA,
      branchId: branchA,
    );
    final auditEvents = (auditSnapshot['events'] as List).cast<Map>();
    final redactedEvent = auditEvents
        .where((event) => event['subjectId'] == '[redacted]')
        .firstOrNull;
    check(
      auditEvents.length <= 100,
      'Audit history remains bounded to one hundred events',
    );
    check(
      redactedEvent != null &&
          redactedEvent['operator'] == 'Host administrator',
      'Unsafe audit subject and operator labels are redacted',
    );
    final auditEventsAreAllowlisted = auditEvents.every(
      (event) =>
          event.keys.length == 5 &&
          event.keys.toSet().containsAll({
            'eventId',
            'occurredAtUtc',
            'action',
            'subjectId',
            'operator',
          }) &&
          !event.containsKey('details'),
    );
    final auditSnapshotContainsInjectedSecret = jsonEncode(
      auditSnapshot,
    ).contains('fixture-secret');
    check(
      auditEventsAreAllowlisted,
      'Audit history returns only allowlisted fields and no details',
    );
    check(
      !auditSnapshotContainsInjectedSecret,
      'Audit history suppresses the injected secret value',
    );

    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    await auditConnection.close();
    await bootstrapConnection.close();
    await adminConnection.close();
    await temporary.delete(recursive: true);
  }
}
