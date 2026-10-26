import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'extension_store.dart';
import 'local_command_queue.dart';

enum VentioPlatformTarget { windows, android, linux, macos, ios, unsupported }

enum LocalDatabaseBackend { ffi, native }

LocalDatabaseBackend localDatabaseBackendFor(VentioPlatformTarget target) =>
    switch (target) {
      VentioPlatformTarget.android ||
      VentioPlatformTarget.ios => LocalDatabaseBackend.native,
      VentioPlatformTarget.windows ||
      VentioPlatformTarget.linux ||
      VentioPlatformTarget.macos => LocalDatabaseBackend.ffi,
      VentioPlatformTarget.unsupported => throw UnsupportedError(
        'Ventio has no SQLite backend for this target.',
      ),
    };

VentioPlatformTarget _currentPlatformTarget() =>
    switch (Platform.operatingSystem) {
      'windows' => VentioPlatformTarget.windows,
      'android' => VentioPlatformTarget.android,
      'linux' => VentioPlatformTarget.linux,
      'macos' => VentioPlatformTarget.macos,
      'ios' => VentioPlatformTarget.ios,
      _ => VentioPlatformTarget.unsupported,
    };

DatabaseFactory databaseFactoryForCurrentPlatform() {
  return switch (localDatabaseBackendFor(_currentPlatformTarget())) {
    LocalDatabaseBackend.native => sqflite.databaseFactory,
    LocalDatabaseBackend.ffi => _ffiDatabaseFactory(),
  };
}

DatabaseFactory _ffiDatabaseFactory() {
  sqfliteFfiInit();
  return databaseFactoryFfi;
}

Future<LocalCommandQueue> openDefaultCommandQueue() async {
  final directory = await getApplicationSupportDirectory();
  return LocalCommandQueue.open(
    factory: databaseFactoryForCurrentPlatform(),
    path: p.join(directory.path, 'ventio_native_client.sqlite3'),
  );
}

Future<LocalExtensionStore> openDefaultExtensionStore() async {
  final directory = await getApplicationSupportDirectory();
  return LocalExtensionStore.open(
    factory: databaseFactoryForCurrentPlatform(),
    path: p.join(directory.path, 'ventio_extensions.sqlite3'),
  );
}
