import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart';

class _CredentialReissueExecutor implements AuthoritativeCommandExecutor {
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
  final apiUrl = Platform.environment['VENTIO_TEST_API_ADMIN_DATABASE_URL'];
  if (auditUrl == null ||
      runtimeUrl == null ||
      adminUrl == null ||
      apiUrl == null ||
      Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
      Uri.parse(
            auditUrl,
          ).pathSegments.where((part) => part.isNotEmpty).lastOrNull !=
          'ventio_host_test') {
    stderr.writeln(
      'Credential reissue integration requires the disposable ventio_host_test database and explicit test opt-in.',
    );
    exitCode = 2;
    return;
  }

  final audit = await pg.Connection.openFromUrl(auditUrl);
  final admin = await pg.Connection.openFromUrl(adminUrl);
  final temporary = await createPrivateTestDirectory('ventio-reissue-');
  final tenant =
      'credential-reissue-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  const company = 'company-reissue';
  const branch = 'branch-reissue';
  const otherCompany = 'company-reissue-other';
  const otherBranch = 'branch-reissue-other';
  const operatorActor = 'reissue-operator';
  const operatorDevice = 'reissue-operator-device';
  const targetActor = 'reissue-client';
  const targetDevice = 'reissue-client-device';
  const sourceCredentialId = 'reissue-client-source';
  const extensionRead = 'extension.package.read';
  const retainedPermission = 'maintenance.create';
  HostApi? api;
  String? replacementCredentialId;
  var assertions = 0;
  void check(bool condition, String label) {
    if (!condition) throw StateError('FAIL: $label');
    assertions++;
    stdout.writeln('PASS: $label');
  }

