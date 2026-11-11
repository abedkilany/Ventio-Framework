import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart';

Future<void> main() async {
  final adminUrl = Platform.environment['VENTIO_TEST_ADMIN_DATABASE_URL'];
  final apiUrl = Platform.environment['VENTIO_TEST_API_ADMIN_DATABASE_URL'];
  final auditUrl = Platform.environment['VENTIO_TEST_DATABASE_URL'];
  if (adminUrl == null ||
      apiUrl == null ||
      auditUrl == null ||
      Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
      Uri.parse(
            adminUrl,
          ).pathSegments.where((part) => part.isNotEmpty).lastOrNull !=
          'ventio_host_test') {
    stderr.writeln(
      'First-administrator bootstrap integration requires the disposable ventio_host_test database and explicit test opt-in.',
    );
    exitCode = 2;
    return;
  }

  final admin = await pg.Connection.openFromUrl(adminUrl);
  final api = await pg.Connection.openFromUrl(apiUrl);
  final audit = await pg.Connection.openFromUrl(auditUrl);
  final temporary = await createPrivateTestDirectory('ventio-first-admin-');
  final witnessPath =
      '${temporary.path}${Platform.pathSeparator}authority.json';
  final tenant = 'first-admin-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  const company = 'initial-company';
  const branch = 'initial-branch';
  const device = 'initial-device';
  const credentialId = 'initial-credential';
  final requestId = OpaqueToken.generate();
  final credential = InitialHostAdministratorCredential(
    actorId: 'usr_${OpaqueToken.generate()}',
    token: OpaqueToken.generate(),
  );
  final expiresAt = DateTime.now().toUtc().add(const Duration(days: 1));
  var assertions = 0;
  void check(bool condition, String label) {
    if (!condition) throw StateError('FAIL: $label');
    assertions++;
    stdout.writeln('PASS: $label');
  }

  try {
    var uninitializedBootstrapDenied = false;
    try {
      await api.execute(
        "SELECT ventio_security.bootstrap_first_admin('{}'::jsonb)",
      );
    } on pg.ServerException catch (error) {
      uninitializedBootstrapDenied = error.code == '28000';
    }
    check(
      uninitializedBootstrapDenied,
      'Identity API cannot bootstrap an administrator before Recovery Authority initialization',
    );

    final authority = RecoveryAuthority(witnessPath);
    await authority.prepareFirstAdministratorBootstrap(
      api,
      requestId: requestId,
      tenantId: tenant,
      actorId: credential.actorId,
      companyId: company,
      branchId: branch,
      deviceId: device,
      credentialId: credentialId,
      token: credential.token,
      expiresAt: expiresAt,
    );
    final witness =
        jsonDecode(await File(witnessPath).readAsString())
            as Map<String, dynamic>;
    final authorityId = witness['authorityId'] as String;
    check(
      witness['pending'] == false && witness['fingerprint'] is String,
      'First-install Recovery Authority is durably initialized from an empty Host database',
    );

    await api.execute(
      pg.Sql.named(
        'SELECT ventio_security.initialize_first_host_recovery(@authority)',
      ),
      parameters: {'authority': authorityId},
    );
    check(
      true,
      'Repeating first-install recovery initialization with the same authority is idempotent',
    );

    var differentAuthorityDenied = false;
    try {
      await api.execute(
        pg.Sql.named(
          'SELECT ventio_security.initialize_first_host_recovery(@authority)',
        ),
        parameters: {'authority': OpaqueToken.generate()},
      );
    } on pg.ServerException catch (error) {
      differentAuthorityDenied = error.code == '42501';
    }
    check(
      differentAuthorityDenied,
      'A different Recovery Authority cannot take over first-install state',
    );

    final crashingAuthority = RecoveryAuthority(
      witnessPath,
      testBarrier: (step) {
        if (step == 'after_commit')
          throw StateError(
            'Simulated process interruption after database commit',
          );
      },
    );
    final administration = IdentityAdministration(
      connection: admin,
      bootstrapConnection: api,
      tenantId: tenant,
      operatorLabel: 'first-admin-bootstrap-test',
      authority: crashingAuthority,
    );
    var postCommitInterruptionObserved = false;
    try {
      await administration.bootstrapFirstAdministrator(
        companyId: company,
        branchId: branch,
        deviceId: device,
        credentialId: credentialId,
        expiresAt: expiresAt,
        requestId: requestId,
        credential: credential,
      );
    } on RecoveryMutationOutcomeUnknown {
      postCommitInterruptionObserved = true;
    } on StateError {
      postCommitInterruptionObserved = true;
    }
    check(
      postCommitInterruptionObserved,
      'The test interrupted the process after database commit and before witness completion',
    );
    final pendingWitness =
        jsonDecode(await File(witnessPath).readAsString())
            as Map<String, dynamic>;
    check(
      pendingWitness['pending'] == true,
      'A post-commit interruption leaves Recovery Authority admission closed',
    );

    await authority.prepareFirstAdministratorBootstrap(
      api,
      requestId: requestId,
      tenantId: tenant,
      actorId: credential.actorId,
      companyId: company,
      branchId: branch,
      deviceId: device,
      credentialId: credentialId,
      token: credential.token,
      expiresAt: expiresAt,
    );
    final reconciledWitness =
        jsonDecode(await File(witnessPath).readAsString())
            as Map<String, dynamic>;
    check(
      reconciledWitness['pending'] == false,
      'A retry reconciles only the exact receipt-backed first-administrator transaction',
    );

    final readyAdministration = IdentityAdministration(
      connection: admin,
      bootstrapConnection: api,
      tenantId: tenant,
      operatorLabel: 'first-admin-bootstrap-test',
      authority: authority,
    );
    final replay = await readyAdministration.bootstrapFirstAdministrator(
      companyId: company,
      branchId: branch,
      deviceId: device,
      credentialId: credentialId,
      expiresAt: expiresAt,
      requestId: requestId,
      credential: credential,
    );
    check(
      replay.actorId == credential.actorId && replay.token == credential.token,
      'The exact bootstrap request replays without creating a second credential',
    );

    var differentRequestDenied = false;
    try {
      await readyAdministration.bootstrapFirstAdministrator(
        companyId: company,
        branchId: branch,
        deviceId: device,
        credentialId: credentialId,
        expiresAt: expiresAt,
        requestId: OpaqueToken.generate(),
        credential: credential,
      );
    } on pg.ServerException catch (error) {
      differentRequestDenied = error.code == '42501';
    }
    check(
      differentRequestDenied,
      'A different first-administrator request cannot replace the durable receipt',
    );

    final otherTenant = IdentityAdministration(
      connection: admin,
      bootstrapConnection: api,
      tenantId: '$tenant-other',
      operatorLabel: 'first-admin-bootstrap-test',
      authority: authority,
    );
    var secondTenantDenied = false;
    try {
      await otherTenant.bootstrapFirstAdministrator(
        companyId: company,
        branchId: branch,
        deviceId: 'other-device',
        credentialId: 'other-credential',
        expiresAt: expiresAt,
        requestId: OpaqueToken.generate(),
      );
    } on pg.ServerException catch (error) {
      secondTenantDenied = error.code == '42501';
    }
    check(
      secondTenantDenied,
      'A second tenant cannot create another first administrator on the same Host',
    );

    final receipt = await audit.execute(
      pg.Sql.named('''
        SELECT count(*)::integer FROM public.ventio_identity_users
        WHERE tenant_id=@tenant
      '''),
      parameters: {'tenant': tenant},
    );
    check(
      receipt.single[0] == 1,
      'First-administrator bootstrap leaves exactly one initial identity',
    );
    final initialCredential = await audit.execute(
      pg.Sql.named('''
        SELECT allowed_scopes FROM public.ventio_identity_credentials
        WHERE tenant_id=@tenant AND credential_id=@credential
      '''),
      parameters: {'tenant': tenant, 'credential': credentialId},
    );
    final rawInitialScopes = initialCredential.single[0];
    final initialScopes = rawInitialScopes is List
        ? rawInitialScopes
        : const <dynamic>[];
    final initialScope =
        initialScopes.length == 1 && initialScopes.single is Map
        ? Map<String, dynamic>.from(initialScopes.single as Map)
        : const <String, dynamic>{};
    final initialPermissions = initialScope['permissions'];
    check(
      rawInitialScopes is List &&
          initialScopes.length == 1 &&
          initialScope['companyId'] == company &&
          initialScope['branchId'] == branch &&
          initialPermissions is List &&
          initialPermissions.toSet().containsAll(const {
            'host.status.read',
            'host.diagnostics.read',
            'identity.users.manage',
            'identity.devices.manage',
            'identity.pairing.manage',
            'identity.roles.manage',
          }) &&
          initialPermissions.length == 6 &&
          !initialPermissions.contains('extension.package.read') &&
          !initialPermissions.contains('extension.package.submit'),
      'Fresh first administrator receives only the initial six exact-branch management permissions in grants and credential ceiling',
    );
    final initialCredentialDigest = (await audit.execute(
      pg.Sql.named('''
        SELECT c.token_digest,c.allowed_scopes::text,d.revoked_at
        FROM public.ventio_identity_credentials c
        JOIN public.ventio_identity_devices d
          ON d.tenant_id=c.tenant_id AND d.actor_id=c.actor_id
          AND d.device_id=c.device_id
        WHERE c.tenant_id=@tenant AND c.credential_id=@credential
      '''),
      parameters: {'tenant': tenant, 'credential': credentialId},
    )).single;
    final migrationUrl =
        Platform.environment['VENTIO_TEST_MIGRATION_DATABASE_URL'];
    final postgresBin = Platform.environment['VENTIO_TEST_POSTGRES_BIN_DIR'];
    if (migrationUrl == null || postgresBin == null) {
      throw StateError('The disposable database upgrade contract is missing.');
    }
    final migrationUri = Uri.parse(migrationUrl);
    final migrationCredentials = Uri.decodeComponent(migrationUri.userInfo);
    final credentialSeparator = migrationCredentials.indexOf(':');
    if (credentialSeparator < 1 || migrationUri.pathSegments.isEmpty) {
      throw StateError('The disposable database upgrade contract is invalid.');
    }
    final psql = Platform.isWindows
        ? '$postgresBin\\psql.exe'
        : '$postgresBin/psql';
    final securityContracts = [
      ('pairing', '../../security/postgres/pairing.sql'),
      ('credential reissue', '../../security/postgres/credential_reissues.sql'),
      ('schema profile', '../../security/postgres/schema_profile.sql'),
    ];
    final processEnvironment = Map<String, String>.from(
      Platform.environment,
    )..['PGPASSWORD'] = migrationCredentials.substring(credentialSeparator + 1);
    for (final (name, contract) in securityContracts) {
      final contractUpgrade = await Process.run(
        psql,
        [
          '-X',
          '-w',
          '-h',
          migrationUri.host,
          '-p',
          '${migrationUri.port}',
          '-U',
          migrationCredentials.substring(0, credentialSeparator),
          '-d',
          migrationUri.pathSegments.last,
          '-v',
          'ON_ERROR_STOP=1',
          '-c',
          'SET ROLE ventio_owner',
          '-f',
          contract,
        ],
        environment: processEnvironment,
        runInShell: false,
      );
      check(
        contractUpgrade.exitCode == 0,
        'Reviewed $name contract reapplies idempotently over a legacy-style first administrator',
      );
    }
    final credentialReissueContract = await audit.execute('''
      SELECT
        has_function_privilege('ventio_identity_api',
          'ventio_security.trusted_windows_credential_reissue_prepare(text,text,text,text,text,text,text,text,text,text,text,bytea,text[],text[],text)',
          'EXECUTE'),
        NOT has_function_privilege('ventio_runtime',
          'ventio_security.trusted_windows_credential_reissue_prepare(text,text,text,text,text,text,text,text,text,text,text,bytea,text[],text[],text)',
          'EXECUTE'),
        has_function_privilege('ventio_identity_api',
          'ventio_security.credential_reissue_claim(text,text)', 'EXECUTE'),
        has_function_privilege('ventio_identity_api',
          'ventio_security.credential_reissue_pending_claim(text)', 'EXECUTE'),
        has_function_privilege('ventio_identity_api',
          'ventio_security.credential_reissue_finalize(text,text)', 'EXECUTE'),
        has_function_privilege('ventio_identity_api',
          'ventio_security.assert_schema()', 'EXECUTE'),
        (SELECT relrowsecurity AND relforcerowsecurity
          FROM pg_class
          WHERE oid='public.ventio_identity_credential_reissues'::regclass),
        (SELECT count(*)=2 FROM pg_trigger
          WHERE tgrelid='public.ventio_identity_credential_reissues'::regclass
            AND NOT tgisinternal
            AND tgname IN ('ventio_recovery_lock','ventio_recovery_mark'))
    ''');
    check(
      credentialReissueContract.single.toList().every((value) => value == true),
      'Credential-reissue upgrade retains narrow API grants, forced RLS, and Recovery Authority triggers',
    );
    final retainedCredential = (await audit.execute(
      pg.Sql.named('''
        SELECT c.token_digest,c.allowed_scopes::text,d.revoked_at
        FROM public.ventio_identity_credentials c
        JOIN public.ventio_identity_devices d
          ON d.tenant_id=c.tenant_id AND d.actor_id=c.actor_id
          AND d.device_id=c.device_id
        WHERE c.tenant_id=@tenant AND c.credential_id=@credential
      '''),
      parameters: {'tenant': tenant, 'credential': credentialId},
    )).single;
    check(
      retainedCredential[0] == initialCredentialDigest[0] &&
          retainedCredential[1] == initialCredentialDigest[1] &&
          retainedCredential[2] == null,
      'Security-contract upgrade preserves the existing first-administrator credential ceiling and active device identity',
    );
    stdout.writeln(
      'First-administrator bootstrap integration passed: $assertions assertions.',
    );
  } finally {
    await audit.close();
    await api.close();
    await admin.close();
    await temporary.delete(recursive: true);
  }
}
