import 'dart:convert';

import 'contracts.dart';
import 'metadata.dart';
import 'exact_decimal.dart';

/// RFC 4180-style UTF-8 CSV with explicit bounds. No formula evaluation,
/// locale inference, script handlers or SQL fragments are accepted.
class StructuredCsv {
  static const maxBytes = 512 * 1024;
  static const maxRows = 500;
  static const maxColumns = 100;
  static const maxCellLength = 65535;

  static List<List<String>> decode(String source) {
    if (utf8.encode(source).length > maxBytes) {
      throw const ContractError(
        'CSV_TOO_LARGE',
        'CSV exceeds the import bound.',
      );
    }
    if (source.startsWith('\uFEFF')) source = source.substring(1);
    final rows = <List<String>>[];
    var row = <String>[];
    var cell = StringBuffer();
    var quoted = false;
    var closedQuote = false;
    var started = false;
    void finishCell() {
      if (cell.length > maxCellLength || row.length >= maxColumns) {
        throw const ContractError(
          'CSV_LIMIT',
          'CSV cell or column limit exceeded.',
        );
      }
      row.add(cell.toString());
      cell = StringBuffer();
      closedQuote = false;
      started = false;
    }

    void finishRow() {
      finishCell();
      rows.add(List.unmodifiable(row));
      row = <String>[];
      if (rows.length > maxRows + 1) {
        throw const ContractError(
          'CSV_LIMIT',
          'At most 500 data rows are allowed.',
        );
      }
    }

    for (var i = 0; i < source.length; i++) {
      final character = source[i];
      if (character == '\u0000')
        throw const ContractError(
          'INVALID_CSV',
          'NUL characters are not supported.',
        );
      if (quoted) {
        if (character == '"') {
          if (i + 1 < source.length && source[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
            closedQuote = true;
          }
        } else {
          cell.write(character);
        }
      } else if (character == ',') {
        finishCell();
      } else if (character == '\n' || character == '\r') {
        finishRow();
        if (character == '\r' && i + 1 < source.length && source[i + 1] == '\n')
          i++;
      } else if (character == '"' && !started && cell.isEmpty && !closedQuote) {
        quoted = true;
        started = true;
      } else {
        if (closedQuote || character == '"' || character == '\u0000') {
          throw const ContractError(
            'INVALID_CSV',
            'Unexpected CSV character or quote.',
          );
        }
        cell.write(character);
        started = true;
      }
      if (cell.length > maxCellLength) {
        throw const ContractError('CSV_LIMIT', 'CSV cell limit exceeded.');
      }
    }
    if (quoted)
      throw const ContractError('INVALID_CSV', 'Unterminated CSV quote.');
    if (started || cell.isNotEmpty || row.isNotEmpty || closedQuote)
      finishRow();
    if (rows.isEmpty ||
        rows.first.any((header) => header.trim().isEmpty) ||
        rows.first.toSet().length != rows.first.length) {
      throw const ContractError(
        'INVALID_CSV',
        'Unique nonempty headers are required.',
      );
    }
    return List.unmodifiable(rows);
  }

  /// Prefix spreadsheet formulas on export. This is a presentation escape;
  /// imports do not remove it or interpret it as code.
  static String encode(Iterable<List<Object?>> rows) {
    String cell(Object? value) {
      var text = value == null
          ? ''
          : value is Map || value is List
          ? jsonEncode(value)
          : '$value';
      if (value is String &&
          (RegExp(r'^[\s]*[=+@-]').hasMatch(text) || text.startsWith('\t')))
        text = "'$text";
      return '"${text.replaceAll('"', '""')}"';
    }

    return rows.map((row) => row.map(cell).join(',')).join('\r\n');
  }
}

class ImportPreviewRow {
  const ImportPreviewRow(
    this.rowNumber,
    this.recordId,
    this.values,
    this.errors,
  );
  final int rowNumber;
  final String recordId;
  final Map<String, dynamic> values;
  final List<String> errors;
  Map<String, dynamic> toJson() => {
    'rowNumber': rowNumber,
    'recordId': recordId,
    'values': values,
    'errors': errors,
  };
}

/// Mapping is header -> metadata field. Record identity is explicit, making
/// duplicate detection deterministic without querying unauthorized records.
List<ImportPreviewRow> previewCsvImport({
  required String source,
  required DocTypeDefinition definition,
  required Map<String, String> mapping,
  required String recordIdHeader,
  required Set<String> writableFields,
}) {
  final rows = StructuredCsv.decode(source);
  final headers = rows.first;
  if (!headers.contains(recordIdHeader) ||
      mapping.isEmpty ||
      mapping.containsKey(recordIdHeader) ||
      !mapping.keys.every(headers.contains) ||
      mapping.values.toSet().length != mapping.length) {
    throw const ContractError(
      'INVALID_IMPORT_MAPPING',
      'Mapping and record ID header must be unambiguous.',
    );
  }
  final fields = {for (final field in definition.fields) field.name: field};
  if (mapping.values.any(
    (name) =>
        !fields.containsKey(name) ||
        !writableFields.contains(name) ||
        fields[name]!.readOnly ||
        fields[name]!.calculation != null,
  )) {
    throw const ContractError(
      'IMPORT_FIELD_DENIED',
      'Import mapping contains an unavailable or unsupported field.',
    );
  }
  final idCounts = <String, int>{};
  final idIndex = headers.indexOf(recordIdHeader);
  for (final row in rows.skip(1)) {
    if (row.length == headers.length)
      idCounts.update(row[idIndex], (count) => count + 1, ifAbsent: () => 1);
  }
  return List.unmodifiable(
    rows.skip(1).indexed.map((entry) {
      final row = entry.$2;
      final issues = <String>[];
      final values = <String, dynamic>{};
      if (row.length != headers.length) {
        return ImportPreviewRow(entry.$1 + 2, '', const {}, const [
          'COLUMN_COUNT_MISMATCH',
        ]);
      }
      final id = row[idIndex];
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$').hasMatch(id))
        issues.add('INVALID_RECORD_ID');
      if (idCounts[id]! > 1) issues.add('DUPLICATE_RECORD_ID');
      for (final mappingEntry in mapping.entries) {
        final name = mappingEntry.value;
        final text = row[headers.indexOf(mappingEntry.key)];
        final field = fields[name]!;
        Object? value;
        if (text.isEmpty) {
          value = null;
        } else {
          value = switch (field.type) {
            'integer' => int.tryParse(text),
            'decimal' => _decimalCell(text, field.precision),
            'table' => _tableCell(text),
            'boolean' => switch (text) {
              'true' => true,
              'false' => false,
              _ => null,
            },
            _ => text,
          };
          if (value == null)
            issues.add('$name:INVALID_${field.type.toUpperCase()}');
        }
        values[name] = value;
      }
      issues.addAll(
        definition.validatePayload(definition.applyDefaults(values)),
      );
      return ImportPreviewRow(
        entry.$1 + 2,
        id,
        Map.unmodifiable(values),
        List.unmodifiable(issues),
      );
    }),
  );
}

num? _decimalCell(String text, int? precision) {
  final match = RegExp(r'^([+-]?)([0-9]+)(?:\.([0-9]+))?$').firstMatch(text);
  if (match == null) return null;
  final fraction = (match.group(3) ?? '').replaceFirst(RegExp(r'0+$'), '');
  final scale = precision ?? 9;
  if (fraction.length > scale || match.group(2)!.length > 16) return null;
  var scaled = BigInt.parse(
    '${match.group(2)}${fraction.padRight(scale, '0')}',
  );
  if (match.group(1) == '-') scaled = -scaled;
  try {
    return ExactDecimal.fromScaledInteger(scaled, scale);
  } on FormatException {
    return null;
  }
}

Object? _tableCell(String text) {
  try {
    final value = jsonDecode(text);
    return value is List ? value : null;
  } on FormatException {
    return null;
  }
}
