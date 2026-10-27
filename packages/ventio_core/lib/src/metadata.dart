import 'contracts.dart';

final RegExp _docTypeIdentifier = RegExp(r'^[A-Z][A-Za-z0-9_]*$');
final RegExp _docFieldIdentifier = RegExp(r'^[a-z][A-Za-z0-9_]*$');
const maxRowsPerTableField = 500;

class FieldDefinition {
  final String name;
  final String type;
  final bool required;
  final String label;
  final String labelKey;
  final String? readPermission;
  final String? writePermission;
  final int? minLength;
  final int? maxLength;
  final num? minValue;
  final num? maxValue;
  final int? precision;
  final Object? defaultValue;
  final bool readOnly;
  final String? description;
  final String? descriptionKey;
  final List<String> enumValues;
  final Map<String, String> enumLabels;
  final Map<String, String> enumLabelKeys;
  final String? referenceTo;

  const FieldDefinition(
      {required this.name,
      required this.type,
      required this.required,
      required this.label,
      required this.labelKey,
      this.readPermission,
      this.writePermission,
      this.minLength,
      required this.maxLength,
      this.minValue,
      this.maxValue,
      this.precision,
      this.defaultValue,
      this.readOnly = false,
      this.description,
      this.descriptionKey,
      required this.enumValues,
      this.enumLabels = const {},
      this.enumLabelKeys = const {},
      required this.referenceTo});

