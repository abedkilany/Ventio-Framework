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

Map<String, dynamic> extensionBundleJson() => {
      'manifest': {
        'manifestVersion': 0,
        'moduleId': 'com.example.assets',
        'version': '0.1.0',
        'minPlatformApi': '0.1.0',
        'displayName': 'Assets',
        'displayNameKey': 'extension.com_example_assets.module.name',
        'englishCatalog': 'localization/en.assets.json',
        'dependencies': <String>[],
        'docTypes': ['Asset'],
        'commands': <Object>[],
        'requiredCapabilities': <String>[],
        'offline': {'enabled': false, 'allowedCommands': <String>[]},
      },
      'docTypes': [
        {
          'name': 'Asset',
          'moduleId': 'com.example.assets',
          'schemaVersion': 1,
          'kind': 'operational',
          'label': 'Asset',
          'labelKey': 'extension.com_example_assets.asset.name',
          'operations': ['read', 'create', 'update'],
          'permissions': {
            'read': 'extension.com_example_assets.asset.read',
            'create': 'extension.com_example_assets.asset.create',
            'update': 'extension.com_example_assets.asset.update',
          },
          'fields': [
            {
              'name': 'name',
              'type': 'text',
              'required': true,
              'maxLength': 120,
              'label': 'Name',
              'labelKey': 'extension.com_example_assets.asset.name_value',
            },
          ],
          'ui': {
            'listColumns': ['name'],
            'formFields': ['name'],
            'detailFields': ['name'],
          },
        },
      ],
      'dependencyVersions': <String, String>{},
      'englishCatalog': {
        'extension.com_example_assets.module.name': 'Assets',
        'extension.com_example_assets.asset.name': 'Asset',
        'extension.com_example_assets.asset.name_value': 'Name',
      },
    };

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
  test('Principal grants stay bound to exact company and branch pairs', () {
    final principal = Principal(
      actorId: 'user',
      deviceId: 'device',
      tenantId: 'tenant',
      companyIds: {'company-A', 'company-B'},
      branchIds: {'branch-1', 'branch-2'},
      permissions: {'assets.read', 'assets.write'},
      scopeGrants: [
        PrincipalScope(
          companyId: 'company-A',
          branchId: 'branch-1',
          permissions: {'assets.read'},
        ),
        PrincipalScope(
          companyId: 'company-B',
          branchId: 'branch-2',
          permissions: {'assets.write'},
        ),
      ],
    );

    check(
      principal.allowsInScope('assets.read', 'company-A', 'branch-1'),
      'Grant for the authorized pair was lost',
    );
    check(
      !principal.hasScope('company-A', 'branch-2'),
      'Separate company and branch grants formed an unauthorized pair',
    );
    check(
      !principal.allowsInScope('assets.write', 'company-A', 'branch-1') &&
          !principal.allowsInScope('assets.read', 'company-B', 'branch-2'),
      'Permissions leaked between exact scopes',
    );
    checkThrows(
      () => Principal(
        actorId: 'user',
        deviceId: 'device',
        tenantId: 'tenant',
        companyIds: {'company-A', 'company-B'},
        branchIds: {'branch-1', 'branch-2'},
        permissions: {'assets.read'},
      ),
      'Multiple scope sets without explicit pairs were accepted',
    );
  });

  test('Extension bundles are declarative, namespaced and versioned', () {
    final source = extensionBundleJson();
    final bundle = ExtensionBundle.fromJson(source);
    check(
      bundle.moduleId == 'com.example.assets' &&
          bundle.version == '0.1.0' &&
          bundle.docTypes.single.name == 'Asset',
      'Valid extension bundle did not parse',
    );
    check(
      canonicalJson(bundle.toJson()) == canonicalJson(source),
      'Extension bundle did not round-trip canonically',
    );
    final outsidePackageRelation = changed(source);
    final relationType = (outsidePackageRelation['docTypes'] as List).single
        as Map<String, dynamic>;
    (relationType['fields'] as List).add({
      'name': 'externalAsset',
      'type': 'reference',
      'referenceTo': 'ExternalAsset',
      'required': false,
      'label': 'External asset',
      'labelKey': 'extension.com_example_assets.asset.external_asset',
    });
    (outsidePackageRelation['englishCatalog'] as Map<String, dynamic>)[
        'extension.com_example_assets.asset.external_asset'] = 'External asset';
    checkThrows(
      () => ExtensionBundle.fromJson(outsidePackageRelation),
      'A package reference target outside the module was accepted',
    );
    final generatedPage = changed(source);
    final generatedPageType =
        (generatedPage['docTypes'] as List).single as Map<String, dynamic>;
    final generatedPageUi = generatedPageType['ui'] as Map<String, dynamic>;
    generatedPageUi.addAll({
      'pageTitle': 'Asset overview',
      'pageTitleKey': 'extension.com_example_assets.asset.page_title',
      'pageIcon': 'grid',
      'pageOrder': 20,
    });
    (generatedPage['englishCatalog'] as Map<String, dynamic>)[
        'extension.com_example_assets.asset.page_title'] = 'Asset overview';
    final configuredPage = ExtensionBundle.fromJson(generatedPage);
    check(
      configuredPage.docTypes.single.pageTitle == 'Asset overview' &&
          configuredPage.docTypes.single.pageIcon == 'grid' &&
          configuredPage.docTypes.single.pageOrder == 20 &&
          canonicalJson(configuredPage.toJson()) ==
              canonicalJson(generatedPage),
      'Generated page settings did not validate and round-trip',
    );
    final unsupportedPageIcon = changed(generatedPage);
    (((unsupportedPageIcon['docTypes'] as List).single
            as Map<String, dynamic>)['ui']
        as Map<String, dynamic>)['pageIcon'] = 'run_script';
    checkThrows(
      () => ExtensionBundle.fromJson(unsupportedPageIcon),
      'A generated page accepted an unsupported icon token',
    );
    final excessivePageOrder = changed(generatedPage);
    (((excessivePageOrder['docTypes'] as List).single
            as Map<String, dynamic>)['ui']
        as Map<String, dynamic>)['pageOrder'] = 10001;
    checkThrows(
      () => ExtensionBundle.fromJson(excessivePageOrder),
      'A generated page accepted an unbounded navigation order',
    );
    final incompletePageTitle = changed(generatedPage);
    (((incompletePageTitle['docTypes'] as List).single
            as Map<String, dynamic>)['ui'] as Map<String, dynamic>)
        .remove('pageTitleKey');
    checkThrows(
      () => ExtensionBundle.fromJson(incompletePageTitle),
      'A custom page title without its localization key was accepted',
    );
    final legacy = changed(source);
    ((legacy['docTypes'] as List).single as Map<String, dynamic>)['ui']
        .remove('detailFields');
    check(
      ExtensionBundle.fromJson(legacy).docTypes.single.detailFields.single ==
              'name' &&
          ExtensionBundle.fromJson(legacy).docTypes.single.pageTitle ==
              'Asset' &&
          ExtensionBundle.fromJson(legacy).docTypes.single.pageIcon == 'list' &&
          ExtensionBundle.fromJson(legacy).docTypes.single.pageOrder == 0,
      'A legacy bundle without detailFields must preserve its default detail view',
    );
    checkThrows(
      () => (bundle.docTypeJson.single['fields'] as List).add({'name': 'sql'}),
      'Nested extension bundle metadata remained mutable',
    );

    final executable = changed(source);
    (executable['manifest'] as Map<String, dynamic>)['commands'] = [
      {
        'type': 'arbitrary.sql',
        'version': 1,
        'capabilityId': 'arbitrary.executor@1',
        'permission': 'extension.com_example_assets.asset.run',
      },
    ];
    (executable['manifest'] as Map<String, dynamic>)['requiredCapabilities'] = [
      'arbitrary.executor@1',
    ];
    checkThrows(
      () => ExtensionBundle.fromJson(executable),
      'An extension supplied an executable command surface',
    );

    final permissions = changed(source);
    ((permissions['docTypes'] as List).single
        as Map<String, dynamic>)['permissions']['create'] = 'system.admin';
    checkThrows(
      () => ExtensionBundle.fromJson(permissions),
      'A package declared a permission outside its namespace',
    );

    final fieldPermissions = changed(source);
    final fieldPermission = (((fieldPermissions['docTypes'] as List).single
            as Map<String, dynamic>)['fields'] as List)
        .single as Map<String, dynamic>;
    fieldPermission['readPermission'] =
        'extension.com_example_assets.asset.field.name.read';
    (fieldPermissions['manifest'] as Map<String, dynamic>)['minPlatformApi'] =
        '0.2.0';
    checkThrows(
      () => ExtensionBundle.fromJson(fieldPermissions),
      'Field permissions were accepted without the enforcing platform API',
    );
    (fieldPermissions['manifest'] as Map<String, dynamic>)['minPlatformApi'] =
        fieldPermissionPlatformApiVersion;
    final securedBundle = ExtensionBundle.fromJson(fieldPermissions);
    check(
      securedBundle.docTypes.single.fields.single.readPermission ==
          'extension.com_example_assets.asset.field.name.read',
      'A valid field permission did not round-trip',
    );
    fieldPermission['writePermission'] = 'system.admin';
    checkThrows(
      () => ExtensionBundle.fromJson(fieldPermissions),
      'A package declared a field permission outside its namespace',
    );

    final injectedLabel = changed(source);
    (injectedLabel['englishCatalog']
        as Map<String, dynamic>)['core.app.title'] = 'Injected';
    checkThrows(
      () => ExtensionBundle.fromJson(injectedLabel),
      'An extension wrote into the Core message namespace',
    );

    final hiddenMigration = changed(source);
    (hiddenMigration['manifest'] as Map<String, dynamic>)['migrations'] = [
      'DROP TABLE ventio_records',
    ];
    checkThrows(
      () => ExtensionBundle.fromJson(hiddenMigration),
      'An extension smuggled SQL through unknown manifest metadata',
    );

    final hiddenUiScript = changed(source);
    ((hiddenUiScript['docTypes'] as List).single as Map<String, dynamic>)['ui']
        ['script'] = 'return process.env';
    checkThrows(
      () => ExtensionBundle.fromJson(hiddenUiScript),
      'Executable UI metadata was accepted',
    );

    final escapedCatalogPath = changed(source);
    (escapedCatalogPath['manifest'] as Map<String, dynamic>)['englishCatalog'] =
        'C:/outside/catalog.json';
    checkThrows(
      () => ExtensionBundle.fromJson(escapedCatalogPath),
      'An absolute catalog path was accepted',
    );

    final bounded = changed(source);
    final boundedField = (((bounded['docTypes'] as List).single
            as Map<String, dynamic>)['fields'] as List)
        .single as Map<String, dynamic>;
    boundedField
      ..['type'] = 'integer'
      ..remove('maxLength')
      ..['minValue'] = 0
      ..['maxValue'] = 100;
    final boundedBundle = ExtensionBundle.fromJson(bounded);
    check(
      boundedBundle.docTypes.single.fields.single.minValue == 0 &&
          boundedBundle.docTypes.single.fields.single.maxValue == 100,
      'Numeric bounds did not survive extension bundle parsing',
    );
    boundedField['minValue'] = 0.5;
    checkThrows(
      () => ExtensionBundle.fromJson(bounded),
      'An invalid integer bound bypassed bundle validation',
    );

    final minimumLength = changed(source);
    final minimumLengthField = (((minimumLength['docTypes'] as List).single
            as Map<String, dynamic>)['fields'] as List)
        .single as Map<String, dynamic>;
    minimumLengthField['minLength'] = 3;
    check(
      ExtensionBundle.fromJson(minimumLength)
              .docTypes
              .single
              .fields
              .single
              .minLength ==
          3,
      'Minimum text length did not survive extension bundle parsing',
    );

    final tooManyMigrationSteps = changed(source);
    final migrationType = (tooManyMigrationSteps['docTypes'] as List).single
        as Map<String, dynamic>;
    migrationType['schemaVersion'] = 6;
    migrationType['migrations'] = [
      for (var fromVersion = 1; fromVersion <= 5; fromVersion++)
        {
          'fromVersion': fromVersion,
          'toVersion': fromVersion + 1,
          'steps': [
            for (var step = 0; step < 32; step++)
              {
                'op': 'setDefault',
                'field': 'name',
                'value': 'Imported',
              },
          ],
        },
    ];
    checkThrows(
      () => ExtensionBundle.fromJson(tooManyMigrationSteps),
      'A package exceeded the aggregate schema migration operation bound',
    );

    final cyclic = extensionBundleJson();
    (cyclic['manifest'] as Map<String, dynamic>)['cycle'] = cyclic;
    checkThrows(
      () => ExtensionBundle.fromJson(cyclic),
      'Cyclic metadata bypassed bounded package validation',
    );

    final deeplyNested = changed(source);
    Object nestedValue = 'leaf';
    for (var i = 0; i < 40; i++) {
      nestedValue = [nestedValue];
    }
    deeplyNested['extra'] = nestedValue;
    checkThrows(
      () => ExtensionBundle.fromJson(deeplyNested),
      'Overly nested package metadata was accepted',
    );
  });

  test('Numeric field bounds are typed, finite and enforced', () {
    Map<String, dynamic> numberField({
      String type = 'integer',
      Object? minimum = 1,
      Object? maximum = 10,
    }) =>
        {
          'name': 'quantity',
          'type': type,
          'required': false,
          if (minimum != null) 'minValue': minimum,
          if (maximum != null) 'maxValue': maximum,
          'label': 'Quantity',
          'labelKey': 'extension.example.asset.quantity',
        };

    final integer = FieldDefinition.fromJson(numberField());
    check(
      integer.validate(1) == null && integer.validate(10) == null,
      'Inclusive integer bounds rejected their edge values',
    );
    check(
      integer.validate(0) == 'BELOW_MINIMUM' &&
          integer.validate(11) == 'ABOVE_MAXIMUM',
      'Integer values outside the declared bounds were accepted',
    );

    final decimal = FieldDefinition.fromJson(
      numberField(type: 'decimal', minimum: -1.25, maximum: 2.5),
    );
    check(
      decimal.validate(-1.3) == 'BELOW_MINIMUM' &&
          decimal.validate(2.6) == 'ABOVE_MAXIMUM' &&
          decimal.validate(2.5) == null,
      'Decimal bounds were not applied inclusively',
    );

    checkThrows(
      () => FieldDefinition.fromJson(
        numberField(type: 'integer', minimum: 1.5),
      ),
      'Fractional bounds were accepted for integer fields',
    );
    checkThrows(
      () => FieldDefinition.fromJson(
        numberField(type: 'text', minimum: 1),
      ),
      'Numeric bounds were accepted for text fields',
    );
    checkThrows(
      () => FieldDefinition.fromJson(
        numberField(minimum: 11, maximum: 10),
      ),
      'A minimum greater than the maximum was accepted',
    );
    checkThrows(
      () => FieldDefinition.fromJson(
        numberField(type: 'decimal', minimum: double.infinity),
      ),
      'A nonfinite numeric bound was accepted',
    );
  });

  test(
      'Partial updates validate supplied fields without requiring omitted ones',
      () {
    final definition = DocTypeDefinition.fromJson(
      (extensionBundleJson()['docTypes'] as List).single
          as Map<String, dynamic>,
    );
    check(
      definition.validatePayload({}, partial: true).isEmpty &&
          definition.validatePayload({}).any(
            (issue) => issue == 'name:REQUIRED',
          ),
      'Partial validation must skip omitted required fields only',
    );
    check(
      definition.validatePayload({'name': 4}, partial: true).any(
            (issue) => issue == 'name:INVALID_TEXT',
          ) &&
          definition.validatePayload({'unknown': 'x'}, partial: true).any(
            (issue) => issue == 'unknown:UNKNOWN_FIELD',
          ),
      'Partial validation must still validate supplied values and field names',
    );
  });

  test('Text length bounds are typed and enforced', () {
    Map<String, dynamic> textField({
      String type = 'text',
      bool required = true,
      int? minimum = 3,
      int? maximum = 10,
    }) =>
        {
          'name': 'title',
          'type': type,
          'required': required,
          if (minimum != null) 'minLength': minimum,
          if (maximum != null) 'maxLength': maximum,
          'label': 'Title',
          'labelKey': 'extension.example.asset.title',
        };

    final title = FieldDefinition.fromJson(textField());
    check(
      title.validate('AB') == 'TOO_SHORT' && title.validate('ABC') == null,
      'Text minimum length was not enforced inclusively',
    );
    check(
      title.validate('😀😀') == 'TOO_SHORT' && title.validate('😀😀😀') == null,
      'Text minimum length counted UTF-16 code units instead of Unicode runes',
    );
    check(
      FieldDefinition.fromJson(textField(required: false)).validate('') == null,
      'A blank optional text field was rejected by its minimum length',
    );
    check(
      FieldDefinition.fromJson(textField(minimum: null, maximum: 2))
              .minLength ==
          null,
      'A field without a minimum length acquired one',
    );
    checkThrows(
      () => FieldDefinition.fromJson(textField(type: 'integer')),
      'Minimum text length was accepted on an integer field',
    );
    checkThrows(
      () => FieldDefinition.fromJson(textField(minimum: 11, maximum: 10)),
      'A minimum text length greater than the maximum was accepted',
    );
  });

  test('Long text and table fields preserve their typed value shapes', () {
    final longText = FieldDefinition.fromJson({
      'name': 'notes',
      'type': 'long_text',
      'required': true,
      'minLength': 2,
      'maxLength': 2000,
      'label': 'Notes',
      'labelKey': 'extension.example.asset.notes',
    });
    check(
      longText.validate('A') == 'TOO_SHORT' &&
          longText.validate('Long description') == null &&
          longText.validate(List.filled(2001, 'x').join()) == 'TOO_LONG',
      'Long text bounds were not enforced',
    );

    final table = FieldDefinition.fromJson({
      'name': 'lines',
      'type': 'table',
      'required': true,
      'label': 'Lines',
      'labelKey': 'extension.example.asset.lines',
    });
    check(
      table.validate([
            {'itemCode': 'SKU-1', 'quantity': 3},
          ]) ==
          null,
      'A flat child-row table was rejected',
    );
    check(
      table.validate([]) == 'INVALID_TABLE' &&
          table.validate([
                {
                  'nested': {'unsupported': true}
                },
              ]) ==
              'INVALID_TABLE' &&
          table.validate(
                List.generate(
                    maxRowsPerTableField + 1, (index) => {'row': index}),
              ) ==
              'INVALID_TABLE',
      'Required, nested, or oversized table data was accepted',
    );
  });

  test('Child DocType rows validate defaults, fields, references and bounds',
      () {
    final raw = changed(
      (extensionBundleJson()['docTypes'] as List).single
          as Map<String, dynamic>,
    );
    final fields = raw['fields'] as List;
    fields.add({
      'name': 'lines',
      'type': 'table',
      'required': true,
      'label': 'Lines',
      'labelKey': 'extension.com_example_assets.asset.lines',
      'childDocType': {
        'name': 'AssetLine',
        'label': 'Asset line',
        'labelKey': 'extension.com_example_assets.asset.line',
        'fields': [
          {
            'name': 'asset',
            'type': 'reference',
            'referenceTo': 'Asset',
            'required': true,
            'label': 'Asset',
            'labelKey': 'extension.com_example_assets.asset.line_asset',
          },
          {
            'name': 'quantity',
            'type': 'decimal',
            'required': true,
            'default': 1.25,
            'precision': 2,
            'label': 'Quantity',
            'labelKey': 'extension.com_example_assets.asset.line_quantity',
          },
        ],
      },
    });
    ((raw['ui'] as Map<String, dynamic>)['formFields'] as List).add('lines');
    final definition = DocTypeDefinition.fromJson(raw);
    final normalized = definition.applyDefaults({
      'name': 'Grouped asset',
      'lines': [
        {'asset': 'asset-1'},
      ],
    });
    check(
      definition.validatePayload(normalized).isEmpty &&
          ((normalized['lines'] as List).single as Map)['quantity'] == 1.25,
      'Child row defaults were not applied and validated',
    );
    check(
      definition.referencesIn(normalized).single.recordId == 'asset-1' &&
          definition.referencesIn(normalized).single.targetDocType == 'Asset',
      'Nested child references were not discoverable for scoped validation',
    );
    final package = extensionBundleJson();
    final packageDocType =
        (package['docTypes'] as List).single as Map<String, dynamic>;
    (packageDocType['fields'] as List).add(fields.last);
    ((packageDocType['ui'] as Map<String, dynamic>)['formFields'] as List)
        .add('lines');
    (package['englishCatalog'] as Map<String, String>).addAll({
      'extension.com_example_assets.asset.lines': 'Lines',
      'extension.com_example_assets.asset.line': 'Asset line',
      'extension.com_example_assets.asset.line_asset': 'Asset',
      'extension.com_example_assets.asset.line_quantity': 'Quantity',
    });
    final packageRoundTrip = ExtensionBundle.fromJson(
      ExtensionBundle.fromJson(package).toJson(),
    );
    check(
      packageRoundTrip.docTypes.single.fields.last.childDocType?.name ==
              'AssetLine' &&
          packageRoundTrip.docTypes.single.fields.last.childDocType!.fields.last
                  .precision ==
              2,
      'Extension package did not retain nested child schema metadata',
    );
    check(
      definition.validatePayload({
        'name': 'Invalid child',
        'lines': [
          {'asset': 'asset-1', 'quantity': 1.234},
        ],
      }).isNotEmpty,
      'Child decimal precision was not enforced',
    );
    check(
      definition.validatePayload({
        'name': 'Unknown child key',
        'lines': [
          {'asset': 'asset-1', 'extra': 'not declared'},
        ],
      }).isNotEmpty,
      'Unknown child fields were accepted',
    );
    check(
      definition.validatePayload({
        'name': 'Too many rows',
        'lines': List.generate(501, (_) => {'asset': 'asset-1'}),
      }).isNotEmpty,
      'The child row count exceeded the bounded table contract',
    );
    final invalidNested = changed(raw);
    final child = (((invalidNested['fields'] as List).last
        as Map)['childDocType'] as Map<String, dynamic>);
    ((child['fields'] as List).last as Map<String, dynamic>)['type'] = 'table';
    checkThrows(
      () => DocTypeDefinition.fromJson(invalidNested),
      'Nested child tables were accepted',
    );
    final invalidPermission = changed(raw);
    final permissionChild = (((invalidPermission['fields'] as List).last
        as Map)['childDocType'] as Map<String, dynamic>);
    ((permissionChild['fields'] as List).first
            as Map<String, dynamic>)['readPermission'] =
        'extension.com_example_assets.asset.secret.read';
    checkThrows(
      () => DocTypeDefinition.fromJson(invalidPermission),
      'A child field escaped the parent table permission boundary',
    );
  });

  test('Field precision, defaults, read-only and descriptions are enforced',
      () {
    final amount = FieldDefinition.fromJson({
      'name': 'amount',
      'type': 'decimal',
      'required': false,
      'precision': 2,
      'minValue': 0,
      'maxValue': 100,
      'default': 1.25,
      'readOnly': true,
      'label': 'Amount',
      'labelKey': 'extension.example.invoice.amount',
      'description': 'Approved amount.',
      'descriptionKey': 'extension.example.invoice.amount_description',
    });
    check(
      amount.validate(1.25) == null &&
          amount.validate(1.234) == 'INVALID_PRECISION' &&
          amount.defaultValue == 1.25 &&
          amount.readOnly &&
          amount.descriptionKey ==
              'extension.example.invoice.amount_description',
      'Decimal precision, default, read-only, or presentation metadata failed',
    );
    checkThrows(
      () => FieldDefinition.fromJson({
        'name': 'amount',
        'type': 'integer',
        'required': false,
        'precision': 2,
        'label': 'Amount',
        'labelKey': 'extension.example.invoice.amount',
      }),
      'Precision was allowed on a non-decimal field',
    );
    checkThrows(
      () => FieldDefinition.fromJson({
        'name': 'amount',
        'type': 'decimal',
        'required': false,
        'precision': 2,
        'default': 1.234,
        'label': 'Amount',
        'labelKey': 'extension.example.invoice.amount',
      }),
      'An invalid decimal default was accepted',
    );
    checkThrows(
      () => FieldDefinition.fromJson({
        'name': 'amount',
        'type': 'text',
        'required': false,
        'description': 'Missing translation key',
        'label': 'Amount',
        'labelKey': 'extension.example.invoice.amount',
      }),
      'A user-visible field description without a stable key was accepted',
    );
    final package = extensionBundleJson();
    final rawDocType =
        (package['docTypes'] as List).single as Map<String, dynamic>;
    ((rawDocType['fields'] as List).single as Map<String, dynamic>)['default'] =
        'Default asset';
    final docType = DocTypeDefinition.fromJson(rawDocType);
    final normalized = docType.applyDefaults({});
    check(
      normalized['name'] == 'Default asset' &&
          docType.validatePayload(normalized).isEmpty,
      'A declared default was not applied during payload normalization',
    );
    final previousJson = changed(
      (extensionBundleJson()['docTypes'] as List).single
          as Map<String, dynamic>,
    );
    final previousField =
        ((previousJson['fields'] as List).single as Map<String, dynamic>)
          ..['type'] = 'decimal'
          ..remove('maxLength')
          ..['precision'] = 4;
    final nextJson = changed(previousJson)..['schemaVersion'] = 2;
    (((nextJson['fields'] as List).single as Map<String, dynamic>)
      ..['precision'] = 2);
    checkThrows(
      () => validateDocTypeUpgrade(
        DocTypeDefinition.fromJson(previousJson),
        DocTypeDefinition.fromJson(nextJson),
      ),
      'A schema upgrade tightened decimal precision over saved values',
    );
    check(previousField['precision'] == 4, 'Previous precision was mutated');
  });

  test('Host rejects extension records outside declared field bounds', () {
    const fixture = '../../fixtures/inspection';
    final modules = ModuleRegistry();
    final docTypes = DocTypeRegistry();
    final english = EnglishCatalog();
    final manifest = loadJsonFile('$fixture/manifest.json');
    final doctype = loadJsonFile('$fixture/doctype.json');
    (doctype['fields'] as List).add({
      'name': 'relatedInspection',
      'type': 'reference',
      'referenceTo': 'EquipmentInspection',
      'required': false,
      'label': 'Related inspection',
      'labelKey': 'inspection.record.related_inspection',
    });
    (doctype['fields'] as List).addAll([
      {
        'name': 'taxRate',
        'type': 'decimal',
        'required': false,
        'precision': 2,
        'label': 'Tax rate',
        'labelKey': 'inspection.record.tax_rate',
      },
      {
        'name': 'approvedRate',
        'type': 'decimal',
        'required': false,
        'precision': 2,
        'default': 1.25,
        'readOnly': true,
        'label': 'Approved rate',
        'labelKey': 'inspection.record.approved_rate',
        'description': 'Host managed approved rate.',
        'descriptionKey': 'inspection.record.approved_rate_description',
      },
    ]);
    ((doctype['ui'] as Map<String, dynamic>)['formFields'] as List)
        .add('relatedInspection');
    ((doctype['fields'] as List).first as Map<String, dynamic>)['minLength'] =
        5;
    final priority = (doctype['fields'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((field) => field['name'] == 'priority');
    priority
      ..['type'] = 'integer'
      ..remove('enumValues')
      ..remove('enumLabels')
      ..['minValue'] = 1
      ..['maxValue'] = 5;
    modules.registerTrustedCapability(
      Capability.fromJson(loadJsonFile('$fixture/capability.json')),
    );
    final englishCatalog = loadJsonFile(
      '$fixture/localization/en.inspection.json',
    )
      ..['inspection.record.related_inspection'] = 'Related inspection'
      ..['inspection.record.tax_rate'] = 'Tax rate'
      ..['inspection.record.approved_rate'] = 'Approved rate'
      ..['inspection.record.approved_rate_description'] =
          'Host managed approved rate.';
    DeclarativeModuleInstaller(
      modules: modules,
      docTypes: docTypes,
      english: english,
    ).install(
      manifestJson: manifest,
      docTypeJsons: [doctype],
      englishCatalog: englishCatalog,
    );
    final host = InMemoryHost(modules: modules, docTypes: docTypes)
      ..registerTrustedCreateBinding(
        const TrustedCommandBinding(
          'inspection.create',
          1,
          'EquipmentInspection',
        ),
      );
    Map<String, int> effectCounts() => {
          'records': host.recordCount,
          'commands': host.acceptedCommandCount,
          'audit': host.auditCount,
          'outbox': host.outboxCount,
        };
    bool effectsUnchanged(Map<String, int> before) {
      final after = effectCounts();
      return before.keys.every((key) => before[key] == after[key]);
    }

    final raw = loadJsonFile('$fixture/create_command.json');
    (raw['payload'] as Map<String, dynamic>)['priority'] = 0;
    final command = CommandEnvelope.fromJson(raw);
    final principal = Principal(
      tenantId: command.tenantId,
      actorId: command.actorId,
      deviceId: command.deviceId,
      companyIds: {command.companyId},
      branchIds: {command.branchId},
      permissions: {'inspection.create', 'inspection.read'},
    );

    check(
      host.execute(command, principal).reasonCode == 'INVALID_PAYLOAD',
      'Host accepted an extension record outside its declared numeric bounds',
    );

    final shortTextRaw = Map<String, dynamic>.from(raw)
      ..['commandId'] = uuid(903)
      ..['payload'] = Map<String, dynamic>.from(
        raw['payload'] as Map<String, dynamic>,
      )
      ..['payload']['priority'] = 'normal'
      ..['payload']['assetTag'] = 'EQ';
    final shortTextCommand = CommandEnvelope.fromJson(shortTextRaw);
    check(
      host.execute(shortTextCommand, principal).reasonCode == 'INVALID_PAYLOAD',
      'Host accepted text shorter than the declared minimum length',
    );

    final parentPayload = Map<String, dynamic>.from(
      raw['payload'] as Map<String, dynamic>,
    )..['priority'] = 3;
    final parentRaw = Map<String, dynamic>.from(raw)
      ..['commandId'] = uuid(904)
      ..['aggregateId'] = 'inspection-parent'
      ..['payload'] = parentPayload;
    final parent = CommandEnvelope.fromJson(parentRaw);
    final parentReceipt = host.execute(parent, principal);
    check(
      parentReceipt.accepted,
      'Host accepts a reference target in the same branch (${parentReceipt.reasonCode})',
    );
    final storedParent = host.readRecord(
      'EquipmentInspection',
      parent.aggregateId,
      principal,
      companyId: command.companyId,
      branchId: command.branchId,
    );
    check(
      storedParent?.data['approvedRate'] == 1.25,
      'Host did not apply and persist the declared read-only default',
    );

    final precisionRaw = Map<String, dynamic>.from(parentRaw)
      ..['commandId'] = uuid(907)
      ..['aggregateId'] = 'inspection-invalid-precision'
      ..['payload'] = Map<String, dynamic>.from(parentPayload)
      ..['payload']['taxRate'] = 1.234;
    check(
      host
              .execute(CommandEnvelope.fromJson(precisionRaw), principal)
              .reasonCode ==
          'INVALID_PAYLOAD',
      'Host accepted a decimal outside its declared precision',
    );

    final readOnlyRaw = Map<String, dynamic>.from(parentRaw)
      ..['commandId'] = uuid(908)
      ..['aggregateId'] = 'inspection-readonly-override'
      ..['payload'] = Map<String, dynamic>.from(parentPayload)
      ..['payload']['approvedRate'] = 9.99;
    check(
      host
              .execute(CommandEnvelope.fromJson(readOnlyRaw), principal)
              .reasonCode ==
          'READ_ONLY_FIELD',
      'Host accepted a client override of a read-only field',
    );

    final childPayload = Map<String, dynamic>.from(parentPayload)
      ..['assetTag'] = 'EQ-101'
      ..['relatedInspection'] = parent.aggregateId;
    final childRaw = Map<String, dynamic>.from(raw)
      ..['commandId'] = uuid(905)
      ..['aggregateId'] = 'inspection-child'
      ..['payload'] = childPayload;
    final child = CommandEnvelope.fromJson(childRaw);
    check(
      host.execute(child, principal).accepted,
      'Host accepts a reference to an existing same-branch record',
    );

    final missingReferenceRaw = Map<String, dynamic>.from(childRaw)
      ..['commandId'] = uuid(906)
      ..['aggregateId'] = 'inspection-missing-reference'
      ..['payload'] = Map<String, dynamic>.from(childPayload)
      ..['payload']['relatedInspection'] = 'missing-inspection';
    final missingReference = CommandEnvelope.fromJson(missingReferenceRaw);
    final beforeMissingReference = effectCounts();
    check(
      host.execute(missingReference, principal).reasonCode ==
              'INVALID_REFERENCE' &&
          effectsUnchanged(beforeMissingReference),
      'Host rejects a missing reference without business effects',
    );

    final otherBranchPrincipal = Principal(
      tenantId: command.tenantId,
      actorId: command.actorId,
      deviceId: command.deviceId,
      companyIds: {command.companyId},
      branchIds: {'other-branch'},
      permissions: {'inspection.create'},
    );
    final otherBranchParentRaw = Map<String, dynamic>.from(parentRaw)
      ..['commandId'] = uuid(907)
      ..['branchId'] = 'other-branch'
      ..['aggregateId'] = 'inspection-other-branch';
    final otherBranchParent = CommandEnvelope.fromJson(otherBranchParentRaw);
    check(
      host.execute(otherBranchParent, otherBranchPrincipal).accepted,
      'Host stores the independent reference target in another branch',
    );

    final crossBranchPayload = Map<String, dynamic>.from(parentPayload)
      ..['assetTag'] = 'EQ-102'
      ..['relatedInspection'] = otherBranchParent.aggregateId;
    final crossBranchRaw = Map<String, dynamic>.from(raw)
      ..['commandId'] = uuid(908)
      ..['aggregateId'] = 'inspection-cross-branch-reference'
      ..['payload'] = crossBranchPayload;
    final crossBranchReference = CommandEnvelope.fromJson(crossBranchRaw);
    final beforeCrossBranchReference = effectCounts();
    check(
      host.execute(crossBranchReference, principal).reasonCode ==
              'INVALID_REFERENCE' &&
          effectsUnchanged(beforeCrossBranchReference),
      'Host refuses a cross-branch reference without business effects',
    );

    final otherCompanyPrincipal = Principal(
      tenantId: command.tenantId,
      actorId: command.actorId,
      deviceId: command.deviceId,
      companyIds: {'other-company'},
      branchIds: {command.branchId},
      permissions: {'inspection.create'},
    );
    final otherCompanyParentRaw = Map<String, dynamic>.from(parentRaw)
      ..['commandId'] = uuid(909)
      ..['companyId'] = 'other-company'
      ..['aggregateId'] = 'inspection-other-company';
    final otherCompanyParent = CommandEnvelope.fromJson(otherCompanyParentRaw);
    check(
      host.execute(otherCompanyParent, otherCompanyPrincipal).accepted,
      'Host stores the independent reference target in another company',
    );
    final crossCompanyPayload = Map<String, dynamic>.from(parentPayload)
      ..['assetTag'] = 'EQ-103'
      ..['relatedInspection'] = otherCompanyParent.aggregateId;
    final crossCompanyRaw = Map<String, dynamic>.from(raw)
      ..['commandId'] = uuid(910)
      ..['aggregateId'] = 'inspection-cross-company-reference'
      ..['payload'] = crossCompanyPayload;
    final beforeCrossCompanyReference = effectCounts();
    check(
      host
                  .execute(CommandEnvelope.fromJson(crossCompanyRaw), principal)
                  .reasonCode ==
              'INVALID_REFERENCE' &&
          effectsUnchanged(beforeCrossCompanyReference),
      'Host refuses a cross-company reference without business effects',
    );

    final otherTenantPrincipal = Principal(
      tenantId: 'other-tenant',
      actorId: command.actorId,
      deviceId: command.deviceId,
      companyIds: {command.companyId},
      branchIds: {command.branchId},
      permissions: {'inspection.create'},
    );
    final otherTenantParentRaw = Map<String, dynamic>.from(parentRaw)
      ..['commandId'] = uuid(911)
      ..['tenantId'] = 'other-tenant'
      ..['aggregateId'] = 'inspection-other-tenant';
    final otherTenantParent = CommandEnvelope.fromJson(otherTenantParentRaw);
    check(
      host.execute(otherTenantParent, otherTenantPrincipal).accepted,
      'Host stores the independent reference target in another tenant',
    );
    final crossTenantPayload = Map<String, dynamic>.from(parentPayload)
      ..['assetTag'] = 'EQ-104'
      ..['relatedInspection'] = otherTenantParent.aggregateId;
    final crossTenantRaw = Map<String, dynamic>.from(raw)
      ..['commandId'] = uuid(912)
      ..['aggregateId'] = 'inspection-cross-tenant-reference'
      ..['payload'] = crossTenantPayload;
    final beforeCrossTenantReference = effectCounts();
    check(
      host
                  .execute(CommandEnvelope.fromJson(crossTenantRaw), principal)
                  .reasonCode ==
              'INVALID_REFERENCE' &&
          effectsUnchanged(beforeCrossTenantReference),
      'Host refuses a cross-tenant reference without business effects',
    );
  });

  test('Generic extension record commands have a strict offline wire shape',
      () {
    final create = ExtensionRecordCommand.create(
      commandId: uuid(901),
      tenantId: 'tenant',
      companyId: 'company',
      branchId: 'branch',
      recordId: 'asset-1',
      actorId: 'actor',
      deviceId: 'device',
      moduleId: 'com.example.assets',
      moduleVersion: '0.1.0',
      docType: 'Asset',
      schemaVersion: 1,
      values: {'name': 'Keyboard'},
    );
    check(
      create.operation == 'create' &&
          create.envelope.type == ExtensionRecordCommand.createType &&
          create.envelope.expectedRevision == null &&
          create.moduleId == 'com.example.assets' &&
          create.values['name'] == 'Keyboard',
      'Generic create command did not preserve the extension record identity',
    );

    final update = ExtensionRecordCommand.update(
      commandId: uuid(902),
      tenantId: 'tenant',
      companyId: 'company',
      branchId: 'branch',
      recordId: 'asset-1',
      expectedRevision: 3,
      actorId: 'actor',
      deviceId: 'device',
      moduleId: 'com.example.assets',
      moduleVersion: '0.1.0',
      docType: 'Asset',
      schemaVersion: 1,
      values: {'name': 'Mouse'},
    );
    check(
      update.operation == 'update' && update.envelope.expectedRevision == 3,
      'Generic update command lost its optimistic revision',
    );
    final deletion = ExtensionRecordCommand.delete(
      commandId: uuid(904),
      tenantId: 'tenant',
      companyId: 'company',
      branchId: 'branch',
      recordId: 'asset-1',
      expectedRevision: 3,
      actorId: 'actor',
      deviceId: 'device',
      moduleId: 'com.example.assets',
      moduleVersion: '0.1.0',
      docType: 'Asset',
      schemaVersion: 1,
    );
    check(
      deletion.operation == 'delete' &&
          deletion.envelope.expectedRevision == 3 &&
          deletion.values.isEmpty,
      'Generic delete command carries only its record identity and revision',
    );
    checkThrows(
      () => ExtensionRecordCommand.update(
        commandId: uuid(903),
        tenantId: 'tenant',
        companyId: 'company',
        branchId: 'branch',
        recordId: 'asset-1',
        expectedRevision: 0,
        actorId: 'actor',
        deviceId: 'device',
        moduleId: 'com.example.assets',
        moduleVersion: '0.1.0',
        docType: 'Asset',
        schemaVersion: 1,
        values: {'name': 'Mouse'},
      ),
      'Generic updates accepted a missing or zero revision',
    );

    final injected = changed(create.envelope.original);
    (injected['payload'] as Map<String, dynamic>)['permission'] =
        'system.admin';
    checkThrows(
      () => ExtensionRecordCommand.fromEnvelope(
        CommandEnvelope.fromJson(injected),
      ),
      'Client supplied authority fields were accepted in a record command',
    );

    final unsupportedVersion = changed(create.envelope.original);
    unsupportedVersion['typeVersion'] = 2;
    checkThrows(
      () => ExtensionRecordCommand.fromEnvelope(
        CommandEnvelope.fromJson(unsupportedVersion),
      ),
      'An unsupported generic record command version was accepted',
    );
  });

  test('V1.2 fixture bootstraps an operational module', () {
    final p = fresh();
    check(p.modules.installedIds.single == 'com.ventio.maintenance',
        'Module missing');
    check(p.docTypes.get('MaintenanceRequest') != null, 'DocType missing');
  });
  test('Dynamic layouts retain order and keep required fields visible', () {
    final json = loadJsonFile('$root/examples/maintenance_doctype.json');
    json['ui'] = {
      'listColumns': ['status', 'customerName'],
      'formFields': [
        'status',
        'problemDescription',
        'deviceModel',
        'customerName',
      ],
      'detailFields': ['customerName', 'status'],
    };
    final definition = DocTypeDefinition.fromJson(json);
    check(
      definition.pageTitle == json['label'] &&
          definition.pageTitleKey == json['labelKey'] &&
          definition.pageIcon == 'list' &&
          definition.pageOrder == 0,
      'Legacy DocTypes must retain safe generated page defaults',
    );
    check(
      definition.listColumns.join(',') == 'status,customerName',
      'List column order was not retained',
    );
    check(
      definition.formFields.first == 'status' &&
          definition.formFields.last == 'customerName',
      'Form field order was not retained',
    );
    check(
      definition.detailFields.join(',') == 'customerName,status',
      'Detail field order was not retained',
    );

    final legacyUi = Map<String, dynamic>.from(json['ui'])
      ..remove('detailFields');
    final legacy = DocTypeDefinition.fromJson({...json, 'ui': legacyUi});
    check(
      legacy.detailFields.join(',') ==
          legacy.fields.map((field) => field.name).join(','),
      'Legacy metadata without detailFields must display every field',
    );

    json['ui']['detailFields'] = ['unknown'];
    checkThrows(
      () => DocTypeDefinition.fromJson(json),
      'An unknown detail field was accepted',
    );

    json['ui']['formFields'] = ['status', 'problemDescription', 'deviceModel'];
    json['ui']['detailFields'] = ['customerName', 'status'];
    checkThrows(
      () => DocTypeDefinition.fromJson(json),
      'A required field was hidden from the generated form',
    );
  });
  test('DocType and field identifiers are validated by Core metadata', () {
    final invalidDocType =
        loadJsonFile('$root/examples/maintenance_doctype.json')
          ..['name'] = 'Invalid DocType';
    checkThrows(
      () => DocTypeDefinition.fromJson(invalidDocType),
      'Core accepted an invalid DocType identifier',
    );

    final invalidField =
        loadJsonFile('$root/examples/maintenance_doctype.json');
    (invalidField['fields'] as List).first['name'] = 'InvalidField';
    checkThrows(
      () => DocTypeDefinition.fromJson(invalidField),
      'Core accepted an invalid field identifier',
    );
  });
  test('Document naming series metadata is bounded and protected', () {
    final valid = loadJsonFile('$root/examples/maintenance_doctype.json');
    (valid['fields'] as List).add({
      'name': 'documentNumber',
      'type': 'text',
      'required': false,
      'readOnly': true,
      'maxLength': 64,
      'label': 'Document Number',
      'labelKey': 'maintenance.request.document_number',
    });
    valid['ui']['formFields'].add('documentNumber');
    valid['ui']['listColumns'].add('documentNumber');
    valid['naming'] = {
      'seriesId': 'maintenance-request',
      'field': 'documentNumber',
      'prefix': 'MR-',
      'padding': 6,
    };
    final definition = DocTypeDefinition.fromJson(valid);
    check(
      definition.namingSeries?.toJson().toString() ==
          '{seriesId: maintenance-request, field: documentNumber, prefix: MR-, padding: 6}',
      'A valid naming series was not retained as declarative metadata',
    );
    check(
      definition.namingSeries!.formatNumber(1) == 'MR-000001' &&
          definition.namingSeries!.formatNumber(1000000) == 'MR-1000000',
      'Official number formatting did not pad without truncating',
    );
    checkThrows(
      () => definition.namingSeries!.formatNumber(0),
      'Zero or negative series values were accepted',
    );

    final invalidPrefix = loadJsonFile('$root/examples/maintenance_doctype.json')
      ..['naming'] = {
        'seriesId': 'maintenance-request',
        'field': 'documentNumber',
        'prefix': 'MR-{{sql}}',
        'padding': 6,
      };
    (invalidPrefix['fields'] as List).add((valid['fields'] as List).last);
    invalidPrefix['ui']['formFields'].add('documentNumber');
    checkThrows(
      () => DocTypeDefinition.fromJson(invalidPrefix),
      'A template or executable expression was accepted as a series prefix',
    );

    final writableField = loadJsonFile('$root/examples/maintenance_doctype.json')
      ..['naming'] = valid['naming'];
    (writableField['fields'] as List).add({
      ...(valid['fields'] as List).last as Map<String, dynamic>,
      'readOnly': false,
    });
    writableField['ui']['formFields'].add('documentNumber');
    checkThrows(
      () => DocTypeDefinition.fromJson(writableField),
      'A client-writable field was accepted as the official document number',
    );
  });
  test('DocTypes default operations and can restrict their declared surface',
      () {
    final json = loadJsonFile('$root/examples/maintenance_doctype.json');
    final legacy = DocTypeDefinition.fromJson(json);
    check(
      legacy.operations.join(',') == 'read,create,update',
      'Legacy operation defaults changed',
    );

    json['operations'] = ['read'];
    json['permissions'] = {'read': 'maintenance.read'};
    final readOnly = DocTypeDefinition.fromJson(json);
    check(
      readOnly.operations.single == 'read' && readOnly.permissions.length == 1,
      'Read-only operation declaration was not retained',
    );

    json['operations'] = ['read', 'delete'];
    json['permissions'] = {
      'read': 'maintenance.read',
      'delete': 'maintenance.delete',
    };
    final deletable = DocTypeDefinition.fromJson(json);
    check(
      deletable.operations.join(',') == 'read,delete',
      'A declared safe-delete operation was not retained',
    );

    json['operations'] = ['read'];
    json['permissions'] = {
      'read': 'maintenance.read',
      'create': 'maintenance.create',
    };
    checkThrows(
      () => DocTypeDefinition.fromJson(json),
      'Undeclared permission key was accepted',
    );
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
  test('Enum metadata preserves stable label keys and English fallbacks', () {
    final json = loadJsonFile('$root/examples/maintenance_doctype.json');
    final definition = DocTypeDefinition.fromJson(json);
    final status =
        definition.fields.singleWhere((field) => field.name == 'status');
    check(
      status.enumLabels['new'] == 'New' &&
          status.enumLabelKeys['new'] == 'maintenance.request.status.new',
      'Enum display label metadata was not preserved',
    );
    check(status.enumValues.contains('new'), 'Stable enum ID changed');
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
  test('Optional display catalogs preserve English fallbacks and placeholders',
      () {
    final catalog = EnglishCatalog()
      ..registerCatalog({'demo.message.greeting': 'Hello {name}'})
      ..registerFallback('extension.demo.item.label', 'Inventory item');
    catalog.registerTranslationCatalog('en-XA', {
      'demo.message.greeting': '[Hëllö {name}]',
      'extension.demo.item.label': '[Ínvëntöry ítëm]',
    });
    check(
      catalog.text('demo.message.greeting', locale: 'en-XA', params: {
            'name': 'Sam',
          }) ==
          '[Hëllö Sam]',
      'Pseudo-localized message or interpolation failed',
    );
    check(
      catalog.text('demo.message.greeting', params: {'name': 'Sam'}) ==
          'Hello Sam',
      'English was not retained as the default',
    );
    check(
      catalog.text('demo.message.greeting', locale: 'fr') == 'Hello {name}',
      'Missing locale did not fall back to English',
    );
    catalog.removeTranslationCatalog('en-XA');
    check(
      catalog.text('extension.demo.item.label', locale: 'en-XA') ==
          'Inventory item',
      'Removing the optional catalog did not restore English',
    );
  });
  test('Optional display catalogs reject unknown keys and changed placeholders',
      () {
    final catalog = EnglishCatalog()
      ..registerCatalog({'demo.message.greeting': 'Hello {name}'});
    checkThrows(
      () => catalog.registerTranslationCatalog('en-XA', {
        'other.module.label': 'Unexpected',
      }),
      'Unknown translation key was accepted',
    );
    checkThrows(
      () => catalog.registerTranslationCatalog('en-XA', {
        'demo.message.greeting': 'Hello {person}',
      }),
      'Changed interpolation placeholder was accepted',
    );
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
  test('Module and dependency IDs fail closed when invalid', () {
    final source = loadJsonFile('$root/examples/maintenance_manifest.json');
    final invalidModule = Map<String, dynamic>.from(source)
      ..['moduleId'] = 'Invalid Module ID';
    checkThrows(
      () => ModuleManifest.fromJson(invalidModule),
      'Invalid module identifier was accepted',
    );

    final invalidDependency = Map<String, dynamic>.from(source)
      ..['dependencies'] = ['com.example.Valid', 'bad dependency'];
    checkThrows(
      () => ModuleManifest.fromJson(invalidDependency),
      'Invalid dependency identifier was accepted',
    );

    final valid = ModuleManifest.fromJson(source);
    final manuallyConstructed = ModuleManifest(
      moduleId: 'Invalid Module ID',
      version: valid.version,
      minPlatformApi: valid.minPlatformApi,
      displayName: valid.displayName,
      displayNameKey: valid.displayNameKey,
      englishCatalog: valid.englishCatalog,
      dependencies: valid.dependencies,
      docTypes: valid.docTypes,
      commands: valid.commands,
      requiredCapabilities: valid.requiredCapabilities,
      offlineEnabled: valid.offlineEnabled,
      offlineCommands: valid.offlineCommands,
    );
    checkThrows(
      () => ModuleRegistry().install(
        manuallyConstructed,
        [
          DocTypeDefinition.fromJson(
            loadJsonFile('$root/examples/maintenance_doctype.json'),
          ),
        ],
      ),
      'Registry accepted an invalid manually constructed module ID',
    );
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
    check(
      ModuleRegistry().platformApiVersion == currentPlatformApiVersion &&
          currentPlatformApiVersion == '0.3.0',
      'The default platform API did not advance for field authorization',
    );
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
  test('Permission on another scope cannot authorize a Host command', () {
    final envelope = command();
    final principal = Principal(
      actorId: envelope.actorId,
      deviceId: envelope.deviceId,
      tenantId: envelope.tenantId,
      companyIds: {envelope.companyId, 'other-company'},
      branchIds: {envelope.branchId, 'other-branch'},
      permissions: {'maintenance.create', 'maintenance.read'},
      scopeGrants: [
        PrincipalScope(
          companyId: envelope.companyId,
          branchId: envelope.branchId,
          permissions: {'maintenance.read'},
        ),
        PrincipalScope(
          companyId: 'other-company',
          branchId: 'other-branch',
          permissions: {'maintenance.create', 'maintenance.read'},
        ),
      ],
    );
    final receipt = fresh().host.execute(envelope, principal);
    check(
      receipt.reasonCode == 'PERMISSION_DENIED',
      'Permission from a different exact scope authorized the command',
    );
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
  test('Host receipts parse and round-trip through the shared Core contract',
      () {
    final acceptedJson = loadJsonFile('$root/examples/accepted_receipt.json');
    final accepted = CommandReceipt.fromJson(acceptedJson);
    check(accepted.accepted, 'Accepted Host receipt changed state');
    check(accepted.serverTimestamp == acceptedJson['serverTimestamp'],
        'Host timestamp was replaced with a client timestamp');
    check(canonicalJson(accepted.toJson()) == canonicalJson(acceptedJson),
        'Accepted Host receipt did not round-trip');
    checkThrows(() => accepted.output!['serverRecordId'] = 'forged',
        'Parsed Host receipt output was mutable');

    final rejectedJson = loadJsonFile('$root/examples/rejected_receipt.json');
    final rejected = CommandReceipt.fromJson(rejectedJson);
    check(rejected.status == 'REJECTED', 'Rejected receipt status changed');
    check(rejected.messageParams?['field'] == 'Device Model',
        'Localized receipt parameters were lost');
    check(canonicalJson(rejected.toJson()) == canonicalJson(rejectedJson),
        'Rejected Host receipt did not round-trip');
  });
  test('Malformed Host receipt combinations fail closed', () {
    final invalid = loadJsonFile('$root/examples/accepted_receipt.json');
    invalid['retryable'] = true;
    checkThrows(() => CommandReceipt.fromJson(invalid),
        'Accepted receipt with retryable=true was accepted');
    final unknown = loadJsonFile('$root/examples/accepted_receipt.json');
    unknown['scope'] = 'client-controlled';
    checkThrows(() => CommandReceipt.fromJson(unknown),
        'Receipt with unsupported authority field was accepted');
  });
  print('RESULT: $passed passed, $failed failed');
  if (failed > 0) throw StateError('$failed tests failed');
}
