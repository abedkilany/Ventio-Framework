import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/ventio_native_client.dart';

class _MemoryCredentialBackend implements HostCredentialBackend {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

ExtensionBundle _bundle() => ExtensionBundle.fromJson({
  'manifest': {
    'manifestVersion': 0,
    'moduleId': 'com.example.host_package',
    'version': '1.0.0',
    'minPlatformApi': '0.1.0',
    'displayName': 'Host Package',
    'displayNameKey': 'extension.com_example_host_package.name',
    'englishCatalog': 'localization/en.host_package.json',
    'dependencies': <String>[],
    'docTypes': ['Item'],
    'commands': <Object>[],
    'requiredCapabilities': <String>[],
    'offline': {'enabled': false, 'allowedCommands': <String>[]},
  },
  'docTypes': [
    {
      'name': 'Item',
      'moduleId': 'com.example.host_package',
      'schemaVersion': 1,
      'kind': 'operational',
      'label': 'Item',
      'labelKey': 'extension.com_example_host_package.item',
      'operations': ['read', 'create', 'update'],
      'permissions': {
        'read': 'extension.com_example_host_package.item.read',
        'create': 'extension.com_example_host_package.item.create',
        'update': 'extension.com_example_host_package.item.update',
      },
      'fields': [
        {
          'name': 'title',
          'type': 'text',
          'required': true,
          'label': 'Title',
          'labelKey': 'extension.com_example_host_package.item.title',
          'maxLength': 100,
        },
      ],
      'ui': {
        'listColumns': ['title'],
        'formFields': ['title'],
      },
    },
  ],
  'dependencyVersions': <String, String>{},
  'englishCatalog': {
    'extension.com_example_host_package.name': 'Host Package',
    'extension.com_example_host_package.item': 'Item',
    'extension.com_example_host_package.item.title': 'Title',
  },
});

void main() {
  const token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';

  test(
    'Discovers the authenticated Host scope without trusting local claims',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final seen = Completer<Map<String, String?>>();
      server.listen((request) async {
        seen.complete({
          'method': request.method,
          'path': request.uri.path,
          'authorization': request.headers.value(
            HttpHeaders.authorizationHeader,
          ),
        });
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'apiVersion': hostApiVersion,
              'identity': {
                'tenantId': 'tenant-1',
                'actorId': 'user-1',
                'deviceId': 'device-1',
                'persistent': true,
                'roleAdministrationAvailable': true,
                'scopes': [
                  {
                    'companyId': 'company-1',
                    'branchId': 'branch-1',
                    'permissions': ['extension.package.read'],
                  },
                ],
              },
            }),
          );
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final vault = HostCredentialVault(_MemoryCredentialBackend());
      await vault.save(endpoint, token);

      final identity = await HostExtensionPackageClient(
        endpoint: endpoint,
        credentials: vault,
      ).session();
      final request = await seen.future;

      expect(request, {
        'method': 'GET',
        'path': '/api/v1/session',
        'authorization': 'Bearer $token',
      });
      expect(identity.tenantId, 'tenant-1');
      expect(identity.persistent, isTrue);
      expect(identity.scopes.single.permissions, {'extension.package.read'});
    },
  );

  test('Lists Host roles for the requested exact branch', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = Completer<Map<String, dynamic>>();
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      seen.complete({
        'method': request.method,
        'path': request.uri.path,
        'authorization': request.headers.value(HttpHeaders.authorizationHeader),
        'body': body,
      });
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'apiVersion': hostApiVersion,
            'identityRoles': {
              'tenantId': 'tenant-1',
              'companyId': 'company-1',
              'branchId': 'branch-1',
              'roles': [
                {
                  'roleId': 'branch-editor',
                  'displayName': 'Branch editor',
                  'permissions': ['example.item.read'],
                  'assignedActorIds': ['user-1'],
                },
              ],
            },
          }),
        );
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final vault = HostCredentialVault(_MemoryCredentialBackend());
    await vault.save(endpoint, token);
    final client = HostExtensionPackageClient(
      endpoint: endpoint,
      credentials: vault,
    );

    final snapshot = await client.listRoles(
      companyId: 'company-1',
      branchId: 'branch-1',
    );
    final request = await seen.future;
    expect(request, {
      'method': 'POST',
      'path': '/api/v1/identity/roles/list',
      'authorization': 'Bearer $token',
      'body': {'companyId': 'company-1', 'branchId': 'branch-1'},
    });
    expect(snapshot.tenantId, 'tenant-1');
    expect(snapshot.roles.single.roleId, 'branch-editor');
    expect(snapshot.roles.single.permissions, {'example.item.read'});
    expect(snapshot.roles.single.assignedActorIds, ['user-1']);
  });

  test('Rejects a role snapshot returned for another branch', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'apiVersion': hostApiVersion,
            'identityRoles': {
              'tenantId': 'tenant-1',
              'companyId': 'company-1',
              'branchId': 'other-branch',
              'roles': <Object>[],
            },
          }),
        );
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final vault = HostCredentialVault(_MemoryCredentialBackend());
    await vault.save(endpoint, token);

    await expectLater(
      HostExtensionPackageClient(
        endpoint: endpoint,
        credentials: vault,
      ).listRoles(companyId: 'company-1', branchId: 'branch-1'),
      throwsA(
        isA<HostPackageTransportException>().having(
          (error) => error.code,
          'code',
          'HOST_INVALID_RESPONSE',
        ),
      ),
    );
  });

  test('Sends role changes through the explicit Host routes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      requests.add({
        'path': request.uri.path,
        'body': jsonDecode(await utf8.decoder.bind(request).join()),
      });
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'apiVersion': hostApiVersion,
            'identityRoleResult': {'status': 'APPLIED'},
          }),
        );
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final vault = HostCredentialVault(_MemoryCredentialBackend());
    await vault.save(endpoint, token);
    final client = HostExtensionPackageClient(
      endpoint: endpoint,
      credentials: vault,
    );

    await client.createRole(
      companyId: 'company-1',
      branchId: 'branch-1',
      roleId: 'branch-editor',
      displayName: 'Branch editor',
    );
    await client.renameRole(
      companyId: 'company-1',
      branchId: 'branch-1',
      roleId: 'branch-editor',
      displayName: 'Editor',
    );
    await client.grantRolePermission(
      companyId: 'company-1',
      branchId: 'branch-1',
      roleId: 'branch-editor',
      permission: 'example.item.read',
    );
    await client.revokeRolePermission(
      companyId: 'company-1',
      branchId: 'branch-1',
      roleId: 'branch-editor',
      permission: 'example.item.read',
    );
    await client.assignRole(
      companyId: 'company-1',
      branchId: 'branch-1',
      roleId: 'branch-editor',
      actorId: 'user-1',
    );
    await client.unassignRole(
      companyId: 'company-1',
      branchId: 'branch-1',
      roleId: 'branch-editor',
      actorId: 'user-1',
    );
    await client.deleteRole(
      companyId: 'company-1',
      branchId: 'branch-1',
      roleId: 'branch-editor',
    );

    expect(requests, [
      {
        'path': '/api/v1/identity/roles/create',
        'body': {
          'companyId': 'company-1',
          'branchId': 'branch-1',
          'roleId': 'branch-editor',
          'displayName': 'Branch editor',
        },
      },
      {
        'path': '/api/v1/identity/roles/rename',
        'body': {
          'companyId': 'company-1',
          'branchId': 'branch-1',
          'roleId': 'branch-editor',
          'displayName': 'Editor',
        },
      },
      {
        'path': '/api/v1/identity/roles/grant-permission',
        'body': {
          'companyId': 'company-1',
          'branchId': 'branch-1',
          'roleId': 'branch-editor',
          'permission': 'example.item.read',
        },
      },
      {
        'path': '/api/v1/identity/roles/revoke-permission',
        'body': {
          'companyId': 'company-1',
          'branchId': 'branch-1',
          'roleId': 'branch-editor',
          'permission': 'example.item.read',
        },
      },
      {
        'path': '/api/v1/identity/roles/assign',
        'body': {
          'companyId': 'company-1',
          'branchId': 'branch-1',
          'roleId': 'branch-editor',
          'actorId': 'user-1',
        },
      },
      {
        'path': '/api/v1/identity/roles/unassign',
        'body': {
          'companyId': 'company-1',
          'branchId': 'branch-1',
          'roleId': 'branch-editor',
          'actorId': 'user-1',
        },
      },
      {
        'path': '/api/v1/identity/roles/delete',
        'body': {
          'companyId': 'company-1',
          'branchId': 'branch-1',
          'roleId': 'branch-editor',
        },
      },
    ]);
  });

  test(
    'Submits candidates and installs only verified approved packages',
    () async {
      final bundle = _bundle();
      final packageHash = sha256
          .convert(utf8.encode(canonicalJson(bundle.toJson())))
          .toString();
      final received = <String, Object?>{};
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final bodyText = await utf8.decoder.bind(request).join();
        received['path'] = request.uri.path;
        received['authorization'] = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        received['body'] = bodyText;
        final result = request.uri.path.endsWith('/submit')
            ? {'status': 'SUBMITTED', 'moduleId': bundle.moduleId}
            : {
                'status': 'APPROVED',
                'moduleId': bundle.moduleId,
                'version': bundle.version,
                'packageSha256': packageHash,
                'package': bundle.toJson(),
              };
        request.response
          ..statusCode = request.uri.path.endsWith('/submit')
              ? HttpStatus.accepted
              : HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({'apiVersion': hostApiVersion, 'packageResult': result}),
          );
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final vault = HostCredentialVault(_MemoryCredentialBackend());
      await vault.save(endpoint, token);
      final client = HostExtensionPackageClient(
        endpoint: endpoint,
        credentials: vault,
      );

      expect(
        await client.submit(
          bundle: bundle,
          companyId: 'company-1',
          branchId: 'branch-1',
        ),
        HostPackageSubmissionStatus.submitted,
      );
      expect(received['path'], '/api/v1/extensions/submit');
      expect(received['authorization'], 'Bearer $token');
      final sent =
          jsonDecode(received['body']! as String) as Map<String, dynamic>;
      expect(sent['companyId'], 'company-1');
      expect(sent['branchId'], 'branch-1');

      final installed = await client.readApproved(
        moduleId: bundle.moduleId,
        version: bundle.version,
        companyId: 'company-1',
        branchId: 'branch-1',
      );
      expect(received['path'], '/api/v1/extensions/read');
      expect(installed.moduleId, bundle.moduleId);
      expect(installed.version, bundle.version);
    },
  );

  test(
    'Lists only validated approved package summaries with a bounded cursor',
    () async {
      final bundle = _bundle();
      final packageHash = sha256
          .convert(utf8.encode(canonicalJson(bundle.toJson())))
          .toString();
      final received = Completer<Map<String, dynamic>>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final body = Map<String, dynamic>.from(
          jsonDecode(await utf8.decoder.bind(request).join()) as Map,
        );
        received.complete(body);
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'apiVersion': hostApiVersion,
              'packageResult': {
                'status': 'APPROVED',
                'packages': [
                  {
                    'moduleId': bundle.moduleId,
                    'version': bundle.version,
                    'packageSha256': packageHash,
                    'displayName': bundle.manifest.displayName,
                    'description': null,
                  },
                ],
                'hasMore': true,
              },
            }),
          );
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final vault = HostCredentialVault(_MemoryCredentialBackend());
      await vault.save(endpoint, token);

      final page =
          await HostExtensionPackageClient(
            endpoint: endpoint,
            credentials: vault,
          ).listApproved(
            companyId: 'company-1',
            branchId: 'branch-1',
            limit: 1,
            afterModuleId: 'com.example.before',
            afterVersion: '2.0.0',
          );
      final sent = await received.future;
      expect(sent['companyId'], 'company-1');
      expect(sent['branchId'], 'branch-1');
      expect(sent['limit'], 1);
      expect(sent['afterModuleId'], 'com.example.before');
      expect(sent['afterVersion'], '2.0.0');
      expect(page.hasMore, isTrue);
      expect(page.packages, hasLength(1));
      expect(page.packages.single.packageSha256, packageHash);
      expect(page.nextCursor?.moduleId, bundle.moduleId);
    },
  );

  test('Rejects malformed approved registry summaries', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'apiVersion': hostApiVersion,
            'packageResult': {
              'status': 'APPROVED',
              'packages': [
                {
                  'moduleId': '../escape',
                  'version': '1.0.0',
                  'packageSha256': List.filled(64, 'a').join(),
                  'displayName': 'Unsafe summary',
                  'description': null,
                },
              ],
              'hasMore': false,
            },
          }),
        );
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final vault = HostCredentialVault(_MemoryCredentialBackend());
    await vault.save(endpoint, token);

    await expectLater(
      HostExtensionPackageClient(
        endpoint: endpoint,
        credentials: vault,
      ).listApproved(companyId: 'company-1', branchId: 'branch-1'),
      throwsA(
        isA<HostPackageTransportException>().having(
          (error) => error.code,
          'code',
          'HOST_INVALID_RESPONSE',
        ),
      ),
    );
  });

  test(
    'Rejects a package whose Host digest does not match its metadata',
    () async {
      final bundle = _bundle();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'apiVersion': hostApiVersion,
              'packageResult': {
                'status': 'APPROVED',
                'moduleId': bundle.moduleId,
                'version': bundle.version,
                'packageSha256': List.filled(64, '0').join(),
                'package': bundle.toJson(),
              },
            }),
          );
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final vault = HostCredentialVault(_MemoryCredentialBackend());
      await vault.save(endpoint, token);

      await expectLater(
        HostExtensionPackageClient(
          endpoint: endpoint,
          credentials: vault,
        ).readApproved(
          moduleId: bundle.moduleId,
          version: bundle.version,
          companyId: 'company-1',
          branchId: 'branch-1',
        ),
        throwsA(
          isA<HostPackageTransportException>().having(
            (error) => error.code,
            'code',
            'HOST_PACKAGE_INTEGRITY_FAILED',
          ),
        ),
      );
    },
  );

  test(
    'Queries bounded Host records with explicit filters and paging',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final seen = Completer<Map<String, dynamic>>();
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        seen.complete(Map<String, dynamic>.from(body as Map));
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'apiVersion': hostApiVersion,
              'recordResult': {
                'status': 'RECORDS',
                'packageSha256': List.filled(64, 'a').join(),
                'readableFields': ['title'],
                'writableFields': [],
                'creatableFields': ['title'],
                'hasMore': true,
                'nextCursor': 'c29tZS1jdXJzb3I',
                'records': [
                  {
                    'recordId': 'item-1',
                    'revision': 3,
                    'updatedAtUtc': '2026-10-24T12:00:00Z',
                    'values': {'title': 'First item'},
                  },
                ],
              },
            }),
          );
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final vault = HostCredentialVault(_MemoryCredentialBackend());
      await vault.save(endpoint, token);

      final page =
          await HostExtensionPackageClient(
            endpoint: endpoint,
            credentials: vault,
          ).queryRecords(
            companyId: 'company-1',
            branchId: 'branch-1',
            moduleId: 'com.example.host_package',
            version: '1.0.0',
            docType: 'Item',
            search: 'first',
            filterField: 'title',
            filterContains: 'item',
            sortField: 'title',
            offset: 50,
            limit: 25,
          );
      final body = await seen.future;

      expect(body['companyId'], 'company-1');
      expect(body['branchId'], 'branch-1');
      expect(body['filterField'], 'title');
      expect(body['filterContains'], 'item');
      expect(body['offset'], 50);
      expect(body['limit'], 25);
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 'c29tZS1jdXJzb3I');
      expect(page.packageSha256, List.filled(64, 'a').join());
      expect(page.readableFields, {'title'});
      expect(page.writableFields, isEmpty);
      expect(page.creatableFields, {'title'});
      expect(page.records.single.recordId, 'item-1');
      expect(page.records.single.revision, 3);
      expect(page.records.single.values['title'], 'First item');
    },
  );

  test('Record query sends an exact Host record selector', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = Completer<Map<String, dynamic>>();
    server.listen((request) async {
      final raw = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      seen.complete(Map<String, dynamic>.from(raw));
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'apiVersion': hostApiVersion,
            'recordResult': {
              'status': 'RECORDS',
              'packageSha256': List.filled(64, 'a').join(),
              'hasMore': false,
              'records': [
                {
                  'recordId': 'record-1',
                  'revision': 2,
                  'updatedAtUtc': '2026-10-24T12:00:00Z',
                  'values': {'title': 'Host value'},
                },
              ],
            },
          }),
        );
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final vault = HostCredentialVault(_MemoryCredentialBackend());
    await vault.save(endpoint, token);

    final page =
        await HostExtensionPackageClient(
          endpoint: endpoint,
          credentials: vault,
        ).queryRecords(
          companyId: 'company-1',
          branchId: 'branch-1',
          moduleId: 'com.example.host_package',
          version: '1.0.0',
          docType: 'Item',
          recordId: 'record-1',
          sortField: null,
          limit: 1,
        );
    final body = await seen.future;

    expect(body['recordId'], 'record-1');
    expect(body['offset'], 0);
    expect(body['limit'], 1);
    expect(page.records.single.recordId, 'record-1');
    expect(page.records.single.values['title'], 'Host value');
  });

  test('Record query sends a keyset continuation cursor', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = Completer<Map<String, dynamic>>();
    server.listen((request) async {
      final raw = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      seen.complete(Map<String, dynamic>.from(raw));
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'apiVersion': hostApiVersion,
            'recordResult': {
              'status': 'RECORDS',
              'packageSha256': List.filled(64, 'a').join(),
              'hasMore': false,
              'nextCursor': null,
              'records': <Object>[],
            },
          }),
        );
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final vault = HostCredentialVault(_MemoryCredentialBackend());
    await vault.save(endpoint, token);
    final cursor = List.filled(4096, 'c').join();
    final page =
        await HostExtensionPackageClient(
          endpoint: endpoint,
          credentials: vault,
        ).queryRecords(
          companyId: 'company-1',
          branchId: 'branch-1',
          moduleId: 'com.example.host_package',
          version: '1.0.0',
          docType: 'Item',
          search: 'first',
          sortField: 'title',
          cursor: cursor,
          limit: 25,
        );
    final body = await seen.future;
    expect(body['cursor'], cursor);
    expect(body['offset'], 0);
    expect(page.nextCursor, isNull);
  });

  test('Report query sends fixed metadata selectors and parses exact results', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = Completer<Map<String, dynamic>>();
    server.listen((request) async {
      final raw = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      seen.complete(Map<String, dynamic>.from(raw));
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'apiVersion': hostApiVersion,
          'reportResult': {
            'status': 'REPORT',
            'reportId': 'amounts',
            'packageSha256': List.filled(64, 'a').join(),
            'rowCount': 3,
            'groups': [
              {
                'key': 'North',
                'aggregates': {'row_count': '3', 'sum_amount': '0.32'},
              },
            ],
          },
        }));
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final vault = HostCredentialVault(_MemoryCredentialBackend());
    await vault.save(endpoint, token);
    final result = await HostExtensionPackageClient(
      endpoint: endpoint,
      credentials: vault,
    ).queryReport(
      companyId: 'company-1',
      branchId: 'branch-1',
      moduleId: 'com.example.host_package',
      version: '1.0.0',
      docType: 'Item',
      reportId: 'amounts',
      filters: const {'status': 'active'},
    );
    final body = await seen.future;
    expect(body['docType'], 'Item');
    expect(body['reportId'], 'amounts');
    expect(body['filters'], {'status': 'active'});
    expect(result.rowCount, 3);
    expect(result.groups.single.aggregates['sum_amount'], '0.32');
  });
}