  factory FieldDefinition.fromJson(Map<String, dynamic> json) {
    final name = requireString(json, 'name');
    if (!_docFieldIdentifier.hasMatch(name) || name.length > 80) {
      throw const ContractError('INVALID_FIELD', 'Invalid field name.');
    }
    final type = requireString(json, 'type');
    if (![
      'text',
      'long_text',
      'table',
      'integer',
      'decimal',
      'boolean',
      'date',
      'datetime',
      'reference',
      'enum'
    ].contains(type)) {
      throw ContractError('INVALID_FIELD', 'Unsupported field type: $type');
    }
    final minLength = json['minLength'];
    if (minLength != null &&
        (minLength is! int || minLength < 1 || minLength > 65535)) {
      throw const ContractError('INVALID_FIELD', 'Invalid minLength');
    }
    final maxLength = json['maxLength'];
    if (maxLength != null &&
        (maxLength is! int || maxLength < 1 || maxLength > 65535)) {
      throw const ContractError('INVALID_FIELD', 'Invalid maxLength');
    }
    if ((minLength != null || maxLength != null) &&
        type != 'text' &&
        type != 'long_text') {
      throw const ContractError(
        'INVALID_FIELD',
        'Text length limits require a text or long text field',
      );
    }
    if (minLength != null && maxLength != null && minLength > maxLength) {
      throw const ContractError(
        'INVALID_FIELD',
        'minLength must not exceed maxLength',
      );
    }
    final minValue = json['minValue'];
    final maxValue = json['maxValue'];
    for (final entry in {'minValue': minValue, 'maxValue': maxValue}.entries) {
      final bound = entry.value;
      if (bound != null && (bound is! num || !bound.isFinite)) {
        throw ContractError('INVALID_FIELD', 'Invalid ${entry.key}');
      }
      if (bound != null && type != 'integer' && type != 'decimal') {
        throw ContractError(
          'INVALID_FIELD',
          'Numeric bounds require an integer or decimal field',
        );
      }
      if (bound != null && type == 'integer' && bound is! int) {
        throw ContractError(
          'INVALID_FIELD',
          '${entry.key} must be a whole number for integer fields',
        );
      }
    }
    if (minValue != null && maxValue != null && minValue > maxValue) {
      throw const ContractError(
        'INVALID_FIELD',
        'minValue must not exceed maxValue',
      );
    }
    final precision = json['precision'];
    if (precision != null &&
        (precision is! int ||
            precision < 0 ||
            precision > 9 ||
            type != 'decimal')) {
      throw const ContractError(
        'INVALID_FIELD',
        'Precision must be between zero and nine and only applies to decimal fields',
      );
    }
    final rawDefault = json['default'];
    if (json.containsKey('default') &&
        (rawDefault == null ||
            rawDefault is Map ||
            rawDefault is List ||
            (rawDefault is num && !rawDefault.isFinite))) {
      throw const ContractError('INVALID_FIELD', 'Invalid field default');
    }
    if (rawDefault != null && (type == 'table' || type == 'reference')) {
      throw const ContractError(
        'INVALID_FIELD',
        'Defaults are not supported for table or reference fields',
      );
    }
    final readOnly = json['readOnly'] ?? false;
    if (readOnly is! bool) {
      throw const ContractError('INVALID_FIELD', 'Invalid readOnly value');
    }
    final description = json['description'];
    final descriptionKey = json['descriptionKey'];
    if (description != null &&
        (description is! String ||
            description.trim().isEmpty ||
            description.length > 500)) {
      throw const ContractError('INVALID_FIELD', 'Invalid field description');
    }
    if ((description == null) != (descriptionKey == null) ||
        (descriptionKey != null &&
            (descriptionKey is! String ||
                !_messageKey.hasMatch(descriptionKey)))) {
      throw const ContractError(
        'INVALID_FIELD',
        'Field description and namespaced descriptionKey must be provided together',
      );
    }
    final options = json['enumValues'] == null
        ? <String>[]
        : strings(requireList(json, 'enumValues'), 'enumValues');
    final enumLabels = <String, String>{};
    final enumLabelKeys = <String, String>{};
    final referenceTo = optionalString(json, 'referenceTo');
    if (type == 'enum') {
      if (options.isEmpty)
        throw const ContractError('INVALID_FIELD', 'Enum needs options');
      final labels = requireMap(json['enumLabels'], 'enumLabels');
      if (labels.keys.toSet().difference(options.toSet()).isNotEmpty ||
          options.toSet().difference(labels.keys.toSet()).isNotEmpty) {
        throw const ContractError(
            'INVALID_FIELD', 'Enum labels must match options');
      }
      for (final label in labels.values) {
        final item = requireMap(label, 'enumLabels[]');
        requireString(item, 'label');
        requireString(item, 'labelKey');
      }
      for (final entry in labels.entries) {
        final item = requireMap(entry.value, 'enumLabels[]');
        enumLabels[entry.key] = requireString(item, 'label');
        final key = requireString(item, 'labelKey');
        if (!_messageKey.hasMatch(key)) {
          throw const ContractError(
            'INVALID_FIELD',
            'Enum label keys must be namespaced message keys',
          );
        }
        enumLabelKeys[entry.key] = key;
      }
    }
    if (type == 'reference' && (referenceTo == null || referenceTo.isEmpty)) {
      throw const ContractError(
          'INVALID_FIELD', 'Reference requires referenceTo');
    }
    final labelKey = requireString(json, 'labelKey');
    if (!_messageKey.hasMatch(labelKey)) {
      throw const ContractError(
          'INVALID_FIELD', 'Field labelKey must be a namespaced message key');
    }
    final readPermission = optionalString(json, 'readPermission');
    final writePermission = optionalString(json, 'writePermission');
    for (final entry in {
      'readPermission': readPermission,
      'writePermission': writePermission,
    }.entries) {
      final permission = entry.value;
      if (permission != null && !_messageKey.hasMatch(permission)) {
        throw ContractError(
          'INVALID_FIELD',
          '${entry.key} must be a namespaced permission key',
        );
      }
    }
    final field = FieldDefinition(
        name: name,
        type: type,
        required: requireBool(json, 'required'),
        label: requireString(json, 'label'),
        labelKey: labelKey,
        readPermission: readPermission,
        writePermission: writePermission,
        minLength: minLength as int?,
        maxLength: maxLength as int?,
        minValue: minValue as num?,
        maxValue: maxValue as num?,
        precision: precision as int?,
        defaultValue: rawDefault,
        readOnly: readOnly,
        description: description as String?,
        descriptionKey: descriptionKey as String?,
        enumValues: List.unmodifiable(options),
        enumLabels: Map.unmodifiable(enumLabels),
        enumLabelKeys: Map.unmodifiable(enumLabelKeys),
        referenceTo: referenceTo);
    if (rawDefault != null && field.validate(rawDefault) != null) {
      throw const ContractError(
        'INVALID_FIELD',
        'The field default does not satisfy its declared type and constraints',
      );
    }
    return field;
  }

