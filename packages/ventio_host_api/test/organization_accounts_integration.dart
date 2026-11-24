import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';
import 'package:ventio_postgres/ventio_postgres.dart';
import 'test_support.dart';

Future<void> main() async {
  final env = Platform.environment;
  final url = env['VENTIO_TEST_DATABASE_URL'];
  if (url == null ||
      Uri.parse(url).pathSegments.last != 'ventio_host_test' ||
      env['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes')
    throw StateError('Disposable database opt-in required');
  final root = await pg.Connection.openFromUrl(url);
  final admin = await pg.Connection.openFromUrl(
    env['VENTIO_TEST_ADMIN_DATABASE_URL']!,
  );
  final api = await pg.Connection.openFromUrl(
    env['VENTIO_TEST_API_ADMIN_DATABASE_URL']!,
  );
  final runtime = await pg.Connection.openFromUrl(
    env['VENTIO_TEST_RUNTIME_DATABASE_URL']!,
  );
  final temp = await privateAccountTestDirectory();
  final authority = RecoveryAuthority('${temp.path}/authority.json');
  final rootToken = OpaqueToken.generate();
  final initial = InitialHostAdministratorCredential(
    actorId: 'initial-owner',
    token: rootToken,
  );
  final request = OpaqueToken.generate();
  final expiry = DateTime.now().toUtc().add(const Duration(days: 1));
  final identityAdmin = IdentityAdministration(
    connection: admin,
    bootstrapConnection: api,
    tenantId: 'org-a',
    operatorLabel: 'account-test',
    authority: authority,
  );
  final accounts = PostgresAccounts(
    connect: () =>
        pg.Connection.openFromUrl(env['VENTIO_TEST_API_ADMIN_DATABASE_URL']!),
    authority: authority,
  );
  var checks = 0;
  void check(bool condition, String label) {
    if (!condition) throw StateError('FAIL: $label');
    checks++;
    stdout.writeln('PASS: $label');
  }

  Future<T> mutation<T>(
    pg.Connection connection,
    Future<T> Function(pg.TxSession) work,
  ) async {
    late T value;
    await authority.change(connection, (tx) async {
      value = await work(tx);
    }, requireAdmissionProof: true);
    return value;
  }

  Future<Map<String, dynamic>?> snapshot(
    String token, {
    String? company,
    String? branch,
  }) => runtime.runTx((tx) async {
    await authority.admit(tx);
    final raw = (await tx.execute(
      pg.Sql.named(
        'SELECT ventio_security.resolve_identity(@digest,@company,@branch,NULL,NULL,NULL,NULL)::text',
      ),
      parameters: {
        'digest': OpaqueToken.digest(token),
        'company': company,
        'branch': branch,
      },
    )).single[0];
    return raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
  });
  Future<String?> userChange(
    String token,
    Map<String, Object?> change,
  ) => mutation(
    api,
    (tx) async =>
        (await tx.execute(
              pg.Sql.named(
                'SELECT ventio_security.scoped_user_admin_change(@digest,\'company\',\'branch\',CAST(@body AS jsonb))',
              ),
              parameters: {
                'digest': OpaqueToken.digest(token),
                'body': jsonEncode(change),
              },
            )).single[0]
            as String?,
  );
  Future<void> denied(Future<dynamic> Function() action, String label) async {
    var rejected = false;
    try {
      await action();
    } on AccountException {
      rejected = true;
    } on pg.ServerException catch (e) {
      rejected = ['42501', '23505', 'P0002', '22023'].contains(e.code);
    }
    check(rejected, label);
  }

  const password = 'Owner password phrase 42!';
  try {
    await migrationSafety(root, url, temp, check);
    await legacyOwnershipUpgrade(root, url, temp, check);
    await authority.prepareFirstAdministratorBootstrap(
      api,
      requestId: request,
      tenantId: 'org-a',
      actorId: initial.actorId,
      companyId: 'company',
      branchId: 'branch',
      deviceId: 'host-device',
      credentialId: 'host-root',
      token: rootToken,
      expiresAt: expiry,
    );
    await identityAdmin.bootstrapFirstAdministrator(
      companyId: 'company',
      branchId: 'branch',
      deviceId: 'host-device',
      credentialId: 'host-root',
      expiresAt: expiry,
      requestId: request,
      credential: initial,
    );
    check(
      (await snapshot(rootToken))?['isOwner'] == true,
      'Native bootstrap creates the organization Owner',
    );
    await denied(
      () => identityAdmin.bootstrapFirstAdministrator(
        companyId: 'company',
        branchId: 'branch',
        deviceId: 'duplicate',
        credentialId: 'duplicate',
        expiresAt: expiry,
      ),
      'Duplicate Owner bootstrap denied',
    );
    await accounts.handle('manage', rootToken, {
      'action': 'SET_LOGIN',
      'username': 'Owner.A',
      'password': password,
    });
    check(
      await snapshot(rootToken) == null,
      'Password-enabled enrollment credential cannot authorize application requests',
    );
    await denied(
      () => accounts.handle('login', rootToken, {
        'tenantId': 'org-a',
        'username': 'Owner.A',
        'password': 'incorrect phrase',
      }),
      'Wrong password denied',
    );
    final login = await accounts.handle('login', rootToken, {
      'tenantId': 'org-a',
      'username': 'owner.a',
      'password': password,
    });
    var token = login['token'] as String;
    check(
      login['tenantId'] == 'org-a' &&
          !(login.toString().contains('pbkdf2-')) &&
          !(login.toString().contains(password)),
      'Sign-in is case-insensitive, tenant-bound and returns no password verifier',
    );
    check(
      DateTime.parse(
            login['expiresAt'] as String,
          ).difference(DateTime.now().toUtc()) <=
          const Duration(hours: 8),
      'Host session and offline authorization are bounded to eight hours',
    );
    final http = await HostApi.bind(
      authenticator: PersistentTokenAuthenticator(
        connect: () =>
            pg.Connection.openFromUrl(env['VENTIO_TEST_RUNTIME_DATABASE_URL']!),
        admission: authority,
      ),
      executor: _UnusedExecutor(),
      accounts: accounts,
    );
    final wire = HttpClient();
    try {
      final request = await wire.postUrl(
        Uri.parse('http://127.0.0.1:${http.port}/api/v1/accounts/login'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $rootToken');
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'tenantId': 'org-a',
          'username': 'Owner.A',
          'password': password,
        }),
      );
      final response = await request.close();
      final envelope =
          jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      check(
        response.statusCode == 200 &&
            (envelope['account'] as Map)['tenantId'] == 'org-a',
        'Native HTTP account route signs in through authoritative Host services',
      );
      final deniedRequest = await wire.getUrl(
        Uri.parse('http://127.0.0.1:${http.port}/api/v1/session'),
      );
      deniedRequest.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $rootToken',
      );
      final deniedResponse = await deniedRequest.close();
      await deniedResponse.drain<void>();
      check(
        deniedResponse.statusCode == 401,
        'Enrollment-only credentials are rejected by the normal HTTP session route',
      );
    } finally {
      wire.close(force: true);
      await http.close();
    }
    final pairingCode = OpaqueToken.generate();
    final pairingId =
        'pair_${OpaqueToken.digest(OpaqueToken.generate()).substring(0, 32)}';
    await mutation(
      api,
      (tx) => tx.execute(
        pg.Sql.named(
          "SELECT ventio_security.scoped_pairing_create(@digest,'company','branch','initial-owner',@id,@code)",
        ),
        parameters: {
          'digest': OpaqueToken.digest(token),
          'id': pairingId,
          'code': OpaqueToken.digest(pairingCode),
        },
      ),
    );
    final enrolled = await PostgresIdentityPairingGateway(
      connectAdministration: () =>
          pg.Connection.openFromUrl(env['VENTIO_TEST_API_ADMIN_DATABASE_URL']!),
      admission: authority,
    ).redeem(code: pairingCode, deviceId: 'second-owner-client');
    final clientLogin = await accounts.handle(
      'login',
      enrolled['credential'] as String,
      {'tenantId': 'org-a', 'username': 'Owner.A', 'password': password},
    );
    check(
      clientLogin['actorId'] == 'initial-owner' &&
          clientLogin['deviceId'] == 'second-owner-client',
      'The same organization username and password work on an independently enrolled Client',
    );
    final before = (await snapshot(token))!;
    check(
      (before['permissions'] as List).contains('*'),
      'Owner receives unrestricted application permission within their organization',
    );
    await identityAdmin.registerBranch('company', 'future-branch');
    check(
      ((await snapshot(
                token,
                company: 'company',
                branch: 'future-branch',
              ))!['scopeGrants']
              as List)
          .isNotEmpty,
      'Owner authority covers a newly created branch without a new Owner',
    );
    check(
      ((await snapshot(
                token,
                company: 'foreign',
                branch: 'branch',
              ))!['scopeGrants']
              as List)
          .isEmpty,
      'Owner does not invent another organization or unregistered scope',
    );
    final bundle = ExtensionBundle.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(
              await File(
                '../../fixtures/wave1/sync-test-extension.json',
              ).readAsString(),
            )
            as Map,
      ),
    );
    final ownerSession = AuthenticatedSession.persistent(
      Principal(
        tenantId: 'org-a',
        actorId: initial.actorId,
        deviceId: 'host-device',
        companyIds: {'company'},
        branchIds: {'branch'},
        permissions: {'*'},
      ),
      OpaqueToken.digest(token),
    );
    await PostgresExtensionPackageGateway(
      connect: () =>
          pg.Connection.openFromUrl(env['VENTIO_TEST_RUNTIME_DATABASE_URL']!),
      admission: authority,
    ).submit(
      session: ownerSession,
      companyId: 'company',
      branchId: 'branch',
      bundle: bundle,
    );
    final reviewed =
        await PostgresExtensionPackageReviewGateway(
          connect: () => pg.Connection.openFromUrl(
            env['VENTIO_TEST_API_ADMIN_DATABASE_URL']!,
          ),
          admission: authority,
        ).review(
          session: ownerSession,
          companyId: 'company',
          branchId: 'branch',
          moduleId: bundle.moduleId,
          version: bundle.version,
          packageSha256: OpaqueToken.digest(canonicalJson(bundle.toJson())),
          decision: 'APPROVE',
        );
    check(
      reviewed['status'] == 'APPROVED',
      'Owner can submit and approve a new module through existing authoritative package services',
    );
    check(
      ((await snapshot(token))!['permissions'] as List).contains(
        'extension.sync_test.product.read',
      ),
      'A newly approved module immediately inherits Owner access without manual grants',
    );
    final user = (await userChange(token, {'action': 'USER_CREATED'}))!;
    await userChange(token, {
      'action': 'PERMISSION_GRANTED',
      'actorId': user,
      'permission': 'extension.package.read',
    });
    await accounts.handle('manage', token, {
      'action': 'SET_LOGIN',
      'actorId': user,
      'username': 'ordinary',
      'password': 'Ordinary password phrase 42!',
    });
    await identityAdmin.registerDevice(user, 'client-device');
    final provision = '${temp.path}/user.json';
    await identityAdmin.provisionToFile(
      actorId: user,
      deviceId: 'client-device',
      credentialId: 'client-root',
      expiresAt: expiry,
      allowedScopes: [
        {
          'companyId': 'company',
          'branchId': 'branch',
          'permissions': ['extension.package.read'],
        },
      ],
      outputPath: provision,
    );
    final userRoot =
        (jsonDecode(await PrivateFiles.read(provision)) as Map)['token']
            as String;
    final userLogin = await accounts.handle('login', userRoot, {
      'tenantId': 'org-a',
      'username': 'ordinary',
      'password': 'Ordinary password phrase 42!',
    });
    var userToken = userLogin['token'] as String;
    check(
      !((await snapshot(userToken))!['permissions'] as List).contains('*'),
      'Ordinary accounts never inherit Owner authority',
    );
    await denied(
      () => accounts.handle('login', userRoot, {
        'tenantId': 'org-b',
        'username': 'ordinary',
        'password': 'Ordinary password phrase 42!',
      }),
      'Same credentials and device cannot sign into another tenant',
    );
    await denied(
      () => userChange(userToken, {
        'action': 'USER_DISABLED',
        'actorId': initial.actorId,
      }),
      'Ordinary account cannot disable Owner server-side',
    );
    await userChange(token, {
      'action': 'PERMISSION_GRANTED',
      'actorId': user,
      'permission': 'identity.users.manage',
    });
    await denied(
      () => userChange(userToken, {
        'action': 'USER_DISABLED',
        'actorId': initial.actorId,
      }),
      'Delegated administrator cannot disable Owner',
    );
    await denied(
      () => accounts.handle('manage', userToken, {
        'action': 'SET_LOGIN',
        'actorId': initial.actorId,
        'username': 'stolen',
        'password': 'Another long password phrase',
      }),
      'Delegated administrator cannot reset Owner credentials',
    );
    await userChange(token, {
      'action': 'PERMISSION_GRANTED',
      'actorId': user,
      'permission': 'identity.devices.manage',
    });
    await denied(
      () => mutation(
        api,
        (tx) => tx.execute(
          pg.Sql.named(
            "SELECT ventio_security.scoped_device_revoke(@digest,'company','branch','host-device')",
          ),
          parameters: {'digest': OpaqueToken.digest(userToken)},
        ),
      ),
      'Delegated administrators cannot revoke Owner devices to lock out the Owner',
    );
    await denied(
      () => runtime.execute("SELECT ventio_security.local_owner_recover('{}')"),
      'Runtime credentials cannot invoke protected local Owner recovery',
    );
    await denied(
      () => userChange(userToken, {
        'action': 'PERMISSION_GRANTED',
        'actorId': user,
        'permission': 'identity.roles.manage',
      }),
      'Delegated administrator cannot grant additional administrative authority',
    );
    await denied(
      () => mutation(
        admin,
        (tx) => tx.execute(
          "SELECT ventio_security.admin_change('{\"tenantId\":\"org-a\",\"operatorLabel\":\"test\",\"action\":\"USER_DISABLED\",\"actorId\":\"initial-owner\"}')",
        ),
      ),
      'Trusted broad administration also preserves Owner',
    );
    await denied(
      () => mutation(
        root,
        (tx) => tx.execute(
          "DELETE FROM ventio_identity_users WHERE tenant_id='org-a' AND is_owner",
        ),
      ),
      'Database trigger prevents deletion of the Owner',
    );
    await denied(
      () => mutation(
        root,
        (tx) => tx.execute(
          "UPDATE ventio_identity_users SET is_owner=false WHERE tenant_id='org-a' AND is_owner",
        ),
      ),
      'Database trigger prevents demotion of the Owner',
    );
    await accounts.handle('manage', token, {
      'action': 'SET_ORGANIZATION_ACCESS',
      'actorId': user,
      'enabled': true,
    });
    check(
      ((await snapshot(
                userToken,
                company: 'company',
                branch: 'future-branch',
              ))!['scopeGrants']
              as List)
          .isNotEmpty,
      'Organization-wide account permissions cover future branches',
    );
    await accounts.handle('manage', token, {
      'action': 'SET_ORGANIZATION_ACCESS',
      'actorId': user,
      'enabled': false,
    });
    check(
      ((await snapshot(
                userToken,
                company: 'company',
                branch: 'future-branch',
              ))!['scopeGrants']
              as List)
          .isEmpty,
      'Removing organization-wide access restores exact branch limits',
    );
    await userChange(token, {
      'action': 'PERMISSION_REVOKED',
      'actorId': user,
      'permission': 'extension.package.read',
    });
    check(
      !((await snapshot(userToken))!['permissions'] as List).contains(
        'extension.package.read',
      ),
      'Permission revocation affects existing sessions immediately',
    );
    Future<void> roleChange(Map<String, Object?> change) => mutation(api, (
      tx,
    ) async {
      await tx.execute(
        pg.Sql.named(
          "SELECT ventio_security.scoped_admin_change(@digest,'company','branch',CAST(@body AS jsonb))",
        ),
        parameters: {
          'digest': OpaqueToken.digest(token),
          'body': jsonEncode({
            ...change,
            if (['ROLE_ASSIGNED', 'ROLE_UNASSIGNED'].contains(change['action']))
              'companyId': 'company',
            if (['ROLE_ASSIGNED', 'ROLE_UNASSIGNED'].contains(change['action']))
              'branchId': 'branch',
          }),
        },
      );
    });
    for (final role in ['readers', 'creators']) {
      await roleChange({
        'action': 'ROLE_CREATED',
        'roleId': role,
        'displayName': role,
      });
      await roleChange({
        'action': 'ROLE_PERMISSION_GRANTED',
        'roleId': role,
        'permission': role == 'readers'
            ? 'extension.sync_test.product.read'
            : 'extension.sync_test.product.create',
      });
      await roleChange({
        'action': 'ROLE_ASSIGNED',
        'actorId': user,
        'roleId': role,
      });
    }
    var grouped = (await snapshot(userToken))!;
    check(
      (grouped['roles'] as List).length == 2 &&
          (grouped['permissions'] as List).contains(
            'extension.sync_test.product.read',
          ) &&
          (grouped['permissions'] as List).contains(
            'extension.sync_test.product.create',
          ),
      'Owner creates and assigns multiple permission groups through the existing role API',
    );
    await roleChange({
      'action': 'ROLE_UNASSIGNED',
      'actorId': user,
      'roleId': 'readers',
    });
    grouped = (await snapshot(userToken))!;
    check(
      (grouped['roles'] as List).length == 1 &&
          !(grouped['permissions'] as List).contains(
            'extension.sync_test.product.read',
          ),
      'Removing one group revokes its effective permissions without removing other groups',
    );
    await mutation(
      root,
      (tx) => tx.execute(
        "UPDATE ventio_wave2_branches SET archived=true WHERE tenant_id='org-a' AND company_id='company' AND branch_id='branch'",
      ),
    );
    check(
      ((await snapshot(token))!['permissions'] as List).contains(
        'platform.organizations.manage',
      ),
      'Owner retains organization management authority when a branch is archived',
    );
    await mutation(
      root,
      (tx) => tx.execute(
        "UPDATE ventio_wave2_branches SET archived=false WHERE tenant_id='org-a' AND company_id='company' AND branch_id='branch'",
      ),
    );
    final renewalId =
        'reissue_${OpaqueToken.digest(OpaqueToken.generate()).substring(0, 32)}';
    final prepared =
        await TrustedCredentialReissueGateway(
          connection: api,
          tenantId: 'org-a',
          authority: authority,
          windowsAdminTag: '0123456789abcdef',
        ).prepare(
          operatorCredentialDigest: OpaqueToken.digest(token),
          operatorActorId: initial.actorId,
          companyId: 'company',
          branchId: 'branch',
          deviceId: 'client-device',
          targetActorId: user,
          sourceCredentialId: 'client-root',
          operationId: renewalId,
          permissions: [
            'extension.sync_test.product.create',
            'identity.users.manage',
            'identity.devices.manage',
          ],
          approvedRemovals: [],
        );
    final liveSession = (await PersistentTokenAuthenticator(
      connect: () =>
          pg.Connection.openFromUrl(env['VENTIO_TEST_RUNTIME_DATABASE_URL']!),
      admission: authority,
    ).authenticate(userToken))!;
    final renewals = IdentityCredentialReissueGateway(
      connectApi: () =>
          pg.Connection.openFromUrl(env['VENTIO_TEST_API_ADMIN_DATABASE_URL']!),
      apiPool: null,
      authority: authority,
    );
    final claimed = await renewals.claim(
      session: liveSession,
      operationId: renewalId,
    );
    final finalized = await renewals.acknowledge(
      replacementToken: claimed['credential'] as String,
      operationId: renewalId,
    );
    check(
      prepared['state'] == 'PREPARED' &&
          finalized['state'] == 'FINALIZED' &&
          await snapshot(userToken) == null,
      'A password session can claim a protected same-device enrollment renewal, which revokes the old parent',
    );
    final afterRenewal = await accounts
        .handle('login', claimed['credential'] as String, {
          'tenantId': 'org-a',
          'username': 'ordinary',
          'password': 'Ordinary password phrase 42!',
        });
    userToken = afterRenewal['token'] as String;
    check(
      afterRenewal['actorId'] == user &&
          afterRenewal['deviceId'] == 'client-device',
      'Renewed credentials accept the same password and preserve the actor/device identity used by pending commands',
    );
    await accounts.handle('manage', token, {
      'action': 'REVOKE_SESSIONS',
      'actorId': user,
    });
    check(
      await snapshot(userToken) == null,
      'Session revocation is authoritative in the Host database',
    );
    // Seed a legacy organization without granting ownership, then explicitly migrate it.
    final legacy = IdentityAdministration(
      connection: admin,
      tenantId: 'org-b',
      operatorLabel: 'legacy-fixture',
      authority: authority,
    );
    await legacy.createUser('legacy-admin');
    await legacy.registerBranch('company', 'branch');
    check(
      (await root.execute(
            "SELECT is_owner FROM ventio_identity_users WHERE tenant_id='org-b'",
          )).single[0] ==
          false,
      'Additive upgrade does not silently promote existing administrators',
    );
    final hash = await AccountPassword.hash(password);
    Future<Map<String, dynamic>> local(
      String mode, {
      String tenant = 'org-b',
    }) => mutation(api, (tx) async {
      final result = await tx.execute(
        pg.Sql.named(
          'SELECT ventio_security.local_owner_recover(CAST(@body AS jsonb))::text',
        ),
        parameters: {
          'body': jsonEncode({
            'mode': mode,
            'tenantId': tenant,
            if (mode == 'INITIALIZE') 'companyId': 'company',
            if (mode == 'INITIALIZE') 'branchId': 'branch',
            'actorId': 'legacy-admin',
            'username': 'Owner.B',
            'passwordHash': hash,
            'windowsAdminTag': 'a' * 16,
            'windowsAdminSid': 'S-1-5-21-111-222-333-1000',
            'tokenDigest': OpaqueToken.digest(OpaqueToken.generate()),
            'credentialId':
                'pair_${OpaqueToken.digest(OpaqueToken.generate()).substring(0, 32)}',
          }),
        },
      );
      return Map<String, dynamic>.from(
        jsonDecode(result.single[0] as String) as Map,
      );
    });
    final migrated = await local('MIGRATE');
    check(
      migrated['actorId'] == 'legacy-admin' &&
          (await root.execute(
                "SELECT count(*) FROM ventio_identity_users WHERE tenant_id='org-b'",
              )).single[0] ==
              1,
      'Explicit Owner migration preserves the existing account and organization',
    );
    await denied(
      () => local('MIGRATE'),
      'A populated owned organization cannot acquire another Owner',
    );
    final unowned = IdentityAdministration(
      connection: admin,
      tenantId: 'org-c',
      operatorLabel: 'legacy-fixture',
      authority: authority,
    );
    await unowned.registerBranch('company', 'branch');
    final bootstrapped = await local('BOOTSTRAP', tenant: 'org-c');
    check(
      bootstrapped['tenantId'] == 'org-c' &&
          (await root.execute(
                "SELECT count(*) FROM ventio_identity_branches WHERE tenant_id='org-c'",
              )).single[0] ==
              1,
      'Explicit bootstrap creates an independent Owner for an existing unowned organization without replacing branches',
    );
    final initialized = await local('INITIALIZE', tenant: 'org-d');
    check(
      initialized['tenantId'] == 'org-d' &&
          (await root.execute(
                "SELECT count(*) FROM ventio_identity_users WHERE tenant_id='org-d' AND is_owner",
              )).single[0] ==
              1,
      'Protected local initialization creates exactly one Owner for a new organization',
    );
    await denied(
      () => local('INITIALIZE', tenant: 'org-d'),
      'Repeating organization initialization cannot create a duplicate Owner',
    );
    await local('RECOVER');
    check(
      (await root.execute(
            "SELECT count(*) FROM ventio_identity_audit WHERE tenant_id='org-b' AND action='OWNER_RECOVER'",
          )).single[0] ==
          1,
      'Local Owner recovery is protected by admission and records a durable audit event',
    );
    await denied(
      () => accounts.handle('manage', token, {
        'action': 'SET_LOGIN',
        'actorId': 'legacy-admin',
        'username': 'foreign',
        'password': password,
      }),
      'Owner cannot manage another organization’s account',
    );
    await accounts.handle('manage', token, {
      'action': 'SET_LOGIN',
      'username': 'Owner.A2',
      'currentPassword': password,
      'password': 'New Owner password phrase 43!',
    });
    check(
      await snapshot(token) == null,
      'Changing Owner password invalidates its existing sessions',
    );
    final renewed = await accounts.handle('login', rootToken, {
      'tenantId': 'org-a',
      'username': 'Owner.A2',
      'password': 'New Owner password phrase 43!',
    });
    token = renewed['token'] as String;
    await identityAdmin.revokeDevice('host-device');
    check(
      await snapshot(token) == null,
      'Device revocation invalidates password sessions through their enrollment parent',
    );
    check(
      (await root.execute(
            "SELECT count(*) FROM ventio_identity_users WHERE is_owner",
          )).single[0] ==
          4,
      'Organizations retain independent Owners; branches do not create Owners',
    );
    final stored =
        (await root.execute(
              "SELECT password_hash FROM ventio_identity_users WHERE tenant_id='org-a' AND is_owner",
            )).single[0]
            as String;
    check(
      AccountPassword.validVerifier(stored) && !stored.contains(password),
      'Host stores only salted, versioned PBKDF2 password verifiers',
    );
    stdout.writeln(
      'RESULT: $checks targeted organization account checks passed',
    );
  } finally {
    await runtime.close();
    await api.close();
    await admin.close();
    await root.close();
    await temp.delete(recursive: true);
  }
}

