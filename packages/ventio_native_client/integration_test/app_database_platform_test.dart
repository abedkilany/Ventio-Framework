import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ventio_native_client/src/app_database.dart';
import 'package:ventio_native_client/src/extension_store.dart';
import 'package:ventio_native_client/src/local_command_queue.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('current platform SQLite opens durable Ventio stores', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'ventio-platform-sqlite-',
    );
    LocalExtensionStore? extensionStore;
    LocalCommandQueue? commandQueue;
    try {
      final factory = databaseFactoryForCurrentPlatform();
      extensionStore = await LocalExtensionStore.open(
        factory: factory,
        path: p.join(directory.path, 'extensions.sqlite3'),
      );
      commandQueue = await LocalCommandQueue.open(
        factory: factory,
        path: p.join(directory.path, 'commands.sqlite3'),
      );

      expect(await extensionStore.listExtensions(), isEmpty);
      expect(await commandQueue.list(), isEmpty);
    } finally {
      await commandQueue?.close();
      await extensionStore?.close();
      await directory.delete(recursive: true);
    }
  });
}