  String? validate(Object? value) {
    if (value == null) return required ? 'REQUIRED' : null;
    switch (type) {
      case 'text':
      case 'long_text':
      case 'reference':
        if (value is! String || (required && value.trim().isEmpty))
          return 'INVALID_TEXT';
        if ((type == 'text' || type == 'long_text') &&
            value.isNotEmpty &&
            minLength != null &&
            value.runes.length < minLength!) {
          return 'TOO_SHORT';
        }
        if (maxLength != null && value.runes.length > maxLength!)
          return 'TOO_LONG';
        return null;
      case 'table':
        if (value is! List ||
            value.length > maxRowsPerTableField ||
            (required && value.isEmpty)) {
          return 'INVALID_TABLE';
        }
        for (final row in value) {
          if (row is! Map ||
              row.isEmpty ||
              row.keys.any((key) => key is! String) ||
              row.values.any(
                (cell) =>
                    cell is Map ||
                    cell is List ||
                    (cell is num && !cell.isFinite) ||
                    (cell != null &&
                        cell is! String &&
                        cell is! bool &&
                        cell is! num),
              )) {
            return 'INVALID_TABLE';
          }
        }
        return null;
      case 'enum':
        return value is String && enumValues.contains(value)
            ? null
            : 'INVALID_ENUM';
      case 'integer':
        if (value is! int) return 'INVALID_INTEGER';
        return _validateNumberBounds(value);
      case 'decimal':
        // A declared scale bounds ordinary form values. Governed financial
        // postings still require an exact decimal representation, not doubles.
        if (value is! num || !value.isFinite) return 'INVALID_DECIMAL';
        if (precision != null &&
            !_hasAtMostFractionalDigits(value, precision!)) {
          return 'INVALID_PRECISION';
        }
        return _validateNumberBounds(value);
      case 'boolean':
        return value is bool ? null : 'INVALID_BOOLEAN';
      case 'date':
        if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value))
          return 'INVALID_DATE';
        final date = DateTime.tryParse(value);
        return date != null && date.toIso8601String().startsWith(value)
            ? null
            : 'INVALID_DATE';
      case 'datetime':
        if (value is! String || !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(value))
          return 'INVALID_DATETIME';
        return DateTime.tryParse(value) != null ? null : 'INVALID_DATETIME';
    }
    return 'UNSUPPORTED_FIELD_TYPE';
  }

  String? _validateNumberBounds(num value) {
    if (minValue != null && value < minValue!) return 'BELOW_MINIMUM';
    if (maxValue != null && value > maxValue!) return 'ABOVE_MAXIMUM';
    return null;
  }

  bool _hasAtMostFractionalDigits(num value, int allowed) {
    final parts = value.abs().toString().toLowerCase().split('e');
    final mantissa = parts.first;
    final exponent = parts.length == 2 ? int.tryParse(parts.last) ?? 0 : 0;
    final fraction = mantissa.split('.').skip(1).firstOrNull ?? '';
    final significantFraction = fraction.replaceFirst(RegExp(r'0+$'), '');
    final decimalPlaces = significantFraction.length - exponent;
    return decimalPlaces <= allowed;
  }
}

final RegExp _messageKey = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2,}$');

class DocTypeDefinition {
  final String name;
  final String moduleId;
  final int schemaVersion;
  final String kind;
  final String label;
  final String labelKey;
  final List<String> operations;
  final Map<String, String> permissions;
  final List<FieldDefinition> fields;
  final List<String> listColumns;
  final List<String> formFields;
  final List<String> detailFields;
  final String pageTitle;
  final String pageTitleKey;
  final String pageIcon;
  final int pageOrder;
  final List<DocTypeMigration> migrations;

