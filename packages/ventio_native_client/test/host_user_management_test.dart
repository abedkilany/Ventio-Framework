import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';
import 'package:ventio_native_client/src/host_user_management.dart';
import 'package:ventio_native_client/src/users_permissions_page.dart';

const _token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';
const _correlationId = 'cor_0123456789abcdef0123456789abcdef';

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

class _FakeExchange {
  final requests = <Map<String, Object?>>[];
  HostUserManagementHttpResponse Function(Map<String, Object?> request)?
  respond;

  Future<HostUserManagementHttpResponse> call({
    required Uri uri,
    required Map<String, String> headers,
    required String body,
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    final request = <String, Object?>{
      'uri': uri,
      'headers': headers,
      'body': jsonDecode(body),
      'timeout': timeout,
      'maxResponseBytes': maxResponseBytes,
    };
    requests.add(request);
    return respond?.call(request) ?? _success();
  }
}

HostUserManagementHttpResponse _success([Map<String, Object?>? fields]) =>
    HostUserManagementHttpResponse(
      statusCode: 200,
      body: {
        'apiVersion': 1,
        'managementApiVersion': 1,
        'correlationId': _correlationId,
        ...?fields,
      },
    );

HostSessionIdentity _identity({
  bool persistent = true,
  String companyId = 'company-1',
  String branchId = 'branch-1',
  Iterable<String> permissions = const {'identity.users.manage'},
  bool roleAdministrationAvailable = false,
}) => HostSessionIdentity(
  tenantId: 'tenant-1',
  actorId: 'admin-1',
  deviceId: 'client-1',
  persistent: persistent,
  roleAdministrationAvailable: roleAdministrationAvailable,
  scopes: [
    HostScopeGrant(
      companyId: companyId,
      branchId: branchId,
      permissions: permissions,
    ),
  ],
);

Future<HostUserManagementClient> _newClient(
  _FakeExchange exchange, {
  HostSessionIdentity? identity,
}) async {
  const endpoint = 'https://host.example';
  final backend = _MemoryCredentialBackend();
  final vault = HostCredentialVault(backend);
  await vault.save(Uri.parse(endpoint), _token);
  return HostUserManagementClient(
    endpoint: Uri.parse(endpoint),
    credentials: vault,
    verifiedIdentity: identity ?? _identity(),
    companyId: 'company-1',
    branchId: 'branch-1',
    exchange: exchange.call,
  );
}

void main() {
  group('HostUserManagementClient', () {
    test('uses versioned routes and exact scope for user operations', () async {
      final exchange = _FakeExchange()
        ..respond = (request) {
          final uri = request['uri'] as Uri;
          if (uri.path.endsWith('/list')) {
            return _success({
              'users': {
                'tenantId': 'tenant-1',
                'companyId': 'company-1',
                'branchId': 'branch-1',
                'items': [
                  {
                    'actorId': 'operator-1',
                    'state': 'ACTIVE',
                    'directPermissions': ['maintenance.read'],
                    'roles': ['branch-reader'],
                  },
                ],
              },
            });
          }
          if (uri.path.endsWith('/audit')) {
            return _success({
              'audit': {
                'tenantId': 'tenant-1',
                'companyId': 'company-1',
                'branchId': 'branch-1',
                'events': [
                  {
                    'eventId': 'event-001',
                    'occurredAtUtc': '2026-10-29T12:30:00.000Z',
                    'action': 'PERMISSION_GRANTED',
                    'subjectId': 'operator-1',
                    'operator': 'admin-1',
                  },
                ],
              },
            });
          }
          if (uri.path.endsWith('/create')) {
            return _success({
              'userOperation': {
                'status': 'APPLIED',
                'actorId': 'usr_0123456789abcdef0123456789abcdef',
              },
            });
          }
          return _success({
            'userOperation': {'status': 'APPLIED'},
          });
        };
      final client = await _newClient(exchange);

      final snapshot = await client.listUsers();
      final audit = await client.listAudit();
      final createdActorId = await client.createUser();
      await client.grantPermission(
        actorId: 'new-user',
        permission: 'maintenance.create',
      );
      await client.revokePermission(
        actorId: 'new-user',
        permission: 'maintenance.create',
      );
      await client.disableUser(actorId: 'new-user');
      await client.enableUser(actorId: 'new-user');

      expect(snapshot.users.single.actorId, 'operator-1');
      expect(snapshot.users.single.roles, ['branch-reader']);
      expect(snapshot.users.single.directPermissions, {'maintenance.read'});
      expect(createdActorId, 'usr_0123456789abcdef0123456789abcdef');
      expect(audit.events.single.action, 'PERMISSION_GRANTED');
      expect(audit.events.single.operatorId, 'admin-1');
      expect(
        audit.events.single.occurredAtUtc,
        DateTime.utc(2026, 10, 29, 12, 30),
      );
      expect(exchange.requests.map((request) => (request['uri'] as Uri).path), [
        '/api/v1/management/users/list',
        '/api/v1/management/users/audit',
        '/api/v1/management/users/create',
        '/api/v1/management/users/grant',
        '/api/v1/management/users/revoke',
        '/api/v1/management/users/disable',
        '/api/v1/management/users/enable',
      ]);
      for (final request in exchange.requests) {
        final headers = request['headers'] as Map<String, String>;
        final body = request['body'] as Map<String, dynamic>;
        expect(headers['authorization'], 'Bearer $_token');
        expect(body['managementApiVersion'], 1);
        expect(body['companyId'], 'company-1');
        expect(body['branchId'], 'branch-1');
      }
      expect(exchange.requests[1]['body'], {
        'managementApiVersion': 1,
        'companyId': 'company-1',
        'branchId': 'branch-1',
      });
      expect(exchange.requests[2]['body'], {
        'managementApiVersion': 1,
        'companyId': 'company-1',
        'branchId': 'branch-1',
      });
    });

    test('accepts only a Host-generated opaque user ID on create', () async {
      final exchange = _FakeExchange()
        ..respond = (_) => _success({
          'userOperation': {
            'status': 'APPLIED',
            'actorId': 'caller-controlled-id',
          },
        });
      final client = await _newClient(exchange);
      await expectLater(
        client.createUser(),
        throwsA(
          isA<HostUserManagementException>()
              .having((error) => error.code, 'code', 'HOST_INVALID_RESPONSE')
              .having(
                (error) => error.correlationId,
                'correlationId',
                _correlationId,
              ),
        ),
      );
    });

    test(
      'requires persistent exact-scope identity.users.manage grant',
      () async {
        final exchange = _FakeExchange();
        final clients = [
          await _newClient(
            exchange,
            identity: _identity(permissions: const {'maintenance.read'}),
          ),
          await _newClient(
            exchange,
            identity: _identity(branchId: 'other-branch'),
          ),
          await _newClient(exchange, identity: _identity(persistent: false)),
          await _newClient(
            exchange,
            identity: _identity(
              permissions: const {'identity.users.manage'},
              roleAdministrationAvailable: false,
            ),
          ),
        ];
        expect(clients.map((value) => value.canManageUsers), [
          false,
          false,
          false,
          true,
        ]);
        await expectLater(
          clients.first.listUsers(),
          throwsA(
            isA<HostUserManagementException>().having(
              (error) => error.code,
              'code',
              'HOST_PERMISSION_DENIED',
            ),
          ),
        );
        expect(exchange.requests, isEmpty);
      },
    );

    test(
      'blocks direct management permission grants and revocations',
      () async {
        final exchange = _FakeExchange();
        final client = await _newClient(exchange);
        for (final permission in [
          'identity.users.manage',
          'identity.roles.manage',
          'host.diagnostics.read',
          'system.admin',
          'recovery.restore',
          'maintenance.*',
          'Invalid.Permission',
        ]) {
          expect(
            HostUserManagementClient.isGrantableNonManagementPermission(
              permission,
            ),
            isFalse,
          );
        }
        await expectLater(
          client.grantPermission(
            actorId: 'user-1',
            permission: 'identity.users.manage',
          ),
          throwsA(isA<HostUserManagementException>()),
        );
        await expectLater(
          client.revokePermission(
            actorId: 'user-1',
            permission: 'host.status.read',
          ),
          throwsA(isA<HostUserManagementException>()),
        );
        expect(exchange.requests, isEmpty);
      },
    );

    test(
      'rejects another branch and retains its correlation reference',
      () async {
        final exchange = _FakeExchange()
          ..respond = (_) => _success({
            'users': {
              'tenantId': 'tenant-1',
              'companyId': 'company-1',
              'branchId': 'other-branch',
              'items': <Object>[],
            },
          });
        final client = await _newClient(exchange);
        await expectLater(
          client.listUsers(),
          throwsA(
            isA<HostUserManagementException>()
                .having((error) => error.code, 'code', 'HOST_INVALID_RESPONSE')
                .having(
                  (error) => error.correlationId,
                  'correlationId',
                  _correlationId,
                ),
          ),
        );
      },
    );

    test(
      'rejects audit detail fields and preserves correlation only',
      () async {
        final exchange = _FakeExchange()
          ..respond = (_) => _success({
            'audit': {
              'tenantId': 'tenant-1',
              'companyId': 'company-1',
              'branchId': 'branch-1',
              'events': [
                {
                  'eventId': 'event-002',
                  'occurredAtUtc': '2026-10-29T12:30:00.000Z',
                  'action': 'USER_CREATED',
                  'subjectId': 'new-user',
                  'operator': 'admin-1',
                  'details': 'postgres://sensitive:secret@host/db',
                },
              ],
            },
          });
        final client = await _newClient(exchange);
        await expectLater(
          client.listAudit(),
          throwsA(
            isA<HostUserManagementException>()
                .having((error) => error.code, 'code', 'HOST_INVALID_RESPONSE')
                .having(
                  (error) => error.correlationId,
                  'correlationId',
                  _correlationId,
                )
                .having(
                  (error) => error.toString(),
                  'safe exception text',
                  isNot(contains('sensitive')),
                ),
          ),
        );
      },
    );

    test('accepts only the Host safe audit redaction labels', () async {
      final exchange = _FakeExchange()
        ..respond = (_) => _success({
          'audit': {
            'tenantId': 'tenant-1',
            'companyId': 'company-1',
            'branchId': 'branch-1',
            'events': [
              {
                'eventId': '102',
                'occurredAtUtc': '2026-10-29T12:30:00.000Z',
                'action': 'USER_CREATED',
                'subjectId': '[redacted]',
                'operator': 'Host administrator',
              },
            ],
          },
        });
      final client = await _newClient(exchange);

      final audit = await client.listAudit();

      expect(audit.events, hasLength(1));
      expect(audit.events.single.subjectId, '[redacted]');
      expect(audit.events.single.operatorId, 'Host administrator');

      final unsafeExchange = _FakeExchange()
        ..respond = (_) => _success({
          'audit': {
            'tenantId': 'tenant-1',
            'companyId': 'company-1',
            'branchId': 'branch-1',
            'events': [
              {
                'eventId': '103',
                'occurredAtUtc': '2026-10-29T12:30:00.000Z',
                'action': 'USER_CREATED',
                'subjectId': 'Bearer fixture-secret',
                'operator': 'admin-1',
              },
            ],
          },
        });
      final unsafeClient = await _newClient(unsafeExchange);
      await expectLater(
        unsafeClient.listAudit(),
        throwsA(
          isA<HostUserManagementException>().having(
            (error) => error.code,
            'code',
            'HOST_INVALID_RESPONSE',
          ),
        ),
      );
    });

    test('returns a safe error code and Host correlation reference', () async {
      final exchange = _FakeExchange()
        ..respond = (_) => HostUserManagementHttpResponse(
          statusCode: 403,
          body: {
            'apiVersion': 1,
            'correlationId': _correlationId,
            'error': {
              'code': 'PERMISSION_DENIED',
              'retryable': false,
              'message': 'postgres://ignored-secret:secret@host/db',
            },
          },
        );
      final client = await _newClient(exchange);
      await expectLater(
        client.listUsers(),
        throwsA(
          isA<HostUserManagementException>()
              .having((error) => error.code, 'code', 'PERMISSION_DENIED')
              .having(
                (error) => error.correlationId,
                'correlationId',
                _correlationId,
              )
              .having(
                (error) => error.toString(),
                'safe exception text',
                isNot(contains('ignored-secret')),
              ),
        ),
      );
    });
  });

  group('UsersPermissionsPage', () {
    testWidgets('disables actions without the exact Host grant', (
      tester,
    ) async {
      final client = _FakeUserClient(
        identity: _identity(permissions: const {'maintenance.read'}),
      );
      await tester.pumpWidget(
        MaterialApp(home: UsersPermissionsPage(client: client)),
      );
      await tester.pumpAndSettle();

      expect(find.text('User-management access required'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Create user'),
            )
            .onPressed,
        isNull,
      );
      expect(client.requests, isEmpty);
    });

    testWidgets('creates an unprivileged user and manages scoped permissions', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(480, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = _FakeUserClient(identity: _identity());
      await tester.pumpWidget(
        MaterialApp(home: UsersPermissionsPage(client: client)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Legacy identity 1'), findsWidgets);
      await tester.tap(find.text('Legacy identity 1').first);
      await tester.pumpAndSettle();
      expect(find.text('branch-reader'), findsOneWidget);

      await tester.tap(find.text('Create user'));
      await tester.pumpAndSettle();
      expect(client.requests.first, {'action': 'create'});
      expect(
        find.text('Generated user ID: usr_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
        findsOneWidget,
      );
      expect(
        find.text(
          'User created. Generated ID: usr_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        findsOneWidget,
      );

      const createdId = 'usr_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      await tester.tap(find.text(createdId).first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('managed-user-$createdId')),
          matching: find.text('Grant permission'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'maintenance.create');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('maintenance.create'), findsOneWidget);
      expect(client.requests.last, {
        'action': 'grant',
        'actorId': createdId,
        'permission': 'maintenance.create',
      });

      await tester.tap(find.byTooltip('Revoke permission').last);
      await tester.pumpAndSettle();
      expect(client.requests.last, {
        'action': 'revoke',
        'actorId': createdId,
        'permission': 'maintenance.create',
      });
    });

    testWidgets('confirms both disabling and enabling a user', (tester) async {
      final client = _FakeUserClient(identity: _identity());
      await tester.pumpWidget(
        MaterialApp(home: UsersPermissionsPage(client: client)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Legacy identity 1').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('User actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disable user').first);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Disable user Legacy identity 1 in this Host scope? Login will be suspended. Existing permissions and unrevoked credentials are preserved and may become active again if the user is re-enabled.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        client.requests.where((request) => request['action'] == 'disable'),
        isEmpty,
      );

      await tester.tap(find.byTooltip('User actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disable user').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Disable user'));
      await tester.pumpAndSettle();
      expect(client.requests.last, {
        'action': 'disable',
        'actorId': 'operator-1',
      });
      expect(find.textContaining('Disabled'), findsOneWidget);

      await tester.tap(find.byTooltip('User actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enable user').first);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Re-enable user Legacy identity 1 in this Host scope? Existing permissions and unrevoked, unexpired credentials will work again. Revoke compromised device credentials separately.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        client.requests.where((request) => request['action'] == 'enable'),
        isEmpty,
      );

      await tester.tap(find.byTooltip('User actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enable user').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Enable user'));
      await tester.pumpAndSettle();
      expect(client.requests.last, {
        'action': 'enable',
        'actorId': 'operator-1',
      });
      expect(find.textContaining('Active'), findsOneWidget);
    });

    testWidgets('shows only allowlisted audit fields and UTC time', (
      tester,
    ) async {
      final client = _FakeUserClient(identity: _identity())
        ..auditEvents = [
          HostUserAuditEvent(
            eventId: 'audit-1',
            occurredAtUtc: DateTime.utc(2026, 10, 29, 12, 30),
            action: 'ROLE_ASSIGNED',
            subjectId: 'operator-1',
            operatorId: 'admin-1',
          ),
        ];
      await tester.pumpWidget(
        MaterialApp(home: UsersPermissionsPage(client: client)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Recent administrative activity'), findsOneWidget);
      expect(find.text('Role assigned'), findsOneWidget);
      expect(
        find.text(
          'User Legacy identity 1 · Operator Legacy identity 2 · 2026-10-29 12:30:00 UTC',
        ),
        findsOneWidget,
      );
      expect(find.text('audit-1'), findsNothing);
      expect(find.textContaining('details'), findsNothing);
    });

    testWidgets('masks legacy identifiers that may contain private data', (
      tester,
    ) async {
      const sensitiveIdentifier = 'Bearer-secret-value-that-must-not-appear';
      final client = _FakeUserClient(identity: _identity())
        ..users.clear()
        ..users[sensitiveIdentifier] = HostManagedUser(
          actorId: sensitiveIdentifier,
          state: HostManagedUserState.active,
          directPermissions: const {'maintenance.read'},
        )
        ..auditEvents = [
          HostUserAuditEvent(
            eventId: 'audit-safe',
            occurredAtUtc: DateTime.utc(2026, 10, 29, 12, 30),
            action: 'USER_CREATED',
            subjectId: '[redacted]',
            operatorId: 'Host administrator',
          ),
        ];
      await tester.pumpWidget(
        MaterialApp(home: UsersPermissionsPage(client: client)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining(sensitiveIdentifier), findsNothing);
      expect(find.textContaining('Legacy identity 1'), findsWidgets);
    });
  });
}

class _FakeUserClient extends HostUserManagementClient {
  _FakeUserClient({required HostSessionIdentity identity})
    : super(
        endpoint: Uri.https('host.example'),
        credentials: HostCredentialVault(_MemoryCredentialBackend()),
        verifiedIdentity: identity,
        companyId: 'company-1',
        branchId: 'branch-1',
      );

  final requests = <Map<String, Object?>>[];
  List<HostUserAuditEvent> auditEvents = const [];
  final users = <String, HostManagedUser>{
    'operator-1': HostManagedUser(
      actorId: 'operator-1',
      state: HostManagedUserState.active,
      directPermissions: const {'maintenance.read'},
      roles: const ['branch-reader'],
    ),
  };

  @override
  Future<HostManagedUserSnapshot> listUsers() async => HostManagedUserSnapshot(
    tenantId: 'tenant-1',
    companyId: 'company-1',
    branchId: 'branch-1',
    users: users.values,
  );

  @override
  Future<HostUserAuditSnapshot> listAudit() async => HostUserAuditSnapshot(
    tenantId: 'tenant-1',
    companyId: 'company-1',
    branchId: 'branch-1',
    events: auditEvents,
  );

  @override
  Future<String> createUser() async {
    const actorId = 'usr_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    requests.add({'action': 'create'});
    users[actorId] = HostManagedUser(
      actorId: actorId,
      state: HostManagedUserState.active,
      directPermissions: const [],
    );
    return actorId;
  }

  @override
  Future<void> grantPermission({
    required String actorId,
    required String permission,
  }) async {
    requests.add({
      'action': 'grant',
      'actorId': actorId,
      'permission': permission,
    });
    final user = users[actorId]!;
    users[actorId] = HostManagedUser(
      actorId: actorId,
      state: user.state,
      directPermissions: {...user.directPermissions, permission},
      roles: user.roles,
    );
  }

  @override
  Future<void> revokePermission({
    required String actorId,
    required String permission,
  }) async {
    requests.add({
      'action': 'revoke',
      'actorId': actorId,
      'permission': permission,
    });
    final user = users[actorId]!;
    users[actorId] = HostManagedUser(
      actorId: actorId,
      state: user.state,
      directPermissions: {...user.directPermissions}..remove(permission),
      roles: user.roles,
    );
  }

  @override
  Future<void> disableUser({required String actorId}) async {
    requests.add({'action': 'disable', 'actorId': actorId});
    final user = users[actorId]!;
    users[actorId] = HostManagedUser(
      actorId: actorId,
      state: HostManagedUserState.disabled,
      directPermissions: user.directPermissions,
      roles: user.roles,
    );
  }

  @override
  Future<void> enableUser({required String actorId}) async {
    requests.add({'action': 'enable', 'actorId': actorId});
    final user = users[actorId]!;
    users[actorId] = HostManagedUser(
      actorId: actorId,
      state: HostManagedUserState.active,
      directPermissions: user.directPermissions,
      roles: user.roles,
    );
  }
}
