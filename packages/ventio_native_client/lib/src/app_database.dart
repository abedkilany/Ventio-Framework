import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'local_command_queue.dart';

Future<LocalCommandQueue> openDefaultCommandQueue() async {
  final DatabaseFactory factory;
  if (Platform.isWindows) {
    sqfliteFfiInit();
    factory = databaseFactoryFfi;
  } else if (Platform.isAndroid) {
    factory = sqflite.databaseFactory;
  } else {
    throw UnsupportedError('The proof client currently supports Windows and Android.');
  }

  final directory = await getApplicationSupportDirectory();
  return LocalCommandQueue.open(
    factory: factory,
    path: p.join(directory.path, 'ventio_native_client.sqlite3'),
  );
}