  const DocTypeDefinition(
      {required this.name,
      required this.moduleId,
      required this.schemaVersion,
      required this.kind,
      required this.label,
      required this.labelKey,
      required this.operations,
      required this.permissions,
      required this.fields,
      required this.listColumns,
      required this.formFields,
      required this.detailFields,
      String? pageTitle,
      String? pageTitleKey,
      this.pageIcon = 'list',
      this.pageOrder = 0,
      this.migrations = const []})
      : pageTitle = pageTitle ?? label,
        pageTitleKey = pageTitleKey ?? labelKey;

  factory DocTypeDefinition.fromJson(Map<String, dynamic> json) {
    final name = requireString(json, 'name');
    final moduleId = requireString(json, 'moduleId');
    if (!_docTypeIdentifier.hasMatch(name) || name.length > 80) {
      throw const ContractError('INVALID_DOCTYPE', 'Invalid DocType name.');
    }
    if (!isValidModuleId(moduleId)) {
      throw const ContractError('INVALID_MODULE_ID', 'Invalid module ID.');
    }
    final rawFields = requireList(json, 'fields');
    if (rawFields.length > 100) {
      throw const ContractError(
        'TOO_MANY_FIELDS',
        'A DocType may contain at most 100 fields.',
      );
    }
    final fields = rawFields
        .map((field) => FieldDefinition.fromJson(requireMap(field, 'fields[]')))
        .toList();
    final rawMigrations = json['migrations'];
    final migrations = rawMigrations == null
        ? const <DocTypeMigration>[]
        : requireList(json, 'migrations')
            .map((migration) => DocTypeMigration.fromJson(
                  requireMap(migration, 'migrations[]'),
                ))
            .toList(growable: false);
    if (migrations.length > 128 ||
        migrations.map((migration) => migration.fromVersion).toSet().length !=
            migrations.length ||
        migrations.asMap().entries.any((entry) =>
            entry.key > 0 &&
            migrations[entry.key - 1].fromVersion >= entry.value.fromVersion)) {
      throw const ContractError(
        'INVALID_MIGRATION',
        'Migrations must be unique, ordered, and bounded.',
      );
    }
    if (fields.isEmpty ||
        fields.map((field) => field.name).toSet().length != fields.length) {
      throw const ContractError(
          'INVALID_DOCTYPE', 'Fields must be unique and nonempty');
    }
    final operationsRaw = json['operations'];
    final operations = operationsRaw == null
        ? const ['read', 'create', 'update']
        : strings(requireList(json, 'operations'), 'operations');
    const supportedOperations = {'read', 'create', 'update', 'delete'};
    if (operations.toSet().length != operations.length ||
        operations
            .any((operation) => !supportedOperations.contains(operation))) {
      throw const ContractError(
        'INVALID_DOCTYPE',
        'operations must contain unique supported record operations',
      );
    }
    final permissionsRaw = requireMap(json['permissions'], 'permissions');
    if (permissionsRaw.keys.toSet().difference(operations.toSet()).isNotEmpty ||
        operations.toSet().difference(permissionsRaw.keys.toSet()).isNotEmpty) {
      throw const ContractError(
        'INVALID_DOCTYPE',
        'Permission keys must exactly match the declared operations',
      );
    }
    final permissions = <String, String>{
      for (final operation in operations)
        operation: requireString(permissionsRaw, operation),
    };
    final kind = requireString(json, 'kind');
    if (!['operational', 'sensitive'].contains(kind)) {
      throw const ContractError('INVALID_DOCTYPE', 'Unknown DocType kind');
    }
    final labelKey = requireString(json, 'labelKey');
    if (!_messageKey.hasMatch(labelKey)) {
      throw const ContractError('INVALID_DOCTYPE', 'Invalid labelKey');
    }
    final fieldNames = fields.map((field) => field.name).toSet();
    final uiRaw = json['ui'];
    final ui = uiRaw == null ? null : requireMap(uiRaw, 'ui');
    final hasPageTitle = ui?.containsKey('pageTitle') ?? false;
    final hasPageTitleKey = ui?.containsKey('pageTitleKey') ?? false;
    if (hasPageTitle != hasPageTitleKey) {
      throw const ContractError(
        'INVALID_DOCTYPE',
        'ui.pageTitle and ui.pageTitleKey must be declared together.',
      );
    }
    final listColumns = ui == null
        ? fields.take(4).map((field) => field.name).toList()
        : strings(requireList(ui, 'listColumns'), 'ui.listColumns');
    final formFields = ui == null
        ? fields.map((field) => field.name).toList()
        : strings(requireList(ui, 'formFields'), 'ui.formFields');
    final detailFields = ui == null || ui['detailFields'] == null
        ? fields.map((field) => field.name).toList()
        : strings(requireList(ui, 'detailFields'), 'ui.detailFields');
    final pageTitle = ui == null || ui['pageTitle'] == null
        ? requireString(json, 'label')
        : requireString(ui, 'pageTitle');
    final pageTitleKey = ui == null || ui['pageTitleKey'] == null
        ? labelKey
        : requireString(ui, 'pageTitleKey');
    final pageIcon = ui == null || ui['pageIcon'] == null
        ? 'list'
        : requireString(ui, 'pageIcon');
    final pageOrder = ui == null || ui['pageOrder'] == null
        ? 0
        : requireInt(ui, 'pageOrder', min: 0);
    const supportedPageIcons = {
      'list',
      'folder',
      'article',
      'location',
      'business',
      'tag',
      'event',
      'checklist',
      'grid',
    };
    if (pageTitle.trim().isEmpty || pageTitle.length > 120) {
      throw const ContractError(
        'INVALID_DOCTYPE',
        'ui.pageTitle must contain between 1 and 120 characters.',
      );
    }
    if (pageOrder > 10000) {
      throw const ContractError(
        'INVALID_DOCTYPE',
        'ui.pageOrder must be between 0 and 10000.',
      );
    }
    if (!_messageKey.hasMatch(pageTitleKey)) {
      throw const ContractError('INVALID_DOCTYPE', 'Invalid pageTitleKey');
    }
    if (!supportedPageIcons.contains(pageIcon)) {
      throw const ContractError(
          'INVALID_DOCTYPE', 'Unknown generated page icon');
    }
    for (final (key, names) in [
      ('listColumns', listColumns),
      ('formFields', formFields),
      ('detailFields', detailFields),
    ]) {
      if (names.isEmpty || names.any((name) => !fieldNames.contains(name))) {
        throw ContractError(
          'INVALID_DOCTYPE',
          'ui.$key must contain known fields',
        );
      }
    }
    final requiredFields = fields
        .where((field) => field.required)
        .map((field) => field.name)
        .toSet();
    if (!formFields.toSet().containsAll(requiredFields)) {
      throw const ContractError(
        'INVALID_DOCTYPE',
        'Required fields must appear in ui.formFields',
      );
    }
    return DocTypeDefinition(
        name: name,
        moduleId: moduleId,
        schemaVersion: requireInt(json, 'schemaVersion', min: 1),
        kind: kind,
        label: requireString(json, 'label'),
        labelKey: labelKey,
        operations: List.unmodifiable(operations),
        permissions: Map.unmodifiable(permissions),
        fields: List.unmodifiable(fields),
        listColumns: List.unmodifiable(listColumns),
        formFields: List.unmodifiable(formFields),
        detailFields: List.unmodifiable(detailFields),
        pageTitle: pageTitle,
        pageTitleKey: pageTitleKey,
        pageIcon: pageIcon,
        pageOrder: pageOrder,
        migrations: List.unmodifiable(migrations));
  }

