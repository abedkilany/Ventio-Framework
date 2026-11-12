import 'dart:convert';
import 'dart:io';

import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart';

/// Provision CI-only storage and validate it through the production ACL helper.
Future<void> main() async {
  if (!Platform.isWindows) {
    throw UnsupportedError('Windows private test storage requires Windows.');
  }
  final profilePath = Platform.environment['USERPROFILE'];
  final environmentFile = Platform.environment['GITHUB_ENV'];
  if (profilePath == null ||
      !Directory(profilePath).isAbsolute ||
      !Directory(profilePath).existsSync() ||
      environmentFile == null) {
    throw StateError('GitHub Windows test storage context is unavailable.');
  }

  final root = await Directory(profilePath).createTemp('ventio-ci-private-');
  var ready = false;
  try {
    await setPrivateWindowsDirectoryAcl(root, await currentWindowsSid());
    final probe = '${root.path}${Platform.pathSeparator}storage-probe.json';
    await PrivateFiles.create(probe, {'probe': true});
    final readback = jsonDecode(await PrivateFiles.read(probe)) as Map;
    if (readback['probe'] != true) {
      throw StateError('Private test storage round-trip failed.');
    }
    await PrivateFiles.verifyPrivateFile(probe);
    await File(probe).delete();
    await File(environmentFile).writeAsString(
      'VENTIO_TEST_PRIVATE_ROOT=${root.path}\n',
      mode: FileMode.append,
      flush: true,
    );
    ready = true;
    stdout.writeln(
      'PASS: CI private test storage passed production ancestor and file ACL checks',
    );
  } finally {
    if (!ready) await root.delete(recursive: true);
  }
}
