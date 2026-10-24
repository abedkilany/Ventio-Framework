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
  });

  final HostExtensionRecordPage page;
  String? queriedCompany;
  String? queriedBranch;

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
    int offset = 0,
    int limit = 50,
  }) async {
    queriedCompany = companyId;
    queriedBranch = branchId;
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
      fields = find.byType(TextFormField);
      await tester.enterText(fields.at(3), 'name');
      await tester.enterText(fields.at(4), 'Name');
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
      final quantityFields = find.descendant(
        of: quantityDialog,
        matching: find.byType(TextFormField),
      );
      await tester.enterText(quantityFields.at(2), '1');
      await tester.enterText(quantityFields.at(3), '10');
      await tester.ensureVisible(find.text('Save field'));
      await tester.tap(find.text('Save field'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save DocType'));
      await tester.tap(find.text('Save DocType'));
      await tester.pumpAndSettle();

      final savedDefinition = (await store.listDocTypes(
        'com.example.asset_register',
      )).single;
      final savedQuantity = (savedDefinition['fields'] as List).last as Map;
      expect(savedQuantity['minValue'], 1);
      expect(savedQuantity['maxValue'], 10);

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
      await tester.enterText(recordFields.at(0), 'Laptop 42');
      await tester.enterText(recordFields.at(1), '0');
      await tester.tap(find.text('Save on device'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a value of at least 1.'), findsOneWidget);
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
        hasMore: false,
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

    final moveNoteUp = find.byTooltip('Move Note up').last;
    await tester.ensureVisible(moveNoteUp);
    await tester.tap(moveNoteUp);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save DocType'));
    await tester.tap(find.text('Save DocType'));
    await tester.pumpAndSettle();

    final definition = (await store.listDocTypes(
      'com.example.configured_layout',
    )).single;
    final ui = definition['ui'] as Map;
    expect(ui['listColumns'], ['note']);
    expect(ui['formFields'], ['note', 'name']);
    expect(definition['operations'], ['read']);
    expect((definition['permissions'] as Map).keys, ['read']);
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
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), 'title');
    await tester.enterText(fields.at(2), 'Title');
    tester.binding.focusManager.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save field'));
    await tester.tap(find.text('Save field'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Save DocType'),
      160,
      scrollable: find.byType(Scrollable).last,
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