  List<String> validatePayload(
    Map<String, dynamic> payload, {
    bool partial = false,
  }) {
    final issues = <String>[];
    final defined = {for (final field in fields) field.name: field};
    for (final key in payload.keys) {
      if (!defined.containsKey(key)) issues.add('$key:UNKNOWN_FIELD');
    }
    for (final field in fields) {
      if (partial && !payload.containsKey(field.name)) continue;
      final value = payload.containsKey(field.name)
          ? payload[field.name]
          : field.defaultValue;
      final issue = field.validate(value);
      if (issue != null) issues.add('${field.name}:$issue');
    }
    return issues;
  }

  Map<String, dynamic> applyDefaults(Map<String, dynamic> payload) {
    final values = Map<String, dynamic>.of(payload);
    for (final field in fields) {
      if (!values.containsKey(field.name) && field.defaultValue != null) {
        values[field.name] = field.defaultValue;
      }
    }
    return values;
  }
}

/// A non-executable, bounded schema migration supported by both SQLite and
/// PostgreSQL. Migrations can only rename a field or populate a constant
/// scalar default; they cannot run code, SQL, or delete data.
class DocTypeMigration {
  const DocTypeMigration({
    required this.fromVersion,
    required this.toVersion,
    required this.steps,
  });

  final int fromVersion;
  final int toVersion;
  final List<DocTypeMigrationStep> steps;

