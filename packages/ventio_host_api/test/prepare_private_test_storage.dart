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
    try {
      await PrivateFiles.create(probe, {'probe': true});
    } catch (_) {
      // Report only the failed probe's ACL, never its contents.
      final acl = await Process.run(
        'powershell.exe',
        [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'''
$acl = Get-Acl -LiteralPath $env:VENTIO_TEST_PROBE_PATH
$metadata = [ordered]@{
  ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
  expectedOwnerSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  protected = $acl.AreAccessRulesProtected
  rules = @($acl.GetAccessRules($true, $true,
    [System.Security.Principal.SecurityIdentifier]) | ForEach-Object {
      [ordered]@{
        sid = $_.IdentityReference.Value
        rights = [string]$_.FileSystemRights
        inherited = $_.IsInherited
        type = [string]$_.AccessControlType
      }
    })
}
[Console]::Out.WriteLine('VENTIO_TEST_PROBE_ACL:' +
  (ConvertTo-Json -InputObject $metadata -Depth 4 -Compress))
''',
        ],
        environment: {'VENTIO_TEST_PROBE_PATH': probe},
      );
      for (final line in const LineSplitter().convert(acl.stdout as String)) {
        if (line.startsWith('VENTIO_TEST_PROBE_ACL:')) stdout.writeln(line);
      }
      rethrow;
    }
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
