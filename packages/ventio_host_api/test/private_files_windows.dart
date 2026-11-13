import 'dart:convert';
import 'dart:io';

import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'test_support.dart'
    show
        createPrivateTestDirectory,
        currentWindowsSid,
        setPrivateWindowsDirectoryAcl;

Future<void> main() async {
  if (!Platform.isWindows) {
    stdout.writeln('SKIP: Windows private-file integration test');
    return;
  }

  final directory = await createPrivateTestDirectory('ventio-private-');
  try {
    final sid = await currentWindowsSid();
    const readerGroupSid = 'S-1-5-11';
    final file = '${directory.path}${Platform.pathSeparator}secret.json';
    await PrivateFiles.create(file, {'token': 'windows-private-test'});
    final initial = jsonDecode(await PrivateFiles.read(file)) as Map;
    if (initial['token'] != 'windows-private-test') {
      throw StateError('Protected Windows file round-trip failed');
    }
    final injectionMarker =
        '${directory.path}${Platform.pathSeparator}injection-marker.txt';
    final escapedMarker = injectionMarker.replaceAll("'", "''");
    final injectionPayload =
        "'; [System.IO.File]::WriteAllText('$escapedMarker', 'injected'); #";
    final injectionFile =
        '${directory.path}${Platform.pathSeparator}untrusted-payload.json';
    await PrivateFiles.create(injectionFile, {'payload': injectionPayload});
    final injectionRoundTrip =
        jsonDecode(await PrivateFiles.read(injectionFile)) as Map;
    if (injectionRoundTrip['payload'] != injectionPayload ||
        File(injectionMarker).existsSync()) {
      throw StateError('Untrusted private-file payload was interpreted as PowerShell');
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
    final inaccessiblePath =
        '${directory.path}${Platform.pathSeparator}inaccessible-diagnostics.json';
    await PrivateFiles.create(inaccessiblePath, {
      'formatVersion': 1,
      'events': const <Object?>[],
    });
    final denyRead = await Process.run('icacls.exe', [
      inaccessiblePath,
      '/deny',
      '*$sid:(R)',
    ]);
    if (denyRead.exitCode != 0) {
      throw StateError('Could not prepare the isolated inaccessible-log case');
    }
    try {
      Object? inaccessibleFailure;
      try {
        await ProtectedManagementDiagnosticLog.open(inaccessiblePath);
      } on Object catch (error) {
        inaccessibleFailure = error;
      }
      final inaccessibleFailureText = inaccessibleFailure?.toString() ?? '';
      if (inaccessibleFailure == null ||
          inaccessibleFailureText.contains(inaccessiblePath) ||
          inaccessibleFailureText.contains('windows-private-test')) {
        throw StateError(
          'An inaccessible protected diagnostic log was accepted or leaked its path (failure=${inaccessibleFailure?.runtimeType ?? 'none'}, pathLeaked=${inaccessibleFailureText.contains(inaccessiblePath)})',
        );
      }
    } finally {
      final restoreAcl = await Process.run('icacls.exe', [
        inaccessiblePath,
        '/remove:d',
        '*$sid',
      ]);
      if (restoreAcl.exitCode != 0) {
        throw StateError('Could not restore the isolated diagnostics test ACL');
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
    final childDiagnosticPath =
        '${directory.path}${Platform.pathSeparator}child-host-diagnostics.json';
    final childWriter = await Process.run(Platform.resolvedExecutable, [
      'run',
      'test/recovery/diagnostic_log_probe.dart',
      childDiagnosticPath,
    ]).timeout(const Duration(seconds: 30));
    if (childWriter.exitCode != 0 ||
        !(childWriter.stdout as String).contains(
          'DIAGNOSTIC_EVENT_PERSISTED',
        )) {
      throw StateError(
        'Child-process protected diagnostic persistence failed safely.',
      );
    }
    final childLog = await ProtectedManagementDiagnosticLog.open(
      childDiagnosticPath,
      capacity: 2,
    );
    if (childLog.recent(limit: 2).single.protectedTechnicalCode != '08006') {
      throw StateError('Child-process diagnostic event was not persisted.');
    }
    final witnessDirectory = Directory(
      directory.path + Platform.pathSeparator + 'authority',
    );
    await witnessDirectory.create();
    await setPrivateWindowsDirectoryAcl(
      witnessDirectory,
      sid,
      readerSid: readerGroupSid,
    );

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
    // A protected child must still be refused when an ancestor grants deletion
    // rights to an untrusted principal. A private child ACL cannot fix its parent.
    final unsafeAncestor = await Directory(
      '${directory.path}${Platform.pathSeparator}unsafe-ancestor',
    ).create();
    await setPrivateWindowsDirectoryAcl(unsafeAncestor, sid);
    final protectedChild = await Directory(
      '${unsafeAncestor.path}${Platform.pathSeparator}protected-child',
    ).create();
    await setPrivateWindowsDirectoryAcl(protectedChild, sid);
    final grantDeleteChild = await Process.run('icacls.exe', [
      unsafeAncestor.path,
      '/grant',
      '*S-1-5-11:(DC)',
    ]);
    if (grantDeleteChild.exitCode != 0) {
      throw StateError('Could not prepare the unsafe ancestor ACL case.');
    }
    try {
      final refusedPath =
          '${protectedChild.path}${Platform.pathSeparator}must-not-exist.json';
      var unsafeAncestorRefused = false;
      try {
        await PrivateFiles.create(refusedPath, {'probe': 'must-not-write'});
      } on StateError {
        unsafeAncestorRefused = true;
      }
      if (!unsafeAncestorRefused || await File(refusedPath).exists()) {
        throw StateError(
          'An ancestor with untrusted delete-child access was accepted.',
        );
      }
      stdout.writeln('PASS: Untrusted ancestor delete-child access is refused');
    } finally {
      await setPrivateWindowsDirectoryAcl(unsafeAncestor, sid);
    }

    stdout.writeln('PASS: Windows ACL-backed private-file operations');
  } finally {
    await directory.delete(recursive: true);
  }
}