  factory DocTypeMigration.fromJson(Map<String, dynamic> json) {
    if (json.keys.toSet().difference(
      const {'fromVersion', 'toVersion', 'steps'},
    ).isNotEmpty) {
      throw const ContractError('INVALID_MIGRATION', 'Unknown migration key.');
    }
    final fromVersion = requireInt(json, 'fromVersion', min: 1);
    final toVersion = requireInt(json, 'toVersion', min: 2);
    if (toVersion != fromVersion + 1) {
      throw const ContractError(
        'INVALID_MIGRATION',
        'A migration must advance exactly one schema version.',
      );
    }
    final rawSteps = requireList(json, 'steps');
    if (rawSteps.length > 32) {
      throw const ContractError(
        'INVALID_MIGRATION',
        'A schema migration may contain at most 32 operations.',
      );
    }
    return DocTypeMigration(
      fromVersion: fromVersion,
      toVersion: toVersion,
      steps: List.unmodifiable(rawSteps.map(
          (raw) => DocTypeMigrationStep.fromJson(requireMap(raw, 'steps[]')))),
    );
  }

  Map<String, dynamic> toJson() => {
        'fromVersion': fromVersion,
        'toVersion': toVersion,
        'steps': steps.map((step) => step.toJson()).toList(growable: false),
      };
}

class DocTypeMigrationStep {
  const DocTypeMigrationStep.rename({required this.from, required this.to})
      : operation = 'renameField',
        field = null,
        value = null;

  const DocTypeMigrationStep.setDefault(
      {required this.field, required this.value})
      : operation = 'setDefault',
        from = null,
        to = null;

  final String operation;
  final String? from;
  final String? to;
  final String? field;
  final Object? value;

  factory DocTypeMigrationStep.fromJson(Map<String, dynamic> json) {
    final operation = requireString(json, 'op');
    if (operation == 'renameField') {
      if (json.keys.toSet().difference(const {'op', 'from', 'to'}).isNotEmpty) {
        throw const ContractError('INVALID_MIGRATION', 'Unknown rename key.');
      }
      final from = requireString(json, 'from');
      final to = requireString(json, 'to');
      if (!_fieldIdentifier.hasMatch(from) ||
          !_fieldIdentifier.hasMatch(to) ||
          from == to) {
        throw const ContractError('INVALID_MIGRATION', 'Invalid field rename.');
      }
      return DocTypeMigrationStep.rename(from: from, to: to);
    }
    if (operation == 'setDefault') {
      if (json.keys
          .toSet()
          .difference(const {'op', 'field', 'value'}).isNotEmpty) {
        throw const ContractError('INVALID_MIGRATION', 'Unknown default key.');
      }
      final field = requireString(json, 'field');
      final value = json['value'];
      if (!_fieldIdentifier.hasMatch(field) ||
          value == null ||
          value is List ||
          value is Map ||
          (value is num && !value.isFinite) ||
          !(value is String || value is num || value is bool)) {
        throw const ContractError(
          'INVALID_MIGRATION',
          'A field default must be a non-null JSON scalar.',
        );
      }
      return DocTypeMigrationStep.setDefault(field: field, value: value);
    }
    throw const ContractError(
        'INVALID_MIGRATION', 'Unsupported migration operation.');
  }

