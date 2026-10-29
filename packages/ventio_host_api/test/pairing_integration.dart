import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart';

class _PairingIntegrationExecutor implements AuthoritativeCommandExecutor {
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
  final migrationUrl =
      Platform.environment['VENTIO_TEST_MIGRATION_DATABASE_URL'];
  final apiAdminUrl =
      Platform.environment['VENTIO_TEST_API_ADMIN_DATABASE_URL'];
  if (auditUrl == null ||
      runtimeUrl == null ||
      adminUrl == null ||
      migrationUrl == null ||
      apiAdminUrl == null ||
      Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
      ![
        auditUrl,
        runtimeUrl,
        adminUrl,
        migrationUrl,
        apiAdminUrl,
      ].every(_isDisposableTestDatabase)) {
    stderr.writeln(
      'Pairing integration requires the disposable ventio_host_test database and explicit test opt-in.',
    );
    exitCode = 2;
    return;
  }

  final audit = await pg.Connection.openFromUrl(auditUrl);
  final admin = await pg.Connection.openFromUrl(adminUrl);
  final migration = await pg.Connection.openFromUrl(migrationUrl);
  final temporary = await createPrivateTestDirectory('ventio-pairing-');
  final authority = RecoveryAuthority('${temporary.path}/authority.json');
  final tenant = 'pairing-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  const company = 'company-pairing';
  const branch = 'branch-pairing';
  HostApi? api;
  var assertions = 0;
  void check(bool condition, String label) {
    if (!condition) throw StateError('FAIL: $label');
    assertions++;
    stdout.writeln('PASS: $label');
  }

