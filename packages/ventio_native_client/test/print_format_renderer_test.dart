import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/host_extension_packages.dart';
import 'package:ventio_native_client/src/print_format_renderer.dart';

void main() {
  final type = DocTypeDefinition.fromJson({
    'name': 'Product',
    'moduleId': 'com.example.inventory',
    'schemaVersion': 1,
    'kind': 'operational',
    'label': 'Product',
    'labelKey': 'extension.com_example_inventory.product.label',
    'operations': ['read'],
    'permissions': {'read': 'extension.com_example_inventory.product.read'},
    'fields': [
      {
        'name': 'name',
        'type': 'text',
        'required': true,
        'maxLength': 120,
        'label': 'Name',
        'labelKey': 'extension.com_example_inventory.product.name',
      },
    ],
    'ui': {
      'listColumns': ['name'],
      'formFields': ['name'],
      'detailFields': ['name'],
    },
  });

  final format = PrintFormatDefinition.fromJson(
    {
      'id': 'product_receipt',
      'docType': 'Product',
      'label': 'Product receipt',
      'labelKey': 'extension.com_example_inventory.print.product_receipt',
      'pageSize': 'a4',
      'orientation': 'portrait',
      'blocks': [
        {'type': 'field', 'field': 'name'},
        {'type': 'page_break'},
        {'type': 'field', 'field': 'name'},
      ],
    },
    moduleId: 'com.example.inventory',
    docTypes: [type],
  );

  test(
    'PDF renderer creates a printable document from validated plain values',
    () async {
      final bytes = await buildPrintFormatPdf(
        format: format,
        docType: type,
        englishCatalog: const {
          'extension.com_example_inventory.print.product_receipt':
              'Product receipt',
          'extension.com_example_inventory.product.name': 'Name',
        },
        record: const {
          'name':
              '<script>alert(1)</script> \u0627\u0644\u0639\u0631\u0628\u064a\u0629',
        },
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, lessThan(5 * 1024 * 1024));
    },
  );

  test('PDF renderer prints bounded child rows as a fixed table', () async {
    final lineType = DocTypeDefinition.fromJson({
      'name': 'Movement',
      'moduleId': 'com.example.inventory',
      'schemaVersion': 1,
      'kind': 'operational',
      'label': 'Movement',
      'labelKey': 'extension.com_example_inventory.movement.label',
      'operations': ['read'],
      'permissions': {'read': 'extension.com_example_inventory.movement.read'},
      'fields': [
        {
          'name': 'lines',
          'type': 'table',
          'required': true,
          'label': 'Lines',
          'labelKey': 'extension.com_example_inventory.movement.lines',
          'childDocType': {
            'name': 'MovementLine',
            'label': 'Movement line',
            'labelKey': 'extension.com_example_inventory.movement.line',
            'fields': [
              {
                'name': 'product',
                'type': 'text',
                'required': true,
                'maxLength': 120,
                'label': 'Product',
                'labelKey': 'extension.com_example_inventory.movement.product',
              },
              {
                'name': 'quantity',
                'type': 'integer',
                'required': true,
                'label': 'Quantity',
                'labelKey': 'extension.com_example_inventory.movement.quantity',
              },
              {
                'name': 'lineTotal',
                'type': 'decimal',
                'required': true,
                'precision': 2,
                'label': 'Line total',
                'labelKey':
                    'extension.com_example_inventory.movement.line_total',
              },
            ],
          },
        },
        {
          'name': 'total',
          'type': 'decimal',
          'required': true,
          'precision': 2,
          'readOnly': true,
          'calculation': {
            'type': 'sum',
            'rowsField': 'lines',
            'valueField': 'lineTotal',
          },
          'label': 'Total',
          'labelKey': 'extension.com_example_inventory.movement.total',
        },
      ],
      'ui': {
        'listColumns': ['lines'],
        'formFields': ['lines', 'total'],
      },
    });
    final tableFormat = PrintFormatDefinition.fromJson(
      {
        'id': 'movement_receipt',
        'docType': 'Movement',
        'label': 'Movement receipt',
        'labelKey': 'extension.com_example_inventory.print.movement_receipt',
        'pageSize': 'letter',
        'orientation': 'landscape',
        'blocks': [
          {'type': 'field', 'field': 'total'},
          {'type': 'page_break'},
          {
            'type': 'table',
            'field': 'lines',
            'columns': ['product', 'quantity'],
          },
        ],
      },
      moduleId: 'com.example.inventory',
      docTypes: [lineType],
    );
    final bytes = await buildPrintFormatPdf(
      format: tableFormat,
      docType: lineType,
      englishCatalog: const {},
      record: const {
        'total': 12.5,
        'lines': [
          {'product': 'Widget', 'quantity': 2, 'lineTotal': 5.0},
          {'product': 'Cable', 'quantity': 3, 'lineTotal': 7.5},
        ],
      },
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test(
    'Host print snapshot must match exact record, revision and approved package',
    () {
      final approvedDigest = List.filled(64, 'a').join();
      HostExtensionRecordPage page({
        String? digest,
        Set<String>? readable,
        bool hasMore = false,
        int recordCount = 1,
      }) => HostExtensionRecordPage(
        records: [
          for (var index = 0; index < recordCount; index++)
            HostExtensionRecord(
              recordId: index == 0 ? 'record-one' : 'record-two',
              revision: 8,
              updatedAtUtc: '2026-10-28T10:00:00Z',
              values: const {'name': 'Pump'},
            ),
        ],
        packageSha256: digest ?? approvedDigest,
        hasMore: hasMore,
        readableFields: readable,
      );

      expect(
        verifiedHostPrintValues(
          page: page(readable: {'name'}),
          recordId: 'record-one',
          minimumRevision: 7,
          approvedPackageDigest: approvedDigest,
          requiredFields: const {'name'},
          fieldPermissionsDeclared: true,
        )['name'],
        'Pump',
      );
      expect(
        () => verifiedHostPrintValues(
          page: page(readable: {}),
          recordId: 'record-one',
          minimumRevision: 7,
          approvedPackageDigest: approvedDigest,
          requiredFields: const {'name'},
          fieldPermissionsDeclared: true,
        ),
        throwsA(isA<HostPackageTransportException>()),
      );
      expect(
        () => verifiedHostPrintValues(
          page: page(),
          recordId: 'record-one',
          minimumRevision: 9,
          approvedPackageDigest: List.filled(64, 'b').join(),
          requiredFields: const {'name'},
          fieldPermissionsDeclared: false,
        ),
        throwsA(isA<HostPackageTransportException>()),
      );
      expect(
        () => verifiedHostPrintValues(
          page: page(hasMore: true),
          recordId: 'record-one',
          minimumRevision: 7,
          approvedPackageDigest: approvedDigest,
          requiredFields: const {'name'},
          fieldPermissionsDeclared: false,
        ),
        throwsA(isA<HostPackageTransportException>()),
      );
      expect(
        () => verifiedHostPrintValues(
          page: page(recordCount: 2),
          recordId: 'record-one',
          minimumRevision: 7,
          approvedPackageDigest: approvedDigest,
          requiredFields: const {'name'},
          fieldPermissionsDeclared: false,
        ),
        throwsA(isA<HostPackageTransportException>()),
      );
    },
  );
}
