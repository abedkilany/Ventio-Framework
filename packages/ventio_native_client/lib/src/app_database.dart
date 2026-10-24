import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'extension_store.dart';
import 'local_command_queue.dart';

DatabaseFactory _defaultDatabaseFactory() {
  if (Platform.isWindows) {
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }
  if (Platform.isAndroid) return sqflite.databaseFactory;
  throw UnsupportedError('Ventio currently supports Windows and Android.');
}

Future<LocalCommandQueue> openDefaultCommandQueue() async {
  final directory = await getApplicationSupportDirectory();
  return LocalCommandQueue.open(
    factory: _defaultDatabaseFactory(),
    path: p.join(directory.path, 'ventio_native_client.sqlite3'),
  );
}

Future<LocalExtensionStore> openDefaultExtensionStore() async {
  final directory = await getApplicationSupportDirectory();
  return LocalExtensionStore.open(
    factory: _defaultDatabaseFactory(),
    path: p.join(directory.path, 'ventio_extensions.sqlite3'),
  );
}
