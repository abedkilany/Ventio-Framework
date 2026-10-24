import 'dart:convert';
import 'package:ventio_core/ventio_core.dart';

/// Dependency-free executable test harness for the first Dart runtime slice.
/// Run from packages/ventio_core: dart run test/all_tests.dart
int passed = 0;
int failed = 0;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void checkThrows(void Function() operation, String message) {
  try {
    operation();
  } catch (_) {
    return;
  }
  throw StateError(message);
}

void test(String name, void Function() body) {
  try {
    body();
    passed++;
    print('PASS: $name');
  } catch (error) {
    failed++;
    print('FAIL: $name => $error');
  }
}

const root = '../../spec/v1.2';
Map<String, dynamic> commandJson() =>
    loadJsonFile('$root/examples/create_maintenance_command.json');

Map<String, dynamic> changed(Map<String, dynamic> original) =>
    jsonDecode(jsonEncode(original)) as Map<String, dynamic>;

String uuid(int index) =>
    '1e1440d9-72aa-4b84-8c53-${index.toString().padLeft(12, '0')}';

CommandEnvelope command([Map<String, dynamic>? json]) =>
    CommandEnvelope.fromJson(json ?? commandJson());

Principal actor(
        {String tenant = 'example-tenant',
        String company = 'example-company',
        String branch = 'example-branch',
        String user = 'example-user',
        String device = 'example-device',
        Set<String>? permissions}) =>
    Principal(
        tenantId: tenant,
        actorId: user,
        deviceId: device,
        companyIds: {company},
        branchIds: {branch},
        permissions: permissions ?? {'maintenance.create', 'maintenance.read'});

MaintenancePrototype fresh() => bootstrapMaintenancePrototype(root);