Future<void> migrationSafety(
  pg.Connection root,
  String url,
  Directory temp,
  void Function(bool, String) check,
) async {
  final name =
      'ventio_account_upgrade_${DateTime.now().microsecondsSinceEpoch}';
  if (!RegExp(r'^ventio_account_upgrade_[0-9]+$').hasMatch(name))
    throw StateError('Unsafe fixture name');
  await root.execute('CREATE DATABASE $name');
  pg.Connection? database;
  try {
    database = await pg.Connection.openFromUrl(
      Uri.parse(url).replace(path: '/$name').toString(),
    );
    final baseline = await Directory(
      '${temp.path}/baseline-migrations',
    ).create();
    final source = Directory('../../migrations/postgres');
    await for (final file in source.list()) {
      if (file is File &&
          file.path.endsWith('.sql') &&
          int.parse(file.uri.pathSegments.last.substring(0, 3)) <= 41) {
        await file.copy('${baseline.path}/${file.uri.pathSegments.last}');
      }
    }
    await PostgresMigrationRunner(database, baseline).apply();
    await database.execute(
      "INSERT INTO ventio_identity_users(tenant_id,actor_id) VALUES('legacy-org','legacy-user')",
    );
    await database.execute(
      "INSERT INTO ventio_identity_devices(tenant_id,actor_id,device_id) VALUES('legacy-org','legacy-user','legacy-device')",
    );
    await database.execute(
      "INSERT INTO ventio_identity_branches(tenant_id,company_id,branch_id) VALUES('legacy-org','company','branch')",
    );
    await database.execute(
      "INSERT INTO ventio_identity_credentials(token_digest,tenant_id,credential_id,actor_id,device_id,expires_at) VALUES(repeat('a',64),'legacy-org','legacy-credential','legacy-user','legacy-device',clock_timestamp()+interval '1 day')",
    );
    await database.execute(
      "INSERT INTO ventio_records(tenant_id,company_id,branch_id,doc_type,record_id,revision,record_data) VALUES('legacy-org','company','branch','Retained','retained',1,'{\"preserved\":true}')",
    );
    await database.execute(
      "INSERT INTO ventio_command_journal(tenant_id,command_id,company_id,branch_id,actor_id,device_id,fingerprint,receipt) VALUES('legacy-org','retained-command','company','branch','legacy-user','legacy-device','retained','{}')",
    );
    await database.execute(
      "INSERT INTO ventio_extension_packages(tenant_id,module_id,version,package_sha256,package_json,submitted_by,submitted_company_id,submitted_branch_id) VALUES('legacy-org','retained.module','1.0.0',repeat('b',64),'{\"manifest\":{\"moduleId\":\"retained.module\",\"version\":\"1.0.0\"}}','legacy-user','company','branch')",
    );
    final before = <String, String>{};
    const tables = [
      'ventio_identity_users',
      'ventio_identity_credentials',
      'ventio_identity_devices',
      'ventio_identity_branches',
      'ventio_records',
      'ventio_command_journal',
      'ventio_extension_packages',
    ];
    const added =
        "ARRAY['is_owner','username','password_hash','password_version','organization_wide','login_failures','login_locked_until','login_parent_id','login_password_version']";
    for (final table in tables) {
      before[table] =
          (await database.execute(
                'SELECT jsonb_agg(to_jsonb(t)-$added)::text FROM $table t',
              )).single[0]
              as String;
    }
    final applied = await PostgresMigrationRunner(database, source).apply();
    check(
      applied.length == 1 && applied.single == '042_organization_accounts.sql',
      'Upgrade applies only the new additive account migration',
    );
    for (final table in tables) {
      final after = (await database.execute(
        'SELECT jsonb_agg(to_jsonb(t)-$added)::text FROM $table t',
      )).single[0];
      check(
        before[table] == after,
        'Upgrade preserves existing $table rows byte-for-byte in their original columns',
      );
    }
    check(
      (await database.execute(
            "SELECT is_owner=false AND username IS NULL AND password_hash IS NULL FROM ventio_identity_users WHERE tenant_id='legacy-org'",
          )).single[0] ==
          true,
      'Legacy accounts require explicit migration; no implicit ownership or password',
    );
    check(
      (await PostgresMigrationRunner(database, source).apply()).isEmpty,
      'Repeating the additive migration is a safe no-op',
    );
  } finally {
    await database?.close();
    await root.execute('DROP DATABASE $name');
  }
}