  Map<String, dynamic> toJson() => switch (operation) {
        'renameField' => {'op': operation, 'from': from, 'to': to},
        'setDefault' => {'op': operation, 'field': field, 'value': value},
        _ => throw StateError('Unsupported migration operation: $operation'),
      };
}

final RegExp _fieldIdentifier = RegExp(r'^[a-z][a-z0-9_]{0,79}$');

/// Checks that an upgrade preserves all existing values and that any newly
/// required field can be populated by the trusted migration DSL.
void validateDocTypeUpgrade(
  DocTypeDefinition previous,
  DocTypeDefinition next,
) {
  final path = <DocTypeMigration>[];
  final migrationsByFrom = {
    for (final migration in next.migrations) migration.fromVersion: migration,
  };
  var cursor = previous.schemaVersion;
  while (cursor < next.schemaVersion && migrationsByFrom.containsKey(cursor)) {
    final migration = migrationsByFrom[cursor]!;
    path.add(migration);
    cursor = migration.toVersion;
  }
  if (cursor != previous.schemaVersion && cursor != next.schemaVersion) {
    throw const ContractError(
      'INVALID_MIGRATION_CHAIN',
      'Schema migrations must form a consecutive path from the installed version.',
    );
  }
  if (path.isNotEmpty && cursor != next.schemaVersion) {
    throw const ContractError(
      'INVALID_MIGRATION_CHAIN',
      'Schema migrations do not reach the new schema version.',
    );
  }

  final names = previous.fields.map((field) => field.name).toSet();
  final renamed = <String, String>{
    for (final field in previous.fields) field.name: field.name
  };
  final defaults = <String, Object>{};
  for (final migration in path) {
    for (final step in migration.steps) {
      if (step.operation == 'renameField') {
        final source = step.from!;
        final destination = step.to!;
        if (!names.contains(source) || names.contains(destination)) {
          throw ContractError(
            'INVALID_MIGRATION',
            'Cannot safely rename $source to $destination in schema version ${migration.fromVersion}.',
          );
        }
        names.remove(source);
        names.add(destination);
        for (final original in renamed.keys.toList()) {
          if (renamed[original] == source) renamed[original] = destination;
        }
      } else {
        final field = step.field!;
        if (!next.fields.any((definition) => definition.name == field)) {
          throw ContractError(
            'INVALID_MIGRATION',
            'Default target $field is absent from the new schema.',
          );
        }
        defaults[field] = step.value!;
      }
    }
  }

  final nextByName = {for (final field in next.fields) field.name: field};
  final oldByName = {for (final field in previous.fields) field.name: field};
  for (final old in previous.fields) {
    final targetName = renamed[old.name]!;
    final updated = nextByName[targetName];
    if (updated == null) {
      throw ContractError(
        'DESTRUCTIVE_SCHEMA_CHANGE',
        'Removing ${old.name} requires a supported rename migration.',
      );
    }
    if (updated.type != old.type || updated.referenceTo != old.referenceTo) {
      throw ContractError(
        'DESTRUCTIVE_SCHEMA_CHANGE',
        'Changing the type or relation of ${old.name} requires a data conversion that is not supported.',
      );
    }
    if (!_constraintsWidened(old, updated)) {
      throw ContractError(
        'DESTRUCTIVE_SCHEMA_CHANGE',
        'Tightening constraints for ${old.name} could invalidate saved values.',
      );
    }
    if (!old.required &&
        updated.required &&
        !defaults.containsKey(targetName)) {
      throw ContractError(
        'DESTRUCTIVE_SCHEMA_CHANGE',
        'Making ${targetName} required needs a validated setDefault migration.',
      );
    }
  }
  for (final field in next.fields) {
    if (!names.contains(field.name) &&
        field.required &&
        !defaults.containsKey(field.name)) {
      throw ContractError(
        'DESTRUCTIVE_SCHEMA_CHANGE',
        'New required field ${field.name} needs a validated setDefault migration.',
      );
    }
    final defaultValue = defaults[field.name];
    if (defaultValue != null && field.validate(defaultValue) != null) {
      throw ContractError(
        'INVALID_MIGRATION',
        'Default value does not satisfy field ${field.name}.',
      );
    }
  }
  // Prevent accidental schema-field replacement after a rename.
  if (nextByName.keys.toSet().difference(names).any(oldByName.containsKey)) {
    throw const ContractError(
        'INVALID_MIGRATION', 'Invalid field rename path.');
  }
}