void main() {
  test('V1.2 fixture bootstraps an operational module', () {
    final p = fresh();
    check(p.modules.installedIds.single == 'com.ventio.maintenance',
        'Module missing');
    check(p.docTypes.get('MaintenanceRequest') != null, 'DocType missing');
  });
  test('English is built in without a translation module', () {
    final en = fresh().english;
    check(en.text('maintenance.module.name') == 'Maintenance Requests',
        'English missing');
    check(
        en.text('maintenance.module.name', locale: 'fr') ==
            'Maintenance Requests',
        'Fallback failed');
  });
  test('English catalog supports interpolation', () {
    check(
        fresh().english.text('core.error.validation_required_field',
                params: {'field': 'Customer Name'}) ==
            'Required field is missing: Customer Name.',
        'Interpolation failed');
  });
  test('Duplicate English keys are rejected', () {
    final en = EnglishCatalog();
    en.registerCatalog({'demo.screen.title': 'Title'});
    checkThrows(() => en.registerCatalog({'demo.screen.title': 'Other'}),
        'Duplicate allowed');
  });
  test('Module manifest parses V1.2 declarations', () {
    final manifest = ModuleManifest.fromJson(
        loadJsonFile('$root/examples/maintenance_manifest.json'));
    check(
        manifest.commands.single.capabilityId == 'records.operational.create@1',
        'Capability changed');
    check(
        manifest.offlineEnabled &&
            manifest.offlineCommands.single == 'maintenance.create',
        'Offline metadata lost');
  });
  test('Malformed manifest version is rejected', () {
    final json = loadJsonFile('$root/examples/maintenance_manifest.json');
    json['manifestVersion'] = 2;
    checkThrows(
        () => ModuleManifest.fromJson(json), 'Unsupported manifest accepted');
  });
  test('Missing command capability declaration is rejected', () {
    final json = loadJsonFile('$root/examples/maintenance_manifest.json');
    json['requiredCapabilities'] = <String>[];
    checkThrows(
        () => ModuleManifest.fromJson(json), 'Missing capability accepted');
  });
  test('Duplicate module installation is rejected', () {
    final p = fresh();
    final manifest = ModuleManifest.fromJson(
        loadJsonFile('$root/examples/maintenance_manifest.json'));
    final doc = DocTypeDefinition.fromJson(
        loadJsonFile('$root/examples/maintenance_doctype.json'));
    checkThrows(
        () => p.modules.install(manifest, [doc]), 'Duplicate installed');
  });
  test('Missing module dependency is rejected', () {
    final p = fresh();
    final json = loadJsonFile('$root/examples/maintenance_manifest.json');
    json['moduleId'] = 'com.example.other';
    json['dependencies'] = ['com.example.uninstalled'];
    final manifest = ModuleManifest.fromJson(json);
    final doc = loadJsonFile('$root/examples/maintenance_doctype.json');
    doc['moduleId'] = 'com.example.other';
    checkThrows(
        () => p.modules.install(manifest, [DocTypeDefinition.fromJson(doc)]),
        'Missing dependency accepted');
  });
  test('Missing trusted capability is rejected', () {
    final modules = ModuleRegistry();
    final manifest = ModuleManifest.fromJson(
        loadJsonFile('$root/examples/maintenance_manifest.json'));
    final doc = DocTypeDefinition.fromJson(
        loadJsonFile('$root/examples/maintenance_doctype.json'));
    checkThrows(
        () => modules.install(manifest, [doc]), 'Missing capability accepted');
  });
  test('Minimum platform API is enforced', () {
    final modules = ModuleRegistry(platformApiVersion: '0.0.1');
    modules.registerTrustedCapability(Capability.fromJson(
        loadJsonFile('$root/examples/maintenance_capability.json')));
    final manifest = ModuleManifest.fromJson(
        loadJsonFile('$root/examples/maintenance_manifest.json'));
    final doc = DocTypeDefinition.fromJson(
        loadJsonFile('$root/examples/maintenance_doctype.json'));
    checkThrows(() => modules.install(manifest, [doc]),
        'Incompatible platform accepted');
  });
  test('Pure Dart Host accepts valid maintenance creation', () {
    final p = fresh();
    final receipt = p.host.execute(command(), actor());
    check(receipt.accepted, 'Create was not accepted');
    check(receipt.hostRevision == 1, 'Revision missing');
    check(
        p.host.recordCount == 1 &&
            p.host.auditCount == 1 &&
            p.host.outboxCount == 1,
        'Effects missing');
  });
  test('Identical retries do not duplicate business effects', () {
    final p = fresh();
    final first = p.host.execute(command(), actor());
    final second = p.host.execute(command(), actor());
    check(identical(first, second), 'Receipt was not replayed');
    check(
        p.host.recordCount == 1 &&
            p.host.auditCount == 1 &&
            p.host.outboxCount == 1,
        'Duplicate effect');
  });
  test('Reusing commandId with different content is rejected', () {
    final p = fresh();
    p.host.execute(command(), actor());
    final json = commandJson();
    (json['payload'] as Map<String, dynamic>)['deviceModel'] =
        'Different Device';
    final receipt = p.host.execute(command(json), actor());
    check(receipt.reasonCode == 'COMMAND_ID_REUSED' && p.host.recordCount == 1,
        'Unsafe replay');
  });
  test('An untrusted actor cannot replay another actor command', () {
    final p = fresh();
    p.host.execute(command(), actor());
    final receipt = p.host.execute(command(), actor(user: 'wrong-user'));
    check(receipt.reasonCode == 'SCOPE_DENIED', 'Replay leaked receipt');
  });
  test('Untrusted device scope is rejected', () {
    final receipt =
        fresh().host.execute(command(), actor(device: 'other-device'));
    check(receipt.reasonCode == 'SCOPE_DENIED', 'Device spoof allowed');
  });
  test('Cross-tenant command is rejected', () {
    final receipt =
        fresh().host.execute(command(), actor(tenant: 'different-tenant'));
    check(receipt.reasonCode == 'SCOPE_DENIED', 'Tenant isolation failed');
  });
  test('Cross-branch command is rejected', () {
    final receipt =
        fresh().host.execute(command(), actor(branch: 'different-branch'));
    check(receipt.reasonCode == 'SCOPE_DENIED', 'Branch isolation failed');
  });
  test('Permission is denied by default', () {
    final receipt =
        fresh().host.execute(command(), actor(permissions: <String>{}));
    check(receipt.reasonCode == 'PERMISSION_DENIED', 'Permission bypass');
  });
  test('Invalid field type is rejected before any effect', () {
    final p = fresh();
    final json = commandJson();
    (json['payload'] as Map<String, dynamic>)['deviceModel'] = 33;
    check(
        p.host.execute(command(json), actor()).reasonCode == 'INVALID_PAYLOAD',
        'Invalid input accepted');
    check(p.host.recordCount == 0 && p.host.outboxCount == 0, 'Partial effect');
  });
  test('Unknown payload fields are rejected', () {
    final json = commandJson();
    (json['payload'] as Map<String, dynamic>)['unknown'] = 'data';
    check(
        fresh().host.execute(command(json), actor()).reasonCode ==
            'INVALID_PAYLOAD',
        'Extra field accepted');
  });
  test('Missing required field is rejected', () {
    final json = commandJson();
    (json['payload'] as Map<String, dynamic>).remove('customerName');
    check(
        fresh().host.execute(command(json), actor()).reasonCode ==
            'INVALID_PAYLOAD',
        'Required field absent');
  });
  test('Invalid enum value is rejected', () {
    final json = commandJson();
    (json['payload'] as Map<String, dynamic>)['status'] = 'invented';
    check(
        fresh().host.execute(command(json), actor()).reasonCode ==
            'INVALID_PAYLOAD',
        'Invalid enum accepted');
  });
  test('Max length is enforced', () {
    final json = commandJson();
    (json['payload'] as Map<String, dynamic>)['deviceModel'] = 'x' * 141;
    check(
        fresh().host.execute(command(json), actor()).reasonCode ==
            'INVALID_PAYLOAD',
        'Oversized value accepted');
  });
  test('Outdated DocType schema version is rejected', () {
    final json = commandJson();
    (json['clientContext'] as Map<String, dynamic>)['docTypeVersion'] = 99;
    check(
        fresh().host.execute(command(json), actor()).reasonCode ==
            'UPGRADE_REQUIRED',
        'Outdated schema accepted');
  });
  test('Outdated module version is rejected', () {
    final json = commandJson();
    (json['clientContext'] as Map<String, dynamic>)['moduleVersion'] = '0.0.1';
    check(
        fresh().host.execute(command(json), actor()).reasonCode ==
            'UPGRADE_REQUIRED',
        'Outdated module accepted');
  });
  test('Unregistered command cannot execute', () {
    final json = commandJson();
    json['type'] = 'maintenance.erase';
    check(
        fresh().host.execute(command(json), actor()).reasonCode ==
            'UNKNOWN_COMMAND',
        'Unknown command accepted');
  });
  test('Unexpected revision on create is a conflict', () {
    final json = commandJson();
    json['expectedRevision'] = 0;
    check(fresh().host.execute(command(json), actor()).status == 'CONFLICT',
        'Revision accepted');
  });
  test('Different commands cannot create duplicate records in one scope', () {
    final p = fresh();
    p.host.execute(command(), actor());
    final json = commandJson();
    json['commandId'] = uuid(10);
    check(p.host.execute(command(json), actor()).status == 'CONFLICT',
        'Record overwritten');
    check(p.host.recordCount == 1, 'Overwrite occurred');
  });
  test('Record ID can be reused in a different branch without collision', () {
    final p = fresh();
    p.host.execute(command(), actor());
    final json = commandJson();
    json['commandId'] = uuid(11);
    json['branchId'] = 'branch-two';
    check(p.host.execute(command(json), actor(branch: 'branch-two')).accepted,
        'Branch collision');
    check(p.host.recordCount == 2, 'Second branch record absent');
  });
  test('Pending dependencies return retry later', () {
    final json = commandJson();
    json['dependsOn'] = [uuid(99)];
    final receipt = fresh().host.execute(command(json), actor());
    check(
        receipt.status == 'RETRY_LATER' &&
            receipt.reasonCode == 'DEPENDENCY_PENDING',
        'Missing dependency accepted');
  });
  test('Accepted dependencies allow subsequent commands', () {
    final p = fresh();
    p.host.execute(command(), actor());
    final json = commandJson();
    json['commandId'] = uuid(13);
    json['aggregateId'] = 'local-maintenance-002';
    json['dependsOn'] = [command().commandId];
    check(p.host.execute(command(json), actor()).accepted,
        'Dependency remained blocked');
  });
  test('Read access requires permissions', () {
    final p = fresh();
    p.host.execute(command(), actor());
    check(
        p.host.readRecord('MaintenanceRequest', 'local-maintenance-001',
                actor(permissions: {'maintenance.create'}),
                companyId: 'example-company', branchId: 'example-branch') ==
            null,
        'Unauthorized read');
  });
  test('Stored record cannot be changed via returned data map', () {
    final p = fresh();
    p.host.execute(command(), actor());
    final record = p.host.readRecord(
        'MaintenanceRequest', 'local-maintenance-001', actor(),
        companyId: 'example-company', branchId: 'example-branch')!;
    record.data['status'] = 'tampered';
    check(
        record.data['status'] == 'new', 'State mutated outside command engine');
  });
  test('Sensitive DocTypes cannot be bound to generic operational create', () {
    final p = fresh();
    final json = loadJsonFile('$root/examples/maintenance_doctype.json');
    json['name'] = 'SensitiveTest';
    json['kind'] = 'sensitive';
    p.docTypes.register(DocTypeDefinition.fromJson(json));
    checkThrows(
        () => p.host.registerTrustedCreateBinding(const TrustedCommandBinding(
            'maintenance.create', 1, 'SensitiveTest')),
        'Sensitive data bound to generic executor');
  });
  test('Invalid UUID fails command parsing', () {
    final json = commandJson();
    json['commandId'] = 'bad-uuid';
    checkThrows(() => command(json), 'Invalid UUID accepted');
  });
  test('Canonical JSON is independent of key order', () {
    check(
        canonicalJson({
              'b': 1,
              'a': {'z': 9, 'y': 8}
            }) ==
            canonicalJson({
              'a': {'y': 8, 'z': 9},
              'b': 1
            }),
        'Canonicalization failed');
  });
  test('Second operational module installs without Core modifications', () {
    final p = fresh();
    const fixture = '../../fixtures/inspection';
    p.modules.registerTrustedCapability(
        Capability.fromJson(loadJsonFile('$fixture/capability.json')));
    DeclarativeModuleInstaller(
            modules: p.modules, docTypes: p.docTypes, english: p.english)
        .install(
      manifestJson: loadJsonFile('$fixture/manifest.json'),
      docTypeJsons: [loadJsonFile('$fixture/doctype.json')],
      englishCatalog: loadJsonFile('$fixture/localization/en.inspection.json'),
    );
    p.host.registerTrustedCreateBinding(const TrustedCommandBinding(
        'inspection.create', 1, 'EquipmentInspection'));
    final inspection = command(loadJsonFile('$fixture/create_command.json'));
    final principal =
        actor(permissions: {'inspection.create', 'inspection.read'});
    check(p.host.execute(inspection, principal).accepted,
        'Inspection create rejected');
    check(p.modules.installedIds.length == 2, 'Second module missing');
    check(p.english.text('inspection.module.name') == 'Equipment Inspections',
        'English fallback missing');
  });
  test('Two independent module commands preserve separate records and effects',
      () {
    final p = fresh();
    const fixture = '../../fixtures/inspection';
    p.modules.registerTrustedCapability(
        Capability.fromJson(loadJsonFile('$fixture/capability.json')));
    DeclarativeModuleInstaller(
            modules: p.modules, docTypes: p.docTypes, english: p.english)
        .install(
      manifestJson: loadJsonFile('$fixture/manifest.json'),
      docTypeJsons: [loadJsonFile('$fixture/doctype.json')],
      englishCatalog: loadJsonFile('$fixture/localization/en.inspection.json'),
    );
    p.host.registerTrustedCreateBinding(const TrustedCommandBinding(
        'inspection.create', 1, 'EquipmentInspection'));
    final all = actor(permissions: {
      'maintenance.create',
      'maintenance.read',
      'inspection.create',
      'inspection.read'
    });
    final maintenance = p.host.execute(command(), all);
    final inspectionCommand =
        command(loadJsonFile('$fixture/create_command.json'));
    final inspection = p.host.execute(inspectionCommand, all);
    final replay = p.host.execute(inspectionCommand, all);
    check(maintenance.accepted && inspection.accepted,
        'Multi-module commands failed');
    check(identical(inspection, replay), 'Second module idempotency failed');
    check(
        p.host.recordCount == 2 &&
            p.host.auditCount == 2 &&
            p.host.outboxCount == 2,
        'Unexpected cross-module effects');
  });
  test('Unauthorized cross-module command is rejected', () {
    final p = fresh();
    const fixture = '../../fixtures/inspection';
    p.modules.registerTrustedCapability(
        Capability.fromJson(loadJsonFile('$fixture/capability.json')));
    DeclarativeModuleInstaller(
            modules: p.modules, docTypes: p.docTypes, english: p.english)
        .install(
      manifestJson: loadJsonFile('$fixture/manifest.json'),
      docTypeJsons: [loadJsonFile('$fixture/doctype.json')],
      englishCatalog: loadJsonFile('$fixture/localization/en.inspection.json'),
    );
    p.host.registerTrustedCreateBinding(const TrustedCommandBinding(
        'inspection.create', 1, 'EquipmentInspection'));
    final inspection = command(loadJsonFile('$fixture/create_command.json'));
    final receipt = p.host.execute(inspection, actor());
    check(receipt.reasonCode == 'PERMISSION_DENIED',
        'Cross-module permission bypass');
    check(p.host.recordCount == 0, 'Unauthorized effect');
  });
  test('Missing English translation aborts installation without partial state',
      () {
    final p = fresh();
    const fixture = '../../fixtures/inspection';
    p.modules.registerTrustedCapability(
        Capability.fromJson(loadJsonFile('$fixture/capability.json')));
    final catalog = loadJsonFile('$fixture/localization/en.inspection.json');
    catalog.remove('inspection.record.asset_tag');
    checkThrows(
        () => DeclarativeModuleInstaller(
                    modules: p.modules,
                    docTypes: p.docTypes,
                    english: p.english)
                .install(
              manifestJson: loadJsonFile('$fixture/manifest.json'),
              docTypeJsons: [loadJsonFile('$fixture/doctype.json')],
              englishCatalog: catalog,
            ),
        'Missing English label accepted');
    check(
        p.modules.installedIds.length == 1 &&
            p.docTypes.get('EquipmentInspection') == null &&
            !p.english.hasKey('inspection.module.name'),
        'Partial installation changed registries');
  });
  test('Duplicate DocType aborts installation without partial state', () {
    final p = fresh();
    const fixture = '../../fixtures/inspection';
    p.modules.registerTrustedCapability(
        Capability.fromJson(loadJsonFile('$fixture/capability.json')));
    final manifest = loadJsonFile('$fixture/manifest.json');
    manifest['docTypes'] = ['MaintenanceRequest'];
    final docType = loadJsonFile('$fixture/doctype.json');
    docType['name'] = 'MaintenanceRequest';
    checkThrows(
        () => DeclarativeModuleInstaller(
                    modules: p.modules,
                    docTypes: p.docTypes,
                    english: p.english)
                .install(
              manifestJson: manifest,
              docTypeJsons: [docType],
              englishCatalog:
                  loadJsonFile('$fixture/localization/en.inspection.json'),
            ),
        'Duplicate DocType accepted');
    check(
        p.modules.installedIds.length == 1 &&
            !p.english.hasKey('inspection.module.name'),
        'Failed install left residue');
  });
  test('Invalid English catalog aborts installation without partial state', () {
    final p = fresh();
    const fixture = '../../fixtures/inspection';
    p.modules.registerTrustedCapability(
        Capability.fromJson(loadJsonFile('$fixture/capability.json')));
    final catalog = loadJsonFile('$fixture/localization/en.inspection.json');
    catalog['inspection.record.asset_tag'] = '';
    checkThrows(
        () => DeclarativeModuleInstaller(
                    modules: p.modules,
                    docTypes: p.docTypes,
                    english: p.english)
                .install(
              manifestJson: loadJsonFile('$fixture/manifest.json'),
              docTypeJsons: [loadJsonFile('$fixture/doctype.json')],
              englishCatalog: catalog,
            ),
        'Invalid English catalog accepted');
    check(
        p.modules.installedIds.length == 1 &&
            p.docTypes.get('EquipmentInspection') == null,
        'Partial installation occurred');
  });
  test('Unknown capability rejects second module before any installation', () {
    final p = fresh();
    const fixture = '../../fixtures/inspection';
    checkThrows(
        () => DeclarativeModuleInstaller(
                    modules: p.modules,
                    docTypes: p.docTypes,
                    english: p.english)
                .install(
              manifestJson: loadJsonFile('$fixture/manifest.json'),
              docTypeJsons: [loadJsonFile('$fixture/doctype.json')],
              englishCatalog:
                  loadJsonFile('$fixture/localization/en.inspection.json'),
            ),
        'Untrusted capability was accepted');
    check(p.modules.installedIds.length == 1,
        'Module installed without trusted capability');
  });
  test('Offline metadata cannot bypass a Host capability restriction', () {
    final p = fresh();
    const fixture = '../../fixtures/inspection';
    p.modules.registerTrustedCapability(
        Capability.fromJson(loadJsonFile('$fixture/capability.json')));
    final manifest = loadJsonFile('$fixture/manifest.json');
    (manifest['offline'] as Map<String, dynamic>)['enabled'] = true;
    (manifest['offline'] as Map<String, dynamic>)['allowedCommands'] = [
      'inspection.create'
    ];
    checkThrows(
        () => DeclarativeModuleInstaller(
                    modules: p.modules,
                    docTypes: p.docTypes,
                    english: p.english)
                .install(
              manifestJson: manifest,
              docTypeJsons: [loadJsonFile('$fixture/doctype.json')],
              englishCatalog:
                  loadJsonFile('$fixture/localization/en.inspection.json'),
            ),
        'Offline permission bypassed Host capability');
    check(p.modules.installedIds.length == 1,
        'Offline rejection left an installed module');
  });
  test('Installed module dependency is accepted in the correct order', () {
    final p = fresh();
    const fixture = '../../fixtures/inspection';
    p.modules.registerTrustedCapability(
        Capability.fromJson(loadJsonFile('$fixture/capability.json')));
    final manifest = loadJsonFile('$fixture/manifest.json');
    manifest['dependencies'] = ['com.ventio.maintenance'];
    DeclarativeModuleInstaller(
            modules: p.modules, docTypes: p.docTypes, english: p.english)
        .install(
      manifestJson: manifest,
      docTypeJsons: [loadJsonFile('$fixture/doctype.json')],
      englishCatalog: loadJsonFile('$fixture/localization/en.inspection.json'),
    );
    check(p.modules.installedIds.length == 2, 'Valid dependency was rejected');
  });
  test('Permission mismatch between command and trusted capability is rejected',
      () {
    final p = fresh();
    const fixture = '../../fixtures/inspection';
    p.modules.registerTrustedCapability(
        Capability.fromJson(loadJsonFile('$fixture/capability.json')));
    final manifest = loadJsonFile('$fixture/manifest.json');
    (manifest['commands'] as List<dynamic>).first['permission'] =
        'maintenance.create';
    checkThrows(
        () => DeclarativeModuleInstaller(
                    modules: p.modules,
                    docTypes: p.docTypes,
                    english: p.english)
                .install(
              manifestJson: manifest,
              docTypeJsons: [loadJsonFile('$fixture/doctype.json')],
              englishCatalog:
                  loadJsonFile('$fixture/localization/en.inspection.json'),
            ),
        'Capability mismatch accepted');
    check(p.modules.installedIds.length == 1,
        'Failed command validation mutated registry');
  });
  test('Nested command values cannot diverge from their fingerprint', () {
    final source = commandJson();
    source['payload']['nested'] = {
      'items': [
        1,
        {'value': 'original'}
      ]
    };
    final envelope = CommandEnvelope.fromJson(source);
    final fingerprint = canonicalJson(envelope.original);
    source['payload']['nested']['items'][1]['value'] = 'caller-change';
    check(canonicalJson(envelope.original) == fingerprint,
        'Source mutated envelope');
    checkThrows(
        () => envelope.payload['nested']['items'][1]['value'] = 'changed',
        'Nested payload allowed a write');
    checkThrows(() => envelope.original['clientContext']['actorId'] = 'forged',
        'Nested wire context allowed a write');
    checkThrows(() => envelope.original['payload']['nested']['items'].add(2),
        'Nested wire array allowed a write');
    check(
        canonicalJson(envelope.original) == fingerprint, 'Fingerprint changed');
  });
  test('A caller cannot corrupt a journaled receipt through its output', () {
    final prototype = fresh();
    final receipt = prototype.host.execute(command(), actor());
    check(receipt.accepted, 'Command was not accepted');
    final expected = canonicalJson(receipt.toJson());
    checkThrows(() => receipt.output!['serverRecordId'] = 'forged',
        'Receipt output was writable');
    final wire = receipt.toJson();
    checkThrows(() => (wire['output'] as Map)['serverRecordId'] = 'forged',
        'Serialized receipt leaked writable journal data');
    check(
        canonicalJson(prototype.host.execute(command(), actor()).toJson()) ==
            expected,
        'Retry receipt was corrupted');
  });
  test('Nonfinite JSON values cannot enter an envelope', () {
    final raw = commandJson();
    raw['payload']['overflow'] = double.infinity;
    checkThrows(
        () => CommandEnvelope.fromJson(raw), 'Nonfinite value accepted');
  });
  test('Host receipts parse and round-trip through the shared Core contract', () {
    final acceptedJson =
        loadJsonFile('$root/examples/accepted_receipt.json');
    final accepted = CommandReceipt.fromJson(acceptedJson);
    check(accepted.accepted, 'Accepted Host receipt changed state');
    check(
        accepted.serverTimestamp == acceptedJson['serverTimestamp'],
        'Host timestamp was replaced with a client timestamp');
    check(
        canonicalJson(accepted.toJson()) == canonicalJson(acceptedJson),
        'Accepted Host receipt did not round-trip');
    checkThrows(
        () => accepted.output!['serverRecordId'] = 'forged',
        'Parsed Host receipt output was mutable');

    final rejectedJson =
        loadJsonFile('$root/examples/rejected_receipt.json');
    final rejected = CommandReceipt.fromJson(rejectedJson);
    check(rejected.status == 'REJECTED', 'Rejected receipt status changed');
    check(
        rejected.messageParams?['field'] == 'Device Model',
        'Localized receipt parameters were lost');
    check(
        canonicalJson(rejected.toJson()) == canonicalJson(rejectedJson),
        'Rejected Host receipt did not round-trip');
  });
  test('Malformed Host receipt combinations fail closed', () {
    final invalid =
        loadJsonFile('$root/examples/accepted_receipt.json');
    invalid['retryable'] = true;
    checkThrows(
        () => CommandReceipt.fromJson(invalid),
        'Accepted receipt with retryable=true was accepted');
    final unknown =
        loadJsonFile('$root/examples/accepted_receipt.json');
    unknown['scope'] = 'client-controlled';
    checkThrows(
        () => CommandReceipt.fromJson(unknown),
        'Receipt with unsupported authority field was accepted');
  });
  print('RESULT: $passed passed, $failed failed');
  if (failed > 0) throw StateError('$failed tests failed');
}
