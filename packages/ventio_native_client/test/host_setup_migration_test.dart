import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_native_client/src/extension_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('Version 13 migration preserves existing Host profile', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ventio_migration_test_',
    );

    addTearDown(() => directory.delete(recursive: true));

    final path = '${directory.path}/migration.sqlite3';

    var store = await LocalExtensionStore.open(
      factory: databaseFactoryFfi,
      path: path,
    );

    const profile = HostConnectionProfile(
      endpoint: 'http://127.0.0.1:8080',
      tenantId: 'existing-org',
      companyId: 'existing-company',
      branchId: 'existing-branch',
      actorId: 'existing-owner',
      deviceId: 'existing-device',
    );

    await store.saveHostProfile(profile);
    await store.close();

    final legacy = await databaseFactoryFfi.openDatabase(path);

    try {
      await legacy.execute('DROP TABLE local_host_setup_draft');
      await legacy.execute('PRAGMA user_version = 13');

      expect(await legacy.getVersion(), 13);
    } finally {
      await legacy.close();
    }

    store = await LocalExtensionStore.open(
      factory: databaseFactoryFfi,
      path: path,
    );

    try {
      final restored = await store.getHostProfile();

      expect(restored, isNotNull);
      expect(restored!.endpoint, profile.endpoint);
      expect(restored.tenantId, profile.tenantId);
      expect(restored.companyId, profile.companyId);
      expect(restored.branchId, profile.branchId);
      expect(restored.actorId, profile.actorId);
      expect(restored.deviceId, profile.deviceId);

      expect(await store.getHostSetupDraft(), isNull);

      await store.saveHostSetupDraft(
        requesterSid: 'S-1-5-21-1000-1000-1000-1001',
        tenantId: profile.tenantId,
        companyId: profile.companyId,
        branchId: profile.branchId,
        organizationName: 'Existing Organization',
        companyName: 'Existing Company',
        branchName: 'Existing Branch',
      );

      expect(await store.getHostSetupDraft(), isNotNull);
    } finally {
      await store.close();
    }

    final upgraded = await databaseFactoryFfi.openDatabase(path);

    try {
      expect(await upgraded.getVersion(), 14);
    } finally {
      await upgraded.close();
    }
  });
}
