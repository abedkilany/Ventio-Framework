import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/host_setup_identifiers.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('Generated Host identifiers are valid and unique', () {
    final ids = <String>{};

    for (var i = 0; i < 100; i++) {
      final scope = generateHostSetupScope();

      expect(scope.tenantId, startsWith('org_'));
      expect(scope.companyId, startsWith('cmp_'));
      expect(scope.branchId, startsWith('br_'));

      expect(ids.add(scope.tenantId), isTrue);
      expect(ids.add(scope.companyId), isTrue);
      expect(ids.add(scope.branchId), isTrue);
    }

    expect(ids, hasLength(300));
  });

  test('Host setup draft survives SQLite restart', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ventio_setup_test_',
    );

    addTearDown(() => directory.delete(recursive: true));

    final path = '${directory.path}/test.sqlite3';
    final scope = generateHostSetupScope();
    const sid = 'S-1-5-21-1000-1000-1000-1001';

    var store = await LocalExtensionStore.open(
      factory: databaseFactoryFfi,
      path: path,
    );

    Future<void> saveDraft() => store.saveHostSetupDraft(
      requesterSid: sid,
      tenantId: scope.tenantId,
      companyId: scope.companyId,
      branchId: scope.branchId,
      organizationName: 'Test Organization',
      companyName: 'Test Company',
      branchName: 'Main Branch',
    );

    expect(await store.getHostSetupDraft(), isNull);

    await saveDraft();
    await store.close();

    store = await LocalExtensionStore.open(
      factory: databaseFactoryFfi,
      path: path,
    );

    try {
      final draft = await store.getHostSetupDraft();

      expect(draft, isNotNull);
      expect(draft!['requester_sid'], sid);
      expect(draft['tenant_id'], scope.tenantId);
      expect(draft['company_id'], scope.companyId);
      expect(draft['branch_id'], scope.branchId);
      expect(draft['organization_name'], 'Test Organization');
      expect(draft['company_name'], 'Test Company');
      expect(draft['branch_name'], 'Main Branch');

      await expectLater(saveDraft(), throwsA(isA<DatabaseException>()));

      await expectLater(
        store.clearHostSetupDraft(
          requesterSid: 'wrong-sid',
          tenantId: scope.tenantId,
          companyId: scope.companyId,
          branchId: scope.branchId,
        ),
        throwsStateError,
      );

      expect(await store.getHostSetupDraft(), draft);

      await store.clearHostSetupDraft(
        requesterSid: sid,
        tenantId: scope.tenantId,
        companyId: scope.companyId,
        branchId: scope.branchId,
      );

      expect(await store.getHostSetupDraft(), isNull);
    } finally {
      await store.close();
    }
  });
}
