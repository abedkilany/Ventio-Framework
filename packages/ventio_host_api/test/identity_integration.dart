import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host/ventio_host.dart';
import 'package:ventio_host_api/ventio_host_api.dart';
import 'package:ventio_postgres/ventio_postgres.dart';

import 'test_support.dart';

class ExecutionGate implements CommandExecutor {
  final CommandExecutor inner;
  Completer<void>? entered;
  Completer<void>? release;
  ExecutionGate(this.inner);
  void hold() {
    entered = Completer<void>();
    release = Completer<void>();
  }

  @override
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session,
  ) async {
    if (entered != null) {
      final waiting = release!;
      entered!.complete();
      await waiting.future;
      entered = null;
      release = null;
    }
    return inner.execute(command, session);
  }
}

Future<void> mustFail(Future<void> Function() action, String label) async {
  var failed = false;
  try {
    await action();
  } catch (_) {
    failed = true;
  }
  check(failed, label);
}

Future<void> waitUntil(
  Future<bool> Function() condition,
  String label, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final watch = Stopwatch()..start();
  while (!await condition()) {
    if (watch.elapsed > timeout) throw StateError('Timed out: $label');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> main() async {
  final url = Platform.environment['VENTIO_TEST_DATABASE_URL'];
  if (url == null ||
      Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
      Uri.parse(url).pathSegments.where((s) => s.isNotEmpty).lastOrNull !=
          'ventio_host_test') {
    stderr.writeln(
      'Identity tests require an explicitly enabled disposable ventio_host_test database.',
    );
    exitCode = 2;
    return;
  }
  Future<pg.Connection> connect() => pg.Connection.openFromUrl(url);
  final runtimeUrl = Platform.environment['VENTIO_TEST_RUNTIME_DATABASE_URL'];
  final administrationUrl =
      Platform.environment['VENTIO_TEST_ADMIN_DATABASE_URL'];
  if (runtimeUrl == null || administrationUrl == null) {
    throw StateError(
      'Restricted runtime and administration test connections are required',
    );
  }
  Future<pg.Connection> runtimeConnect() =>
      pg.Connection.openFromUrl(runtimeUrl);
  final db = await connect();
  final adminConnection = await pg.Connection.openFromUrl(administrationUrl);
  final authorityDirectory = await createPrivateTestDirectory(
    'ventio-identity-integration-',
  );
  final authority = RecoveryAuthority(
    '${authorityDirectory.path}/authority.json',
  );
  final tenant = 'identity-${DateTime.now().microsecondsSinceEpoch}';
  final otherTenant = '$tenant-other';
  final admin = IdentityAdministration(
    connection: adminConnection,
    tenantId: tenant,
    operatorLabel: 'integration-operator',
    authority: authority,
  );
  final otherAdmin = IdentityAdministration(
    connection: adminConnection,
    tenantId: otherTenant,
    operatorLabel: 'integration-operator',
    authority: authority,
  );
  final prototype = bootstrapMaintenancePrototype('../../spec/v1.2');
  final authenticator = PersistentTokenAuthenticator(
    connect: runtimeConnect,
    admission: authority,
  );
  PersistentCommandExecutor executor({
    Future<pg.Connection> Function()? open,
  }) => PersistentCommandExecutor(
    connect: open ?? runtimeConnect,
    admission: authority,
    modules: prototype.modules,
    docTypes: prototype.docTypes,
    bindings: const [
      TrustedCommandBinding('maintenance.create', 1, 'MaintenanceRequest'),
    ],
  );
  final realExecutor = executor();
  final gate = ExecutionGate(realExecutor);
  HostApi? api;
  Process? child;
  Future<Reply> submit(String token, Map<String, dynamic> body) =>
      send(api!, token: token, body: body);
  Future<String> issueScopedCredential(
    IdentityAdministration administration, {
    required String actorId,
    required String deviceId,
    required String credentialId,
    required DateTime expiresAt,
    required List<Map<String, Object?>> allowedScopes,
  }) async {
    final outputPath =
        '${authorityDirectory.path}/credential-${OpaqueToken.generate()}.json';
    await administration.provisionToFile(
      actorId: actorId,
      deviceId: deviceId,
      credentialId: credentialId,
      expiresAt: expiresAt,
      allowedScopes: allowedScopes,
      outputPath: outputPath,
    );
    final credential =
        jsonDecode(await PrivateFiles.read(outputPath)) as Map<String, dynamic>;
    return credential['token'] as String;
  }

  Future<String> provision(
    IdentityAdministration administration,
    String actor,
    String device,
    String credential, {
    DateTime? expiresAt,
  }) async {
    await administration.createUser(actor);
    await administration.registerBranch('company-001', 'branch-001');
    await administration.registerDevice(actor, device);
    await administration.grant(
      actor,
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    await administration.grant(
      actor,
      'company-001',
      'branch-001',
      'maintenance.read',
    );
    return issueScopedCredential(
      administration,
      actorId: actor,
      deviceId: device,
      credentialId: credential,
      expiresAt:
          expiresAt ?? DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': 'company-001',
          'branchId': 'branch-001',
          'permissions': ['maintenance.create', 'maintenance.read'],
        },
      ],
    );
  }

  Map<String, dynamic> scoped(
    String scope,
    int id, {
    String actor = 'user-001',
    String device = 'device-001',
  }) {
    final body = command(scope, id: id);
    body['clientContext']['actorId'] = actor;
    body['clientContext']['deviceId'] = device;
    return body;
  }

  Future<List<int>> counts() async {
    final values = <int>[];
    for (final table in [
      'ventio_records',
      'ventio_command_journal',
      'ventio_audit_entries',
      'ventio_outbox',
    ]) {
      values.add(
        (await db.execute(
              pg.Sql.named(
                'SELECT count(*) FROM $table WHERE tenant_id IN (@tenant, @other)',
              ),
              parameters: {'tenant': tenant, 'other': otherTenant},
            )).single[0]
            as int,
      );
    }
    return values;
  }

  Future<bool> blocked(int pid) async =>
      (await db.execute(
        pg.Sql.named(
          "SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = @pid",
        ),
        parameters: {'pid': pid},
      )).single[0] ==
      true;
  try {
    await PostgresMigrationRunner(
      db,
      Directory('../../migrations/postgres'),
    ).apply();
    await authority.resetForReenrollment(
      adminConnection,
      'identity-integration-reset',
    );
    final token = await provision(admin, 'user-001', 'device-001', 'primary');
    final secondToken = await issueScopedCredential(
      admin,
      actorId: 'user-001',
      deviceId: 'device-001',
      credentialId: 'secondary',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': 'company-001',
          'branchId': 'branch-001',
          'permissions': ['maintenance.create', 'maintenance.read'],
        },
      ],
    );
    final foreignToken = await provision(
      otherAdmin,
      'user-001',
      'device-001',
      'primary',
    );
    check(
      token.length == 43 && OpaqueToken.isValid(token) && token != secondToken,
      'Server issues distinct 256-bit opaque credentials',
    );
    final stored = await db.execute(
      pg.Sql.named(
        'SELECT token_digest FROM ventio_identity_credentials WHERE tenant_id = @tenant AND credential_id = @id',
      ),
      parameters: {'tenant': tenant, 'id': 'primary'},
    );
    check(
      stored.single[0] == OpaqueToken.digest(token) &&
          stored.single[0] != token,
      'Only credential digest is stored',
    );
    check(
      (await authenticator.authenticate(token))?.principal.tenantId == tenant,
      'Persistent authentication resolves server-owned identity',
    );
    check(
      await authenticator.authenticate(List.filled(43, 'x').join()) == null,
      'Unknown well-formed credential is denied',
    );
    check(
      await authenticator.authenticate('invalid') == null,
      'Malformed credential is denied',
    );

    api = await HostApi.bind(authenticator: authenticator, executor: gate);
    final first = scoped(tenant, 1);
    final firstReply = await submit(token, first);
    check(
      firstReply.status == 200,
      'Persistent identity authorizes operational command',
    );
    final originalReceipt = canonicalJson(firstReply.body);
    check(
      canonicalJson((await submit(token, first)).body) == originalReceipt,
      'Authenticated retry returns stable stored receipt',
    );
    await admin.createRole('maintenance-editor', 'Maintenance editor');
    await admin.grantRolePermission('maintenance-editor', 'maintenance.create');
    await admin.grantRolePermission('maintenance-editor', 'maintenance.read');
    await admin.createUser('role-user');
    await admin.registerDevice('role-user', 'role-device');
    await admin.registerBranch('company-002', 'branch-002');
    await admin.assignRole(
      actorId: 'role-user',
      roleId: 'maintenance-editor',
      companyId: 'company-001',
      branchId: 'branch-001',
    );
    await admin.assignRole(
      actorId: 'role-user',
      roleId: 'maintenance-editor',
      companyId: 'company-002',
      branchId: 'branch-002',
    );
    final roleToken = await issueScopedCredential(
      admin,
      actorId: 'role-user',
      deviceId: 'role-device',
      credentialId: 'role-credential',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': 'company-001',
          'branchId': 'branch-001',
          'permissions': ['maintenance.create', 'maintenance.read'],
        },
        {
          'companyId': 'company-002',
          'branchId': 'branch-002',
          'permissions': ['maintenance.create', 'maintenance.read'],
        },
      ],
    );
    final roleSession = (await authenticator.authenticate(roleToken))!;
    check(
      roleSession.principal.allowsInScope(
            'maintenance.create',
            'company-001',
            'branch-001',
          ) &&
          roleSession.principal.allowsInScope(
            'maintenance.read',
            'company-002',
            'branch-002',
          ),
      'Assigned role contributes permissions only at each assigned scope',
    );
    final scopedRoleToken = await issueScopedCredential(
      admin,
      actorId: 'role-user',
      deviceId: 'role-device',
      credentialId: 'role-credential-scoped',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': 'company-001',
          'branchId': 'branch-001',
          'permissions': ['maintenance.create'],
        },
      ],
    );
    final scopedRoleSession = (await authenticator.authenticate(
      scopedRoleToken,
    ))!;
    check(
      scopedRoleSession.principal.allowsInScope(
            'maintenance.create',
            'company-001',
            'branch-001',
          ) &&
          !scopedRoleSession.principal.allowsInScope(
            'maintenance.read',
            'company-001',
            'branch-001',
          ) &&
          !scopedRoleSession.principal.allowsInScope(
            'maintenance.create',
            'company-002',
            'branch-002',
          ),
      'Provisioned role credentials retain their exact permission and branch ceiling',
    );
    final roleScoped = scoped(
      tenant,
      19,
      actor: 'role-user',
      device: 'role-device',
    );
    final roleBranchCommand =
        scoped(tenant, 20, actor: 'role-user', device: 'role-device')
          ..['companyId'] = 'company-002'
          ..['branchId'] = 'branch-002';
    final roleBranchOneReply = await submit(roleToken, roleScoped);
    final roleBranchTwoReply = await submit(roleToken, roleBranchCommand);
    check(
      roleBranchOneReply.status == 200 && roleBranchTwoReply.status == 200,
      'Role permissions authorize records in assigned branches',
    );
    final forgedRoleScope = Map<String, dynamic>.from(roleScoped)
      ..['companyId'] = 'company-001'
      ..['branchId'] = 'branch-002';
    check(
      (await submit(roleToken, forgedRoleScope)).status == 403,
      'Role assignments cannot create a company/branch cross-product',
    );
    await mustFail(
      () => admin.deleteRole('maintenance-editor'),
      'A role with active assignments cannot be deleted',
    );
    await admin.revokeRolePermission(
      'maintenance-editor',
      'maintenance.create',
    );
    check(
      (await submit(roleToken, roleScoped)).status == 403,
      'Removing a role permission takes effect on the next command',
    );
    await admin.grantRolePermission('maintenance-editor', 'maintenance.create');
    await admin.revokeRoleAssignment(
      actorId: 'role-user',
      roleId: 'maintenance-editor',
      companyId: 'company-001',
      branchId: 'branch-001',
    );
    check(
      (await submit(roleToken, roleScoped)).status == 403 &&
          (await submit(roleToken, roleBranchCommand)).status == 200,
      'Revoking a role assignment removes only that exact branch access',
    );
    await admin.revokeRoleAssignment(
      actorId: 'role-user',
      roleId: 'maintenance-editor',
      companyId: 'company-002',
      branchId: 'branch-002',
    );
    await admin.deleteRole('maintenance-editor');
    check(
      (await submit(roleToken, roleBranchCommand)).status == 403,
      'Deleted roles leave no permission path on issued credentials',
    );
    final foreignCommand = scoped(otherTenant, 1);
    check(
      (await submit(foreignToken, foreignCommand)).status == 200,
      'Same actor and device IDs work independently in another tenant',
    );
    for (final field in [
      'tenantId',
      'companyId',
      'branchId',
      'actorId',
      'deviceId',
    ]) {
      final forged = scoped(tenant, 2);
      if (field == 'actorId' || field == 'deviceId') {
        forged['clientContext'][field] = 'forged';
      } else {
        forged[field] = field == 'tenantId' ? otherTenant : 'forged';
      }
      check(
        (await submit(token, forged)).status == 403,
        'Persistent boundary rejects forged $field',
      );
    }
    await admin.registerBranch('company-002', 'branch-002');
    await admin.grant(
      'user-001',
      'company-002',
      'branch-002',
      'maintenance.create',
    );
    final secondBranchToken = await issueScopedCredential(
      admin,
      actorId: 'user-001',
      deviceId: 'device-001',
      credentialId: 'second-branch',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': 'company-002',
          'branchId': 'branch-002',
          'permissions': ['maintenance.create'],
        },
      ],
    );
    final pair = scoped(tenant, 3)
      ..['companyId'] = 'company-002'
      ..['branchId'] = 'branch-002';
    check(
      (await submit(secondBranchToken, pair)).status == 200,
      'A separate credential with the second branch scope is accepted',
    );
    await mustFail(
      () => admin.grant(
        'user-001',
        'company-001',
        'branch-002',
        'maintenance.create',
      ),
      'Foreign keys reject a grant for an unregistered company and branch pair',
    );
    final crossed = scoped(tenant, 4)
      ..['companyId'] = 'company-001'
      ..['branchId'] = 'branch-002';
    check(
      (await submit(token, crossed)).status == 403,
      'Company and branch grants do not form an unintended cross-product',
    );
    final malformed = scoped(tenant, 4)
      ..['permissions'] = ['maintenance.create'];
    check(
      (await submit(token, malformed)).status == 400,
      'Client permission claims cannot enter the identity store',
    );
    final beforeDenials = await counts();

    final staleSession = (await authenticator.authenticate(token))!;
    gate.hold();
    final racing = submit(token, scoped(tenant, 4));
    await gate.entered!.future;
    await admin.revokeGrant(
      'user-001',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    gate.release!.complete();
    check(
      (await racing).status == 403,
      'Permission removed after HTTP authentication is rechecked at execution',
    );
    check(
      (await submit(token, first)).status == 403,
      'Removed permission also blocks saved-receipt replay',
    );
    final staleReceipt = await realExecutor.execute(
      CommandEnvelope.fromJson(scoped(tenant, 4)),
      staleSession,
    );
    check(
      staleReceipt['reasonCode'] == 'PERMISSION_DENIED',
      'Stale authenticated Principal cannot preserve an old permission',
    );
    check(
      canonicalJson(await counts()) == canonicalJson(beforeDenials),
      'Permission denials create no journal, record, audit or outbox effects',
    );
    await admin.grant(
      'user-001',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    check(
      canonicalJson((await submit(token, first)).body) == originalReceipt,
      'Regranting permission reveals the same original receipt without re-execution',
    );
    await admin.revokeCredential('secondary');
    check(
      (await submit(secondToken, first)).status == 401,
      'Credential revocation is enforced',
    );
    check(
      (await submit(token, first)).status == 200,
      'Revoking one credential leaves another active credential intact',
    );
    await admin.revokeCredential('secondary');
    check(
      (await submit(secondToken, scoped(tenant, 4))).status == 401,
      'Credential revocation is idempotent and remains denied',
    );
    await mustFail(() async {
      await issueScopedCredential(
        admin,
        actorId: 'user-001',
        deviceId: 'device-001',
        credentialId: 'secondary',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        allowedScopes: [
          {
            'companyId': 'company-001',
            'branchId': 'branch-001',
            'permissions': ['maintenance.create', 'maintenance.read'],
          },
        ],
      );
    }, 'Revoked credential ID cannot be overwritten by issuance');
    await mustFail(
      () => admin.registerDevice('user-001', 'device-001'),
      'Duplicate device registration cannot replace an identity',
    );
    await mustFail(
      () => otherAdmin.revokeCredential('secondary'),
      'Tenant-scoped administration cannot revoke another tenant credential',
    );
    check(
      (await submit(token, first)).status == 200,
      'Cross-tenant administrative denial leaves the intended credential intact',
    );

    // Audit writes must commit with security changes, or neither may persist.
    await db.execute(
      "ALTER TABLE ventio_identity_audit ADD CONSTRAINT identity_audit_test_reject CHECK (operator_label <> 'rollback-test') NOT VALID",
    );
    try {
      final brokenAudit = IdentityAdministration(
        connection: adminConnection,
        tenantId: tenant,
        operatorLabel: 'rollback-test',
        authority: authority,
      );
      await mustFail(
        () => brokenAudit.revokeDevice('device-001'),
        'Audit failure aborts the revocation transaction',
      );
      check(
        (await submit(token, first)).status == 200,
        'Audit failure rolls back device revocation',
      );
    } finally {
      await db.execute(
        'ALTER TABLE ventio_identity_audit DROP CONSTRAINT identity_audit_test_reject',
      );
    }

    await admin.createUser('expiry-user');
    await admin.registerDevice('expiry-user', 'expiry-device');
    await admin.grant(
      'expiry-user',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    await admin.grant(
      'expiry-user',
      'company-001',
      'branch-001',
      'maintenance.read',
    );
    final expiry =
        (await db.execute('SELECT clock_timestamp()')).single[0] as DateTime;
    final expiringToken = await issueScopedCredential(
      admin,
      actorId: 'expiry-user',
      deviceId: 'expiry-device',
      credentialId: 'expiring',
      expiresAt: expiry.add(const Duration(seconds: 30)),
      allowedScopes: [
        {
          'companyId': 'company-001',
          'branchId': 'branch-001',
          'permissions': ['maintenance.create', 'maintenance.read'],
        },
      ],
    );
    final expiringSession = await authenticator.authenticate(expiringToken);
    check(
      expiringSession != null,
      'Time-limited credential authenticates before expiry',
    );
    final lockConnection = await connect();
    final commandConnection = await runtimeConnect();
    final commandPid =
        (await commandConnection.execute('SELECT pg_backend_pid()')).single[0]
            as int;
    final locked = Completer<void>();
    final unlock = Completer<void>();
    final held = lockConnection.runTx((tx) async {
      await tx.execute(
        pg.Sql.named(
          'SELECT actor_id FROM ventio_identity_users WHERE tenant_id = @tenant AND actor_id = @actor FOR UPDATE',
        ),
        parameters: {'tenant': tenant, 'actor': 'expiry-user'},
      );
      locked.complete();
      await unlock.future;
    });
    await locked.future;
    await waitUntil(
      () async =>
          (await db.execute(
                pg.Sql.named('''
                  SELECT expires_at <= clock_timestamp() + interval '2 seconds'
                  FROM ventio_identity_credentials WHERE token_digest = @digest
                '''),
                parameters: {'digest': OpaqueToken.digest(expiringToken)},
              )).single[0]
              as bool,
      'Credential approaches expiry before the delayed command starts',
      timeout: const Duration(seconds: 35),
    );
    final delayedExpiry = executor(open: () async => commandConnection).execute(
      CommandEnvelope.fromJson(
        scoped(tenant, 5, actor: 'expiry-user', device: 'expiry-device'),
      ),
      expiringSession!,
    );
    try {
      await waitUntil(
        () => blocked(commandPid),
        'Command waits on user authorization lock',
      );
      await waitUntil(
        () async =>
            (await db.execute(
              pg.Sql.named(
                'SELECT expires_at <= clock_timestamp() FROM ventio_identity_credentials WHERE token_digest = @digest',
              ),
              parameters: {'digest': OpaqueToken.digest(expiringToken)},
            )).single[0] ==
            true,
        'Credential expires while waiting',
      );
    } finally {
      unlock.complete();
      await held;
      await lockConnection.close();
    }
    check(
      (await delayedExpiry)['reasonCode'] == 'AUTHENTICATION_REQUIRED',
      'Expiry is checked after lock wait using database wall clock',
    );
    check(
      (await submit(expiringToken, first)).status == 401,
      'Expired credential cannot replay an accepted command',
    );
    check(
      (await submit(expiringToken, scoped(tenant, 5))).status == 401,
      'Expired credential cannot create a new command',
    );

    // Commands holding a valid authorization lock may finish first. Revocation
    // waits for them and denies every later execute/retry once it returns.
    final raceToken = await provision(
      admin,
      'race-user',
      'race-device',
      'race-credential',
    );
    final raceCommand = scoped(
      tenant,
      6,
      actor: 'race-user',
      device: 'race-device',
    );
    final raceConnection = await connect();
    final revocationConnection = await connect();
    final revocationPid =
        (await revocationConnection.execute(
              'SELECT pg_backend_pid()',
            )).single[0]
            as int;
    final authorized = Completer<void>();
    final finishCommand = Completer<void>();
    final raceHost =
        DurableCommandHost(
          connection: raceConnection,
          modules: prototype.modules,
          docTypes: prototype.docTypes,
        )..registerTrustedCreateBinding(
          const TrustedCommandBinding(
            'maintenance.create',
            1,
            'MaintenanceRequest',
          ),
        );
    final admitted = raceHost.executeAuthorized(
      CommandEnvelope.fromJson(raceCommand),
      (tx) async {
        await authority.admit(tx);
        final resolved = await const PostgresIdentityStore().resolve(
          tx,
          OpaqueToken.digest(raceToken),
          command: CommandEnvelope.fromJson(raceCommand),
        );
        authorized.complete();
        await finishCommand.future;
        return resolved;
      },
    );
    await authorized.future;
    final revoker = IdentityAdministration(
      connection: revocationConnection,
      tenantId: tenant,
      operatorLabel: 'race-operator',
      authority: authority,
    );
    final revoking = revoker.revokeDevice('race-device');
    try {
      await waitUntil(
        () => blocked(revocationPid),
        'Revocation waits for admitted command',
      );
      check(
        true,
        'Device revocation waits on the in-flight authorization transaction',
      );
    } finally {
      finishCommand.complete();
    }
    final raceReceipt = await admitted;
    check(
      raceReceipt['status'] == 'ACCEPTED',
      'Command authorized before revocation commits once: ${jsonEncode(raceReceipt)}',
    );
    await revoking;
    await raceConnection.close();
    await revocationConnection.close();
    check(
      (await submit(raceToken, raceCommand)).status == 401,
      'After revocation returns even the saved receipt is inaccessible',
    );

    // A permission change is ordered against in-flight execution by the same guard.
    final policyToken = await provision(
      admin,
      'policy-user',
      'policy-device',
      'policy-credential',
    );
    final policyConnection = await connect();
    final policyAdminConnection = await connect();
    final policyPid =
        (await policyAdminConnection.execute(
              'SELECT pg_backend_pid()',
            )).single[0]
            as int;
    final policyCommand = CommandEnvelope.fromJson(
      scoped(tenant, 7, actor: 'policy-user', device: 'policy-device'),
    );
    final policyEntered = Completer<void>();
    final policyRelease = Completer<void>();
    final policyHost =
        DurableCommandHost(
          connection: policyConnection,
          modules: prototype.modules,
          docTypes: prototype.docTypes,
        )..registerTrustedCreateBinding(
          const TrustedCommandBinding(
            'maintenance.create',
            1,
            'MaintenanceRequest',
          ),
        );
    final policyAccepted = policyHost.executeAuthorized(policyCommand, (
      tx,
    ) async {
      await authority.admit(tx);
      final resolved = await const PostgresIdentityStore().resolve(
        tx,
        OpaqueToken.digest(policyToken),
        command: policyCommand,
      );
      policyEntered.complete();
      await policyRelease.future;
      return resolved;
    });
    await policyEntered.future;
    final policyAdmin = IdentityAdministration(
      connection: policyAdminConnection,
      tenantId: tenant,
      operatorLabel: 'policy-operator',
      authority: authority,
    );
    final changingPolicy = policyAdmin.revokeGrant(
      'policy-user',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    try {
      await waitUntil(
        () => blocked(policyPid),
        'Policy update waits for command authorization',
      );
    } finally {
      policyRelease.complete();
    }
    check(
      (await policyAccepted)['status'] == 'ACCEPTED',
      'Admitted command and concurrent permission change have a defined order',
    );
    await changingPolicy;
    await policyConnection.close();
    await policyAdminConnection.close();
    check(
      (await submit(
            policyToken,
            scoped(tenant, 7, actor: 'policy-user', device: 'policy-device'),
          )).status ==
          403,
      'Committed permission change denies later receipt replay',
    );

    await admin.registerDevice('user-001', 'alternate-device');
    final alternateToken = await issueScopedCredential(
      admin,
      actorId: 'user-001',
      deviceId: 'alternate-device',
      credentialId: 'alternate',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': 'company-001',
          'branchId': 'branch-001',
          'permissions': ['maintenance.create', 'maintenance.read'],
        },
      ],
    );
    final anotherActiveToken = await issueScopedCredential(
      admin,
      actorId: 'user-001',
      deviceId: 'device-001',
      credentialId: 'another-active',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': 'company-001',
          'branchId': 'branch-001',
          'permissions': ['maintenance.create', 'maintenance.read'],
        },
      ],
    );
    final beforeRevocation = await counts();
    final beforeRevocationSession = (await authenticator.authenticate(token))!;
    await admin.revokeDevice('device-001');
    check(
      (await submit(token, first)).status == 401,
      'Device revocation denies its primary credential and accepted retry',
    );
    check(
      (await realExecutor.execute(
            CommandEnvelope.fromJson(first),
            beforeRevocationSession,
          ))['reasonCode'] ==
          'AUTHENTICATION_REQUIRED',
      'Execution rejects a session authenticated before device revocation',
    );
    check(
      (await submit(anotherActiveToken, first)).status == 401,
      'All credentials of a revoked device remain denied',
    );
    check(
      (await submit(
            alternateToken,
            scoped(tenant, 8, device: 'alternate-device'),
          )).status ==
          200,
      'Revoking one device leaves another device usable',
    );
    check(
      (await submit(foreignToken, foreignCommand)).status == 200,
      'Device revocation is isolated to its tenant',
    );
    await mustFail(
      () => admin.registerDevice('user-001', 'device-001'),
      'Revoked device tombstone cannot be replaced',
    );
    await mustFail(() async {
      await issueScopedCredential(
        admin,
        actorId: 'user-001',
        deviceId: 'device-001',
        credentialId: 'revival',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        allowedScopes: [
          {
            'companyId': 'company-001',
            'branchId': 'branch-001',
            'permissions': ['maintenance.create', 'maintenance.read'],
          },
        ],
      );
    }, 'New credential issuance cannot revive a revoked device');
    await admin.revokeDevice('device-001');
    await admin.disableUser('user-001');
    check(
      (await submit(
            alternateToken,
            scoped(tenant, 8, device: 'alternate-device'),
          )).status ==
          401,
      'Disabling user denies every otherwise active device',
    );
    await mustFail(
      () => admin.createUser('user-001'),
      'Disabled user cannot be recreated to reset its state',
    );
    await mustFail(
      () => admin.grant(
        'user-001',
        'company-001',
        'branch-001',
        'maintenance.create',
      ),
      'Disabled user cannot receive a new grant',
    );
    final afterRevocation = await counts();
    check(
      afterRevocation.every((n) => n == beforeRevocation.first + 1),
      'Revocation and denied retries add no business effects',
    );
    final audit = await db.execute(
      pg.Sql.named(
        'SELECT action, details::text, database_actor FROM ventio_identity_audit WHERE tenant_id = @tenant',
      ),
      parameters: {'tenant': tenant},
    );
    check(
      audit.any((r) => r[0] == 'DEVICE_REVOKED') &&
          audit.any((r) => r[0] == 'PERMISSION_REVOKED') &&
          audit.any((r) => r[0] == 'USER_DISABLED') &&
          audit.every((r) => (r[2] as String).isNotEmpty),
      'Security changes have persistent audit entries and actual database operator identity',
    );
    check(
      !jsonEncode(audit.map((r) => r[1]).toList()).contains(token) &&
          !jsonEncode(
            audit.map((r) => r[1]).toList(),
          ).contains(OpaqueToken.digest(token)),
      'Security audit contains no raw tokens or credential digests',
    );
    final revokedEvents = await db.execute(
      pg.Sql.named(
        "SELECT count(*) FROM ventio_identity_audit WHERE tenant_id = @tenant AND subject_id = 'device-001' AND action = 'DEVICE_REVOKED'",
      ),
      parameters: {'tenant': tenant},
    );
    check(
      revokedEvents.single[0] == 1,
      'Idempotent revocation records one state transition',
    );

    // Fail closed on identity store outage; never fall back to development grants.
    final unavailableApi = await HostApi.bind(
      authenticator: PersistentTokenAuthenticator(
        connect: () async {
          throw StateError('private db detail');
        },
      ),
      executor: realExecutor,
    );
    try {
      final failed = await send(
        unavailableApi,
        token: foreignToken,
        body: foreignCommand,
      );
      check(
        failed.status == 503 && !jsonEncode(failed.body).contains('private db'),
        'Identity database failure denies access without fallback or detail leaks',
      );
    } finally {
      await unavailableApi.close();
    }
    check(
      (await realExecutor.execute(
            CommandEnvelope.fromJson(foreignCommand),
            AuthenticatedSession.development(principal(otherTenant)),
          ))['reasonCode'] ==
          'AUTHENTICATION_REQUIRED',
      'Persistent executor refuses development-only Principals',
    );
    await mustFail(
      () async =>
          PostgresCommandExecutor(
                connect: connect,
                modules: prototype.modules,
                docTypes: prototype.docTypes,
                bindings: const [
                  TrustedCommandBinding(
                    'maintenance.create',
                    1,
                    'MaintenanceRequest',
                  ),
                ],
              )
              .execute(
                CommandEnvelope.fromJson(foreignCommand),
                (await authenticator.authenticate(foreignToken))!,
              )
              .then((_) {}),
      'Development executor cannot silently handle a persistent session',
    );

    await api.close();
    api = null;
    final survivorToken = await provision(
      otherAdmin,
      'survivor',
      'survivor-device',
      'survivor-credential',
    );
    final revokedSurvivorToken = await issueScopedCredential(
      otherAdmin,
      actorId: 'survivor',
      deviceId: 'survivor-device',
      credentialId: 'survivor-revoked',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': 'company-001',
          'branchId': 'branch-001',
          'permissions': ['maintenance.create', 'maintenance.read'],
        },
      ],
    );
    await otherAdmin.revokeCredential('survivor-revoked');
    final survivorCommand = scoped(
      otherTenant,
      9,
      actor: 'survivor',
      device: 'survivor-device',
    );
    await otherAdmin.revokeGrant(
      'user-001',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    Future<int> startChild() async {
      child = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'test/recovery/legacy_host.dart'],
        environment: {
          'VENTIO_ALLOW_DATABASE_TESTS': 'yes',
          'VENTIO_ENABLE_LOCAL_HOST': 'yes',
          'VENTIO_TEST_ALLOW_STDIN_SHUTDOWN': 'yes',
          'VENTIO_PRIVATE_FILES_DIAGNOSTICS': '0',
          'VENTIO_RECOVERY_AUTHORITY_FILE': authority.path,
          'VENTIO_HOST_DATABASE_URL': runtimeUrl,
          'VENTIO_HOST_PORT': '0',
        },
      );
      final stderrText = child!.stderr.transform(utf8.decoder).join();
      try {
        final line = await child!.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 30));
        return int.parse(line.split(':').last);
      } catch (error) {
        final code = await child!.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            child!.kill();
            return -999;
          },
        );
        throw StateError(
          'Persistent Host subprocess failed to start (exit $code): '
          '${await stderrText}: $error',
        );
      }
    }

    Future<Reply> childSubmit(
      int port,
      String bearer,
      Map<String, dynamic> body,
    ) async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:$port/api/v1/commands'),
        );
        request.headers.set('Authorization', 'Bearer $bearer');
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
        final response = await request.close();
        return Reply(
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
          response.headers,
        );
      } finally {
        client.close(force: true);
      }
    }

    Future<void> stopChild() async {
      child!.stdin.writeln('shutdown');
      // EOF lets the fixture finish cancelling its stdin subscription on Windows.
      await child!.stdin.close();
      final code = await child!.exitCode.timeout(const Duration(seconds: 20));
      check(code == 0, 'Persistent Host process shuts down cleanly');
      child = null;
    }

    final firstPort = await startChild();
    check(
      (await childSubmit(firstPort, token, first)).status == 401,
      'Independent Host process preserves device/user revocation',
    );
    check(
      (await childSubmit(firstPort, expiringToken, first)).status == 401,
      'Independent Host process rejects expired credentials',
    );
    check(
      (await childSubmit(firstPort, foreignToken, foreignCommand)).status ==
          403,
      'Independent Host process preserves changed permissions',
    );
    check(
      (await childSubmit(
            firstPort,
            revokedSurvivorToken,
            survivorCommand,
          )).status ==
          401,
      'Individual credential revocation survives restart while its user and device stay active',
    );
    check(
      (await childSubmit(
            firstPort,
            alternateToken,
            scoped(tenant, 8, device: 'alternate-device'),
          )).status ==
          401,
      'User disablement survives restart while the alternate device stays unrevoked',
    );
    final survivorReply = await childSubmit(
      firstPort,
      survivorToken,
      survivorCommand,
    );
    check(
      survivorReply.status == 200,
      'Persisted active identity works without an identity configuration file',
    );
    await otherAdmin.grant(
      'user-001',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    check(
      (await childSubmit(firstPort, foreignToken, foreignCommand)).status ==
          200,
      'Running Host observes grants changed by a separate database connection',
    );
    await otherAdmin.revokeDevice('device-001');
    check(
      (await childSubmit(firstPort, foreignToken, foreignCommand)).status ==
          401,
      'Running Host observes device revocation without restart',
    );
    await stopChild();
    final restartedPort = await startChild();
    check(
      (await childSubmit(restartedPort, foreignToken, foreignCommand)).status ==
          401,
      'Committed device revocation survives a second Host process',
    );
    check(
      (await childSubmit(
            restartedPort,
            policyToken,
            scoped(tenant, 7, actor: 'policy-user', device: 'policy-device'),
          )).status ==
          403,
      'Permission withdrawal survives Host restart',
    );
    check(
      canonicalJson(
            (await childSubmit(
              restartedPort,
              survivorToken,
              survivorCommand,
            )).body,
          ) ==
          canonicalJson(survivorReply.body),
      'Restarted Host returns identical receipt for an authorized surviving identity',
    );
    await stopChild();
    final finalCounts = await counts();
    check(
      finalCounts.every((n) => n == afterRevocation.first + 1),
      'Restarts, revocations and replays preserve one set of business effects',
    );
    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    child?.kill(ProcessSignal.sigkill);
    await api?.close();
    // Only these generated test tenants are removed, under Recovery Authority.
    await authority.change(db, (tx) async {
      for (final table in [
        'ventio_outbox',
        'ventio_audit_entries',
        'ventio_command_journal',
        'ventio_records',
        'ventio_identity_audit',
        'ventio_identity_role_assignments',
        'ventio_identity_role_permissions',
        'ventio_identity_roles',
        'ventio_identity_grants',
        'ventio_identity_credentials',
        'ventio_identity_device_activity',
        'ventio_identity_devices',
        'ventio_identity_users',
        'ventio_identity_branches',
      ]) {
        await tx.execute(
          pg.Sql.named(
            'DELETE FROM $table WHERE tenant_id IN (@tenant, @other)',
          ),
          parameters: {'tenant': tenant, 'other': otherTenant},
        );
      }
    });
    await adminConnection.close();
    await db.close();
    await authorityDirectory.delete(recursive: true);
  }
}
