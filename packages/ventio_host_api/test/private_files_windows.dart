import 'dart:convert';
import 'dart:io';

import 'package:ventio_host_api/ventio_host_api.dart';

Future<void> main() async {
  if (!Platform.isWindows) {
    stdout.writeln('SKIP: Windows private-file integration test');
    return;
  }

  final userProfile = Platform.environment['USERPROFILE'];
  if (userProfile == null || !Directory(userProfile).existsSync()) {
    throw StateError('A Windows user profile directory is unavailable');
  }
  final directory = Directory(
    userProfile +
        Platform.pathSeparator +
        'ventio-private-$pid-' +
        DateTime.now().microsecondsSinceEpoch.toString(),
  );
  await directory.create();
  try {
    final identity = await Process.run('whoami.exe', [
      '/user',
      '/fo',
      'csv',
      '/nh',
    ]);
    if (identity.exitCode != 0) throw StateError('Cannot resolve current SID');
    final sid = (identity.stdout as String).split(',').last.trim().replaceAll(
          '"',
          '',
        );
    if (!RegExp(r'^S-1-\d+(?:-\d+)+$').hasMatch(sid)) {
      throw StateError('Windows returned an invalid current SID');
    }
    const readerGroupSid = 'S-1-5-11';
    final acl = await Process.run('icacls.exe', [
      directory.path,
      '/inheritance:r',
      '/grant:r',
      '*$sid:(OI)(CI)F',
      '*S-1-5-18:(OI)(CI)F',
      '*S-1-5-32-544:(OI)(CI)F',
    ]);
    if (acl.exitCode != 0)
      throw StateError('Cannot prepare a protected test directory');

    final file = '${directory.path}${Platform.pathSeparator}secret.json';
    await PrivateFiles.create(file, {'token': 'windows-private-test'});
    final initial = jsonDecode(await PrivateFiles.read(file)) as Map;
    if (initial['token'] != 'windows-private-test') {
      throw StateError('Protected Windows file round-trip failed');
    }
    await PrivateFiles.verifyPrivateFile(file);
    await PrivateFiles.replace(file, {'token': 'rotated-private-test'});
    final rotated = jsonDecode(await PrivateFiles.read(file)) as Map;
    if (rotated['token'] != 'rotated-private-test') {
      throw StateError('Protected Windows file replacement failed');
    }

    final witnessDirectory = Directory(
      directory.path + Platform.pathSeparator + 'authority',
    );
    await witnessDirectory.create();
    final witnessAcl = await Process.run('icacls.exe', [
      witnessDirectory.path,
      '/inheritance:r',
      '/grant:r',
      '*$sid:(OI)(CI)F',
      '*S-1-5-18:(OI)(CI)F',
      '*S-1-5-32-544:(OI)(CI)F',
      '*$readerGroupSid:(OI)(CI)RX',
    ]);
    if (witnessAcl.exitCode != 0) {
      throw StateError('Cannot prepare a protected witness directory');
    }

    final witness =
        witnessDirectory.path + Platform.pathSeparator + 'authority.json';
    await PrivateFiles.createAuthority(
      witness,
      {'version': 1, 'pending': false, 'fingerprint': 'test'},
      -1,
      readerSid: readerGroupSid,
    );
    final witnessData = await PrivateFiles.readAuthority(
      witness,
      readerSid: readerGroupSid,
    );
    if (!witnessData.contains('"fingerprint":"test"')) {
      throw StateError('Windows authority witness round-trip failed');
    }
    await PrivateFiles.replaceAuthority(
      witness,
      {'version': 1, 'pending': false, 'fingerprint': 'rotated'},
      -1,
      readerSid: readerGroupSid,
    );
    var wrongOwnerRefused = false;
    try {
      await PrivateFiles.readAuthority(
        witness,
        trustedOwnerSid: 'S-1-5-18',
        readerSid: readerGroupSid,
      );
    } on StateError {
      wrongOwnerRefused = true;
    }
    if (!wrongOwnerRefused) {
      throw StateError('A mismatched Windows witness owner was accepted');
    }
    var nonMemberRefused = false;
    try {
      await PrivateFiles.readAuthority(
        witness,
        trustedOwnerSid: 'S-1-5-18',
        readerSid: 'S-1-5-99',
      );
    } on StateError {
      nonMemberRefused = true;
    }
    if (!nonMemberRefused) {
      throw StateError('A Windows Host outside the reader group was accepted');
    }

    final inherited = await Directory(
      '${directory.path}${Platform.pathSeparator}inherited',
    ).create();
    var unsafeDirectoryRefused = false;
    try {
      await PrivateFiles.create(
        '${inherited.path}${Platform.pathSeparator}secret.json',
        {'token': 'must-not-write'},
      );
    } on StateError {
      unsafeDirectoryRefused = true;
    }
    if (!unsafeDirectoryRefused) {
      throw StateError('An inherited, unprotected directory was accepted');
    }
    stdout.writeln('PASS: Windows ACL-backed private-file operations');
  } finally {
    await directory.delete(recursive: true);
  }
}
