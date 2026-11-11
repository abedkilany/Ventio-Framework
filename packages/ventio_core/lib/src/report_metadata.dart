import 'contracts.dart';
import 'metadata.dart';

final RegExp _reportIdentifier = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

/// One bounded aggregate in an ordinary declarative extension report.
class ReportAggregateDefinition {
  const ReportAggregateDefinition({
    required this.id,
    required this.operation,
    required this.label,
    required this.labelKey,
    this.field,
  });

  final String id;
  final String operation;
  final String? field;
  final String label;
  final String labelKey;

  factory ReportAggregateDefinition.fromJson(
    Map<String, dynamic> json,
    Map<String, FieldDefinition> fields,
  ) {
    _checkKeys(json, const {'id', 'operation', 'field', 'label', 'labelKey'});
    final id = requireString(json, 'id');
    final operation = requireString(json, 'operation');
    final label = requireString(json, 'label');
    final labelKey = requireString(json, 'labelKey');
    final fieldValue = json['field'];
    if (!_reportIdentifier.hasMatch(id) ||
        label.trim().isEmpty ||
        label.length > 120 ||
        !_validMessageKey(labelKey)) {
      throw const ContractError('INVALID_REPORT', 'Invalid report aggregate.');
    }
    if (operation == 'count') {
      if (fieldValue != null) {
        throw const ContractError(
          'INVALID_REPORT',
          'Count aggregates do not declare a source field.',
        );
      }
    } else if (operation == 'sum') {
      if (fieldValue is! String ||
          !fields.containsKey(fieldValue) ||
          !{'integer', 'decimal'}.contains(fields[fieldValue]!.type)) {
        throw const ContractError(
          'INVALID_REPORT',
          'A sum aggregate must reference a numeric DocType field.',
        );
      }
    } else {
      throw const ContractError(
        'INVALID_REPORT',
        'Reports support only count and sum aggregates.',
      );
    }
    return ReportAggregateDefinition(
      id: id,
      operation: operation,
      field: fieldValue as String?,
      label: label,
      labelKey: labelKey,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'operation': operation,
        if (field != null) 'field': field,
        'label': label,
        'labelKey': labelKey,
      };
}

/// A saved report whose query shape is fixed by an approved extension package.
class ReportDefinition {
  const ReportDefinition({
    required this.id,
    required this.docType,
    required this.label,
    required this.labelKey,
    required this.filterFields,
    required this.aggregates,
    required this.descending,
    this.groupBy,
    this.sortBy,
  });

  static const maxReportsPerBundle = 32;
  static const maxFilters = 10;
  static const maxAggregates = 8;

  final String id;
  final String docType;
  final String label;
  final String labelKey;
  final List<String> filterFields;
  final String? groupBy;
  final String? sortBy;
  final bool descending;
  final List<ReportAggregateDefinition> aggregates;

  factory ReportDefinition.fromJson(
    Map<String, dynamic> json, {
    required String moduleId,
    required List<DocTypeDefinition> docTypes,
  }) {
    _checkKeys(json, const {
      'id',
      'docType',
      'label',
      'labelKey',
      'filters',
      'groupBy',
      'sortBy',
      'descending',
      'aggregates',
    });
    final id = requireString(json, 'id');
    final docTypeName = requireString(json, 'docType');
    final label = requireString(json, 'label');
    final labelKey = requireString(json, 'labelKey');
    final descending = json['descending'];
    if (!_reportIdentifier.hasMatch(id) ||
        !RegExp(r'^[A-Z][A-Za-z0-9_]{0,79}$').hasMatch(docTypeName) ||
        label.trim().isEmpty ||
        label.length > 120 ||
        !_validMessageKey(labelKey) ||
        descending is! bool ||
        !labelKey.startsWith(_reportNamespace(moduleId))) {
      throw const ContractError('INVALID_REPORT', 'Invalid report metadata.');
    }
    final matchingDocTypes = docTypes.where(
      (type) => type.name == docTypeName,
    );
    if (matchingDocTypes.length != 1) {
      throw const ContractError(
        'INVALID_REPORT',
        'A report must reference one DocType in its extension.',
      );
    }
    final definition = matchingDocTypes.single;
    final fields = {for (final field in definition.fields) field.name: field};
    final filters = json['filters'] ?? const <Object>[];
    if (filters is! List ||
        filters.length > maxFilters ||
        filters
            .any((field) => field is! String || !fields.containsKey(field)) ||
        filters.toSet().length != filters.length) {
      throw const ContractError(
        'INVALID_REPORT',
        'Report filters must be unique fields from the source DocType.',
      );
    }
    for (final fieldName in filters.cast<String>()) {
      if (fields[fieldName]!.type == 'table') {
        throw const ContractError(
          'INVALID_REPORT',
          'A report filter must reference a scalar field.',
        );
      }
    }
    final groupValue = json['groupBy'];
    final groupBy = groupValue == null ? null : requireString(json, 'groupBy');
    if (groupBy != null &&
        (!fields.containsKey(groupBy) || fields[groupBy]!.type == 'table')) {
      throw const ContractError(
        'INVALID_REPORT',
        'Report grouping must reference a scalar source field.',
      );
    }
    final sortValue = json['sortBy'];
    final sortBy = sortValue == null ? null : requireString(json, 'sortBy');
    final rawAggregates = requireList(json, 'aggregates');
    if (rawAggregates.isEmpty || rawAggregates.length > maxAggregates) {
      throw const ContractError(
        'INVALID_REPORT',
        'A report must define between one and eight aggregates.',
      );
    }
    final aggregates = rawAggregates
        .map(
          (value) => ReportAggregateDefinition.fromJson(
            requireMap(value, 'aggregates[]'),
            fields,
          ),
        )
        .toList(growable: false);
    if (aggregates.map((aggregate) => aggregate.id).toSet().length !=
        aggregates.length) {
      throw const ContractError(
        'INVALID_REPORT',
        'Report aggregate IDs must be unique.',
      );
    }
    final aggregateIds = aggregates.map((aggregate) => aggregate.id).toSet();
    if (sortBy != null && sortBy != groupBy && !aggregateIds.contains(sortBy)) {
      throw const ContractError(
        'INVALID_REPORT',
        'Report sorting must use the grouping field or an aggregate output.',
      );
    }
    return ReportDefinition(
      id: id,
      docType: docTypeName,
      label: label,
      labelKey: labelKey,
      filterFields: List.unmodifiable(filters.cast<String>()),
      groupBy: groupBy,
      sortBy: sortBy,
      descending: descending,
      aggregates: List.unmodifiable(aggregates),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'docType': docType,
        'label': label,
        'labelKey': labelKey,
        'filters': filterFields,
        if (groupBy != null) 'groupBy': groupBy,
        if (sortBy != null) 'sortBy': sortBy,
        'descending': descending,
        'aggregates':
            aggregates.map((aggregate) => aggregate.toJson()).toList(),
      };
}

void _checkKeys(Map<String, dynamic> json, Set<String> allowed) {
  if (json.keys.any((key) => !allowed.contains(key))) {
    throw const ContractError(
      'INVALID_REPORT',
      'Report metadata contains unsupported properties.',
    );
  }
}

bool _validMessageKey(String value) =>
    RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2,}$').hasMatch(value) &&
    value.length <= 200;

String _reportNamespace(String moduleId) =>
    'extension.${moduleId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}.report.';
