import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';
import 'package:ventio_native_client/src/role_administration_page.dart';

class _MemoryCredentialBackend implements HostCredentialBackend {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

class _FakeRoleClient extends HostExtensionPackageClient {
  _FakeRoleClient()
    : super(
        endpoint: Uri.https('host.example'),
        credentials: HostCredentialVault(_MemoryCredentialBackend()),
      );

  final requests = <Map<String, Object?>>[];
  HostIdentityRole? role;

  HostIdentityRole _copyRole({
    Iterable<String>? permissions,
    Iterable<String>? assignedActorIds,
    String? displayName,
  }) => HostIdentityRole(
    roleId: role!.roleId,
    displayName: displayName ?? role!.displayName,
    permissions: permissions ?? role!.permissions,
    assignedActorIds: assignedActorIds ?? role!.assignedActorIds,
  );

  @override
  Future<HostIdentityRoleSnapshot> listRoles({
    required String companyId,
    required String branchId,
  }) async {
    requests.add({
      'path': 'list',
      'companyId': companyId,
      'branchId': branchId,
    });
    return HostIdentityRoleSnapshot(
      tenantId: 'tenant-1',
      companyId: companyId,
      branchId: branchId,
      roles: role == null ? const [] : [role!],
    );
  }

  @override
  Future<void> createRole({
    required String companyId,
    required String branchId,
    required String roleId,
    required String displayName,
  }) async {
    requests.add({
      'path': 'create',
      'companyId': companyId,
      'branchId': branchId,
      'roleId': roleId,
      'displayName': displayName,
    });
    role = HostIdentityRole(
      roleId: roleId,
      displayName: displayName,
      permissions: const [],
      assignedActorIds: const [],
    );
  }

  @override
  Future<void> grantRolePermission({
    required String companyId,
    required String branchId,
    required String roleId,
    required String permission,
  }) async {
    requests.add({
      'path': 'grant-permission',
      'companyId': companyId,
      'branchId': branchId,
      'roleId': roleId,
      'permission': permission,
    });
    role = _copyRole(permissions: {...role!.permissions, permission});
  }

  @override
  Future<void> assignRole({
    required String companyId,
    required String branchId,
    required String roleId,
    required String actorId,
  }) async {
    requests.add({
      'path': 'assign',
      'companyId': companyId,
      'branchId': branchId,
      'roleId': roleId,
      'actorId': actorId,
    });
    role = _copyRole(assignedActorIds: {...role!.assignedActorIds, actorId});
  }
}

void main() {
  testWidgets('Creates roles, grants permissions and assigns branch users', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = _FakeRoleClient();

    await tester.pumpWidget(
      MaterialApp(
        home: RoleAdministrationPage(
          client: client,
          tenantId: 'tenant-1',
          companyId: 'company-1',
          branchId: 'branch-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create role'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'branch-editor');
    await tester.enterText(find.byType(TextFormField).at(1), 'Branch editor');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Branch editor'), findsOneWidget);

    await tester.tap(find.text('Branch editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add permission'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).last,
      'com.example.item.read',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('com.example.item.read'), findsOneWidget);

    await tester.ensureVisible(find.text('Assign user'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assign user'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, 'user-1');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('user-1'), findsOneWidget);

    expect(client.requests.map((request) => request['path']).toList(), [
      'list',
      'create',
      'list',
      'grant-permission',
      'list',
      'assign',
      'list',
    ]);
    expect(client.requests[1]['companyId'], 'company-1');
    expect(client.requests[1]['branchId'], 'branch-1');
    expect(client.requests[3]['permission'], 'com.example.item.read');
    expect(client.requests[5]['actorId'], 'user-1');
  });
}