Future<Directory> privateAccountTestDirectory() async {
  final base = Platform.environment['RUNNER_TEMP'];
  if (base == null || !Directory(base).isAbsolute)
    throw StateError('Disposable runner required');
  final directory = await Directory(
    '$base/account-witness-${DateTime.now().microsecondsSinceEpoch}',
  ).create();
  final sid = await currentWindowsSid();
  final acl = await Process.run('icacls.exe', [
    directory.path,
    '/inheritance:r',
    '/grant:r',
    '*$sid:(OI)(CI)F',
    '*S-1-5-18:(OI)(CI)F',
    '*S-1-5-32-544:(OI)(CI)F',
  ]);
  if (acl.exitCode != 0) throw StateError('Private fixture ACL failed');
  final owner = await Process.run('icacls.exe', [
    directory.path,
    '/setowner',
    '*$sid',
  ]);
  if (owner.exitCode != 0) throw StateError('Private fixture ownership failed');
  return directory;
}

class _UnusedExecutor implements CommandExecutor {
  @override
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session,
  ) async =>
      throw StateError('Business commands are outside this targeted test');
}

Future<void> legacyOwnershipUpgrade(
  pg.Connection root,
  String url,
  Directory temp,
  void Function(bool, String) check,
) async {
  final name = 'ventio_owner_legacy_${DateTime.now().microsecondsSinceEpoch}';
  if (!RegExp(r'^ventio_owner_legacy_[0-9]+$').hasMatch(name))
    throw StateError('Unsafe fixture');
  await root.execute('CREATE DATABASE $name');
  pg.Connection? database;
  try {
    database = await pg.Connection.openFromUrl(
      Uri.parse(url).replace(path: '/$name').toString(),
    );
    final staged = await Directory(
      '${temp.path}/legacy-owner-migrations',
    ).create();
    await for (final file in Directory('../../migrations/postgres').list()) {
      if (file is File &&
          file.path.endsWith('.sql') &&
          int.parse(file.uri.pathSegments.last.substring(0, 3)) <= 36) {
        await file.copy('${staged.path}/${file.uri.pathSegments.last}');
      }
    }
    await PostgresMigrationRunner(database, staged).apply();
    await database.execute(
      "INSERT INTO ventio_identity_users(tenant_id,actor_id) VALUES('retained-org','retained-owner')",
    );
    await database.execute(
      "INSERT INTO ventio_identity_branches(tenant_id,company_id,branch_id) VALUES('retained-org','company','branch')",
    );
    await database.execute(
      "INSERT INTO ventio_identity_audit(tenant_id,operator_label,action,subject_id,details) VALUES('retained-org','fixture','INITIAL_ADMIN_BOOTSTRAPPED','retained-owner','{}')",
    );
    await database.execute(
      "INSERT INTO ventio_records(tenant_id,company_id,branch_id,doc_type,record_id,revision,record_data) VALUES('retained-org','company','branch','Retained','original',1,'{\"retained\":true}')",
    );
    await for (final file in Directory(
      '../../fixtures/organization-accounts/legacy_migrations',
    ).list()) {
      if (file is File) {
        await file.copy('${staged.path}/${file.uri.pathSegments.last}');
      }
    }
    await PostgresMigrationRunner(database, staged).apply();
    check(
      (await database.execute(
            "SELECT is_owner FROM ventio_identity_users WHERE tenant_id='retained-org'",
          )).single[0] ==
          true,
      'Fixture reproduces the published pre-Wave-2 Owner schema',
    );
    final before = (await database.execute(
      'SELECT jsonb_agg(to_jsonb(t))::text FROM ventio_records t',
    )).single[0];
    final previous = (await database.execute(
      "SELECT jsonb_agg(to_jsonb(t) ORDER BY name)::text FROM ventio_schema_migrations t WHERE name IN ('037_extension_submitter_review.sql','038_initial_account_owner.sql')",
    )).single[0];
    final applied = await PostgresMigrationRunner(
      database,
      Directory('../../migrations/postgres'),
    ).apply();
    check(
      applied.length == 6 && applied.last == '042_organization_accounts.sql',
      'Reviewed legacy Owner chain bridges to the current Wave 2 migrations',
    );
    check(
      (await database.execute(
            "SELECT jsonb_agg(to_jsonb(t) ORDER BY name)::text FROM ventio_schema_migrations t WHERE name IN ('037_extension_submitter_review.sql','038_initial_account_owner.sql')",
          )).single[0] ==
          previous,
      'Legacy migration names, checksums and applied timestamps remain unchanged',
    );
    check(
      (await database.execute(
                'SELECT jsonb_agg(to_jsonb(t))::text FROM ventio_records t',
              )).single[0] ==
              before &&
          (await database.execute(
                "SELECT is_owner AND username IS NULL FROM ventio_identity_users WHERE tenant_id='retained-org' AND actor_id='retained-owner'",
              )).single[0] ==
              true,
      'Legacy upgrade preserves the original Owner and business data; password selection remains explicit',
    );
    final bin = Platform.environment['VENTIO_TEST_POSTGRES_BIN_DIR']!;
    final port = Uri.parse(url).port;
    final contracts = await Process.run(
      '$bin/psql.exe',
      [
        '-X',
        '-w',
        '-h',
        '127.0.0.1',
        '-p',
        '$port',
        '-U',
        'ventio',
        '-d',
        name,
        '-v',
        'ON_ERROR_STOP=1',
        '-v',
        'expected_database=$name',
        '-f',
        '../../security/postgres/bootstrap.sql',
      ],
      environment: {'PGPASSWORD': 'ventio_test_only'},
    );
    if (contracts.exitCode != 0)
      throw StateError('Legacy security refresh failed: ${contracts.stderr}');
    await database.execute('SELECT ventio_security.assert_schema()');
    check(
      true,
      'Refreshed schema contract accepts only the reviewed retained legacy ledger',
    );
    await database.execute(
      "UPDATE ventio_schema_migrations SET sha256=repeat('0',64) WHERE name='037_extension_submitter_review.sql'",
    );
    var refused = false;
    try {
      await PostgresMigrationRunner(
        database,
        Directory('../../migrations/postgres'),
      ).apply();
    } on StateError {
      refused = true;
    }
    check(
      refused,
      'An unrecognized legacy migration checksum is refused without adopting that schema',
    );
  } finally {
    await database?.close();
    await root.execute('DROP DATABASE $name');
  }
}
