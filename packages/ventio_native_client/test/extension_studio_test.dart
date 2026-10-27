import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/extension_studio_page.dart';
import 'package:ventio_native_client/src/host_credentials.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';
import 'package:ventio_native_client/src/local_command_queue.dart';

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

class _FakeHostPackageClient extends HostExtensionPackageClient {
  _FakeHostPackageClient({required super.endpoint, required super.credentials});

  HostApprovedPackagePage registryPage = HostApprovedPackagePage(
    packages: const [],
    hasMore: false,
  );
  ExtensionBundle? approvedBundle;
  String? listedCompany;
  String? listedBranch;
  String? expectedDigest;

  @override
  Future<HostSessionIdentity> session() async => HostSessionIdentity(
    tenantId: 'tenant-1',
    actorId: 'user-1',
    deviceId: 'device-1',
    persistent: true,
    roleAdministrationAvailable: true,
    scopes: [
      HostScopeGrant(
        companyId: 'company-1',
        branchId: 'branch-1',
        permissions: const {
          'extension.package.read',
          'extension.package.submit',
        },
      ),
    ],
  );

  @override
  Future<HostApprovedPackagePage> listApproved({
    required String companyId,
    required String branchId,
    int limit = 50,
    String? afterModuleId,
    String? afterVersion,
  }) async {
    listedCompany = companyId;
    listedBranch = branchId;
    return registryPage;
  }

  @override
  Future<ExtensionBundle> readApproved({
    required String moduleId,
    required String version,
    required String companyId,
    required String branchId,
    String? expectedPackageSha256,
  }) async {
    final bundle = approvedBundle;
    if (bundle == null ||
        bundle.moduleId != moduleId ||
        bundle.version != version ||
        (expectedPackageSha256 != null &&
            expectedPackageSha256 != expectedDigest)) {
      throw StateError('Unexpected approved package request.');
    }
    expectedDigest = expectedPackageSha256;
    return bundle;
  }
}

class _FakeRecordQueryClient extends HostExtensionPackageClient {
  _FakeRecordQueryClient({
    required super.endpoint,
    required super.credentials,
    required this.page,
    this.queryError,
  });

  HostExtensionRecordPage page;
  Object? queryError;
  String? queriedCompany;
  String? queriedBranch;
  String? queriedCursor;

  @override
  Future<HostExtensionRecordPage> queryRecords({
    required String companyId,
    required String branchId,
    required String moduleId,
    required String version,
    required String docType,
    String? recordId,
    String search = '',
    Map<String, dynamic> filters = const {},
    String? filterField,
    String filterContains = '',
    String? sortField,
    bool descending = false,
    String? cursor,
    int offset = 0,
    int limit = 50,
  }) async {
    queriedCompany = companyId;
    queriedBranch = branchId;
    queriedCursor = cursor;
    final error = queryError;
    if (error != null) throw error;
    return page;
  }
}