Map<String, dynamic> applyDocTypeMigrations(
  Map<String, dynamic> values,
  List<DocTypeMigration> migrations, {
  required int fromVersion,
  required int toVersion,
}) {
  if (fromVersion > toVersion) {
    throw const ContractError(
      'SCHEMA_VERSION_DOWNGRADE',
      'Saved records cannot use a schema newer than the package definition.',
    );
  }
  final current = Map<String, dynamic>.from(values);
  final path = migrations
      .where((migration) =>
          migration.fromVersion >= fromVersion &&
          migration.toVersion <= toVersion)
      .toList()
    ..sort((left, right) => left.fromVersion.compareTo(right.fromVersion));
  var cursor = fromVersion;
  for (final migration in path) {
    if (migration.fromVersion != cursor) {
      throw const ContractError(
          'INVALID_MIGRATION_CHAIN', 'Migration path has a gap.');
    }
    for (final step in migration.steps) {
      if (step.operation == 'renameField') {
        if (current.containsKey(step.to) && current.containsKey(step.from)) {
          throw ContractError(
            'MIGRATION_CONFLICT',
            'Record contains both ${step.from} and ${step.to}.',
          );
        }
        if (current.containsKey(step.from)) {
          current[step.to!] = current.remove(step.from);
        }
      } else if (!current.containsKey(step.field) ||
          current[step.field] == null) {
        current[step.field!] = step.value;
      }
    }
    cursor = migration.toVersion;
  }
  if (path.isNotEmpty && cursor != toVersion) {
    throw const ContractError(
        'INVALID_MIGRATION_CHAIN', 'Migration path is incomplete.');
  }
  return current;
}

bool _constraintsWidened(FieldDefinition old, FieldDefinition updated) {
  return (updated.minValue == null ||
          (old.minValue != null && updated.minValue! <= old.minValue!)) &&
      (updated.maxValue == null ||
          (old.maxValue != null && updated.maxValue! >= old.maxValue!)) &&
      (updated.precision == null ||
          (old.precision != null && updated.precision! >= old.precision!)) &&
      (updated.minLength == null ||
          (old.minLength != null && updated.minLength! <= old.minLength!)) &&
      (updated.maxLength == null ||
          (old.maxLength != null && updated.maxLength! >= old.maxLength!)) &&
      updated.enumValues.toSet().containsAll(old.enumValues);
}

class DocTypeRegistry {
  final Map<String, DocTypeDefinition> _types = {};

  void validateRegistrations(List<DocTypeDefinition> definitions) {
    final seen = <String>{};
    for (final docType in definitions) {
      if (!seen.add(docType.name) || _types.containsKey(docType.name)) {
        throw ContractError('DUPLICATE_DOCTYPE', docType.name);
      }
    }
  }

  void register(DocTypeDefinition docType) {
    validateRegistrations([docType]);
    _types[docType.name] = docType;
  }

  void registerAll(List<DocTypeDefinition> definitions) {
    validateRegistrations(definitions);
    for (final docType in definitions) {
      _types[docType.name] = docType;
    }
  }

  DocTypeDefinition? get(String name) => _types[name];
  List<DocTypeDefinition> get all => List.unmodifiable(_types.values);
}
