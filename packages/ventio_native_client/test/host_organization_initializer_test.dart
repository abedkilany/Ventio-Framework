import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/host_setup.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';
import 'package:ventio_native_client/src/host_organization_initializer.dart';

class _MemoryBackend implements HostCredentialBackend {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

class _FakeHost extends HostExtensionPackageClient {
  _FakeHost()
    : super(
        endpoint: Uri.parse(hostSetupEndpoint),
        credentials: HostCredentialVault(_MemoryBackend()),
      );

  int changes = 0;
  int? failAfterChanges;

  final entities = <Map<String, dynamic>>[
    {
      'kind': 'organization',
      'id': 'org-one',
      'parentId': null,
      'displayName': 'org-one',
      'revision': 1,
      'archived': false,
    },
    {
      'kind': 'company',
      'id': 'cmp-one',
      'parentId': null,
      'displayName': 'cmp-one',
      'revision': 1,
      'archived': false,
    },
    {
      'kind': 'branch',
      'id': 'br-one',
      'parentId': 'cmp-one',
      'displayName': 'br-one',
      'revision': 1,
      'archived': false,
    },
  ];

  @override
  Future<Map<String, dynamic>> platformRequest(
    String action,
    Map<String, Object?> body,
  ) async {
    if (action == 'organization/list') {
      return {
        'status': 'ORGANIZATION',
        'entities': entities
            .map((entity) => Map<String, dynamic>.from(entity))
            .toList(),
      };
    }

    if (action != 'organization/change') {
      throw StateError('Unexpected operation');
    }

    if (failAfterChanges == changes) {
      throw StateError('Simulated interruption');
    }

    final change = body['change'] as Map;
    final entity = entities.singleWhere(
      (entity) =>
          entity['id'] == change['id'] &&
          entity['kind'] == change['kind'] &&
          entity['parentId'] == change['parentId'],
    );

    expect(change['expectedRevision'], entity['revision']);
    expect(change['archived'], isFalse);

    entity['displayName'] = change['displayName'];
    entity['revision'] = (entity['revision'] as int) + 1;
    changes++;

    return {'status': 'SAVED'};
  }
}

void main() {
  final scope = HostSetupScope(
    tenantId: 'org-one',
    companyId: 'cmp-one',
    branchId: 'br-one',
  );

  Future<void> initialize(_FakeHost host) =>
      HostOrganizationInitializer(host).apply(
        scope: scope,
        organizationName: 'Test Organization',
        companyName: 'Test Company',
        branchName: 'Main Branch',
      );

  test('Initializes all three display names', () async {
    final host = _FakeHost();

    await initialize(host);

    expect(host.entities[0]['displayName'], 'Test Organization');
    expect(host.entities[1]['displayName'], 'Test Company');
    expect(host.entities[2]['displayName'], 'Main Branch');
    expect(host.changes, 3);
  });

  test('Repeated initialization does not duplicate changes', () async {
    final host = _FakeHost();

    await initialize(host);
    await initialize(host);

    expect(host.changes, 3);
  });

  test('Existing custom names cannot be overwritten', () async {
    final host = _FakeHost();
    host.entities[0]['displayName'] = 'Existing Organization';

    await expectLater(
      initialize(host),
      throwsA(
        isA<HostSetupException>().having(
          (error) => error.code,
          'code',
          'HOST_ORGANIZATION_NAME_CONFLICT',
        ),
      ),
    );

    expect(host.changes, 0);
    expect(host.entities[0]['displayName'], 'Existing Organization');
  });

  test(
    'Interrupted initialization resumes without duplicate changes',
    () async {
      final host = _FakeHost()..failAfterChanges = 1;

      await expectLater(initialize(host), throwsStateError);

      expect(host.changes, 1);
      expect(host.entities[0]['displayName'], 'Test Organization');

      host.failAfterChanges = null;

      await initialize(host);

      expect(host.changes, 3);
      expect(host.entities[0]['revision'], 2);
      expect(host.entities[1]['displayName'], 'Test Company');
      expect(host.entities[2]['displayName'], 'Main Branch');
    },
  );

  test('Archived organization cannot be modified', () async {
    final host = _FakeHost();
    host.entities[0]['archived'] = true;

    await expectLater(
      initialize(host),
      throwsA(
        isA<HostSetupException>().having(
          (error) => error.code,
          'code',
          'HOST_ORGANIZATION_SCOPE_UNAVAILABLE',
        ),
      ),
    );

    expect(host.changes, 0);
  });
}