void main() {
  late Directory directory;
  late LocalExtensionStore store;
  late LocalCommandQueue queue;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ventio_studio_test_');
    store = await LocalExtensionStore.open(
      factory: databaseFactoryFfiNoIsolate,
      path: '${directory.path}${Platform.pathSeparator}extensions.sqlite3',
    );
    queue = await LocalCommandQueue.open(
      factory: databaseFactoryFfiNoIsolate,
      path: '${directory.path}${Platform.pathSeparator}commands.sqlite3',
    );
  });

  tearDown(() async {
    await queue.close();
    await store.close();
    await directory.delete(recursive: true);
  });

  testWidgets(
    'Builder exports, reviews and installs a declarative package locally',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const moduleId = 'com.example.package_source';
      const permissionPrefix = 'extension.com_example_package_source.item';
      await store.createExtension(
        moduleId: moduleId,
        displayName: 'Package Source',
        description: 'Portable declarative example.',
      );
      await store.saveDocType({
        'name': 'Item',
        'moduleId': moduleId,
        'schemaVersion': 1,
        'kind': 'operational',
        'fields': [
          {
            'name': 'label',
            'type': 'text',
            'required': true,
            'label': 'Label',
            'labelKey': '$permissionPrefix.label',
            'maxLength': 80,
          },
        ],
        'operations': ['read', 'create', 'update'],
        'permissions': {
          'read': '$permissionPrefix.read',
          'create': '$permissionPrefix.create',
          'update': '$permissionPrefix.update',
        },
        'ui': {
          'listColumns': ['label'],
          'formFields': ['label'],
          'detailFields': ['label'],
        },
        'label': 'Item',
        'labelKey': '$permissionPrefix.name',
        'description': 'A portable item definition.',
        'descriptionKey': '$permissionPrefix.description',
      });
      final package = jsonEncode((await store.exportBundle(moduleId)).toJson());
      await store.remove(moduleId);

      await tester.pumpWidget(
        MaterialApp(
          home: ExtensionStudioPage(store: store, queue: queue),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Install extension package'));
      await tester.pumpAndSettle();
      expect(find.text('Install extension package'), findsOneWidget);
      await tester.enterText(find.byType(TextField), package);
      await tester.tap(find.text('Validate package'));
      await tester.pumpAndSettle();

      expect(find.text('Review extension package'), findsOneWidget);
      expect(find.textContaining(moduleId), findsOneWidget);
      expect(find.textContaining('Item'), findsWidgets);
      await tester.tap(find.text('Install on this device'));
      await tester.pumpAndSettle();

      final installed = await store.getExtension(moduleId);
      expect(installed?.state, ExtensionState.draft);
      expect(find.text('Package Source'), findsWidgets);
      expect(find.text('LOCAL ONLY'), findsWidgets);
      final sourceBundle = Map<String, dynamic>.from(
        jsonDecode(package) as Map,
      );
      final installedBundle = await store.exportBundle(moduleId);
      expect(
        canonicalJson(installedBundle.toJson()),
        canonicalJson(sourceBundle),
        reason:
            'Installed declarative metadata must retain the Host-approved digest.',
      );

      await tester.tap(find.byTooltip('Export declarative package'));
      await tester.pumpAndSettle();
      expect(find.text('Declarative extension package'), findsOneWidget);
      expect(find.textContaining(moduleId), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Removal is blocked by unresolved extension commands', (
    tester,
  ) async {
    const moduleId = 'com.example.pending_removal';
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Pending Removal',
      description: '',
    );
    final command = ExtensionRecordCommand.create(
      commandId: '00000000-0000-4000-8000-000000000002',
      tenantId: 'tenant-1',
      companyId: 'company-1',
      branchId: 'branch-1',
      recordId: 'inventory-move-2',
      actorId: 'operator-1',
      deviceId: 'desktop-1',
      moduleId: moduleId,
      moduleVersion: '0.1.0',
      docType: 'InventoryMove',
      schemaVersion: 1,
      values: const {'reference': 'MOVE-0002'},
    );
    await queue.enqueue(command.envelope);

    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionDetailsPage(
          store: store,
          queue: queue,
          moduleId: moduleId,
          scope: const RecordScope(
            organizationId: 'tenant-1',
            companyId: 'company-1',
            branchId: 'branch-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Remove'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();

    expect(await store.getExtension(moduleId), isNotNull);
    expect(
      find.text(
        'Resolve this extension’s queued Host commands before removing it.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Generated form round-trips long text and table rows', (
    tester,
  ) async {
    const moduleId = 'com.example.typed_fields';
    const permission = 'extension.com_example_typed_fields.asset';
    const scope = RecordScope(
      organizationId: 'tenant-1',
      companyId: 'company-1',
      branchId: 'branch-1',
    );
    final metadata = <String, dynamic>{
      'name': 'Asset',
      'moduleId': moduleId,
      'schemaVersion': 1,
      'kind': 'operational',
      'fields': [
        {
          'name': 'name',
          'type': 'text',
          'required': true,
          'maxLength': 80,
          'label': 'Name',
          'labelKey': '$permission.name',
        },
        {
          'name': 'notes',
          'type': 'long_text',
          'required': true,
          'maxLength': 2000,
          'label': 'Notes',
          'labelKey': '$permission.notes',
        },
        {
          'name': 'lines',
          'type': 'table',
          'required': false,
          'label': 'Lines',
          'labelKey': '$permission.lines',
        },
      ],
      'operations': ['read', 'create', 'update'],
      'permissions': {
        'read': '$permission.read',
        'create': '$permission.create',
        'update': '$permission.update',
      },
      'ui': {
        'listColumns': ['name', 'notes'],
        'formFields': ['name', 'notes', 'lines'],
        'detailFields': ['name', 'notes', 'lines'],
      },
      'label': 'Asset',
      'labelKey': '$permission.label',
    };
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Typed Fields',
      description: '',
    );
    await store.saveDocType(metadata);
    await store.activate(moduleId);

    await tester.pumpWidget(
      MaterialApp(
        home: DynamicRecordFormPage(
          store: store,
          queue: queue,
          moduleId: moduleId,
          definition: DocTypeDefinition.fromJson(metadata),
          scope: scope,
          moduleVersion: '0.1.0',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final inputs = find.byType(TextFormField);
    await tester.enterText(inputs.at(0), 'Pump');
    await tester.enterText(inputs.at(1), 'Installed beside the west workshop.');
    await tester.enterText(
      inputs.at(2),
      '[{"itemCode":"SEAL-1","quantity":3}]',
    );
    await tester.scrollUntilVisible(
      find.text('Save on device'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Save on device'));
    await tester.pumpAndSettle();

    final record = (await store.listRecords(
      moduleId: moduleId,
      docTypeName: 'Asset',
      scope: scope,
    )).single;
    expect(record.values['notes'], 'Installed beside the west workshop.');
    expect(record.values['lines'], [
      {'itemCode': 'SEAL-1', 'quantity': 3},
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Generated form applies defaults and enforces field precision', (
    tester,
  ) async {
    const moduleId = 'com.example.field_properties';
    const permission = 'extension.com_example_field_properties.invoice';
    const scope = RecordScope(
      organizationId: 'tenant-1',
      companyId: 'company-1',
      branchId: 'branch-1',
    );
    final metadata = <String, dynamic>{
      'name': 'Invoice',
      'moduleId': moduleId,
      'schemaVersion': 1,
      'kind': 'operational',
      'fields': [
        {
          'name': 'amount',
          'type': 'decimal',
          'required': true,
          'minValue': 0,
          'maxValue': 9,
          'precision': 2,
          'default': 1.25,
          'label': 'Amount',
          'labelKey': '$permission.amount',
        },
        {
          'name': 'status',
          'type': 'text',
          'required': true,
          'maxLength': 40,
          'default': 'Pending',
          'readOnly': true,
          'label': 'Status',
          'labelKey': '$permission.status',
          'description': 'Managed by the Host.',
          'descriptionKey': '$permission.status_description',
        },
      ],
      'operations': ['read', 'create', 'update'],
      'permissions': {
        'read': '$permission.read',
        'create': '$permission.create',
        'update': '$permission.update',
      },
      'ui': {
        'listColumns': ['amount', 'status'],
        'formFields': ['amount', 'status'],
        'detailFields': ['amount', 'status'],
      },
      'label': 'Invoice',
      'labelKey': '$permission.label',
    };
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Field Properties',
      description: '',
    );
    await store.saveDocType(metadata);
    await store.activate(moduleId);
    await tester.pumpWidget(
      MaterialApp(
        home: DynamicRecordFormPage(
          store: store,
          queue: queue,
          moduleId: moduleId,
          definition: DocTypeDefinition.fromJson(metadata),
          scope: scope,
        ),
      ),
    );
    await tester.pumpAndSettle();
    Finder labeledField(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );
    expect(tester.widget<TextField>(labeledField('Status')).readOnly, isTrue);
    expect(find.textContaining('Managed by the Host.'), findsOneWidget);
    await tester.enterText(labeledField('Amount'), '-1');
    await tester.tap(find.text('Save on device'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a value of at least 0.'), findsOneWidget);

    await tester.enterText(labeledField('Amount'), '10');
    await tester.tap(find.text('Save on device'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a value no greater than 9.'), findsOneWidget);

    await tester.enterText(labeledField('Amount'), '1.234');
    await tester.tap(find.text('Save on device'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter a value with no more than 2 decimal places.'),
      findsOneWidget,
    );

    await tester.enterText(labeledField('Amount'), '1.2');
    await tester.tap(find.text('Save on device'));
    await tester.pumpAndSettle();
    final record = (await store.listRecords(
      moduleId: moduleId,
      docTypeName: 'Invoice',
      scope: scope,
    )).single;
    expect(record.values, {'amount': 1.2, 'status': 'Pending'});
  });

  testWidgets('Builder verifies Host and saves an exact granted scope', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final endpoint = Uri.parse('http://127.0.0.1:8123');
    const token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';
    final backend = _MemoryCredentialBackend();
    final vault = HostCredentialVault(backend);

    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionStudioPage(
          store: store,
          queue: queue,
          credentialVault: vault,
          hostPackageClientFactory:
              ({required endpoint, required credentials}) =>
                  _FakeHostPackageClient(
                    endpoint: endpoint,
                    credentials: credentials,
                  ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Connect Host'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), endpoint.toString());
    await tester.enterText(find.byType(TextField).at(1), token);
    await tester.tap(find.text('Verify Host'));
    await tester.pumpAndSettle();
    expect(find.text('Tenant: tenant-1'), findsOneWidget);

    await tester.tap(find.text('company-1 / branch-1'));
    await tester.tap(find.text('Use this scope'));
    await tester.pumpAndSettle();

    final profile = await store.getHostProfile();
    expect(profile?.tenantId, 'tenant-1');
    expect(profile?.companyId, 'company-1');
    expect(profile?.branchId, 'branch-1');
    expect(backend.values.values, contains(token));
    expect(find.textContaining('Host connected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Changed Host profile identity stops sync before queue attempts',
    (tester) async {
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const profile = HostConnectionProfile(
        endpoint: 'https://host.example.test',
        tenantId: 'tenant-1',
        companyId: 'company-1',
        branchId: 'branch-1',
        actorId: 'saved-user',
        deviceId: 'saved-device',
      );
      await store.saveHostProfile(profile);
      await queue.enqueue(
        CommandEnvelope.fromJson({
          'protocolVersion': 0,
          'commandId': '1e1440d9-72aa-4b84-8c53-bb5856c675a5',
          'type': 'extension.example.create',
          'typeVersion': 1,
          'tenantId': profile.tenantId,
          'companyId': profile.companyId,
          'branchId': profile.branchId,
          'aggregateId': 'record-1',
          'expectedRevision': null,
          'dependsOn': <String>[],
          'payload': <String, Object?>{'name': 'Pending'},
          'clientContext': <String, Object?>{
            'deviceId': profile.deviceId,
            'actorId': profile.actorId,
            'moduleVersion': '0.1.0',
            'docTypeVersion': 1,
            'clientTimestamp': '2026-10-24T10:00:00Z',
          },
        }),
      );

      final vault = HostCredentialVault(_MemoryCredentialBackend());
      await tester.pumpWidget(
        MaterialApp(
          home: ExtensionStudioPage(
            store: store,
            queue: queue,
            credentialVault: vault,
            hostPackageClientFactory:
                ({required endpoint, required credentials}) =>
                    _FakeHostPackageClient(
                      endpoint: endpoint,
                      credentials: credentials,
                    ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Sync pending records'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('HOST_PROFILE_IDENTITY_CHANGED'),
        findsOneWidget,
      );
      final entry = (await queue.list()).single;
      expect(entry.hostStatus, HostCommandStatus.pending);
      expect(entry.attemptCount, 0);
      expect(entry.lastAttemptAtUtc, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Builder browses scoped approved packages and installs a draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const moduleId = 'com.example.host_browsed';
    const permissionPrefix = 'extension.com_example_host_browsed.item';
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Host Browsed',
      description: 'Approved by the configured Host.',
    );
    await store.saveDocType({
      'name': 'Item',
      'moduleId': moduleId,
      'schemaVersion': 1,
      'kind': 'operational',
      'fields': [
        {
          'name': 'title',
          'type': 'text',
          'required': true,
          'label': 'Title',
          'labelKey': '$permissionPrefix.title',
          'maxLength': 100,
        },
      ],
      'operations': ['read', 'create', 'update'],
      'permissions': {
        'read': '$permissionPrefix.read',
        'create': '$permissionPrefix.create',
        'update': '$permissionPrefix.update',
      },
      'ui': {
        'listColumns': ['title'],
        'formFields': ['title'],
      },
      'label': 'Item',
      'labelKey': permissionPrefix,
    });
    final bundle = await store.exportBundle(moduleId);
    await store.remove(moduleId);
    final digest = sha256
        .convert(utf8.encode(canonicalJson(bundle.toJson())))
        .toString();
    const profile = HostConnectionProfile(
      endpoint: 'https://host.example.test',
      tenantId: 'tenant-1',
      companyId: 'company-1',
      branchId: 'branch-1',
      actorId: 'user-1',
      deviceId: 'device-1',
    );
    await store.saveHostProfile(profile);
    final vault = HostCredentialVault(_MemoryCredentialBackend());
    final fakeClient =
        _FakeHostPackageClient(
            endpoint: Uri.parse(profile.endpoint),
            credentials: vault,
          )
          ..approvedBundle = bundle
          ..expectedDigest = digest
          ..registryPage = HostApprovedPackagePage(
            packages: [
              HostApprovedPackageSummary(
                moduleId: bundle.moduleId,
                version: bundle.version,
                packageSha256: digest,
                displayName: bundle.manifest.displayName,
                description: null,
              ),
            ],
            hasMore: false,
          );

    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionStudioPage(
          store: store,
          queue: queue,
          credentialVault: vault,
          hostPackageClientFactory:
              ({required endpoint, required credentials}) => fakeClient,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Workspace actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install from Host'));
    await tester.pumpAndSettle();

    expect(find.text('Approved extensions'), findsOneWidget);
    expect(find.text('Host Browsed'), findsOneWidget);
    expect(fakeClient.listedCompany, profile.companyId);
    expect(fakeClient.listedBranch, profile.branchId);
    await tester.tap(find.text('Host Browsed').last);
    await tester.pumpAndSettle();
    expect(find.text('Install Host-approved extension'), findsOneWidget);
    await tester.tap(find.text('Install on this device'));
    await tester.pumpAndSettle();

    expect((await store.getExtension(moduleId))?.state, ExtensionState.draft);
    expect(fakeClient.expectedDigest, digest);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Builder creates, previews, activates and runs a generated DocType',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: ExtensionStudioPage(store: store, queue: queue),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create your first extension'));
      await tester.pumpAndSettle();
      var fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'com.example.asset_register');
      await tester.enterText(fields.at(1), 'Asset Register');
      await tester.enterText(fields.at(2), 'Track equipment by branch.');
      await tester.tap(find.text('Create draft'));
      await tester.pumpAndSettle();

      expect(find.text('Asset Register'), findsWidgets);
      await tester.tap(find.text('Add DocType'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add field'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a valid DocType ID before adding fields.'),
        findsOneWidget,
      );
      expect(find.text('Save field'), findsNothing);
      fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'Asset');
      await tester.enterText(fields.at(1), 'Asset');
      await tester.enterText(fields.at(2), 'An asset assigned to a branch.');
      await tester.tap(find.text('Add field'));
      await tester.pumpAndSettle();
      final nameDialogFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(nameDialogFields.at(0), 'name');
      await tester.enterText(nameDialogFields.at(1), 'Name');
      final minimumLengthField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Minimum length',
      );
      await tester.ensureVisible(minimumLengthField);
      await tester.enterText(minimumLengthField, '3');
      await tester.ensureVisible(find.text('Save field'));
      await tester.tap(find.text('Save field'));
      await tester.pumpAndSettle();
      expect(find.text('Save field'), findsNothing);

      await tester.tap(find.text('Add field'));
      await tester.pumpAndSettle();
      final quantityDialog = find.byType(AlertDialog);
      await tester.enterText(
        find
            .descendant(
              of: quantityDialog,
              matching: find.byType(TextFormField),
            )
            .at(0),
        'quantity',
      );
      await tester.enterText(
        find
            .descendant(
              of: quantityDialog,
              matching: find.byType(TextFormField),
            )
            .at(1),
        'Quantity',
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Whole number').last);
      await tester.pumpAndSettle();
      Finder labeledField(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );
      await tester.enterText(labeledField('Minimum value'), '1');
      await tester.enterText(labeledField('Maximum value'), '10');
      await tester.ensureVisible(find.text('Save field'));
      await tester.tap(find.text('Save field'));
      await tester.pumpAndSettle();
      final saveDocTypeButton = find.text('Save DocType');
      await tester.scrollUntilVisible(
        saveDocTypeButton,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(saveDocTypeButton);
      await tester.pumpAndSettle();
      await tester.tap(saveDocTypeButton);
      await tester.pumpAndSettle();

      final savedDefinition = (await store.listDocTypes(
        'com.example.asset_register',
      )).single;
      final savedQuantity = (savedDefinition['fields'] as List).last as Map;
      expect(savedQuantity['minValue'], 1);
      expect(savedQuantity['maxValue'], 10);
      final savedName = (savedDefinition['fields'] as List).first as Map;
      expect(savedName['minLength'], 3);

      expect(find.text('Asset · operational DocType'), findsOneWidget);
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.text('Generated list view'), findsOneWidget);
      await tester.tap(find.text('Open generated form'));
      await tester.pumpAndSettle();
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Preview only'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Activate on device'));
      await tester.pumpAndSettle();
      expect(find.text('ACTIVE_LOCAL'), findsOneWidget);
      await tester.tap(find.text('Open records'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New record'));
      await tester.pumpAndSettle();
      final recordFields = find.byType(TextFormField);
      await tester.enterText(recordFields.at(0), 'AB');
      await tester.enterText(recordFields.at(1), '3');
      await tester.tap(find.text('Save on device'));
      await tester.pumpAndSettle();
      expect(find.text('Enter at least 3 characters.'), findsOneWidget);
      await tester.tap(recordFields.at(0));
      await tester.enterText(recordFields.at(0), 'Laptop 42');
      await tester.enterText(recordFields.at(1), '0');
      await tester.tap(find.text('Save on device'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a value of at least 1.'), findsOneWidget);
      await tester.tap(recordFields.at(1));
      await tester.enterText(recordFields.at(1), '3');
      await tester.tap(find.text('Save on device'));
      await tester.pumpAndSettle();

      expect(find.text('Laptop 42'), findsOneWidget);
      final records = await store.listRecords(
        moduleId: 'com.example.asset_register',
        docTypeName: 'Asset',
        scope: const RecordScope(
          organizationId: 'local-organization',
          companyId: 'local-company',
          branchId: 'local-branch',
        ),
      );
      expect(records, hasLength(1));
      expect(records.single.values['name'], 'Laptop 42');
      expect(records.single.values['quantity'], 3);
      expect(records.single.syncState, 'LOCAL_ONLY');
    },
  );

  testWidgets('Field editor configures Host-granted field permissions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionStudioPage(store: store, queue: queue),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create your first extension'));
    await tester.pumpAndSettle();
    var fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'com.example.field_acl_builder');
    await tester.enterText(fields.at(1), 'Field ACL Builder');
    await tester.enterText(fields.at(2), 'Configure Host field grants.');
    await tester.tap(find.text('Create draft'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add DocType'));
    await tester.pumpAndSettle();
    fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Profile');
    await tester.enterText(fields.at(1), 'Profile');
    await tester.enterText(fields.at(2), 'A field protected profile.');
    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();
    Finder permissionField(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );
    await tester.enterText(permissionField('Field ID'), 'secret');
    await tester.enterText(permissionField('Label'), 'Secret');
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Decimal').last);
    await tester.pumpAndSettle();
    final descriptionField = permissionField('Field description');
    await tester.ensureVisible(descriptionField);
    await tester.enterText(descriptionField, 'A protected value.');
    final defaultField = permissionField('Default value');
    await tester.ensureVisible(defaultField);
    await tester.enterText(defaultField, '1.25');
    final precisionField = permissionField('Decimal places');
    await tester.ensureVisible(precisionField);
    await tester.enterText(precisionField, '2');
    final readPermission =
        'extension.com_example_field_acl_builder.profile.secret.read';
    final writePermission =
        'extension.com_example_field_acl_builder.profile.secret.write';
    final readField = permissionField('Read permission (optional)');
    await tester.ensureVisible(readField);
    await tester.enterText(readField, readPermission);
    final writeField = permissionField('Write permission (optional)');
    await tester.ensureVisible(writeField);
    await tester.enterText(writeField, writePermission);
    await tester.ensureVisible(find.text('Save field'));
    await tester.tap(find.text('Save field'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();
    Finder newFieldInput(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );
    await tester.enterText(newFieldInput('Field ID'), 'status');
    await tester.enterText(newFieldInput('Label'), 'Status');
    final defaultValueField = newFieldInput('Default value');
    await tester.ensureVisible(defaultValueField);
    await tester.enterText(defaultValueField, 'Pending');
    await tester.tap(find.byType(CheckboxListTile).last);
    await tester.ensureVisible(find.text('Save field'));
    await tester.tap(find.text('Save field'));
    await tester.pumpAndSettle();

    final saveDocType = find.text('Save DocType');
    for (
      var attempt = 0;
      attempt < 12 && saveDocType.evaluate().isEmpty;
      attempt++
    ) {
      await tester.drag(find.byType(ListView).last, const Offset(0, -700));
      await tester.pumpAndSettle();
    }
    expect(saveDocType, findsOneWidget);
    await tester.ensureVisible(saveDocType);
    await tester.pumpAndSettle();
    await tester.tap(saveDocType);
    await tester.pumpAndSettle();
    final definition = (await store.listDocTypes(
      'com.example.field_acl_builder',
    )).single;
    final savedFields = (definition['fields'] as List).cast<Map>();
    final field = savedFields.singleWhere((item) => item['name'] == 'secret');
    expect(field['readPermission'], readPermission);
    expect(field['writePermission'], writePermission);
    expect(field['default'], 1.25);
    expect(field['description'], 'A protected value.');
    expect(field['precision'], 2);
    final status = savedFields.singleWhere((item) => item['name'] == 'status');
    expect(status['readOnly'], isTrue);
    expect(status['default'], 'Pending');
    final bundle = await store.exportBundle('com.example.field_acl_builder');
    final bundledSecret = bundle.docTypes.single.fields.singleWhere(
      (item) => item.name == 'secret',
    );
    expect(bundledSecret.defaultValue, 1.25);
    expect(bundledSecret.precision, 2);
    expect(bundledSecret.description, 'A protected value.');
    expect(
      bundle.englishCatalog[field['descriptionKey']],
      'A protected value.',
    );
    expect(bundle.manifest.minPlatformApi, '0.3.0');
  });

  testWidgets('DocType Builder authors a validated migration step', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const moduleId = 'com.example.migration_editor';
    final metadata = <String, dynamic>{
      'name': 'Asset',
      'moduleId': moduleId,
      'schemaVersion': 1,
      'kind': 'operational',
      'fields': [
        {
          'name': 'name',
          'type': 'text',
          'required': true,
          'label': 'Name',
          'labelKey': 'extension.com_example_migration_editor.asset.name',
          'maxLength': 80,
        },
      ],
      'permissions': {
        'read': 'extension.com_example_migration_editor.asset.read',
        'create': 'extension.com_example_migration_editor.asset.create',
        'update': 'extension.com_example_migration_editor.asset.update',
      },
      'ui': {
        'listColumns': ['name'],
        'formFields': ['name'],
      },
      'label': 'Asset',
      'labelKey': 'extension.com_example_migration_editor.asset.label',
    };
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Migration Editor',
      description: '',
    );
    await store.saveDocType(metadata);
    await tester.pumpWidget(
      MaterialApp(
        home: DocTypeBuilderPage(
          store: store,
          moduleId: moduleId,
          existing: metadata,
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> reveal(Finder target) async {
      final list = find.byType(ListView).first;
      for (var attempt = 0; attempt < 8; attempt++) {
        final bounds = tester.getRect(target);
        if (bounds.top >= 0 && bounds.bottom <= 800) return;
        await tester.drag(list, Offset(0, bounds.center.dy > 800 ? -500 : 500));
        await tester.pumpAndSettle();
      }
    }

    await tester.scrollUntilVisible(
      find.text('Add default'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await reveal(find.text('Add default'));
    expect(find.text('Data migration'), findsOneWidget);

    await tester.tap(find.text('Add default'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '"Unspecified"');
    await tester.tap(find.text('Add step'));
    await tester.pumpAndSettle();
    expect(find.text('Default name to "Unspecified"'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Save DocType'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await reveal(find.text('Save DocType'));
    await tester.tap(find.text('Save DocType'));
    await tester.pumpAndSettle();
    final saved = await store.getDocType(moduleId, 'Asset');
    expect(saved?['schemaVersion'], 2);
    expect(saved?['migrations'], [
      {
        'fromVersion': 1,
        'toVersion': 2,
        'steps': [
          {'op': 'setDefault', 'field': 'name', 'value': 'Unspecified'},
        ],
      },
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DocType Builder authors a typed child DocType', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const moduleId = 'com.example.child_builder';
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Child Builder',
      description: '',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DocTypeBuilderPage(store: store, moduleId: moduleId),
      ),
    );
    await tester.pumpAndSettle();
    var inputs = find.byType(TextFormField);
    await tester.enterText(inputs.at(0), 'Order');
    await tester.enterText(inputs.at(1), 'Order');
    await tester.enterText(inputs.at(2), 'A parent with typed child rows.');
    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();

    Finder fieldInput(String label) => find.descendant(
      of: find.byType(AlertDialog).last,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      ),
    );
    Future<void> invokeDialogAction(String label) async {
      final action = find.ancestor(
        of: find.text(label),
        matching: find.byType(FilledButton),
      ).last;
      tester.widget<FilledButton>(action).onPressed!.call();
      await tester.pumpAndSettle();
    }
    await tester.enterText(fieldInput('Field ID'), 'lines');
    await tester.enterText(fieldInput('Label'), 'Lines');
    final fieldType = find.descendant(
      of: find.byType(AlertDialog).last,
      matching: find.byType(DropdownButtonFormField<String>),
    );
    await tester.ensureVisible(fieldType);
    await tester.pumpAndSettle();
    await tester.tap(fieldType);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Child table').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Configure child DocType'));
    await tester.pumpAndSettle();

    inputs = find.descendant(
      of: find.byType(AlertDialog).last,
      matching: find.byType(TextFormField),
    );
    await tester.enterText(inputs.at(0), 'OrderLine');
    await tester.enterText(inputs.at(1), 'Order line');
    await tester.tap(find.text('Add child field'));
    await tester.pumpAndSettle();
    inputs = find.descendant(
      of: find.byType(AlertDialog).last,
      matching: find.byType(TextFormField),
    );
    await tester.enterText(fieldInput('Field ID'), 'itemCode');
    await tester.enterText(fieldInput('Label'), 'Item code');
    await invokeDialogAction('Save field');
    expect(find.text('itemCode · text'), findsOneWidget);
    await invokeDialogAction('Save child DocType');
    expect(find.text('Edit child DocType · OrderLine'), findsOneWidget);
    await invokeDialogAction('Save field');

    final saveDocType = find.text('Save DocType');
    await tester.scrollUntilVisible(
      saveDocType,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await invokeDialogAction('Save DocType');
    final saved = await store.getDocType(moduleId, 'Order');
    final table = (saved!['fields'] as List).cast<Map>().single;
    expect(table['childDocType']['name'], 'OrderLine');
    expect(
      (table['childDocType']['fields'] as List).single['name'],
      'itemCode',
    );
    final bundle = await store.exportBundle(moduleId);
    expect(
      bundle.englishCatalog.containsKey(
        'extension.com_example_child_builder.order.child.orderline.label',
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Conflict review seeds a merge from the selected Host values', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const moduleId = 'com.example.conflict_review';
    const scope = RecordScope(
      organizationId: 'tenant-1',
      companyId: 'company-1',
      branchId: 'branch-1',
    );
    const permission = 'extension.com_example_conflict_review.asset';
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Conflict Review',
      description: '',
    );
    await store.saveDocType({
      'name': 'Asset',
      'moduleId': moduleId,
      'schemaVersion': 1,
      'kind': 'operational',
      'fields': [
        {
          'name': 'name',
          'type': 'text',
          'required': true,
          'label': 'Name',
          'labelKey': '$permission.name',
          'maxLength': 120,
        },
      ],
      'operations': ['read', 'create', 'update'],
      'permissions': {
        'read': '$permission.read',
        'create': '$permission.create',
        'update': '$permission.update',
      },
      'ui': {
        'listColumns': ['name'],
        'formFields': ['name'],
      },
      'label': 'Asset',
      'labelKey': '$permission.title',
    });
    await store.activate(moduleId);
    final created = await store.createRecord(
      moduleId: moduleId,
      docTypeName: 'Asset',
      scope: scope,
      values: const {'name': 'Local draft'},
      recordId: 'conflict-review-1',
    );
    await store.markRecordPending(
      recordId: created.recordId,
      scope: scope,
      commandId: 'conflict-review-command',
    );
    await store.applyHostReceipt(
      recordId: created.recordId,
      scope: scope,
      commandId: 'conflict-review-command',
      receipt: CommandReceipt(
        commandId: 'conflict-review-command',
        status: 'CONFLICT',
        reasonCode: 'REVISION_CONFLICT',
        currentRevision: 2,
      ),
    );
    await store.applyHostRecord(
      moduleId: moduleId,
      docTypeName: 'Asset',
      scope: scope,
      recordId: created.recordId,
      revision: 2,
      values: const {'name': 'Concurrent Host value'},
      updatedAtUtc: DateTime.utc(2026, 10, 24),
    );
    final conflicted = (await store.getRecord(
      moduleId: moduleId,
      docTypeName: 'Asset',
      recordId: created.recordId,
      scope: scope,
    ))!;

    await tester.pumpWidget(
      MaterialApp(
        home: DynamicRecordConflictPage(
          store: store,
          queue: queue,
          moduleId: moduleId,
          definition: DocTypeDefinition.fromJson(
            (await store.listDocTypes(moduleId)).single,
          ),
          scope: scope,
          record: conflicted,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Local · Local draft'), findsOneWidget);
    expect(find.text('Host · Concurrent Host value'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Use Host'));
    await tester.tap(find.text('Continue with selected values'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Asset'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).first)
          .controller
          ?.text,
      'Concurrent Host value',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Dynamic records read from Host and stay branch scoped', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const moduleId = 'com.example.host_records';
    const readPermission = 'extension.com_example_host_records.asset.read';
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Host Records',
      description: 'Read records from the Host.',
    );
    await store.saveDocType({
      'name': 'Asset',
      'moduleId': moduleId,
      'schemaVersion': 1,
      'kind': 'operational',
      'fields': [
        {
          'name': 'name',
          'type': 'text',
          'required': true,
          'label': 'Name',
          'labelKey': '$readPermission.name',
          'maxLength': 120,
        },
      ],
      'operations': ['read', 'create', 'update'],
      'permissions': {
        'read': readPermission,
        'create': 'extension.com_example_host_records.asset.create',
        'update': 'extension.com_example_host_records.asset.update',
      },
      'ui': {
        'listColumns': ['name'],
        'formFields': ['name'],
      },
      'label': 'Asset',
      'labelKey': '$readPermission.title',
    });
    await store.activate(moduleId);
    const profile = HostConnectionProfile(
      endpoint: 'https://host.example.test',
      tenantId: 'tenant-host',
      companyId: 'company-host',
      branchId: 'branch-host',
      actorId: 'user-host',
      deviceId: 'device-host',
    );
    await store.saveHostProfile(profile);
    final bundle = await store.exportBundle(moduleId);
    final digest = sha256
        .convert(utf8.encode(canonicalJson(bundle.toJson())))
        .toString();
    final backend = _MemoryCredentialBackend();
    final vault = HostCredentialVault(backend);
    late _FakeRecordQueryClient fakeClient;
    fakeClient = _FakeRecordQueryClient(
      endpoint: Uri.parse(profile.endpoint),
      credentials: vault,
      page: HostExtensionRecordPage(
        packageSha256: digest,
        hasMore: true,
        nextCursor: 'host-record-page-2',
        records: [
          HostExtensionRecord(
            recordId: 'host-asset-1',
            revision: 7,
            updatedAtUtc: '2026-10-24T12:00:00Z',
            values: const {'name': 'Host record'},
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionStudioPage(
          store: store,
          queue: queue,
          credentialVault: vault,
          hostPackageClientFactory:
              ({required endpoint, required credentials}) => fakeClient,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Host Records').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open records'));
    await tester.pumpAndSettle();

    expect(find.text('Host-authoritative records'), findsOneWidget);
    expect(find.text('Host record'), findsOneWidget);
    expect(fakeClient.queriedCompany, profile.companyId);
    expect(fakeClient.queriedBranch, profile.branchId);
    expect(find.text('Load more Host records'), findsOneWidget);
    await tester.tap(find.text('Load more Host records'));
    await tester.pumpAndSettle();
    expect(fakeClient.queriedCursor, 'host-record-page-2');
    final imported = await store.getRecord(
      moduleId: moduleId,
      docTypeName: 'Asset',
      recordId: 'host-asset-1',
      scope: const RecordScope(
        organizationId: 'tenant-host',
        companyId: 'company-host',
        branchId: 'branch-host',
      ),
    );
    expect(imported?.authorityState, 'HOST_ACCEPTED');
    expect(imported?.hostRevision, 7);

    await tester.tap(find.text('Host record').first);
    await tester.pumpAndSettle();
    expect(find.text('Host accepted record'), findsOneWidget);
    await tester.tap(find.text('Edit record'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Edited offline');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    final queuedUpdate = await queue.list();
    expect(queuedUpdate, hasLength(1));
    expect(
      queuedUpdate.single.envelope.type,
      ExtensionRecordCommand.updateType,
    );
    expect(queuedUpdate.single.envelope.expectedRevision, 7);
    final pendingEdit = await store.getRecord(
      moduleId: moduleId,
      docTypeName: 'Asset',
      recordId: 'host-asset-1',
      scope: const RecordScope(
        organizationId: 'tenant-host',
        companyId: 'company-host',
        branchId: 'branch-host',
      ),
    );
    expect(pendingEdit?.values['name'], 'Edited offline');
    expect(pendingEdit?.authorityState, 'PENDING');
    expect(pendingEdit?.hostRevision, 7);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Offline record saves enqueue a durable Host command', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const moduleId = 'com.example.offline_records';
    const permissionPrefix = 'extension.com_example_offline_records.asset';
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Offline Records',
      description: 'Queue record changes for Host acceptance.',
    );
    await store.saveDocType({
      'name': 'Asset',
      'moduleId': moduleId,
      'schemaVersion': 1,
      'kind': 'operational',
      'fields': [
        {
          'name': 'name',
          'type': 'text',
          'required': true,
          'label': 'Name',
          'labelKey': '$permissionPrefix.name',
          'maxLength': 120,
        },
      ],
      'operations': ['read', 'create', 'update'],
      'permissions': {
        'read': '$permissionPrefix.read',
        'create': '$permissionPrefix.create',
        'update': '$permissionPrefix.update',
      },
      'ui': {
        'listColumns': ['name'],
        'formFields': ['name'],
      },
      'label': 'Asset',
      'labelKey': '$permissionPrefix.title',
    });
    await store.activate(moduleId);
    const profile = HostConnectionProfile(
      endpoint: 'https://host.example.test',
      tenantId: 'tenant-host',
      companyId: 'company-host',
      branchId: 'branch-host',
      actorId: 'user-host',
      deviceId: 'device-host',
    );
    await store.saveHostProfile(profile);
    final bundle = await store.exportBundle(moduleId);
    final digest = sha256
        .convert(utf8.encode(canonicalJson(bundle.toJson())))
        .toString();
    final vault = HostCredentialVault(_MemoryCredentialBackend());

    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionStudioPage(
          store: store,
          queue: queue,
          credentialVault: vault,
          hostPackageClientFactory:
              ({required endpoint, required credentials}) =>
                  _FakeRecordQueryClient(
                    endpoint: endpoint,
                    credentials: credentials,
                    page: HostExtensionRecordPage(
                      packageSha256: digest,
                      hasMore: false,
                      records: const [],
                    ),
                  ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Offline Records').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open records'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New record'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Pending asset');
    await tester.tap(find.text('Save on device'));
    await tester.pumpAndSettle();

    final entries = await queue.list();
    expect(entries, hasLength(1));
    expect(entries.single.envelope.type, ExtensionRecordCommand.createType);
    expect(entries.single.hostStatus, HostCommandStatus.pending);
    expect(entries.single.envelope.tenantId, profile.tenantId);
    expect(entries.single.envelope.companyId, profile.companyId);
    expect(entries.single.envelope.branchId, profile.branchId);
    expect(entries.single.envelope.actorId, profile.actorId);
    expect(entries.single.envelope.deviceId, profile.deviceId);
    expect(entries.single.envelope.payload['values']['name'], 'Pending asset');
    final records = await store.listRecords(
      moduleId: moduleId,
      docTypeName: 'Asset',
      scope: const RecordScope(
        organizationId: 'tenant-host',
        companyId: 'company-host',
        branchId: 'branch-host',
      ),
    );
    expect(records.single.syncState, 'PENDING');
    expect(records.single.hostRevision, isNull);

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Host read denial hides cached records until an authorized refresh succeeds',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const moduleId = 'com.example.denied_host_records';
      const scope = RecordScope(
        organizationId: 'tenant-host',
        companyId: 'company-host',
        branchId: 'branch-host',
      );
      const profile = HostConnectionProfile(
        endpoint: 'https://host.example.test',
        tenantId: 'tenant-host',
        companyId: 'company-host',
        branchId: 'branch-host',
        actorId: 'user-host',
        deviceId: 'device-host',
      );
      await store.createExtension(
        moduleId: moduleId,
        displayName: 'Restricted Cache',
        description: '',
      );
      await store.saveDocType({
        'name': 'Asset',
        'moduleId': moduleId,
        'schemaVersion': 1,
        'kind': 'operational',
        'fields': [
          {
            'name': 'name',
            'type': 'text',
            'required': true,
            'label': 'Name',
            'labelKey': 'extension.com_example_denied_host_records.asset.name',
            'maxLength': 120,
          },
        ],
        'operations': ['read', 'create', 'update'],
        'permissions': {
          'read': 'extension.com_example_denied_host_records.asset.read',
          'create': 'extension.com_example_denied_host_records.asset.create',
          'update': 'extension.com_example_denied_host_records.asset.update',
        },
        'ui': {
          'listColumns': ['name'],
          'formFields': ['name'],
        },
        'label': 'Asset',
        'labelKey': 'extension.com_example_denied_host_records.asset.title',
      });
      await store.activate(moduleId);
      await store.saveHostProfile(profile);
      await store.applyHostRecord(
        moduleId: moduleId,
        docTypeName: 'Asset',
        scope: scope,
        recordId: 'restricted-cache-1',
        revision: 4,
        values: const {'name': 'Cached private record'},
        updatedAtUtc: DateTime.utc(2026, 10, 25),
      );
      final bundle = await store.exportBundle(moduleId);
      final digest = sha256
          .convert(utf8.encode(canonicalJson(bundle.toJson())))
          .toString();
      final vault = HostCredentialVault(_MemoryCredentialBackend());
      final fakeClient = _FakeRecordQueryClient(
        endpoint: Uri.parse(profile.endpoint),
        credentials: vault,
        page: HostExtensionRecordPage(
          packageSha256: digest,
          hasMore: false,
          records: const [],
        ),
        queryError: const HostPackageTransportException(
          'PERMISSION_DENIED',
          statusCode: 403,
        ),
      );

      Future<Widget> page(String key) async => MaterialApp(
        key: ValueKey(key),
        home: DynamicDocTypePage(
          store: store,
          moduleId: moduleId,
          metadata: (await store.listDocTypes(moduleId)).single,
          scope: scope,
          moduleVersion: '0.1.0',
          hostProfile: profile,
          credentialVault: vault,
          hostPackageClientFactory:
              ({required endpoint, required credentials}) => fakeClient,
        ),
      );

      await tester.pumpWidget(await page('denied'));
      await tester.pumpAndSettle();
      expect(find.text('Host denied record access'), findsOneWidget);
      expect(find.text('Cached private record'), findsNothing);
      expect(
        (await store.getRecord(
          moduleId: moduleId,
          docTypeName: 'Asset',
          recordId: 'restricted-cache-1',
          scope: scope,
        ))?.authorityState,
        'HOST_ACCEPTED',
      );
      expect(
        await store.hasHostRecordReadDenial(
          profile: profile,
          moduleId: moduleId,
        ),
        isTrue,
      );

      fakeClient.queryError = const HostPackageTransportException(
        'HOST_UNREACHABLE',
        retryable: true,
      );
      await tester.pumpWidget(await page('offline'));
      await tester.pumpAndSettle();
      expect(find.text('Host denied record access'), findsOneWidget);
      expect(find.text('Cached private record'), findsNothing);

      fakeClient.queryError = null;
      fakeClient.page = HostExtensionRecordPage(
        packageSha256: digest,
        hasMore: false,
        records: [
          HostExtensionRecord(
            recordId: 'restricted-cache-1',
            revision: 4,
            updatedAtUtc: '2026-10-25T00:00:00Z',
            values: const {'name': 'Cached private record'},
          ),
        ],
      );
      await tester.pumpWidget(await page('restored'));
      await tester.pumpAndSettle();
      expect(find.text('Host-authoritative records'), findsOneWidget);
      expect(find.text('Cached private record'), findsOneWidget);
      expect(
        await store.hasHostRecordReadDenial(
          profile: profile,
          moduleId: moduleId,
        ),
        isFalse,
      );
    },
  );

  testWidgets('Host field masks hide details and persist per identity', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const moduleId = 'com.example.field_masked_ui';
    const prefix = 'extension.com_example_field_masked_ui.asset';
    const profile = HostConnectionProfile(
      endpoint: 'https://host.example.test',
      tenantId: 'tenant-field-mask',
      companyId: 'company-field-mask',
      branchId: 'branch-field-mask',
      actorId: 'field-user',
      deviceId: 'field-device',
    );
    const scope = RecordScope(
      organizationId: 'tenant-field-mask',
      companyId: 'company-field-mask',
      branchId: 'branch-field-mask',
    );
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Field Masked UI',
      description: '',
    );
    await store.saveDocType({
      'name': 'Asset',
      'moduleId': moduleId,
      'schemaVersion': 1,
      'kind': 'operational',
      'fields': [
        {
          'name': 'name',
          'type': 'text',
          'required': true,
          'label': 'Name',
          'labelKey': '$prefix.name_value',
          'maxLength': 120,
        },
        {
          'name': 'secret',
          'type': 'text',
          'required': false,
          'label': 'Secret',
          'labelKey': '$prefix.secret_value',
          'maxLength': 120,
          'readPermission': '$prefix.secret_read',
          'writePermission': '$prefix.secret_write',
        },
      ],
      'operations': ['read', 'create', 'update'],
      'permissions': {
        'read': '$prefix.read',
        'create': '$prefix.create',
        'update': '$prefix.update',
      },
      'ui': {
        'listColumns': ['name', 'secret'],
        'formFields': ['name', 'secret'],
        'detailFields': ['name', 'secret'],
      },
      'label': 'Asset',
      'labelKey': '$prefix.title',
    });
    await store.activate(moduleId);
    await store.saveHostProfile(profile);
    await store.createRecord(
      moduleId: moduleId,
      docTypeName: 'Asset',
      scope: scope,
      values: const {'name': 'Public asset', 'secret': 'SECRET SENTINEL'},
      recordId: 'field-mask-ui-1',
    );
    final bundle = await store.exportBundle(moduleId);
    final digest = sha256
        .convert(utf8.encode(canonicalJson(bundle.toJson())))
        .toString();
    final vault = HostCredentialVault(_MemoryCredentialBackend());
    final fakeClient = _FakeRecordQueryClient(
      endpoint: Uri.parse(profile.endpoint),
      credentials: vault,
      page: HostExtensionRecordPage(
        packageSha256: digest,
        hasMore: false,
        readableFields: const {'name'},
        writableFields: const {'name'},
        creatableFields: const {'name'},
        records: [
          HostExtensionRecord(
            recordId: 'field-mask-ui-1',
            revision: 1,
            updatedAtUtc: '2026-10-25T00:00:00Z',
            values: const {'name': 'Public asset'},
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DynamicDocTypePage(
          store: store,
          moduleId: moduleId,
          metadata: (await store.listDocTypes(moduleId)).single,
          scope: scope,
          moduleVersion: '0.1.0',
          hostProfile: profile,
          credentialVault: vault,
          hostPackageClientFactory:
              ({required endpoint, required credentials}) => fakeClient,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Public asset'), findsOneWidget);
    expect(find.text('Secret'), findsNothing);
    expect(find.text('SECRET SENTINEL'), findsNothing);
    final stored = (await store.getRecord(
      moduleId: moduleId,
      docTypeName: 'Asset',
      recordId: 'field-mask-ui-1',
      scope: scope,
    ))!;
    expect(stored.values, {'name': 'Public asset'});
    expect(
      (await store.getHostFieldPermissions(
        profile: profile,
        moduleId: moduleId,
        docTypeName: 'Asset',
      ))!.readableFields,
      {'name'},
    );
    const differentUser = HostConnectionProfile(
      endpoint: 'https://host.example.test',
      tenantId: 'tenant-field-mask',
      companyId: 'company-field-mask',
      branchId: 'branch-field-mask',
      actorId: 'another-user',
      deviceId: 'another-device',
    );
    expect(
      await store.getHostFieldPermissions(
        profile: differentUser,
        moduleId: moduleId,
        docTypeName: 'Asset',
      ),
      isNull,
    );
    await tester.tap(find.text('Public asset'));
    await tester.pumpAndSettle();
    expect(find.text('Secret'), findsNothing);
    expect(find.text('SECRET SENTINEL'), findsNothing);
  });

  testWidgets('Startup recovers a saved record missing its queued command', (
    tester,
  ) async {
    const moduleId = 'com.example.recovered_records';
    const permissionPrefix = 'extension.com_example_recovered_records.asset';
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Recovered Records',
      description: 'Recover an interrupted local submission.',
    );
    await store.saveDocType({
      'name': 'Asset',
      'moduleId': moduleId,
      'schemaVersion': 1,
      'kind': 'operational',
      'fields': [
        {
          'name': 'name',
          'type': 'text',
          'required': true,
          'label': 'Name',
          'labelKey': '$permissionPrefix.name',
          'maxLength': 120,
        },
      ],
      'operations': ['read', 'create', 'update'],
      'permissions': {
        'read': '$permissionPrefix.read',
        'create': '$permissionPrefix.create',
        'update': '$permissionPrefix.update',
      },
      'ui': {
        'listColumns': ['name'],
        'formFields': ['name'],
      },
      'label': 'Asset',
      'labelKey': '$permissionPrefix.title',
    });
    await store.activate(moduleId);
    const profile = HostConnectionProfile(
      endpoint: 'https://host.example.test',
      tenantId: 'tenant-host',
      companyId: 'company-host',
      branchId: 'branch-host',
      actorId: 'user-host',
      deviceId: 'device-host',
    );
    await store.saveHostProfile(profile);
    final localRecord = await store.createRecord(
      moduleId: moduleId,
      docTypeName: 'Asset',
      scope: const RecordScope(
        organizationId: 'tenant-host',
        companyId: 'company-host',
        branchId: 'branch-host',
      ),
      values: const {'name': 'Recovered after restart'},
      recordId: 'interrupted-record',
    );
    final bundle = await store.exportBundle(moduleId);
    final digest = sha256
        .convert(utf8.encode(canonicalJson(bundle.toJson())))
        .toString();
    final vault = HostCredentialVault(_MemoryCredentialBackend());

    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionStudioPage(
          store: store,
          queue: queue,
          credentialVault: vault,
          hostPackageClientFactory:
              ({required endpoint, required credentials}) =>
                  _FakeRecordQueryClient(
                    endpoint: endpoint,
                    credentials: credentials,
                    page: HostExtensionRecordPage(
                      packageSha256: digest,
                      hasMore: false,
                      records: const [],
                    ),
                  ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entries = await queue.list();
    expect(entries, hasLength(1));
    expect(entries.single.envelope.type, ExtensionRecordCommand.createType);
    expect(entries.single.envelope.aggregateId, localRecord.recordId);
    expect(
      entries.single.envelope.payload['values']['name'],
      'Recovered after restart',
    );
    final recovered = await store.getRecord(
      moduleId: moduleId,
      docTypeName: 'Asset',
      recordId: localRecord.recordId,
      scope: localRecord.scope,
    );
    expect(recovered?.authorityState, 'PENDING');
    expect(recovered?.pendingCommandId, entries.single.envelope.commandId);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Builder saves an explicitly selected extension dependency', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await store.createExtension(
      moduleId: 'com.example.shared_catalog',
      displayName: 'Shared Catalog',
      description: 'A local dependency.',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionStudioPage(store: store, queue: queue),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('New extension'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'com.example.catalog_client');
    await tester.enterText(fields.at(1), 'Catalog Client');
    await tester.enterText(fields.at(2), 'Uses the shared catalog.');
    await tester.enterText(fields.at(3), '1.2.3');
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.tap(find.text('Create draft'));
    await tester.pumpAndSettle();

    final extension = (await store.getExtension('com.example.catalog_client'))!;
    expect(extension.version, '1.2.3');
    expect(extension.dependencies, {'com.example.shared_catalog': '0.1.0'});
  });

  testWidgets('Builder saves configured list columns and form order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionStudioPage(store: store, queue: queue),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create your first extension'));
    await tester.pumpAndSettle();
    var fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'com.example.configured_layout');
    await tester.enterText(fields.at(1), 'Configured Layout');
    await tester.enterText(fields.at(2), 'A configurable generated layout.');
    await tester.tap(find.text('Create draft'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add DocType'));
    await tester.pumpAndSettle();
    fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'LayoutRecord');
    await tester.enterText(fields.at(1), 'Layout Record');
    await tester.enterText(fields.at(2), 'Test form and list layout.');
    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();
    final fieldDialog = find.byType(AlertDialog);
    fields = find.descendant(
      of: fieldDialog,
      matching: find.byType(TextFormField),
    );
    await tester.enterText(fields.at(0), 'name');
    await tester.enterText(fields.at(1), 'Name');
    await tester.tap(
      find.descendant(of: fieldDialog, matching: find.byType(SwitchListTile)),
    );
    await tester.tap(find.text('Save field'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();
    final noteDialog = find.byType(AlertDialog);
    fields = find.descendant(
      of: noteDialog,
      matching: find.byType(TextFormField),
    );
    await tester.enterText(fields.at(0), 'note');
    await tester.enterText(fields.at(1), 'Note');
    await tester.tap(find.text('Save field'));
    await tester.pumpAndSettle();

    final nameColumn = find.widgetWithText(CheckboxListTile, 'Name').first;
    await tester.ensureVisible(nameColumn);
    await tester.tap(nameColumn);
    await tester.pumpAndSettle();

    for (final operation in ['create', 'update']) {
      final operationToggle = find.widgetWithText(CheckboxListTile, operation);
      await tester.ensureVisible(operationToggle);
      await tester.tap(operationToggle);
      await tester.pumpAndSettle();
    }

    await tester.scrollUntilVisible(
      find.text('Generated form fields'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    final formCard = find.ancestor(
      of: find.text('Generated form fields'),
      matching: find.byType(Card),
    );
    final moveNoteUp = find.descendant(
      of: formCard,
      matching: find.byTooltip('Move Note up'),
    );
    await tester.ensureVisible(moveNoteUp);
    await tester.tap(moveNoteUp);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Details page fields'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    final detailsCard = find.ancestor(
      of: find.text('Details page fields'),
      matching: find.byType(Card),
    );
    final hideNameFromDetails = find.descendant(
      of: detailsCard,
      matching: find.widgetWithText(CheckboxListTile, 'Name'),
    );
    await tester.ensureVisible(hideNameFromDetails);
    await tester.tap(hideNameFromDetails);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Generated page settings'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    final pageTitleField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Page title',
    );
    await tester.ensureVisible(pageTitleField);
    await tester.enterText(pageTitleField, 'Asset overview');
    final pageOrderField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Navigation order',
    );
    await tester.ensureVisible(pageOrderField);
    await tester.enterText(pageOrderField, '20');
    final pageIconField = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButtonFormField<String> &&
          widget.decoration.labelText == 'Navigation icon',
    );
    await tester.ensureVisible(pageIconField);
    await tester.tap(pageIconField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('grid').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Save DocType'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Save DocType'));
    await tester.pumpAndSettle();

    final definition = (await store.listDocTypes(
      'com.example.configured_layout',
    )).single;
    final ui = definition['ui'] as Map;
    expect(ui['listColumns'], ['note']);
    expect(ui['formFields'], ['note', 'name']);
    expect(ui['detailFields'], ['note']);
    expect(ui['pageTitle'], 'Asset overview');
    expect(
      ui['pageTitleKey'],
      'extension.com_example_configured_layout.layoutrecord.page_title',
    );
    expect(ui['pageIcon'], 'grid');
    expect(ui['pageOrder'], 20);
    expect(definition['operations'], ['read']);
    expect((definition['permissions'] as Map).keys, ['read']);
    final exportedBundle = await store.exportBundle(
      'com.example.configured_layout',
    );
    expect(exportedBundle.manifest.minPlatformApi, currentPlatformApiVersion);
    expect(exportedBundle.englishCatalog[ui['pageTitleKey']], 'Asset overview');
    expect(find.text('Asset overview'), findsOneWidget);
    await tester.tap(find.text('Preview').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Asset overview'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    final earlierPage = Map<String, dynamic>.from(definition)
      ..['name'] = 'EarlierRecord'
      ..['schemaVersion'] = 1
      ..['label'] = 'Earlier record'
      ..['labelKey'] =
          'extension.com_example_configured_layout.earlierrecord.name';
    earlierPage['ui'] = Map<String, dynamic>.from(ui)
      ..['pageTitle'] = 'Earlier page'
      ..['pageTitleKey'] =
          'extension.com_example_configured_layout.earlierrecord.page_title'
      ..['pageOrder'] = 0;
    await store.saveDocType(earlierPage);
    final savedPages = await store.listDocTypes(
      'com.example.configured_layout',
    );
    expect(savedPages, hasLength(2));
    expect((savedPages.first['ui'] as Map)['pageTitle'], 'Earlier page');
    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey('ordered-pages-app'),
        home: ExtensionDetailsPage(
          key: const ValueKey('ordered-pages'),
          store: store,
          moduleId: 'com.example.configured_layout',
          scope: const RecordScope(
            organizationId: 'local-organization',
            companyId: 'local-company',
            branchId: 'local-branch',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.grid_view_outlined), findsNWidgets(2));
    await tester.scrollUntilVisible(
      find.text('Earlier page'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.getTopLeft(find.text('Earlier page')).dy,
      lessThan(tester.getTopLeft(find.text('Asset overview')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Generated details follow the configured detail fields', (
    tester,
  ) async {
    const moduleId = 'com.example.detail_layout';
    const scope = RecordScope(
      organizationId: 'tenant-1',
      companyId: 'company-1',
      branchId: 'branch-1',
    );
    final metadata = <String, dynamic>{
      'name': 'DetailItem',
      'moduleId': moduleId,
      'schemaVersion': 1,
      'kind': 'operational',
      'fields': [
        {
          'name': 'name',
          'type': 'text',
          'required': true,
          'maxLength': 120,
          'label': 'Name',
          'labelKey': 'detail_layout.item.name',
        },
        {
          'name': 'extraNote',
          'type': 'text',
          'required': false,
          'maxLength': 240,
          'label': 'Additional note',
          'labelKey': 'detail_layout.item.additional_note',
        },
      ],
      'permissions': {
        'read': 'extension.com_example_detail_layout.item.read',
        'create': 'extension.com_example_detail_layout.item.create',
        'update': 'extension.com_example_detail_layout.item.update',
      },
      'ui': {
        'listColumns': ['name'],
        'formFields': ['name', 'extraNote'],
        'detailFields': ['name'],
      },
      'label': 'Detail item',
      'labelKey': 'detail_layout.item.label',
    };
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Detail Layout',
      description: '',
    );
    await store.saveDocType(metadata);
    await store.activate(moduleId);
    await store.createRecord(
      moduleId: moduleId,
      docTypeName: 'DetailItem',
      scope: scope,
      values: {'name': 'Visible value', 'extraNote': 'Hidden value'},
      recordId: 'detail-record-1',
    );
    final record = (await store.listRecords(
      moduleId: moduleId,
      docTypeName: 'DetailItem',
      scope: scope,
    )).single;

    await tester.pumpWidget(
      MaterialApp(
        home: DynamicRecordDetailsPage(
          store: store,
          moduleId: moduleId,
          definition: DocTypeDefinition.fromJson(metadata),
          scope: scope,
          record: record,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Visible value'), findsOneWidget);
    expect(find.text('Additional note'), findsNothing);
    expect(find.text('Hidden value'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('The full builder setup flow fits a phone-sized viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionStudioPage(store: store, queue: queue),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Create your first extension'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create your first extension'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    var fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'com.example.phone_extension');
    await tester.enterText(fields.at(1), 'Phone Extension');
    await tester.enterText(fields.at(2), 'Created on a phone-sized screen.');
    await tester.tap(find.text('Create draft'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.text('Add DocType'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Add DocType'));
    await tester.pumpAndSettle();
    fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'PhoneNote');
    await tester.enterText(fields.at(1), 'Phone Note');
    await tester.enterText(fields.at(2), 'A note created from a compact view.');
    await tester.scrollUntilVisible(
      find.text('Add field'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final phoneFieldDialog = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(phoneFieldDialog.at(0), 'title');
    await tester.enterText(phoneFieldDialog.at(1), 'Title');
    tester.binding.focusManager.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save field'));
    await tester.tap(find.text('Save field'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Save DocType'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Save DocType'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      await store.listDocTypes('com.example.phone_extension'),
      hasLength(1),
    );
  });

  testWidgets('Generated record list and form fit a phone-sized viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const moduleId = 'com.example.phone_preview';
    final metadata = <String, dynamic>{
      'name': 'Asset',
      'moduleId': moduleId,
      'schemaVersion': 1,
      'kind': 'operational',
      'fields': [
        {
          'name': 'name',
          'type': 'text',
          'required': true,
          'maxLength': 120,
          'label': 'Name',
          'labelKey': 'phone_preview.asset.name',
        },
      ],
      'permissions': {
        'read': 'extension.com_example_phone_preview.asset.read',
        'create': 'extension.com_example_phone_preview.asset.create',
        'update': 'extension.com_example_phone_preview.asset.update',
      },
      'ui': {
        'listColumns': ['name'],
        'formFields': ['name'],
      },
      'label': 'Asset',
      'labelKey': 'phone_preview.asset.label',
    };
    await store.createExtension(
      moduleId: moduleId,
      displayName: 'Phone Preview',
      description: '',
    );
    await store.saveDocType(metadata);
    await store.activate(moduleId);

    await tester.pumpWidget(
      MaterialApp(
        home: DynamicDocTypePage(
          store: store,
          moduleId: moduleId,
          metadata: metadata,
          scope: const RecordScope(
            organizationId: 'local-organization',
            companyId: 'local-company',
            branchId: 'local-branch',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('No matching records'), findsOneWidget);

    await tester.tap(find.text('New record'));
    await tester.pumpAndSettle();
    expect(find.text('New Asset'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Generated forms follow configured order and preserve hidden values',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const moduleId = 'com.example.layout_preview';
      const scope = RecordScope(
        organizationId: 'local-organization',
        companyId: 'local-company',
        branchId: 'local-branch',
      );
      final metadata = <String, dynamic>{
        'name': 'LayoutItem',
        'moduleId': moduleId,
        'schemaVersion': 1,
        'kind': 'operational',
        'fields': [
          {
            'name': 'name',
            'type': 'text',
            'required': true,
            'maxLength': 120,
            'label': 'Name',
            'labelKey': 'layout_preview.item.name',
          },
          {
            'name': 'internalNote',
            'type': 'text',
            'required': false,
            'maxLength': 240,
            'label': 'Internal note',
            'labelKey': 'layout_preview.item.internal_note',
          },
          {
            'name': 'flagged',
            'type': 'boolean',
            'required': false,
            'label': 'Flagged',
            'labelKey': 'layout_preview.item.flagged',
          },
        ],
        'permissions': {
          'read': 'extension.com_example_layout_preview.layout_item.read',
          'create': 'extension.com_example_layout_preview.layout_item.create',
          'update': 'extension.com_example_layout_preview.layout_item.update',
        },
        'ui': {
          'listColumns': ['name'],
          'formFields': ['internalNote', 'name'],
        },
        'label': 'Layout item',
        'labelKey': 'layout_preview.item.label',
      };
      await store.createExtension(
        moduleId: moduleId,
        displayName: 'Layout Preview',
        description: '',
      );
      await store.saveDocType(metadata);
      await store.activate(moduleId);
      await store.createRecord(
        moduleId: moduleId,
        docTypeName: 'LayoutItem',
        scope: scope,
        values: {
          'name': 'Before',
          'internalNote': 'Retain this',
          'flagged': true,
        },
        recordId: 'layout-record-1',
      );
      final record = (await store.listRecords(
        moduleId: moduleId,
        docTypeName: 'LayoutItem',
        scope: scope,
      )).single;

      await tester.pumpWidget(
        MaterialApp(
          home: DynamicRecordFormPage(
            store: store,
            moduleId: moduleId,
            definition: DocTypeDefinition.fromJson(metadata),
            scope: scope,
            record: record,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Internal note'), findsOneWidget);
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Flagged'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Internal note')).dy,
        lessThan(tester.getTopLeft(find.text('Name')).dy),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'After',
      );
      await tester.ensureVisible(find.text('Save changes'));
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();

      final updated = (await store.listRecords(
        moduleId: moduleId,
        docTypeName: 'LayoutItem',
        scope: scope,
      )).single;
      expect(updated.values['name'], 'After');
      expect(updated.values['internalNote'], 'Retain this');
      expect(updated.values['flagged'], true);
    },
  );
}