  try {
    await authority.resetForReenrollment(admin, 'pairing-integration-reset');
    final operator = IdentityAdministration(
      connection: admin,
      tenantId: tenant,
      operatorLabel: 'pairing-integration-operator',
      authority: authority,
    );
    await operator.registerBranch(company, branch);
    await operator.registerBranch(company, 'branch-other');

    await operator.createUser('pairing-manager');
    await operator.registerDevice('pairing-manager', 'pairing-manager-host');
    await operator.grant(
      'pairing-manager',
      company,
      branch,
      identityPairingManagePermission,
    );
    await operator.grant(
      'pairing-manager',
      company,
      branch,
      'maintenance.create',
    );
    final managerFile = '${temporary.path}/manager-credential.json';
    await operator.provisionToFile(
      actorId: 'pairing-manager',
      deviceId: 'pairing-manager-host',
      credentialId: 'pairing-manager-credential',
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 10)),
      allowedScopes: [
        {
          'companyId': company,
          'branchId': branch,
          'permissions': [
            identityPairingManagePermission,
            'maintenance.create',
          ],
        },
      ],
      outputPath: managerFile,
    );
    final managerToken =
        (jsonDecode(await PrivateFiles.read(managerFile)) as Map)['token']
            as String;

    await operator.createUser('pairing-target');
    await operator.grant(
      'pairing-target',
      company,
      branch,
      'maintenance.create',
    );
    await operator.createUser('pairing-privileged-target');
    await operator.grant(
      'pairing-privileged-target',
      company,
      branch,
      'maintenance.delete',
    );
    await operator.createUser('pairing-other-branch-target');
    await operator.grant(
      'pairing-other-branch-target',
      company,
      'branch-other',
      'maintenance.create',
    );

    Future<pg.Connection> runtimeConnect() =>
        pg.Connection.openFromUrl(runtimeUrl);
    final diagnostics = ManagementDiagnosticBuffer();
    api = await HostApi.bind(
      authenticator: PersistentTokenAuthenticator(
        connect: runtimeConnect,
        admission: authority,
      ),
      executor: _PairingIntegrationExecutor(),
      identityPairing: PostgresIdentityPairingGateway(
        connectAdministration: () => pg.Connection.openFromUrl(apiAdminUrl),
        admission: authority,
      ),
      diagnostics: diagnostics,
    );

    final created = await send(
      api,
      path: HostManagementRoutes.pairingCreate,
      token: managerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
      },
    );
    check(
      created.status == 201 &&
          created.body['pairing']['deviceRole'] == 'CLIENT',
      'Authorized exact-branch manager receives a short-lived CLIENT pairing code',
    );
    final privilegedTarget = await send(
      api,
      path: HostManagementRoutes.pairingCreate,
      token: managerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-privileged-target',
      },
    );
    check(
      privilegedTarget.status == 403 &&
          privilegedTarget.body['error']['code'] == 'PERMISSION_DENIED',
      'Pairing cannot transfer branch permissions the caller does not hold',
    );
    final otherBranchTarget = await send(
      api,
      path: HostManagementRoutes.pairingCreate,
      token: managerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-other-branch-target',
      },
    );
    check(
      otherBranchTarget.status == 404 &&
          otherBranchTarget.body['error']['code'] ==
              'PAIRING_TARGET_UNAVAILABLE',
      'Pairing actor selection cannot reveal users outside the authorized branch',
    );
    final pairing = created.body['pairing'] as Map<String, dynamic>;
    final code = pairing['code'] as String;
    final pairingId = pairing['pairingId'] as String;
    final storedDigest =
        (await audit.execute(
              pg.Sql.named('''
        SELECT pairing_digest FROM public.ventio_identity_pairings
        WHERE tenant_id=@tenant AND pairing_id=@pairing
      '''),
              parameters: {'tenant': tenant, 'pairing': pairingId},
            )).single[0]
            as String;
    check(
      storedDigest == OpaqueToken.digest(code) && storedDigest != code,
      'Host stores only the pairing-code digest',
    );

    final enrolled = await send(
      api,
      path: HostManagementRoutes.pairingRedeem,
      body: {
        'managementApiVersion': managementApiVersion,
        'code': code,
        'deviceId': 'pairing-target-client',
      },
    );
    check(
      enrolled.status == 201 &&
          enrolled.body['enrollment']['deviceRole'] == 'CLIENT' &&
          enrolled.body['enrollment']['branchId'] == branch,
      'Single-use redemption atomically registers a client credential and exact branch scope',
    );
    final enrollment = enrolled.body['enrollment'] as Map<String, dynamic>;
    final rawCredential = enrollment['credential'] as String;
    final credentialRows = await audit.execute(
      pg.Sql.named('''
        SELECT token_digest,allowed_scopes::text,
          expires_at<=clock_timestamp()+interval '30 days',
          expires_at>clock_timestamp()+interval '29 days'
        FROM public.ventio_identity_credentials
        WHERE tenant_id=@tenant AND credential_id=@credential
      '''),
      parameters: {'tenant': tenant, 'credential': enrollment['credentialId']},
    );
    final credentialRow = credentialRows.single;
    check(
      credentialRow[0] == OpaqueToken.digest(rawCredential) &&
          credentialRow[0] != rawCredential &&
          (credentialRow[1] as String).contains(company) &&
          (credentialRow[1] as String).contains(branch) &&
          !(credentialRow[1] as String).contains(
            identityPairingManagePermission,
          ) &&
          credentialRow[2] == true &&
          credentialRow[3] == true,
      'Enrolled credential is digest-backed, branch-bounded, and capped at 30 days without inheriting pairing permission',
    );
    final deviceRole = (await audit.execute(
      pg.Sql.named('''
        SELECT device_role FROM public.ventio_identity_devices
        WHERE tenant_id=@tenant AND device_id=@device
      '''),
      parameters: {'tenant': tenant, 'device': enrollment['deviceId']},
    )).single[0];
    check(
      deviceRole == 'CLIENT',
      'Database records CLIENT as descriptive device role',
    );

    final authenticated = await send(
      api,
      path: '/api/v1/session',
      method: 'GET',
      token: rawCredential,
    );
    final permissions =
        ((authenticated.body['identity']['scopes'] as List)
                .single['permissions']
            as List);
    check(
      authenticated.status == 200 &&
          permissions.contains('maintenance.create') &&
          !permissions.contains(identityPairingManagePermission),
      'Client authentication preserves target permissions without adding pairing authority',
    );

    final replay = await send(
      api,
      path: HostManagementRoutes.pairingRedeem,
      body: {
        'managementApiVersion': managementApiVersion,
        'code': code,
        'deviceId': 'pairing-target-replay',
      },
    );
    check(
      replay.status == 410 &&
          replay.body['error']['code'] == 'PAIRING_INVALID_OR_EXPIRED',
      'Consumed pairing code cannot be replayed',
    );
    final expiringPairing = await send(
      api,
      path: HostManagementRoutes.pairingCreate,
      token: managerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
      },
    );
    final expiringCode = expiringPairing.body['pairing']['code'] as String;
    final expiringPairingId =
        expiringPairing.body['pairing']['pairingId'] as String;
    await authority.change(migration, (tx) async {
      await tx.execute('SET LOCAL ROLE ventio_owner');
      await tx.execute(
        pg.Sql.named('''
            UPDATE public.ventio_identity_pairings
            SET created_at=transaction_timestamp()-interval '10 minutes',
              expires_at=transaction_timestamp()-interval '5 minutes'
            WHERE tenant_id=@tenant AND pairing_id=@pairing
          '''),
        parameters: {'tenant': tenant, 'pairing': expiringPairingId},
      );
    }, requireAdmissionProof: true);
    final expired = await send(
      api,
      path: HostManagementRoutes.pairingRedeem,
      body: {
        'managementApiVersion': managementApiVersion,
        'code': expiringCode,
        'deviceId': 'pairing-target-expired',
      },
    );
    check(
      expired.status == 410 &&
          expired.body['error']['code'] == 'PAIRING_INVALID_OR_EXPIRED',
      'Expired pairing code cannot be redeemed',
    );
    var rateLimitCreatesSucceeded = 0;
    for (var attempt = 0; attempt < 8; attempt++) {
      final createdWithinLimit = await send(
        api,
        path: HostManagementRoutes.pairingCreate,
        token: managerToken,
        body: {
          'managementApiVersion': managementApiVersion,
          'companyId': company,
          'branchId': branch,
          'actorId': 'pairing-target',
        },
      );
      if (createdWithinLimit.status == 201) rateLimitCreatesSucceeded++;
    }
    final rateLimitedCreate = await send(
      api,
      path: HostManagementRoutes.pairingCreate,
      token: managerToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': company,
        'branchId': branch,
        'actorId': 'pairing-target',
      },
    );
    check(
      rateLimitCreatesSucceeded == 8 &&
          rateLimitedCreate.status == 429 &&
          rateLimitedCreate.headers.value('Retry-After') == '900' &&
          rateLimitedCreate.body['error']['code'] == 'PAIRING_RATE_LIMITED',
      'Host SQL limits pairing issuance to ten per creator, exact branch, and fifteen-minute window',
    );
    final auditDetails = await audit.execute(
      pg.Sql.named('''
        SELECT coalesce(jsonb_agg(details)::text,'[]')
        FROM public.ventio_identity_audit
        WHERE tenant_id=@tenant AND action IN ('PAIRING_CREATED','DEVICE_ENROLLED')
      '''),
      parameters: {'tenant': tenant},
    );
    check(
      !(auditDetails.single[0] as String).contains(code) &&
          !(auditDetails.single[0] as String).contains(rawCredential) &&
          !jsonEncode(
            diagnostics.recent().map((event) => event.toJson()).toList(),
          ).contains(rawCredential),
      'Audit and diagnostics exclude raw pairing and device credentials',
    );
    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    await api?.close();
    await admin.close();
    await migration.close();
    await audit.close();
    await temporary.delete(recursive: true);
  }
}

bool _isDisposableTestDatabase(String? url) =>
    url != null &&
    Uri.parse(url).pathSegments.where((part) => part.isNotEmpty).lastOrNull ==
        'ventio_host_test';
