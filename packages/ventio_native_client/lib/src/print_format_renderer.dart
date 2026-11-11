import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:ventio_core/ventio_core.dart';

import 'host_extension_packages.dart';

Future<(pw.Font, pw.Font)?>? _windowsFontCache;

/// Accepts only the exact Host response for a single record and approved
/// package. Callers must obtain [page] with the authenticated exact-record API.
Map<String, dynamic> verifiedHostPrintValues({
  required HostExtensionRecordPage page,
  required String recordId,
  required int minimumRevision,
  required String approvedPackageDigest,
  required Iterable<String> requiredFields,
  required bool fieldPermissionsDeclared,
}) {
  if (page.packageSha256 != approvedPackageDigest ||
      page.records.length != 1 ||
      page.hasMore ||
      page.records.single.recordId != recordId ||
      page.records.single.revision < minimumRevision ||
      (fieldPermissionsDeclared && page.readableFields == null) ||
      (page.readableFields != null &&
          requiredFields.any(
            (field) => !page.readableFields!.contains(field),
          ))) {
    throw const HostPackageTransportException(
      'HOST_PRINT_AUTHORIZATION_FAILED',
    );
  }
  return Map.unmodifiable(page.records.single.values);
}

/// Renders only validated, data-only print metadata and an authorized record.
/// The renderer has no API for HTML, scripts, expressions, or arbitrary assets.
Future<List<int>> buildPrintFormatPdf({
  required PrintFormatDefinition format,
  required DocTypeDefinition docType,
  required Map<String, String> englishCatalog,
  required Map<String, dynamic> record,
  bool useSystemFonts = true,
}) async {
  if (format.docType != docType.name) {
    throw const FormatException(
      'Print format and record DocType do not match.',
    );
  }
  final fields = {for (final field in docType.fields) field.name: field};
  final page =
      (format.pageSize == 'letter' ? PdfPageFormat.letter : PdfPageFormat.a4)
          .copyWith(
            marginLeft: 36,
            marginTop: 36,
            marginRight: 36,
            marginBottom: 36,
          );
  final pageFormat = format.orientation == 'landscape'
      ? page.landscape
      : page.portrait;
  final fonts = useSystemFonts ? await _loadWindowsFonts() : null;
  final content = <pw.Widget>[
    pw.Text(
      englishCatalog[format.labelKey] ?? format.label,
      style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
    ),
    pw.SizedBox(height: 18),
  ];
  for (final block in format.blocks) {
    if (block.type == 'page_break') {
      content.add(pw.NewPage());
      continue;
    }
    final field = fields[block.field];
    if (field == null) {
      throw const FormatException('Print format references an unknown field.');
    }
    if (!record.containsKey(field.name)) {
      throw FormatException(
        'The authorized Host response omitted ${field.name}.',
      );
    }
    if (block.type == 'field') {
      content.add(
        _fieldValue(
          englishCatalog[field.labelKey] ?? field.label,
          record[field.name],
        ),
      );
      content.add(pw.SizedBox(height: 8));
      continue;
    }
    final rows = record[field.name];
    if (rows is! List || rows.length > 500 || field.childDocType == null) {
      throw const FormatException(
        'The authorized table value is invalid or too large.',
      );
    }
    final childFields = {
      for (final childField in field.childDocType!.fields)
        childField.name: childField,
    };
    final columns = block.columns
        .map((name) {
          final child = childFields[name];
          if (child == null) {
            throw const FormatException(
              'Print table references an unknown child field.',
            );
          }
          return child;
        })
        .toList(growable: false);
    content.add(
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey600, width: .5),
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey300),
            children: columns
                .map(
                  (column) => _cell(
                    englishCatalog[column.labelKey] ?? column.label,
                    bold: true,
                  ),
                )
                .toList(growable: false),
          ),
          for (final rawRow in rows)
            if (rawRow is Map<String, dynamic>)
              pw.TableRow(
                children: columns
                    .map((column) {
                      if (!rawRow.containsKey(column.name)) {
                        throw FormatException(
                          'The authorized Host response omitted ${column.name}.',
                        );
                      }
                      return _cell(_displayValue(rawRow[column.name]));
                    })
                    .toList(growable: false),
              )
            else
              throw const FormatException(
                'A print table row is not an object.',
              ),
        ],
      ),
    );
    content.add(pw.SizedBox(height: 12));
  }
  final document = pw.Document(
    theme: fonts == null
        ? null
        : pw.ThemeData.withFont(
            base: fonts.$1,
            bold: fonts.$1,
            italic: fonts.$1,
            boldItalic: fonts.$1,
            fontFallback: [fonts.$2],
          ),
  );
  document.addPage(
    pw.MultiPage(pageFormat: pageFormat, maxPages: 100, build: (_) => content),
  );
  return document.save();
}

Future<(pw.Font, pw.Font)?> _loadWindowsFonts() =>
    _windowsFontCache ??= _readWindowsFonts();

Future<(pw.Font, pw.Font)?> _readWindowsFonts() async {
  if (!Platform.isWindows) return null;
  final directory = '${Platform.environment['WINDIR'] ?? r'C:\Windows'}\\Fonts';
  final primary = File('$directory\\segoeui.ttf');
  final fallback = File('$directory\\ARIALUNI.ttf');
  if (!await primary.exists()) return null;
  final primaryFont = pw.Font.ttf(
    ByteData.sublistView(await primary.readAsBytes()),
  );
  final fallbackFont = await fallback.exists()
      ? pw.Font.ttf(ByteData.sublistView(await fallback.readAsBytes()))
      : primaryFont;
  return (primaryFont, fallbackFont);
}

pw.Widget _fieldValue(String label, Object? value) => pw.Row(
  crossAxisAlignment: pw.CrossAxisAlignment.start,
  children: [
    pw.SizedBox(
      width: 150,
      child: pw.Text(
        label,
        style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
      ),
    ),
    pw.Expanded(child: pw.Text(_displayValue(value))),
  ],
);

pw.Widget _cell(String value, {bool bold = false}) => pw.Padding(
  padding: const pw.EdgeInsets.all(5),
  child: pw.Text(
    value,
    style: pw.TextStyle(
      fontSize: 9,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
    ),
  ),
);

String _displayValue(Object? value) {
  if (value == null) return '';
  if (value is String || value is num || value is bool) return value.toString();
  return jsonEncode(value);
}
