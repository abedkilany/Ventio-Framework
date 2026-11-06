import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart';

class FakeExecutor implements CommandExecutor {
  int calls = 0;
  bool fail = false;
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session,
  ) async {
    final principal = session.principal;
    final canCreate = principal.allowsInScope(
      'maintenance.create',
      command.companyId,
      command.branchId,
    );
    calls++;
    entered?.complete();
    if (release != null) await release!.future;
    if (fail) throw StateError('sensitive database diagnostic');
    return CommandReceipt(
      commandId: command.commandId,
      status: canCreate ? 'ACCEPTED' : 'REJECTED',
      reasonCode: canCreate ? null : 'PERMISSION_DENIED',
    ).toJson();
  }
}

class FakePersistentAuthenticator implements PersistentHostAuthenticator {
  @override
  Future<AuthenticatedSession?> authenticate(String token) async => null;
}

class FailingSessionAuthenticator implements PersistentHostAuthenticator {
  @override
  Future<AuthenticatedSession?> authenticate(String token) async {
    throw StateError('DATABASE_URL=synthetic-secret');
  }
}

class RecoveryAdmissionUnavailableAuthenticator
    implements PersistentHostAuthenticator {
  @override
  Future<AuthenticatedSession?> authenticate(String token) async {
    throw const RecoveryAdmissionUnavailable();
  }
}

class FakeAuthoritativeExecutor implements AuthoritativeCommandExecutor {
  @override
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session,
  ) async =>
      CommandReceipt(commandId: command.commandId, status: 'ACCEPTED').toJson();
}

class FakeManagementAuthenticator implements PersistentHostAuthenticator {
  @override
  Future<AuthenticatedSession?> authenticate(String token) async {
    if (token != validToken && token != deniedToken) return null;
    final allowed = token == validToken;
    final scoped = PrincipalScope(
      companyId: 'company-001',
      branchId: 'branch-001',
      permissions: allowed
          ? {hostStatusReadPermission, hostDiagnosticsReadPermission}
          : const {},
    );
    final principal = Principal(
      actorId: 'operator-001',
      deviceId: 'client-001',
      tenantId: 'management-test',
      companyIds: {'company-001'},
      branchIds: {'branch-001'},
      permissions: allowed
          ? {hostStatusReadPermission, hostDiagnosticsReadPermission}
          : const {},
      scopeGrants: [scoped],
    );
    return AuthenticatedSession.persistent(
      principal,
      OpaqueToken.digest(token),
    );
  }
}

class PairingContractAuthenticator implements PersistentHostAuthenticator {
  @override
  Future<AuthenticatedSession?> authenticate(String token) async {
    if (token != validToken && token != deniedToken) return null;
    final permissions = token == validToken
        ? {identityPairingManagePermission}
        : const <String>{};
    final scope = PrincipalScope(
      companyId: 'company-001',
      branchId: 'branch-001',
      permissions: permissions,
    );
    return AuthenticatedSession.persistent(
      Principal(
        actorId: 'operator-001',
        deviceId: 'operator-device-001',
        tenantId: 'pairing-contract',
        companyIds: {'company-001'},
        branchIds: {'branch-001'},
        permissions: permissions,
        scopeGrants: [scope],
      ),
      OpaqueToken.digest(token),
    );
  }
}

class FakeIdentityPairingGateway implements IdentityPairingGateway {
  static final code = List.filled(43, 'e').join();
  static final credential = List.filled(43, 'f').join();
  bool failRedeem = false;
  bool failCreate = false;
  int createCalls = 0;
  int redeemCalls = 0;
  String? lastRedeemedCode;
  String? lastDeviceId;
  String? lastRequestId;

  @override
  Future<IdentityPairingCreateResult> create({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String actorId,
    required String requestId,
  }) async {
    createCalls++;
    lastRequestId = requestId;
    if (failCreate) throw StateError('PAIRING_DB_PASSWORD=synthetic-secret');
    return IdentityPairingCreateResult(
      pairing: {
        'pairingId': 'pair_${List.filled(32, '1').join()}',
        'actorId': actorId,
        'deviceRole': 'CLIENT',
        'code': code,
        'companyId': companyId,
        'branchId': branchId,
        'expiresAtUtc': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 5))
            .toIso8601String(),
      },
      timings: PairingCreateTimings(
        connectionAcquisitionMs: 0,
        connectionSetupMs: 0,
        recovery: RecoveryMutationTimings(),
        totalMs: 1,
      ),
    );
  }

  @override
  Future<Map<String, dynamic>> redeem({
    required String code,
    required String deviceId,
  }) async {
    redeemCalls++;
    lastRedeemedCode = code;
    lastDeviceId = deviceId;
    if (failRedeem) {
      throw const IdentityPairingException(
        'PAIRING_INVALID_OR_EXPIRED',
        statusCode: 410,
      );
    }
    return {
      'tenantId': 'pairing-contract',
      'actorId': 'user-001',
      'deviceId': deviceId,
      'deviceRole': 'CLIENT',
      'credentialId': 'cred_${List.filled(32, '2').join()}',
      'companyId': 'company-001',
      'branchId': 'branch-001',
      'expiresAtUtc': DateTime.now()
          .toUtc()
          .add(const Duration(days: 30))
          .toIso8601String(),
      'credential': credential,
    };
  }
}

