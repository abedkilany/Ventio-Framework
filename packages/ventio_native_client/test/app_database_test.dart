import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/app_database.dart';

void main() {
  group('local database backend selection', () {
    test('uses SQLite FFI for Windows and additional desktop platforms', () {
      for (final target in [
        VentioPlatformTarget.windows,
        VentioPlatformTarget.linux,
        VentioPlatformTarget.macos,
      ]) {
        expect(
          localDatabaseBackendFor(target),
          LocalDatabaseBackend.ffi,
          reason: '$target must use the desktop FFI backend',
        );
      }
    });

    test('uses platform SQLite on Android and iOS', () {
      for (final target in [
        VentioPlatformTarget.android,
        VentioPlatformTarget.ios,
      ]) {
        expect(
          localDatabaseBackendFor(target),
          LocalDatabaseBackend.native,
          reason: '$target must use its native SQLite plugin',
        );
      }
    });

    test('fails closed for targets without a supported SQLite backend', () {
      expect(
        () => localDatabaseBackendFor(VentioPlatformTarget.unsupported),
        throwsUnsupportedError,
      );
    });
  });
}
