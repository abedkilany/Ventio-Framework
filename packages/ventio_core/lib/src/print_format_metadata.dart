import 'contracts.dart';
import 'metadata.dart';

final RegExp _printFormatIdentifier = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

/// One data-only content block in a reviewed print format.
class PrintFormatBlockDefinition {
  const PrintFormatBlockDefinition._({
    required this.type,
    this.field,
    this.columns = const [],
  });

  final String type;
  final String? field;
  final List<String> columns;

  factory PrintFormatBlockDefinition.fromJson(
    Map<String, dynamic> json, {
    required DocTypeDefinition docType,
  }) {
    final type = requireString(json, 'type');
    switch (type) {
      case 'field':
        _checkPrintKeys(json, const {'type', 'field'});
        final fieldName = requireString(json, 'field');
        final field = docType.fields.where((item) => item.name == fieldName);
        if (field.length != 1 || field.single.type == 'table') {
          throw const ContractError(
            'INVALID_PRINT_FORMAT',
            'A field block must reference a scalar source field.',
          );
        }
        return PrintFormatBlockDefinition._(type: type, field: fieldName);
      case 'table':
        _checkPrintKeys(json, const {'type', 'field', 'columns'});
        final fieldName = requireString(json, 'field');
        final matches = docType.fields.where((item) => item.name == fieldName);
        if (matches.length != 1 || matches.single.childDocType == null) {
          throw const ContractError(
            'INVALID_PRINT_FORMAT',
            'A table block must reference a declared Child Table field.',
          );
        }
        final rawColumns = requireList(json, 'columns');
        final childFields = matches.single.childDocType!.fields;
        if (rawColumns.isEmpty ||
            rawColumns.length > PrintFormatDefinition.maxColumnsPerTable ||
            rawColumns.any(
              (column) =>
                  column is! String ||
                  !childFields.any(
                    (childField) =>
                        childField.name == column && childField.type != 'table',
                  ),
            ) ||
            rawColumns.toSet().length != rawColumns.length) {
          throw const ContractError(
            'INVALID_PRINT_FORMAT',
            'Table columns must be unique scalar fields from its Child DocType.',
          );
        }
        return PrintFormatBlockDefinition._(
          type: type,
          field: fieldName,
          columns: List.unmodifiable(rawColumns.cast<String>()),
        );
      case 'page_break':
        _checkPrintKeys(json, const {'type'});
        return const PrintFormatBlockDefinition._(type: 'page_break');
      default:
        throw const ContractError(
          'INVALID_PRINT_FORMAT',
          'Print formats support only field, table, and page-break blocks.',
        );
    }
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        if (field != null) 'field': field,
        if (type == 'table') 'columns': columns,
      };
}

/// A bounded printable layout that contains no executable template language.
class PrintFormatDefinition {
  const PrintFormatDefinition({
    required this.id,
    required this.docType,
    required this.label,
    required this.labelKey,
    required this.pageSize,
    required this.orientation,
    required this.blocks,
  });

  static const maxFormatsPerBundle = 32;
  static const maxBlocks = 64;
  static const maxColumnsPerTable = 10;

  final String id;
  final String docType;
  final String label;
  final String labelKey;
  final String pageSize;
  final String orientation;
  final List<PrintFormatBlockDefinition> blocks;

  factory PrintFormatDefinition.fromJson(
    Map<String, dynamic> json, {
    required String moduleId,
    required List<DocTypeDefinition> docTypes,
  }) {
    _checkPrintKeys(json, const {
      'id',
      'docType',
      'label',
      'labelKey',
      'pageSize',
      'orientation',
      'blocks',
    });
    final id = requireString(json, 'id');
    final docTypeName = requireString(json, 'docType');
    final label = requireString(json, 'label');
    final labelKey = requireString(json, 'labelKey');
    final pageSize = requireString(json, 'pageSize');
    final orientation = requireString(json, 'orientation');
    if (!_printFormatIdentifier.hasMatch(id) ||
        !RegExp(r'^[A-Z][A-Za-z0-9_]{0,79}$').hasMatch(docTypeName) ||
        label.trim().isEmpty ||
        label.length > 120 ||
        !_validPrintMessageKey(labelKey) ||
        !labelKey.startsWith(_printNamespace(moduleId)) ||
        !{'a4', 'letter'}.contains(pageSize) ||
        !{'portrait', 'landscape'}.contains(orientation)) {
      throw const ContractError(
        'INVALID_PRINT_FORMAT',
        'Invalid print format identity, labels, or page settings.',
      );
    }
    final matches = docTypes.where((item) => item.name == docTypeName);
    if (matches.length != 1) {
      throw const ContractError(
        'INVALID_PRINT_FORMAT',
        'A print format must reference one DocType in its extension.',
      );
    }
    final rawBlocks = requireList(json, 'blocks');
    if (rawBlocks.isEmpty || rawBlocks.length > maxBlocks) {
      throw const ContractError(
        'INVALID_PRINT_FORMAT',
        'A print format must define between one and 64 content blocks.',
      );
    }
    final blocks = rawBlocks
        .map(
          (raw) => PrintFormatBlockDefinition.fromJson(
            requireMap(raw, 'blocks[]'),
            docType: matches.single,
          ),
        )
        .toList(growable: false);
    if (!blocks.any((block) => block.type != 'page_break')) {
      throw const ContractError(
        'INVALID_PRINT_FORMAT',
        'A print format must contain printable content.',
      );
    }
    return PrintFormatDefinition(
      id: id,
      docType: docTypeName,
      label: label,
      labelKey: labelKey,
      pageSize: pageSize,
      orientation: orientation,
      blocks: List.unmodifiable(blocks),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'docType': docType,
        'label': label,
        'labelKey': labelKey,
        'pageSize': pageSize,
        'orientation': orientation,
        'blocks': blocks.map((block) => block.toJson()).toList(),
      };
}

void _checkPrintKeys(Map<String, dynamic> json, Set<String> allowed) {
  if (json.keys.any((key) => !allowed.contains(key))) {
    throw const ContractError(
      'INVALID_PRINT_FORMAT',
      'Print format metadata contains unsupported properties.',
    );
  }
}

bool _validPrintMessageKey(String value) =>
    RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2,}$').hasMatch(value) &&
    value.length <= 200;

String _printNamespace(String moduleId) =>
    'extension.${moduleId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}.print.';