class FakeCredentialReissueGateway
    implements AuthoritativeIdentityCredentialReissueGateway {
  static final replacement = List.filled(43, 'g').join();
  int claims = 0;
  int acknowledgments = 0;
  String? acknowledgedToken;
  String? acknowledgedOperation;

  @override
  Future<Map<String, dynamic>> claim({
    required AuthenticatedSession session,
    String? operationId,
  }) async {
    claims++;
    return {
      'operationId': operationId ?? 'reissue_0123456789abcdef0123456789abcdef',
      'state': 'PREPARED',
      'tenantId': session.principal.tenantId,
      'actorId': session.principal.actorId,
      'deviceId': session.principal.deviceId,
      'companyId': 'company-001',
      'branchId': 'branch-001',
      'credentialId': 'cred_0123456789abcdef0123456789abcdef',
      'permissions': ['extension.package.read'],
      'expiresAtUtc': DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 10))
          .toIso8601String(),
      'credential': replacement,
    };
  }

  @override
  Future<Map<String, dynamic>> acknowledge({
    required String replacementToken,
    required String operationId,
  }) async {
    acknowledgments++;
    acknowledgedToken = replacementToken;
    acknowledgedOperation = operationId;
    return {
      'operationId': operationId,
      'state': 'FINALIZED',
      'deviceId': 'client-001',
      'credentialId': 'cred_0123456789abcdef0123456789abcdef',
    };
  }
}

class FakeIdentityDeviceAdministrationGateway
    implements IdentityDeviceAdministrationGateway {
  @override
  Future<Map<String, dynamic>> list({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
  }) async => {};

  @override
  Future<void> revoke({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String deviceId,
  }) async {}

  @override
  Future<Map<String, dynamic>> rotateCredential({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String deviceId,
    required String credentialId,
  }) async => {};
}

class FakeReadinessProvider implements HostReadinessProvider {
  FakeReadinessProvider(this.snapshot);

  HostReadinessSnapshot snapshot;

  @override
  Future<HostReadinessSnapshot> checkReadiness() async => snapshot;
}

class FakeExtensionPackageGateway implements ExtensionPackageGateway {
  int calls = 0;

  @override
  Future<Map<String, dynamic>> submit({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required ExtensionBundle bundle,
  }) async {
    calls++;
    return {'status': 'SUBMITTED'};
  }

  @override
  Future<Map<String, dynamic>> readApproved({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String moduleId,
    required String version,
  }) async {
    calls++;
    return {'status': 'APPROVED'};
  }

  @override
  Future<Map<String, dynamic>> listApproved({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required int limit,
    String? afterModuleId,
    String? afterVersion,
  }) async {
    calls++;
    return {'status': 'APPROVED', 'packages': <Object>[], 'hasMore': false};
  }
}

