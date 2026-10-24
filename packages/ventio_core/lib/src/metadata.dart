import 'contracts.dart';

class FieldDefinition {
  final String name;
  final String type;
  final bool required;
  final String label;
  final String labelKey;
  final int? maxLength;
  final num? minValue;
  final num? maxValue;
  final List<String> enumValues;
  final String? referenceTo;

  const FieldDefinition(
      {required this.name,
      required this.type,
      required this.required,
      required this.label,
      required this.labelKey,
      required this.maxLength,
      this.minValue,
      this.maxValue,
      required this.enumValues,
      required this.referenceTo});

  factory FieldDefinition.fromJson(Map<String, dynamic> json) {
    final type = requireString(json, 'type');
    if (![
      'text',
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
    final maxLength = json['maxLength'];
    if (maxLength != null &&
        (maxLength is! int || maxLength < 1 || maxLength > 65535)) {
      throw const ContractError('INVALID_FIELD', 'Invalid maxLength');
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
    final options = json['enumValues'] == null
        ? <String>[]
        : strings(requireList(json, 'enumValues'), 'enumValues');
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
    return FieldDefinition(
        name: requireString(json, 'name'),
        type: type,
        required: requireBool(json, 'required'),
        label: requireString(json, 'label'),
        labelKey: labelKey,
        maxLength: maxLength as int?,
        minValue: minValue as num?,
        maxValue: maxValue as num?,
        enumValues: List.unmodifiable(options),
        referenceTo: referenceTo);
  }

  String? validate(Object? value) {
    if (value == null) return required ? 'REQUIRED' : null;
    switch (type) {
      case 'text':
      case 'reference':
        if (value is! String || (required && value.trim().isEmpty))
          return 'INVALID_TEXT';
        if (maxLength != null && value.runes.length > maxLength!)
          return 'TOO_LONG';
        return null;
      case 'enum':
        return value is String && enumValues.contains(value)
            ? null
            : 'INVALID_ENUM';
      case 'integer':
        if (value is! int) return 'INVALID_INTEGER';
        return _validateNumberBounds(value);
      case 'decimal':
        // Monetary values need a decimal-precision contract before this type can
        // be used for financial postings. Never use binary doubles for ledgers.
        if (value is! num || !value.isFinite) return 'INVALID_DECIMAL';
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
      required this.formFields});

  factory DocTypeDefinition.fromJson(Map<String, dynamic> json) {
    final fields = requireList(json, 'fields')
        .map((field) => FieldDefinition.fromJson(requireMap(field, 'fields[]')))
        .toList();
    if (fields.isEmpty ||
        fields.map((field) => field.name).toSet().length != fields.length) {
      throw const ContractError(
          'INVALID_DOCTYPE', 'Fields must be unique and nonempty');
    }
    final operationsRaw = json['operations'];
    final operations = operationsRaw == null
        ? const ['read', 'create', 'update']
        : strings(requireList(json, 'operations'), 'operations');
    const supportedOperations = {'read', 'create', 'update'};
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
    final listColumns = ui == null
        ? fields.take(4).map((field) => field.name).toList()
        : strings(requireList(ui, 'listColumns'), 'ui.listColumns');
    final formFields = ui == null
        ? fields.map((field) => field.name).toList()
        : strings(requireList(ui, 'formFields'), 'ui.formFields');
    for (final (key, names) in [
      ('listColumns', listColumns),
      ('formFields', formFields),
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
        name: requireString(json, 'name'),
        moduleId: requireString(json, 'moduleId'),
        schemaVersion: requireInt(json, 'schemaVersion', min: 1),
        kind: kind,
        label: requireString(json, 'label'),
        labelKey: labelKey,
        operations: List.unmodifiable(operations),
        permissions: Map.unmodifiable(permissions),
        fields: List.unmodifiable(fields),
        listColumns: List.unmodifiable(listColumns),
        formFields: List.unmodifiable(formFields));
  }

  List<String> validatePayload(Map<String, dynamic> payload) {
    final issues = <String>[];
    final defined = {for (final field in fields) field.name: field};
    for (final key in payload.keys) {
      if (!defined.containsKey(key)) issues.add('$key:UNKNOWN_FIELD');
    }
    for (final field in fields) {
      final issue = field.validate(payload[field.name]);
      if (issue != null) issues.add('${field.name}:$issue');
    }
    return issues;
  }
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
