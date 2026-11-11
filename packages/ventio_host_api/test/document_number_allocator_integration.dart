import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

final class _Rollback implements Exception {
  const _Rollback();
}

Future<void> main() async {
  final adminUrl = Platform.environment['VENTIO_TEST_ADMIN_DATABASE_URL'];
  if (adminUrl == null ||
      Platform.environment['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
      Uri.parse(
            adminUrl,
          ).pathSegments.where((part) => part.isNotEmpty).lastOrNull !=
          'ventio_host_test') {
    stderr.writeln(
      'Document numbering integration requires the disposable ventio_host_test database and explicit test opt-in.',
    );
    exitCode = 2;
    return;
  }

  final tenant = 'numbering-${DateTime.now().toUtc().microsecondsSinceEpoch}';
  const company = 'numbering-company';
  const branch = 'numbering-branch';
  const module = 'com.example.numbering';
  const docType = 'NumberedDocument';
  const series = DocumentNamingSeries(
    seriesId: 'main',
    field: 'documentNumber',
    prefix: 'DOC-',
    padding: 6,
  );
  const allocator = PostgresDocumentNumberAllocator();
  var assertions = 0;
  void expect(bool condition, String label) {
    if (!condition) throw StateError('FAIL: $label');
    assertions++;
    stdout.writeln('PASS: $label');
  }

  Future<String> allocateOnConnection({
    DocumentNamingSeries selectedSeries = series,
    String selectedBranch = branch,
  }) async {
    final connection = await pg.Connection.openFromUrl(adminUrl);
    try {
      return await connection.runTx(
        (tx) => allocator.allocate(
          transaction: tx,
          tenantId: tenant,
          companyId: company,
          branchId: selectedBranch,
          moduleId: module,
          docType: docType,
          series: selectedSeries,
        ),
      );
    } finally {
      await connection.close();
    }
  }

  final connection = await pg.Connection.openFromUrl(adminUrl);
  try {
    try {
      await connection.runTx((tx) async {
        final value = await allocator.allocate(
          transaction: tx,
          tenantId: tenant,
          companyId: company,
          branchId: branch,
          moduleId: module,
          docType: docType,
          series: series,
        );
        expect(value == 'DOC-000001', 'First transactional allocation is one');
        throw const _Rollback();
      });
    } on _Rollback {
      // The transaction must restore the counter with the document rollback.
    }

    expect(
      await allocateOnConnection() == 'DOC-000001',
      'Rolled-back allocation does not consume a number',
    );
    final concurrent = await Future.wait([
      allocateOnConnection(),
      allocateOnConnection(),
    ]);
    concurrent.sort();
    expect(
      concurrent.join(',') == 'DOC-000002,DOC-000003',
      'Concurrent transactions serialize to distinct sequential numbers',
    );

    var changedSeriesRejected = false;
    try {
      await allocateOnConnection(
        selectedSeries: const DocumentNamingSeries(
          seriesId: 'main',
          field: 'documentNumber',
          prefix: 'INV-',
          padding: 6,
        ),
      );
    } on StateError {
      changedSeriesRejected = true;
    }
    expect(
      changedSeriesRejected,
      'A changed prefix cannot reset a live series',
    );
    expect(
      await allocateOnConnection() == 'DOC-000004',
      'Rejected configuration change does not consume a number',
    );
    expect(
      await allocateOnConnection(selectedBranch: 'numbering-branch-2') ==
          'DOC-000001',
      'Each branch has an independent numbering sequence',
    );
  } finally {
    await connection.close();
  }
  stdout.writeln('RESULT: $assertions passed, 0 failed');
}