Future<void> main() async {
  var cleartextExternalRejected = false;
  try {
    await HostApi.bind(
      listenAddress: InternetAddress.anyIPv4,
      authenticator: authenticator('external-cleartext-test'),
      executor: FakeExecutor(),
    );
  } on ArgumentError {
    cleartextExternalRejected = true;
  }
  check(
    cleartextExternalRejected,
    'An external cleartext Host listener is rejected',
  );

  var developmentExternalTlsRejected = false;
  try {
    await HostApi.bind(
      listenAddress: InternetAddress.anyIPv4,
      tlsContext: SecurityContext(withTrustedRoots: true),
      authenticator: authenticator('external-development-test'),
      executor: FakeExecutor(),
    );
  } on ArgumentError {
    developmentExternalTlsRejected = true;
  }
  check(
    developmentExternalTlsRejected,
    'Development credentials cannot back an external TLS Host listener',
  );

  var nonAuthoritativeExecutorRejected = false;
  try {
    await HostApi.bind(
      listenAddress: InternetAddress.anyIPv4,
      tlsContext: SecurityContext(withTrustedRoots: true),
      authenticator: FakePersistentAuthenticator(),
      executor: FakeExecutor(),
    );
  } on ArgumentError {
    nonAuthoritativeExecutorRejected = true;
  }
  check(
    nonAuthoritativeExecutorRejected,
    'An external TLS listener rejects non-authoritative executors',
  );

  var nonAuthoritativeReadinessRejected = false;
  try {
    await HostApi.bind(
      listenAddress: InternetAddress.anyIPv4,
      tlsContext: SecurityContext(withTrustedRoots: true),
      authenticator: FakePersistentAuthenticator(),
      executor: FakeAuthoritativeExecutor(),
      readinessProvider: FakeReadinessProvider(
        HostReadinessSnapshot(
          checkedAtUtc: DateTime.now().toUtc(),
          hostVersion: '0.1.0',
          components: [
            ManagementComponentHealth(
              component: ManagementComponent.api,
              state: ManagementHealthState.ready,
              checkedAtUtc: DateTime.now().toUtc(),
            ),
          ],
        ),
      ),
    );
  } on ArgumentError {
    nonAuthoritativeReadinessRejected = true;
  }
  check(
    nonAuthoritativeReadinessRejected,
    'An external TLS listener rejects non-authoritative readiness providers',
  );

  var nonAuthoritativePairingRejected = false;
  try {
    await HostApi.bind(
      listenAddress: InternetAddress.anyIPv4,
      tlsContext: SecurityContext(withTrustedRoots: true),
      authenticator: FakePersistentAuthenticator(),
      executor: FakeAuthoritativeExecutor(),
      identityPairing: FakeIdentityPairingGateway(),
    );
  } on ArgumentError {
    nonAuthoritativePairingRejected = true;
  }
  check(
    nonAuthoritativePairingRejected,
    'An external TLS listener rejects non-authoritative pairing gateways',
  );

  var nonAuthoritativeDeviceAdministrationRejected = false;
  try {
    await HostApi.bind(
      listenAddress: InternetAddress.anyIPv4,
      tlsContext: SecurityContext(withTrustedRoots: true),
      authenticator: FakePersistentAuthenticator(),
      executor: FakeAuthoritativeExecutor(),
      identityDeviceAdministration: FakeIdentityDeviceAdministrationGateway(),
    );
  } on ArgumentError {
    nonAuthoritativeDeviceAdministrationRejected = true;
  }
  check(
    nonAuthoritativeDeviceAdministrationRejected,
    'An external TLS listener rejects non-authoritative device gateways',
  );

  final executor = FakeExecutor();
  final fakePackages = FakeExtensionPackageGateway();
  final diagnostics = ManagementDiagnosticBuffer();
  final api = await HostApi.bind(
    authenticator: authenticator('api-test'),
    executor: executor,
    extensionPackages: fakePackages,
    diagnostics: diagnostics,
    maxBodyBytes: 4096,
    bodyTimeout: const Duration(milliseconds: 200),
  );
  final body = command('api-test');
  Future<Reply> submit({String? token, Object? json}) =>
      send(api, token: token ?? validToken, body: json ?? body);
  try {
    final liveness = await send(api, path: '/healthz', method: 'GET');
    check(
      liveness.status == 200 &&
          RegExp(
            r'^cor_[a-f0-9]{32}$',
          ).hasMatch(liveness.headers.value('X-Correlation-ID') ?? ''),
      'Liveness is available without credentials and has a correlation header',
    );
    final sessionReply = await send(
      api,
      path: '/api/v1/session',
      method: 'GET',
      token: validToken,
    );
    final sessionIdentity =
        sessionReply.body['identity'] as Map<String, dynamic>;
    check(
      sessionReply.status == 200 &&
          sessionIdentity['tenantId'] == 'api-test' &&
          sessionIdentity['persistent'] == false &&
          (sessionIdentity['scopes'] as List).single['companyId'] ==
              'company-001' &&
          ((sessionIdentity['scopes'] as List).single['permissions'] as List)
              .contains('maintenance.create'),
      'Authenticated session discovery returns only the caller exact-scope grants',
    );
    final unauthenticatedSession = await send(
      api,
      path: '/api/v1/session',
      method: 'GET',
    );
    check(
      unauthenticatedSession.status == 401 &&
          unauthenticatedSession.body['correlationId'] ==
              unauthenticatedSession.headers.value('X-Correlation-ID'),
      'Session discovery requires authentication and returns a matching correlation ID',
    );
    check(
      (await send(
            api,
            path: '/api/v1/session',
            method: 'POST',
            token: validToken,
          )).status ==
          405,
      'Session discovery rejects non-GET methods',
    );
    check(
      (await send(api, path: '/missing')).status == 404,
      'Unknown route is rejected',
    );
    final draftTransfer = await send(
      api,
      path: '/api/v1/extensions/submit',
      token: validToken,
      body: {
        'companyId': 'company-001',
        'branchId': 'branch-001',
        'package': {},
      },
    );
    final packageRead = await send(
      api,
      path: '/api/v1/extensions/read',
      token: validToken,
      body: {
        'companyId': 'company-001',
        'branchId': 'branch-001',
        'moduleId': 'com.example.package',
        'version': '1.0.0',
      },
    );
    final packageList = await send(
      api,
      path: '/api/v1/extensions/approved',
      token: validToken,
      body: {'companyId': 'company-001', 'branchId': 'branch-001', 'limit': 20},
    );
    check(
      draftTransfer.status == 403 &&
          draftTransfer.body['error']['code'] ==
              'PERSISTENT_IDENTITY_REQUIRED' &&
          packageRead.status == 403 &&
          packageList.status == 403 &&
          fakePackages.calls == 0,
      'Package transfer and registry reads refuse development-only identities before the gateway',
    );
    check(
      (await send(api, method: 'GET')).status == 405,
      'Command route requires POST',
    );
    check(
      (await send(
            api,
            path: '/api/v1/commands?token=secret',
            body: body,
          )).status ==
          400,
      'Query credentials are unsupported',
    );
    for (final token in [
      null,
      'invalid',
      List.filled(43, 'z').join(),
      expiredToken,
      revokedToken,
    ]) {
      final reply = await send(api, token: token, body: body);
      check(
        reply.status == 401 &&
            reply.headers.value('www-authenticate') == 'Bearer',
        'Missing, malformed, unknown, expired or revoked credential is denied (${assertions + 1})',
      );
    }
    check(
      executor.calls == 0,
      'Authentication failure never reaches command execution',
    );
    check(
      (await submit()).status == 200,
      'Valid credential dispatches authenticated command',
    );
    final accepted = await submit();
    check(
      accepted.body['receipt']['status'] == 'ACCEPTED' &&
          accepted.headers.value('cache-control') == 'no-store',
      'Receipt is versioned and responses are not cached',
    );
    check(
      (await submit(token: deniedToken)).status == 403,
      'Insufficient permission is denied',
    );
    final calls = executor.calls;
    for (final field in [
      'tenantId',
      'companyId',
      'branchId',
      'actorId',
      'deviceId',
    ]) {
      final forged = command('api-test');
      if (field == 'actorId' || field == 'deviceId') {
        forged['clientContext'][field] = 'forged';
      } else {
        forged[field] = 'forged';
      }
      check(
        (await submit(json: forged)).status == 403,
        'Forged $field is denied',
      );
    }
    check(
      executor.calls == calls,
      'Scope denial occurs before executor access',
    );
    check(
      (await submit(json: '{broken')).status == 400,
      'Malformed JSON is rejected',
    );
    check(
      (await submit(json: '[]')).status == 400,
      'Non-object command is rejected',
    );
    final unknown = command('api-test')
      ..['permissions'] = ['maintenance.create'];
    check(
      (await submit(json: unknown)).status == 400,
      'Client cannot add permission claims',
    );
    final unknownContext = command('api-test');
    unknownContext['clientContext']['roles'] = ['admin'];
    check(
      (await submit(json: unknownContext)).status == 400,
      'Unknown context properties are rejected',
    );
    final badVersion = command('api-test')..['protocolVersion'] = 1;
    check(
      (await submit(json: badVersion)).status == 400,
      'Unsupported command protocol is rejected',
    );
    final badId = command('api-test')..['commandId'] = 'invalid';
    check(
      (await submit(json: badId)).status == 400,
      'Invalid command UUID is rejected',
    );
    check(
      (await send(
            api,
            token: validToken,
            body: body,
            contentType: 'text/plain',
          )).status ==
          415,
      'Non-JSON media type is rejected',
    );
    check(
      (await send(
            api,
            token: validToken,
            body: body,
            contentType: 'application/json; charset=latin1',
          )).status ==
          415,
      'Unsupported encoding is rejected',
    );
    check(
      (await submit(json: List.filled(5000, 'a').join())).status == 413,
      'Declared oversized body is rejected',
    );
    check(
      (await send(
            api,
            token: validToken,
            body: List.filled(5000, 'a').join(),
            chunked: true,
          )).status ==
          413,
      'Chunked oversized body is rejected',
    );
    check(
      (await submit(
            json:
                '${List.filled(40, '[').join()}0${List.filled(40, ']').join()}',
          )).status ==
          400,
      'Deeply nested JSON is bounded',
    );
    final slowSocket = await Socket.connect('127.0.0.1', api.port);
    final rawResponse = utf8.decoder.bind(slowSocket).join();
    slowSocket.write(
      'POST /api/v1/commands HTTP/1.1\r\n'
      'Host: localhost\r\nAuthorization: Bearer $validToken\r\n'
      'Content-Type: application/json\r\nContent-Length: 100\r\n\r\n{',
    );
    await slowSocket.flush();
    final timeoutReply = await rawResponse.timeout(const Duration(seconds: 5));
    check(
      timeoutReply.startsWith('HTTP/1.1 408') &&
          timeoutReply.contains('BODY_TIMEOUT'),
      'Incomplete upload hits total body deadline',
    );
    slowSocket.destroy();
    final unauthenticatedSocket = await Socket.connect('127.0.0.1', api.port);
    final earlyResponse = utf8.decoder.bind(unauthenticatedSocket).join();
    unauthenticatedSocket.write(
      'POST /api/v1/commands HTTP/1.1\r\n'
      'Host: localhost\r\nContent-Length: 1000000\r\n\r\n',
    );
    await unauthenticatedSocket.flush();
    check(
      (await earlyResponse.timeout(
        const Duration(seconds: 5),
      )).startsWith('HTTP/1.1 401'),
      'Unauthenticated incomplete upload is rejected without draining its body',
    );
    unauthenticatedSocket.destroy();
    executor.fail = true;
    final failed = await submit();
    check(
      failed.status == 503 &&
          failed.body['error']['retryable'] == true &&
          failed.body['correlationId'] ==
              failed.headers.value('X-Correlation-ID') &&
          !jsonEncode(failed.body).contains('sensitive'),
      'Execution exception produces a correlation ID and no diagnostic leak',
    );
    final internalFailure = diagnostics.recent().single;
    check(
      internalFailure.code == 'HOST_UNAVAILABLE' &&
          internalFailure.correlationId == failed.body['correlationId'] &&
          internalFailure.protectedFailureType == 'StateError' &&
          internalFailure.protectedFailureSource == 'FakeExecutor.execute' &&
          !jsonEncode(internalFailure.toJson()).contains('sensitive') &&
          !jsonEncode(internalFailure.toJson()).contains('StateError') &&
          !jsonEncode(internalFailure.toJson()).contains('FakeExecutor'),
      'Unexpected Host failures are recorded as structured safe diagnostics',
    );
  } finally {
    await api.close();
  }

  final gate = FakeExecutor()
    ..entered = Completer<void>()
    ..release = Completer<void>();
  final bounded = await HostApi.bind(
    authenticator: authenticator('api-test'),
    executor: gate,
    maxConcurrentRequests: 1,
  );
  final inFlight = send(bounded, token: validToken, body: body);
  await gate.entered!.future;
  check(
    (await send(bounded, token: validToken, body: body)).status == 503,
    'Admission limit rejects excess concurrent work',
  );
  var closed = false;
  final closing = bounded.close().then((_) => closed = true);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  check(!closed, 'Shutdown waits for admitted command completion');
  gate.release!.complete();
  check(
    (await inFlight).status == 200,
    'In-flight command completes during graceful shutdown',
  );
  await closing;
  await bounded.close();
  check(closed, 'Shutdown completes and is idempotent');

  final checkedAtUtc = DateTime.now().toUtc();
  final readinessProvider = FakeReadinessProvider(
    HostReadinessSnapshot(
      checkedAtUtc: checkedAtUtc,
      hostVersion: hostApiReleaseVersion,
      components: ManagementComponent.values
          .map(
            (component) => ManagementComponentHealth(
              component: component,
              state: ManagementHealthState.ready,
              checkedAtUtc: checkedAtUtc,
            ),
          )
          .toList(),
    ),
  );
  final managementDiagnostics = ManagementDiagnosticBuffer();
  final managementApi = await HostApi.bind(
    authenticator: FakeManagementAuthenticator(),
    executor: FakeExecutor(),
    readinessProvider: readinessProvider,
    diagnostics: managementDiagnostics,
  );
  try {
    final unauthorized = await send(
      managementApi,
      path: HostManagementRoutes.readiness,
      token: deniedToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
      },
    );
    check(
      unauthorized.status == 403 &&
          unauthorized.body['error']['code'] == 'PERMISSION_DENIED',
      'Readiness requires its dedicated exact-scope permission',
    );

    final readiness = await send(
      managementApi,
      path: HostManagementRoutes.readiness,
      token: validToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
      },
    );
    final snapshot = HostReadinessSnapshot.fromJson(
      readiness.body['readiness'],
    );
    check(
      readiness.status == 200 &&
          snapshot.overallState == ManagementHealthState.ready &&
          readiness.body['correlationId'] ==
              readiness.headers.value('X-Correlation-ID'),
      'Versioned readiness returns component status and a correlation ID',
    );
    final outOfScope = await send(
      managementApi,
      path: HostManagementRoutes.readiness,
      token: validToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'another-branch',
      },
    );
    check(
      outOfScope.status == 403 &&
          outOfScope.body['error']['code'] == 'SCOPE_DENIED',
      'A status grant cannot be used outside its exact company/branch pair',
    );

    readinessProvider.snapshot = HostReadinessSnapshot(
      checkedAtUtc: checkedAtUtc,
      hostVersion: hostApiReleaseVersion,
      components: ManagementComponent.values.map((component) {
        final blocked = component == ManagementComponent.recoveryAuthority;
        return ManagementComponentHealth(
          component: component,
          state: blocked
              ? ManagementHealthState.blocked
              : ManagementHealthState.ready,
          checkedAtUtc: checkedAtUtc,
          reasonCode: blocked ? 'RECOVERY_ADMISSION_BLOCKED' : null,
        );
      }).toList(),
    );
    final notReady = await send(
      managementApi,
      path: HostManagementRoutes.readiness,
      token: validToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
      },
    );
    check(
      HostReadinessSnapshot.fromJson(notReady.body['readiness']).overallState ==
              ManagementHealthState.unavailable &&
          managementDiagnostics.recent().single.code ==
              'RECOVERY_ADMISSION_BLOCKED' &&
          managementDiagnostics.recent().single.correlationId ==
              notReady.body['correlationId'],
      'A recovery readiness failure returns safe status and a structured correlated event',
    );
    final unsupportedVersion = await send(
      managementApi,
      path: HostManagementRoutes.readiness,
      token: validToken,
      body: {
        'managementApiVersion': managementApiVersion + 1,
        'companyId': 'company-001',
        'branchId': 'branch-001',
      },
    );
    check(
      unsupportedVersion.body['error']['code'] == 'INVALID_REQUEST' &&
          unsupportedVersion.body.containsKey('correlationId'),
      'Readiness rejects unsupported contract versions with correlation',
    );

    await managementDiagnostics.record(
      ManagementDiagnosticEvent(
        code: 'HOST_UNAVAILABLE',
        component: 'host_api',
        category: ManagementDiagnosticCategory.apiExecution,
        severity: ManagementDiagnosticSeverity.error,
        occurredAtUtc: checkedAtUtc,
        correlationId: 'cor_0123456789abcdef0123456789abcdef',
        retryable: true,
        messageKey: 'host_api.error.host_unavailable',
        safeExplanation: 'The Host could not complete this request.',
        recommendedAction: 'Retry safely and share the correlation ID.',
        protectedFailureType: 'StateError',
        protectedFailureSource: 'PersistentPool.execute',
      ),
    );
    final diagnosticsDenied = await send(
      managementApi,
      path: HostManagementRoutes.diagnosticsRecent,
      token: deniedToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
        'limit': 10,
      },
    );
    check(
      diagnosticsDenied.status == 403 &&
          diagnosticsDenied.body['error']['code'] == 'PERMISSION_DENIED',
      'Diagnostic history requires its dedicated exact-scope permission',
    );
    final diagnosticHistory = await send(
      managementApi,
      path: HostManagementRoutes.diagnosticsRecent,
      token: validToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
        'limit': 10,
      },
    );
    final exportedEvents = diagnosticHistory.body['events'] as List;
    check(
      diagnosticHistory.status == 200 &&
          exportedEvents.length == 2 &&
          diagnosticHistory.body['correlationId'] ==
              diagnosticHistory.headers.value('X-Correlation-ID') &&
          !jsonEncode(
            diagnosticHistory.body,
          ).contains('protectedFailureType') &&
          !jsonEncode(diagnosticHistory.body).contains('StateError'),
      'Authorized diagnostic history is bounded, correlated and omits protected failure details',
    );
    final diagnosticsOutOfScope = await send(
      managementApi,
      path: HostManagementRoutes.diagnosticsRecent,
      token: validToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'another-branch',
        'limit': 10,
      },
    );
    check(
      diagnosticsOutOfScope.status == 403 &&
          diagnosticsOutOfScope.body['error']['code'] == 'SCOPE_DENIED',
      'Diagnostic history cannot cross its exact company/branch scope',
    );
    final invalidDiagnosticLimit = await send(
      managementApi,
      path: HostManagementRoutes.diagnosticsRecent,
      token: validToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
        'limit': 101,
      },
    );
    check(
      invalidDiagnosticLimit.status == 400 &&
          invalidDiagnosticLimit.body['error']['code'] == 'INVALID_REQUEST',
      'Diagnostic history rejects unbounded page sizes',
    );
  } finally {
    await managementApi.close();
  }

  final sessionFailureDiagnostics = ManagementDiagnosticBuffer();
  final sessionFailureApi = await HostApi.bind(
    authenticator: FailingSessionAuthenticator(),
    executor: FakeExecutor(),
    diagnostics: sessionFailureDiagnostics,
  );
  try {
    final failedSession = await send(
      sessionFailureApi,
      path: '/api/v1/session',
      method: 'GET',
      token: validToken,
    );
    check(
      failedSession.status == 503 &&
          failedSession.body['error']['code'] == 'HOST_UNAVAILABLE' &&
          failedSession.body['correlationId'] ==
              failedSession.headers.value('X-Correlation-ID') &&
          !jsonEncode(failedSession.body).contains('synthetic-secret'),
      'Authenticated-session HTTP 503 is correlated and hides private failure details',
    );
    check(
      sessionFailureDiagnostics.recent().single.correlationId ==
              failedSession.body['correlationId'] &&
          !jsonEncode(
            sessionFailureDiagnostics.recent().single.toJson(),
          ).contains('synthetic-secret'),
      'Session 503 diagnostics retain only a safe code and correlation ID',
    );
  } finally {
    await sessionFailureApi.close();
  }

  final recoveryAdmissionDiagnostics = ManagementDiagnosticBuffer();
  final recoveryAdmissionApi = await HostApi.bind(
    authenticator: RecoveryAdmissionUnavailableAuthenticator(),
    executor: FakeExecutor(),
    diagnostics: recoveryAdmissionDiagnostics,
  );
  try {
    const recoveryCorrelation = 'cor_abcdef0123456789abcdef0123456789';
    final rejectedDuringRecovery = await send(
      recoveryAdmissionApi,
      path: HostManagementRoutes.pairingCreateV2,
      token: validToken,
      headers: {'X-Correlation-ID': recoveryCorrelation},
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
        'actorId': 'user-001',
        'requestId': recoveryCorrelation,
      },
    );
    check(
      rejectedDuringRecovery.status == 503 &&
          rejectedDuringRecovery.body['error']['code'] ==
              'RECOVERY_AUTHORITY_UNAVAILABLE' &&
          rejectedDuringRecovery.body['error']['retryable'] == true &&
          rejectedDuringRecovery.body['correlationId'] == recoveryCorrelation,
      'Pairing authentication during a pending Recovery Authority window returns a safe, retryable recovery-specific error',
    );
    check(
      recoveryAdmissionDiagnostics.recent().single.category ==
              ManagementDiagnosticCategory.recovery &&
          recoveryAdmissionDiagnostics.recent().single.correlationId ==
              recoveryCorrelation &&
          !jsonEncode(
            recoveryAdmissionDiagnostics.recent().single.toJson(),
          ).contains('witness'),
      'Recovery admission rejection is correlated and contains no protected witness detail',
    );
  } finally {
    await recoveryAdmissionApi.close();
  }

  final pairingGateway = FakeIdentityPairingGateway();
  final pairingDiagnostics = ManagementDiagnosticBuffer();
  final pairingApi = await HostApi.bind(
    authenticator: PairingContractAuthenticator(),
    executor: FakeAuthoritativeExecutor(),
    identityPairing: pairingGateway,
    diagnostics: pairingDiagnostics,
  );
  try {
    final unauthenticatedCreate = await send(
      pairingApi,
      path: HostManagementRoutes.pairingCreate,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
        'actorId': 'user-001',
      },
    );
    check(
      unauthenticatedCreate.status == 401 && pairingGateway.createCalls == 0,
      'Pairing creation requires authenticated Host authorization',
    );
    final deniedCreate = await send(
      pairingApi,
      path: HostManagementRoutes.pairingCreate,
      token: deniedToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
        'actorId': 'user-001',
      },
    );
    check(
      deniedCreate.status == 403 && pairingGateway.createCalls == 0,
      'Pairing creation requires the dedicated exact-scope permission',
    );
    final outOfScopeCreate = await send(
      pairingApi,
      path: HostManagementRoutes.pairingCreate,
      token: validToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-other',
        'actorId': 'user-001',
      },
    );
    check(
      outOfScopeCreate.status == 403 && pairingGateway.createCalls == 0,
      'Pairing creation cannot cross the caller exact company and branch scope',
    );
    final clientChosenRole = await send(
      pairingApi,
      path: HostManagementRoutes.pairingCreate,
      token: validToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
        'actorId': 'user-001',
        'deviceRole': 'HOST',
      },
    );
    check(
      clientChosenRole.status == 400 && pairingGateway.createCalls == 0,
      'Clients cannot select or change the server-fixed device role',
    );
    final createdPairing = await send(
      pairingApi,
      path: HostManagementRoutes.pairingCreate,
      token: validToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
        'actorId': 'user-001',
      },
    );
    check(
      createdPairing.status == 201 &&
          createdPairing.body['managementApiVersion'] == managementApiVersion &&
          createdPairing.body['correlationId'] ==
              createdPairing.headers.value('X-Correlation-ID') &&
          createdPairing.body['pairing']['deviceRole'] == 'CLIENT' &&
          createdPairing.body['pairing']['code'] ==
              FakeIdentityPairingGateway.code,
      'Pairing creation returns a correlated one-time code and fixed CLIENT role',
    );
    const pairingRequestId = 'cor_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final idempotentContractPairing = await send(
      pairingApi,
      path: HostManagementRoutes.pairingCreateV2,
      token: validToken,
      headers: const {'X-Correlation-ID': pairingRequestId},
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
        'actorId': 'user-001',
        'requestId': pairingRequestId,
      },
    );
    check(
      idempotentContractPairing.status == 201 &&
          pairingGateway.lastRequestId == pairingRequestId &&
          idempotentContractPairing.body['correlationId'] == pairingRequestId,
      'Version 2 pairing contract binds the authenticated request reference to Host correlation',
    );
    final mismatchedPairingReference = await send(
      pairingApi,
      path: HostManagementRoutes.pairingCreateV2,
      token: validToken,
      headers: const {
        'X-Correlation-ID': 'cor_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      },
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
        'actorId': 'user-001',
        'requestId': 'cor_cccccccccccccccccccccccccccccccc',
      },
    );
    check(
      mismatchedPairingReference.status == 400 &&
          mismatchedPairingReference.body['error']['code'] ==
              'INVALID_REQUEST' &&
          pairingGateway.createCalls == 2,
      'Version 2 rejects mismatched request and correlation references before mutation',
    );
    pairingGateway.failCreate = true;
    const uncertainPairingRequestId = 'cor_dddddddddddddddddddddddddddddddd';
    final uncertainPairing = await send(
      pairingApi,
      path: HostManagementRoutes.pairingCreateV2,
      token: validToken,
      headers: const {'X-Correlation-ID': uncertainPairingRequestId},
      body: {
        'managementApiVersion': managementApiVersion,
        'companyId': 'company-001',
        'branchId': 'branch-001',
        'actorId': 'user-001',
        'requestId': uncertainPairingRequestId,
      },
    );
    final uncertainDiagnostic = pairingDiagnostics.recent().first;
    check(
      uncertainPairing.status == 503 &&
          uncertainPairing.body['error']['code'] == 'PAIRING_OUTCOME_UNKNOWN' &&
          uncertainPairing.body['correlationId'] == uncertainPairingRequestId &&
          uncertainDiagnostic.code == 'PAIRING_OUTCOME_UNKNOWN' &&
          uncertainDiagnostic.category ==
              ManagementDiagnosticCategory.pairing &&
          uncertainDiagnostic.protectedFailureType == 'StateError' &&
          !jsonEncode(
            uncertainDiagnostic.toJson(),
          ).contains('synthetic-secret'),
      'Unexpected pairing processing failures return a correlated unknown outcome without exposing private details',
    );
    pairingGateway.failCreate = false;
    final credentialShapedDeviceId = await send(
      pairingApi,
      path: HostManagementRoutes.pairingRedeem,
      body: {
        'managementApiVersion': managementApiVersion,
        'code': FakeIdentityPairingGateway.code,
        'deviceId': List.filled(43, 'a').join(),
      },
    );
    check(
      credentialShapedDeviceId.status == 400 &&
          credentialShapedDeviceId.body['error']['code'] == 'INVALID_REQUEST' &&
          pairingGateway.redeemCalls == 0,
      'Credential-shaped device IDs are rejected before enrollment',
    );
    final redeemedPairing = await send(
      pairingApi,
      path: HostManagementRoutes.pairingRedeem,
      body: {
        'managementApiVersion': managementApiVersion,
        'code': FakeIdentityPairingGateway.code,
        'deviceId': 'client-device-001',
      },
    );
    check(
      redeemedPairing.status == 201 &&
          pairingGateway.lastRedeemedCode == FakeIdentityPairingGateway.code &&
          pairingGateway.lastDeviceId == 'client-device-001' &&
          redeemedPairing.body['enrollment']['deviceRole'] == 'CLIENT' &&
          redeemedPairing.body['enrollment']['credential'] ==
              FakeIdentityPairingGateway.credential &&
          redeemedPairing.body['correlationId'] ==
              redeemedPairing.headers.value('X-Correlation-ID'),
      'Pairing redemption is unauthenticated but returns a correlated device-bound enrollment contract',
    );
    pairingGateway.failRedeem = true;
    final secretFailure = await send(
      pairingApi,
      path: HostManagementRoutes.pairingRedeem,
      body: {
        'managementApiVersion': managementApiVersion,
        'code': FakeIdentityPairingGateway.code,
        'deviceId': 'client-device-002',
      },
    );
    final diagnosticJson = jsonEncode(
      pairingDiagnostics.recent().map((event) => event.toJson()).toList(),
    );
    check(
      secretFailure.status == 410 &&
          secretFailure.body['error']['code'] == 'PAIRING_INVALID_OR_EXPIRED' &&
          !diagnosticJson.contains(FakeIdentityPairingGateway.code) &&
          !diagnosticJson.contains(FakeIdentityPairingGateway.credential),
      'Pairing errors use stable codes and diagnostics exclude code and credential material',
    );
    final unsupportedPairingVersion = await send(
      pairingApi,
      path: HostManagementRoutes.pairingRedeem,
      body: {
        'managementApiVersion': managementApiVersion + 1,
        'code': FakeIdentityPairingGateway.code,
        'deviceId': 'client-device-003',
      },
    );
    check(
      unsupportedPairingVersion.status == 400 &&
          unsupportedPairingVersion.body['error']['code'] == 'INVALID_REQUEST',
      'Pairing endpoints reject unsupported contract versions',
    );
  } finally {
    await pairingApi.close();
  }

  final rateLimitGateway = FakeIdentityPairingGateway();
  final rateLimitApi = await HostApi.bind(
    authenticator: PairingContractAuthenticator(),
    executor: FakeAuthoritativeExecutor(),
    identityPairing: rateLimitGateway,
  );
  try {
    final replies = <Reply>[];
    for (var attempt = 0; attempt < 11; attempt++) {
      replies.add(
        await send(
          rateLimitApi,
          path: HostManagementRoutes.pairingRedeem,
          body: {
            'managementApiVersion': managementApiVersion,
            'code': FakeIdentityPairingGateway.code,
            'deviceId': 'rate-client-$attempt',
          },
        ),
      );
    }
    check(
      replies.take(10).every((reply) => reply.status == 201) &&
          replies.last.status == 429 &&
          replies.last.headers.value('Retry-After') == '60' &&
          replies.last.body['error']['code'] == 'PAIRING_RATE_LIMITED',
      'Pairing redemption enforces a per-source bounded attempt rate',
    );
  } finally {
    await rateLimitApi.close();
  }

  final credentialReissueGateway = FakeCredentialReissueGateway();
  final credentialReissueDiagnostics = ManagementDiagnosticBuffer();
  final credentialReissueApi = await HostApi.bind(
    authenticator: FakeManagementAuthenticator(),
    executor: FakeAuthoritativeExecutor(),
    credentialReissues: credentialReissueGateway,
    diagnostics: credentialReissueDiagnostics,
  );
  try {
    final claim = await send(
      credentialReissueApi,
      path: HostManagementRoutes.credentialReissueClaim,
      token: validToken,
      body: {'managementApiVersion': managementApiVersion},
    );
    final replacement = claim.body['credentialReissue'] as Map<String, dynamic>;
    check(
      claim.status == 200 &&
          replacement['deviceId'] == 'client-001' &&
          replacement['state'] == 'PREPARED' &&
          replacement['credential'] == FakeCredentialReissueGateway.replacement &&
          credentialReissueGateway.claims == 1,
      'A pending credential update is returned only through its authenticated existing device session',
    );
    final malformedClaim = await send(
      credentialReissueApi,
      path: HostManagementRoutes.credentialReissueClaim,
      token: validToken,
      body: {
        'managementApiVersion': managementApiVersion,
        'operationId': 'invalid',
      },
    );
    check(
      malformedClaim.status == 400 && credentialReissueGateway.claims == 1,
      'Credential update claim rejects malformed operation references before gateway access',
    );
    final missingCredential = await send(
      credentialReissueApi,
      path: HostManagementRoutes.credentialReissueClaim,
      body: {'managementApiVersion': managementApiVersion},
    );
    check(
      missingCredential.status == 401 && credentialReissueGateway.claims == 1,
      'Credential update claim requires the currently enrolled device credential',
    );
    final acknowledgment = await send(
      credentialReissueApi,
      path: HostManagementRoutes.credentialReissueAcknowledge,
      token: FakeCredentialReissueGateway.replacement,
      body: {
        'managementApiVersion': managementApiVersion,
        'operationId': 'reissue_0123456789abcdef0123456789abcdef',
      },
    );
    final diagnosticJson = jsonEncode(
      credentialReissueDiagnostics.recent().map((event) => event.toJson()).toList(),
    );
    check(
      acknowledgment.status == 200 &&
          credentialReissueGateway.acknowledgments == 1 &&
          credentialReissueGateway.acknowledgedToken ==
              FakeCredentialReissueGateway.replacement &&
          acknowledgment.body['credentialReissue']['state'] == 'FINALIZED' &&
          !diagnosticJson.contains(FakeCredentialReissueGateway.replacement),
      'Credential update acknowledgment proves replacement possession and diagnostics exclude the credential',
    );
  } finally {
    await credentialReissueApi.close();
  }

  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', 'bin/development_host.dart'],
    environment: {
      'VENTIO_ENVIRONMENT': 'production',
      'VENTIO_ENABLE_DEVELOPMENT_API': 'yes',
    },
  );
  check(
    result.exitCode == 2,
    'Development launcher refuses production configuration',
  );
  stdout.writeln('RESULT: $assertions passed, 0 failed');
}
