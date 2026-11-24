import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';
import 'test_support.dart';

Future<void> main() async {
  final url = Platform.environment['VENTIO_TEST_DATABASE_URL'];
  if (url == null ||
      Uri.parse(url).pathSegments.last != 'ventio_host_test' ||
      Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes') {
    throw StateError('Disposable database and explicit test opt-in required');
  }
  final root = await pg.Connection.openFromUrl(url);
  final admin = await pg.Connection.openFromUrl(
    Platform.environment['VENTIO_TEST_ADMIN_DATABASE_URL']!,
  );
  final api = await pg.Connection.openFromUrl(
    Platform.environment['VENTIO_TEST_API_ADMIN_DATABASE_URL']!,
  );
  final runtime = await pg.Connection.openFromUrl(
    Platform.environment['VENTIO_TEST_RUNTIME_DATABASE_URL']!,
  );
  final temp = await createPrivateTestDirectory('ventio-owner-');
  final authority = RecoveryAuthority('${temp.path}/authority.json');
  const tenant = 'owner-test', company = 'company', branch = 'branch';
  final owner = InitialHostAdministratorCredential(
    actorId: 'owner',
    token: OpaqueToken.generate(),
  );
  final requestId = OpaqueToken.generate();
  final expiry = DateTime.now().toUtc().add(const Duration(days: 1));
  var checks = 0;
  void check(bool value, String label) {
    if (!value) throw StateError('FAIL: $label');
    checks++;
    stdout.writeln('PASS: $label');
  }

  String digest(String token) => sha256.convert(utf8.encode(token)).toString();
  Future<Map<String, dynamic>> snapshot(
    String token, {
    String scopeCompany = company,
  }) async => runtime.runTx((tx) async {
    await authority.admit(tx);
    final r = await tx.execute(
      pg.Sql.named(
        'SELECT ventio_security.resolve_identity(@digest,@company,@branch,NULL,NULL,NULL,NULL)::text',
      ),
      parameters: {
        'digest': digest(token),
        'company': scopeCompany,
        'branch': branch,
      },
    );
    return Map<String, dynamic>.from(jsonDecode(r.single[0] as String) as Map);
  });
  Future<String?> userChange(Map<String, Object?> change) async {
    String? result;
    await authority.change(api, (tx) async {
      final rows = await tx.execute(
        pg.Sql.named(
          'SELECT ventio_security.scoped_user_admin_change(@digest,@company,@branch,CAST(@change AS jsonb))',
        ),
        parameters: {
          'digest': digest(owner.token),
          'company': company,
          'branch': branch,
          'change': jsonEncode(change),
        },
      );
      result = rows.single[0] as String?;
    }, requireAdmissionProof: true);
    return result;
  }

  try {
    await authority.prepareFirstAdministratorBootstrap(
      api,
      requestId: requestId,
      tenantId: tenant,
      actorId: owner.actorId,
      companyId: company,
      branchId: branch,
      deviceId: 'device',
      credentialId: 'credential',
      token: owner.token,
      expiresAt: expiry,
    );
    final administration = IdentityAdministration(
      connection: admin,
      bootstrapConnection: api,
      tenantId: tenant,
      operatorLabel: 'owner-test',
      authority: authority,
    );
    await administration.bootstrapFirstAdministrator(
      companyId: company,
      branchId: branch,
      deviceId: 'device',
      credentialId: 'credential',
      expiresAt: expiry,
      requestId: requestId,
      credential: owner,
    );
    var identity = await snapshot(owner.token);
    check(
      identity['isOwner'] == true &&
          (identity['permissions'] as List).contains('*'),
      'First installed account is a server-verified Owner',
    );
    check(
      (await snapshot(owner.token, scopeCompany: 'other'))['scopeGrants']
              is List &&
          ((await snapshot(owner.token, scopeCompany: 'other'))['scopeGrants']
                  as List)
              .isEmpty,
      'Owner authority does not invent another tenant or unregistered scope',
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
    final gateway = PostgresExtensionPackageGateway(
      connect: () => pg.Connection.openFromUrl(
        Platform.environment['VENTIO_TEST_RUNTIME_DATABASE_URL']!,
      ),
      admission: authority,
    );
    final session = AuthenticatedSession.persistent(
      Principal(
        tenantId: tenant,
        actorId: 'owner',
        deviceId: 'device',
        companyIds: {company},
        branchIds: {branch},
        permissions: {'*'},
      ),
      digest(owner.token),
    );
    await gateway.submit(
      session: session,
      companyId: company,
      branchId: branch,
      bundle: bundle,
    );
    final review = PostgresExtensionPackageReviewGateway(
      connect: () => pg.Connection.openFromUrl(
        Platform.environment['VENTIO_TEST_API_ADMIN_DATABASE_URL']!,
      ),
      admission: authority,
    );
    final hash = sha256
        .convert(utf8.encode(canonicalJson(bundle.toJson())))
        .toString();
    final decision = await review.review(
      session: session,
      companyId: company,
      branchId: branch,
      moduleId: bundle.moduleId,
      version: bundle.version,
      packageSha256: hash,
      decision: 'APPROVE',
    );
    check(
      decision['status'] == 'APPROVED',
      'Owner submits and approves a new extension with the original credential',
    );
    identity = await snapshot(owner.token);
    check(
      (identity['permissions'] as List).contains(
            'extension.sync_test.product.read',
          ) &&
          (identity['permissions'] as List).contains(
            'extension.sync_test.product.create',
          ),
      'New extension read/create permissions become effective without manual grants or credential reissue',
    );
    await runtime.runTx((tx) async {
      await authority.admit(tx);
      final r = await tx.execute(
        pg.Sql.named(
          'SELECT ventio_security.resolve_extension_read_identity(@digest,@company,@branch,@module,@version,@doctype)::text',
        ),
        parameters: {
          'digest': digest(owner.token),
          'company': company,
          'branch': branch,
          'module': bundle.moduleId,
          'version': bundle.version,
          'doctype': 'Product',
        },
      );
      final data = jsonDecode(r.single[0] as String) as Map;
      check(
        data['package'] != null,
        'PostgreSQL authorizes Owner record queries on the new package',
      );
    });
    final user = (await userChange({'action': 'USER_CREATED'}))!;
    await userChange({
      'action': 'PERMISSION_GRANTED',
      'actorId': user,
      'permission': 'extension.package.read',
    });
    await administration.registerDevice(user, 'user-device');
    final tokenPath = '${temp.path}/user.json';
    await administration.provisionToFile(
      actorId: user,
      deviceId: 'user-device',
      credentialId: 'user-credential',
      expiresAt: expiry,
      allowedScopes: [
        {
          'companyId': company,
          'branchId': branch,
          'permissions': <String>['extension.package.read'],
        },
      ],
      outputPath: tokenPath,
    );
    final userToken =
        (jsonDecode(await PrivateFiles.read(tokenPath)) as Map)['token']
            as String;
    check(
      !(await snapshot(userToken))['permissions'].contains('*'),
      'A new ordinary user has no Owner authority',
    );
    await userChange({
      'action': 'PERMISSION_GRANTED',
      'actorId': user,
      'permission': 'extension.sync_test.product.read',
    });
    check(
      (await snapshot(
        userToken,
      ))['permissions'].contains('extension.sync_test.product.read'),
      'Owner grant updates an already enrolled user credential immediately',
    );
    await userChange({
      'action': 'PERMISSION_GRANTED',
      'actorId': user,
      'permission': 'identity.users.manage',
    });
    check(
      (await snapshot(
        userToken,
      ))['permissions'].contains('identity.users.manage'),
      'Owner can grant an administrative permission',
    );
    await userChange({
      'action': 'PERMISSION_REVOKED',
      'actorId': user,
      'permission': 'extension.sync_test.product.read',
    });
    check(
      !(await snapshot(
        userToken,
      ))['permissions'].contains('extension.sync_test.product.read'),
      'Owner revocation takes effect on the existing credential',
    );
    var escalationDenied = false;
    try {
      await authority.change(api, (tx) async {
        await tx.execute(
          pg.Sql.named(
            'SELECT ventio_security.scoped_user_admin_change(@digest,@company,@branch,CAST(@change AS jsonb))',
          ),
          parameters: {
            'digest': digest(userToken),
            'company': company,
            'branch': branch,
            'change': jsonEncode({
              'action': 'PERMISSION_GRANTED',
              'actorId': user,
              'permission': 'host.status.read',
            }),
          },
        );
      }, requireAdmissionProof: true);
    } on pg.ServerException catch (e) {
      escalationDenied = e.code == '42501';
    }
    check(
      escalationDenied,
      'Ordinary user management permission cannot grant Owner-only administrative authority',
    );
    // Model the pre-Owner account and replay the exact upgrade backfill.
    await authority.change(root, (tx) async {
      await tx.execute('SET LOCAL ROLE ventio_owner');
      await tx.execute(
        'UPDATE ventio_identity_users SET is_owner=false WHERE is_owner',
      );
      await tx.execute(
        "WITH initial AS (SELECT DISTINCT ON (tenant_id) tenant_id,subject_id FROM ventio_identity_audit WHERE action='INITIAL_ADMIN_BOOTSTRAPPED' ORDER BY tenant_id,id) UPDATE ventio_identity_users u SET is_owner=true FROM initial a WHERE u.tenant_id=a.tenant_id AND u.actor_id=a.subject_id",
      );
    });
    check(
      (await snapshot(owner.token))['isOwner'] == true &&
          !(await snapshot(userToken))['permissions'].contains('*'),
      'Upgrade identifies only the audit-backed initial account and preserves its original credential',
    );
    stdout.writeln('RESULT: $checks Owner checks passed');
  } finally {
    await runtime.close();
    await api.close();
    await admin.close();
    await root.close();
    await temp.delete(recursive: true);
  }
}
