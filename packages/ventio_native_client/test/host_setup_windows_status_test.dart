import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/host_setup.dart';
import 'package:ventio_native_client/src/host_setup_windows.dart';

void main() {
  test('Windows can query Ventio service status without elevation', () async {
    if (!Platform.isWindows) return;

    final platform = WindowsHostSetupPlatform();
    final postgres = await platform.serviceState('VentioPostgres');
    final host = await platform.serviceState('VentioHost');

    expect(postgres, isNot(HostWindowsServiceState.unknown));
    expect(host, isNot(HostWindowsServiceState.unknown));
  });
}
