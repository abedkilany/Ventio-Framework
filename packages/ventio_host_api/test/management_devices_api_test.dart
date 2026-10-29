import 'dart:convert';

import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart';

class _DeviceAuthenticator implements PersistentHostAuthenticator {
  @override
  Future<AuthenticatedSession?> authenticate(String token) async {
    if (token != validToken && token != deniedToken) return null;
    final permissions = token == validToken
        ? {identityDevicesManagePermission}
        : {'maintenance.read'};
    final scope = PrincipalScope(
      companyId: 'company-001',
      branchId: 'branch-001',
      permissions: permissions,
    );
    return AuthenticatedSession.persistent(
      Principal(
        actorId: 'manager-001',
        deviceId: 'client-manager-001',
        tenantId: 'device-api-test',
        companyIds: {'company-001'},
        branchIds: {'branch-001'},
        permissions: permissions,
        scopeGrants: [scope],
      ),
      OpaqueToken.digest(token),
    );
  }
}

class _DeviceExecutor implements AuthoritativeCommandExecutor {
  @override
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session,
  ) async =>
      CommandReceipt(commandId: command.commandId, status: 'ACCEPTED').toJson();
}

class _DeviceGateway
    implements AuthoritativeIdentityDeviceAdministrationGateway {
  int listCalls = 0;
  int revokeCalls = 0;
  bool unsafe = false;
  String? revokedDeviceId;

  @override
  Future<Map<String, dynamic>> list({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
  }) async {
    listCalls++;
    return {
      'tenantId': session.principal.tenantId,
      'companyId': companyId,
      'branchId': branchId,
      'items': [
        {
          'deviceId': 'client-device-001',
          'actorId': 'usr_0123456789abcdef0123456789abcdef',
          'role': 'CLIENT',
          'registrationState': 'REGISTERED',
          'registeredAtUtc': '2026-10-30T00:00:00.000Z',
          'lastAuthenticatedAtUtc': unsafe ? 'Bearer synthetic-secret' : null,
          'credentials': [
            {
              'credentialId': 'cred_0123456789abcdef0123456789abcdef',
              'state': 'ACTIVE',
              'expiresAtUtc': '2026-11-29T00:00:00.000Z',
              'revokedAtUtc': null,
            },
          ],
        },
      ],
    };
  }

  @override
  Future<void> revoke({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String deviceId,
  }) async {
    revokeCalls++;
    revokedDeviceId = deviceId;
  }
}

Future<void> main() async {
  final gateway = _DeviceGateway();
  final api = await HostApi.bind(
    authenticator: _DeviceAuthenticator(),
    executor: _DeviceExecutor(),
    identityDeviceAdministration: gateway,
  );
  try {
    Map<String, Object?> body({
      String company = 'company-001',
      String branch = 'branch-001',
      Map<String, Object?> extra = const {},
    }) => {
      'managementApiVersion': managementApiVersion,
      'companyId': company,
      'branchId': branch,
      ...extra,
    };

    final unauthenticated = await send(
      api,
      path: HostManagementRoutes.devicesList,
      body: body(),
    );
    check(
      unauthenticated.status == 401 && gateway.listCalls == 0,
      'Device inventory requires an authenticated Host identity',
    );

    final denied = await send(
      api,
      path: HostManagementRoutes.devicesList,
      token: deniedToken,
      body: body(),
    );
    check(
      denied.status == 403 &&
          denied.body['error']['code'] == 'PERMISSION_DENIED' &&
          gateway.listCalls == 0,
      'Device inventory requires the dedicated exact-scope permission',
    );

    final wrongBranch = await send(
      api,
      path: HostManagementRoutes.devicesList,
      token: validToken,
      body: body(branch: 'branch-other'),
    );
    check(
      wrongBranch.status == 403 && gateway.listCalls == 0,
      'Device inventory cannot cross the authenticated branch scope',
    );

    final listed = await send(
      api,
      path: HostManagementRoutes.devicesList,
      token: validToken,
      body: body(),
    );
    final snapshot = listed.body['devices'] as Map;
    final device = (snapshot['items'] as List).single as Map;
    check(
      listed.status == 200 &&
          listed.body['managementApiVersion'] == managementApiVersion &&
          listed.body['correlationId'] ==
              listed.headers.value('X-Correlation-ID') &&
          device['role'] == 'CLIENT' &&
          device['lastAuthenticatedAtUtc'] == null &&
          !jsonEncode(listed.body).contains('tokenDigest') &&
          !jsonEncode(listed.body).contains('Bearer '),
      'Device inventory returns scoped status metadata and no secret material',
    );

    final revoked = await send(
      api,
      path: HostManagementRoutes.devicesRevoke,
      token: validToken,
      body: body(extra: {'deviceId': 'client-device-001'}),
    );
    check(
      revoked.status == 200 &&
          revoked.body['deviceOperation']['status'] == 'APPLIED' &&
          gateway.revokedDeviceId == 'client-device-001' &&
          gateway.revokeCalls == 1,
      'Device revocation calls the authorized Host gateway and correlates success',
    );

    final deniedRevoke = await send(
      api,
      path: HostManagementRoutes.devicesRevoke,
      token: deniedToken,
      body: body(extra: {'deviceId': 'client-device-001'}),
    );
    check(
      deniedRevoke.status == 403 && gateway.revokeCalls == 1,
      'An ordinary user on a Host cannot revoke devices',
    );

    final malformed = await send(
      api,
      path: HostManagementRoutes.devicesRevoke,
      token: validToken,
      body: body(extra: {'deviceId': List.filled(43, 'a').join()}),
    );
    check(
      malformed.status == 400 && gateway.revokeCalls == 1,
      'Malformed credential-shaped device IDs are rejected before the gateway',
    );

    gateway.unsafe = true;
    final unsafe = await send(
      api,
      path: HostManagementRoutes.devicesList,
      token: validToken,
      body: body(),
    );
    check(
      unsafe.status == 503 &&
          unsafe.body['error']['code'] == 'HOST_INVALID_RESPONSE' &&
          !jsonEncode(unsafe.body).contains('synthetic-secret'),
      'Unsafe device projections fail closed without exposing technical text',
    );

    print('RESULT: $assertions passed, 0 failed');
  } finally {
    await api.close();
  }
}
