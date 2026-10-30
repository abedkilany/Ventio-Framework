import 'dart:convert';
import 'dart:io';

import 'package:ventio_core/ventio_core.dart';
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
    final sid = (identity.stdout as String)
        .split(',')
        .last
        .trim()
        .replaceAll('"', '');
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
    final missingPath =
        '${directory.path}${Platform.pathSeparator}missing-private-test.json';
    try {
      await PrivateFiles.read(missingPath);
      throw StateError('Missing protected file was unexpectedly readable');
    } on StateError catch (error) {
      if (!error.toString().contains('(read, helper_rejected)') ||
          error.toString().contains(missingPath)) {
        rethrow;
      }
    }
    await PrivateFiles.verifyPrivateFile(file);
    await PrivateFiles.replace(file, {'token': 'rotated-private-test'});
    final rotated = jsonDecode(await PrivateFiles.read(file)) as Map;
    if (rotated['token'] != 'rotated-private-test') {
      throw StateError('Protected Windows file replacement failed');
    }

    final diagnosticsPath =
        '${directory.path}${Platform.pathSeparator}host-diagnostics.json';
    final diagnosticLog = await ProtectedManagementDiagnosticLog.open(
      diagnosticsPath,
      capacity: 2,
    );
    final diagnostic = ManagementDiagnosticEvent(
      code: 'DATABASE_UNAVAILABLE',
      component: 'host.database',
      category: ManagementDiagnosticCategory.database,
      severity: ManagementDiagnosticSeverity.error,
      occurredAtUtc: DateTime.utc(2026, 10, 30),
      correlationId: 'cor_0123456789abcdef0123456789abcdef',
      retryable: true,
      messageKey: 'native.diagnostics.database_unavailable',
      safeExplanation: 'The Host cannot reach its configured database.',
      recommendedAction: 'Check database service status and retry.',
      protectedTechnicalCode: '08006',
      protectedFailureType: 'SocketException',
      protectedFailureSource: 'PostgresPool.connect',
    );
    await diagnosticLog.record(diagnostic);
    final publicEventJson = jsonEncode(diagnostic.toJson());
    if (publicEventJson.contains('08006') ||
        publicEventJson.contains('SocketException')) {
      throw StateError('Public diagnostic JSON exposed protected details');
    }
    final reopenedLog = await ProtectedManagementDiagnosticLog.open(
      diagnosticsPath,
      capacity: 2,
    );
    if (reopenedLog.recent(limit: 2).single.protectedTechnicalCode != '08006' ||
        reopenedLog.recent(limit: 2).single.protectedFailureType !=
            'SocketException') {
      throw StateError('Protected diagnostic log did not survive reopening');
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
    final ownerWitnessData = await PrivateFiles.readAuthorityAsOwner(
      witness,
      trustedOwnerSid: sid,
      readerSid: readerGroupSid,
    );
    if (!ownerWitnessData.contains('"fingerprint":"test"')) {
      throw StateError('Windows witness owner read failed');
    }
    var wrongWriterRefused = false;
    try {
      await PrivateFiles.readAuthorityAsOwner(
        witness,
        trustedOwnerSid: 'S-1-5-18',
        readerSid: readerGroupSid,
      );
    } on StateError {
      wrongWriterRefused = true;
    }
    if (!wrongWriterRefused) {
      throw StateError('A non-owner Windows Host could write the witness');
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