  try {
    final authority = RecoveryAuthority('${temporary.path}/authority.json');
    await authority.resetForReenrollment(
      admin,
      'credential-reissue-test-reset',
    );
    final identityAdmin = IdentityAdministration(
      connection: admin,
      tenantId: tenant,
      operatorLabel: 'credential-reissue-integration',
      authority: authority,
    );
    await identityAdmin.registerBranch(company, branch);
    await identityAdmin.registerBranch(otherCompany, otherBranch);

    await identityAdmin.createUser(operatorActor);
    await identityAdmin.registerDevice(operatorActor, operatorDevice);
    await identityAdmin.grant(
      operatorActor,
      company,
      branch,
      identityDevicesManagePermission,
    );
    final operatorCredentialPath = '${temporary.path}/operator.json';
    await identityAdmin.provisionToFile(
      actorId: operatorActor,
      deviceId: operatorDevice,
      credentialId: 'reissue-operator-credential',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': company,
          'branchId': branch,
          'permissions': [identityDevicesManagePermission],
        },
      ],
      outputPath: operatorCredentialPath,
    );
    final operatorToken =
        (jsonDecode(await PrivateFiles.read(operatorCredentialPath))
                as Map)['token']
            as String;

    await identityAdmin.createUser(targetActor);
    await identityAdmin.registerDevice(targetActor, targetDevice);
    await identityAdmin.grant(targetActor, company, branch, retainedPermission);
    final targetCredentialPath = '${temporary.path}/target.json';
    await identityAdmin.provisionToFile(
      actorId: targetActor,
      deviceId: targetDevice,
      credentialId: sourceCredentialId,
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      allowedScopes: [
        {
          'companyId': company,
          'branchId': branch,
          'permissions': [retainedPermission],
        },
      ],
      outputPath: targetCredentialPath,
    );
    final targetToken =
        (jsonDecode(await PrivateFiles.read(targetCredentialPath))
                as Map)['token']
            as String;

    // The new permission is deliberately role-derived and arrives after the
    // original credential was issued. It must not expand that credential.
    await identityAdmin.createRole('reissue-package-reader', 'Package reader');
    await identityAdmin.grantRolePermission(
      'reissue-package-reader',
      extensionRead,
    );
    await identityAdmin.assignRole(
      actorId: targetActor,
      roleId: 'reissue-package-reader',
      companyId: company,
      branchId: branch,
    );

    Future<pg.Connection> runtimeConnection() =>
        pg.Connection.openFromUrl(runtimeUrl);
    Future<pg.Connection> apiConnection() => pg.Connection.openFromUrl(apiUrl);
    final admission = RecoveryAuthority('${temporary.path}/authority.json');
    api = await HostApi.bind(
      authenticator: PersistentTokenAuthenticator(
        connect: runtimeConnection,
        admission: admission,
      ),
      executor: _CredentialReissueExecutor(),
      extensionPackages: PostgresExtensionPackageGateway(
        connect: runtimeConnection,
        permissionDiagnosticConnect: apiConnection,
        admission: admission,
      ),
      credentialReissues: IdentityCredentialReissueGateway(
        connectApi: apiConnection,
        apiPool: null,
        authority: admission,
      ),
    );

    final oldRegistry = await send(
      api,
      path: '/api/v1/extensions/approved',
      token: targetToken,
      body: {'companyId': company, 'branchId': branch, 'limit': 10},
    );
    final oldRegistryError = oldRegistry.body['error'];
    final oldRegistryErrorCode = oldRegistryError is Map
        ? oldRegistryError['code']
        : null;
    check(
      oldRegistry.status == 403 &&
          oldRegistryErrorCode == 'CREDENTIAL_CEILING_DENIED',
      'A later role grant leaves the original Client ceiling constrained '
      '(HTTP ${oldRegistry.status}, safe error $oldRegistryErrorCode)',
    );

    final reissueConnection = await apiConnection();
    try {
      final trusted = TrustedCredentialReissueGateway(
        connection: reissueConnection,
        tenantId: tenant,
        authority: admission,
        windowsAdminTag: '0123456789abcdef',
      );
      var missingGrantDenied = false;
      try {
        await trusted.prepare(
          operatorCredentialDigest: OpaqueToken.digest(operatorToken),
          operatorActorId: operatorActor,
          companyId: company,
          branchId: branch,
          deviceId: targetDevice,
          targetActorId: targetActor,
          sourceCredentialId: sourceCredentialId,
          operationId: 'reissue_11111111111111111111111111111111',
          permissions: [retainedPermission, 'extension.package.submit'],
          approvedRemovals: const [],
        );
      } on CredentialReissueException catch (error) {
        missingGrantDenied = error.statusCode == 403;
      }
      check(
        missingGrantDenied,
        'A requested permission without a current direct or role grant is denied',
      );

      var managementExpansionDenied = false;
      try {
        await trusted.prepare(
          operatorCredentialDigest: OpaqueToken.digest(operatorToken),
          operatorActorId: operatorActor,
          companyId: company,
          branchId: branch,
          deviceId: targetDevice,
          targetActorId: targetActor,
          sourceCredentialId: sourceCredentialId,
          operationId: 'reissue_22222222222222222222222222222222',
          permissions: [
            retainedPermission,
            extensionRead,
            'identity.users.manage',
          ],
          approvedRemovals: const [],
        );
      } on CredentialReissueException catch (error) {
        managementExpansionDenied = error.statusCode == 403;
      }
      check(
        managementExpansionDenied,
        'A trusted reissue cannot add an identity-management permission',
      );

      const operationId = 'reissue_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final prepared = await trusted.prepare(
        operatorCredentialDigest: OpaqueToken.digest(operatorToken),
        operatorActorId: operatorActor,
        companyId: company,
        branchId: branch,
        deviceId: targetDevice,
        targetActorId: targetActor,
        sourceCredentialId: sourceCredentialId,
        operationId: operationId,
        permissions: [retainedPermission, extensionRead],
        approvedRemovals: const [],
      );
      replacementCredentialId = prepared['credentialId'] as String;
      check(
        prepared['state'] == 'PREPARED' &&
            prepared['deviceId'] == targetDevice &&
            prepared['actorId'] == targetActor,
        'The approved replacement is prepared for the existing exact device identity',
      );
      final duplicate = await trusted.prepare(
        operatorCredentialDigest: OpaqueToken.digest(operatorToken),
        operatorActorId: operatorActor,
        companyId: company,
        branchId: branch,
        deviceId: targetDevice,
        targetActorId: targetActor,
        sourceCredentialId: sourceCredentialId,
        operationId: operationId,
        permissions: [retainedPermission, extensionRead],
        approvedRemovals: const [],
      );
      check(
        duplicate['credentialId'] == prepared['credentialId'],
        'Repeating the same operation reference is idempotent',
      );
      final pendingRows = await audit.execute(
        pg.Sql.named('''
          SELECT tenant_id,actor_id,device_id,source_credential_id,state,
                 expires_at>clock_timestamp()
          FROM public.ventio_identity_credential_reissues
          WHERE operation_id=@operation
        '''),
        parameters: {'operation': operationId},
      );
      check(
        pendingRows.length == 1 &&
            pendingRows.single[0] == tenant &&
            pendingRows.single[1] == targetActor &&
            pendingRows.single[2] == targetDevice &&
            pendingRows.single[3] == sourceCredentialId &&
            pendingRows.single[4] == 'PREPARED' &&
            pendingRows.single[5] == true,
        'The prepared operation is durable, live, and bound to the intended source device',
      );

      final oldSession = await PersistentTokenAuthenticator(
        connect: runtimeConnection,
        admission: admission,
      ).authenticate(targetToken);
      final claimPreconditions = await audit.execute(
        pg.Sql.named('''
          SELECT EXISTS (
            SELECT FROM public.ventio_identity_credentials c
            JOIN public.ventio_identity_users u USING (tenant_id,actor_id)
            JOIN public.ventio_identity_devices d
              ON d.tenant_id=c.tenant_id AND d.actor_id=c.actor_id
             AND d.device_id=c.device_id
            WHERE c.token_digest=@digest AND c.tenant_id=@tenant
              AND c.actor_id=@actor AND c.device_id=@device
              AND c.credential_id=@source AND c.revoked_at IS NULL
              AND c.expires_at>clock_timestamp() AND u.disabled_at IS NULL
              AND d.revoked_at IS NULL
          ), EXISTS (
            SELECT FROM public.ventio_identity_credential_reissues r
            JOIN public.ventio_identity_credentials c
              ON c.tenant_id=r.tenant_id AND c.actor_id=r.actor_id
             AND c.device_id=r.device_id AND c.credential_id=r.source_credential_id
            JOIN public.ventio_identity_users u
              ON u.tenant_id=r.tenant_id AND u.actor_id=r.actor_id
            JOIN public.ventio_identity_devices d
              ON d.tenant_id=r.tenant_id AND d.actor_id=r.actor_id
             AND d.device_id=r.device_id
            WHERE r.operation_id=@operation AND r.tenant_id=@tenant
              AND r.actor_id=@actor AND r.device_id=@device
              AND r.source_credential_id=@source AND r.state='PREPARED'
              AND r.expires_at>clock_timestamp() AND c.revoked_at IS NULL
              AND c.expires_at>clock_timestamp() AND u.disabled_at IS NULL
              AND d.revoked_at IS NULL
          )
        '''),
        parameters: {
          'digest': oldSession?.credentialDigest,
          'tenant': tenant,
          'actor': targetActor,
          'device': targetDevice,
          'source': sourceCredentialId,
          'operation': operationId,
        },
      );
      final probeConnection = await apiConnection();
      Map<String, dynamic>? claimMetadata;
      String? claimSqlState;
      try {
        await probeConnection.execute('SELECT ventio_security.assert_schema()');
        await probeConnection.execute("SET statement_timeout = '20s'");
        final rows = await probeConnection.runTx((tx) async {
          await admission.admit(tx);
          return tx.execute(
            pg.Sql.named('''
              SELECT jsonb_build_object(
                'operationId', result->>'operationId',
                'state', result->>'state',
                'tenantId', result->>'tenantId',
                'actorId', result->>'actorId',
                'deviceId', result->>'deviceId',
                'companyId', result->>'companyId',
                'branchId', result->>'branchId',
                'credentialId', result->>'credentialId',
                'ciphertextIsString',
                  jsonb_typeof(result->'deliveryCiphertext')='string',
                'deliveryCiphertext', result->>'deliveryCiphertext',
                'permissionCount', jsonb_array_length(result->'permissions')
              )::text
              FROM (SELECT ventio_security.credential_reissue_claim(
                @digest,@operation)::jsonb AS result) claimed
            '''),
            parameters: {
              'digest': OpaqueToken.digest(targetToken),
              'operation': operationId,
            },
          );
        });
        claimMetadata = Map<String, dynamic>.from(
          jsonDecode(rows.single[0] as String) as Map,
        );
      } on pg.ServerException catch (error) {
        claimSqlState = error.code;
      } finally {
        await probeConnection.close();
      }
      final safeClaimMetadata = claimMetadata;
      final ciphertext = safeClaimMetadata?.remove('deliveryCiphertext');
      var protectedEnvelopeRoundTrips = false;
      if (ciphertext is String) {
        Uint8List? restored;
        try {
          restored = const WindowsCredentialReissueCipher().unprotect(
            base64.decode(ciphertext),
            operationId,
          );
          protectedEnvelopeRoundTrips = OpaqueToken.isValid(
            utf8.decode(restored),
          );
        } on Object {
          protectedEnvelopeRoundTrips = false;
        } finally {
          restored?.fillRange(0, restored.length, 0);
        }
      }
      check(
        safeClaimMetadata != null &&
            safeClaimMetadata['operationId'] == operationId &&
            safeClaimMetadata['state'] == 'PREPARED' &&
            safeClaimMetadata['tenantId'] == tenant &&
            safeClaimMetadata['actorId'] == targetActor &&
            safeClaimMetadata['deviceId'] == targetDevice &&
            safeClaimMetadata['companyId'] == company &&
            safeClaimMetadata['branchId'] == branch &&
            safeClaimMetadata['credentialId'] == prepared['credentialId'] &&
            safeClaimMetadata['ciphertextIsString'] == true &&
            safeClaimMetadata['permissionCount'] == 2 &&
            protectedEnvelopeRoundTrips,
        'SQL claim metadata is exact and DPAPI-unprotectable '
        '(SQLSTATE=$claimSqlState, state=${safeClaimMetadata?['state']}, '
        'cipherIsString=${safeClaimMetadata?['ciphertextIsString']}, '
        'cipherRoundTrips=$protectedEnvelopeRoundTrips)',
      );
      check(
        oldSession != null &&
            oldSession.credentialDigest == OpaqueToken.digest(targetToken) &&
            oldSession.principal.tenantId == tenant &&
            oldSession.principal.actorId == targetActor &&
            oldSession.principal.deviceId == targetDevice &&
            claimPreconditions.single[0] == true &&
            claimPreconditions.single[1] == true,
        'The active source and pending operation satisfy the Host claim preconditions',
      );
      check(
        oldSession != null,
        'The source credential remains usable while a replacement is pending',
      );
      final reissuer = IdentityCredentialReissueGateway(
        connectApi: apiConnection,
        apiPool: null,
        authority: admission,
      );
      late final Map<String, dynamic> replacement;
      try {
        replacement = await reissuer.claim(
          session: oldSession!,
          operationId: operationId,
        );
      } on CredentialReissueException catch (error) {
        throw StateError(
          'Safe claim failure ${error.code} HTTP ${error.statusCode}',
        );
      }
      final replacementToken = replacement['credential'] as String;
      check(
        replacement['deviceId'] == targetDevice &&
            replacement['tenantId'] == tenant &&
            replacement['actorId'] == targetActor &&
            replacement['companyId'] == company &&
            replacement['branchId'] == branch &&
            (replacement['permissions'] as List).toSet().containsAll([
              retainedPermission,
              extensionRead,
            ]),
        'The protected claim returns the exact requested scope and complete ceiling',
      );
      final finalized = await reissuer.acknowledge(
        replacementToken: replacementToken,
        operationId: operationId,
      );
      check(
        finalized['state'] == 'FINALIZED',
        'Replacement possession atomically finalizes the transition',
      );

      final newSession = await PersistentTokenAuthenticator(
        connect: runtimeConnection,
        admission: admission,
      ).authenticate(replacementToken);
      check(
        newSession != null &&
            newSession.principal.deviceId == targetDevice &&
            newSession.principal.actorId == targetActor &&
            newSession.principal.tenantId == tenant &&
            newSession.principal.allowsInScope(
              extensionRead,
              company,
              branch,
            ) &&
            newSession.principal.allowsInScope(
              retainedPermission,
              company,
              branch,
            ),
        'The new credential preserves identity and retains prior authorized permissions',
      );
      final newRegistry = await send(
        api,
        path: '/api/v1/extensions/approved',
        token: replacementToken,
        body: {'companyId': company, 'branchId': branch, 'limit': 10},
      );
      check(
        newRegistry.status == 200 && newRegistry.body['packageResult'] is Map,
        'The same device can access the approved registry after reissue',
      );
      final wrongBranch = await send(
        api,
        path: '/api/v1/extensions/approved',
        token: replacementToken,
        body: {'companyId': otherCompany, 'branchId': otherBranch, 'limit': 10},
      );
      check(
        wrongBranch.status == 403,
        'The replacement ceiling cannot cross the approved company and branch',
      );
      check(
        await PersistentTokenAuthenticator(
              connect: runtimeConnection,
              admission: admission,
            ).authenticate(targetToken) ==
            null,
        'The superseded credential is revoked after finalization',
      );
    } finally {
      await reissueConnection.close();
    }

    final credentials = await audit.execute(
      pg.Sql.named('''
        SELECT c.credential_id,c.revoked_at IS NOT NULL
        FROM public.ventio_identity_credentials c
        WHERE c.tenant_id=@tenant AND c.device_id=@device
        ORDER BY c.credential_id
      '''),
      parameters: {'tenant': tenant, 'device': targetDevice},
    );
    check(
      credentials.length == 2 &&
          credentials.any(
            (row) => row[0] == sourceCredentialId && row[1] == true,
          ) &&
          credentials.any(
            (row) => row[0] == replacementCredentialId && row[1] == false,
          ),
      'Same-device transition revokes only the source credential and preserves the replacement',
    );
    final devices = await audit.execute(
      pg.Sql.named('''
        SELECT count(*) FROM public.ventio_identity_devices
        WHERE tenant_id=@tenant AND actor_id=@actor AND device_id=@device
          AND revoked_at IS NULL
      '''),
      parameters: {
        'tenant': tenant,
        'actor': targetActor,
        'device': targetDevice,
      },
    );
    check(
      devices.single[0] == 1,
      'The enrolled Host device row and identity remain active and unchanged',
    );
    stdout.writeln(
      'RESULT: $assertions credential reissue integration assertions passed',
    );
  } finally {
    await api?.close();
    await audit.close();
    await admin.close();
    await temporary.delete(recursive: true);
  }
}
