import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Contains only bounded classifications. The exception text never includes
/// paths, file contents, interpreter stderr, SQL or credentials.
class WindowsPrivateFileFailure extends StateError {
  WindowsPrivateFileFailure(
    this.operation,
    this.phase, {
    this.helperStage,
    this.helperType,
    this.helperCode,
  }) : super('Protected file operation failed ($operation, $phase)');
  final String operation;
  final String phase;
  final String? helperStage;
  final String? helperType;
  final String? helperCode;
}

/// Native Windows ACL-backed counterpart to the Linux private-file helper.
/// Request data, including secrets, is sent over stdin rather than argv.
class WindowsPrivateFiles {
  static Future<String> run(
    String operation,
    String path,
    String data, {
    String? ownerSid,
    String? readerSid,
  }) async {
    // Installed AOT executables and their as-invoker native helper share the
    // protected payload directory. Test runners may supply a built helper only
    // inside an explicitly admitted disposable GitHub-hosted job.
    final fixtureHelper =
        Platform.environment['VENTIO_WINDOWS_PRIVATE_FILE_HELPER'];
    if (fixtureHelper != null &&
        (Platform.environment['GITHUB_ACTIONS'] != 'true' ||
            Platform.environment['RUNNER_ENVIRONMENT'] != 'github-hosted')) {
      throw StateError(
        'Private-file fixture helper is restricted to hosted tests',
      );
    }
    final helper = File(
      fixtureHelper ??
          '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}VentioHostService.exe',
    );
    if (!helper.isAbsolute ||
        await FileSystemEntity.type(helper.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw StateError('Windows private-file runtime is unavailable');
    }
    Process? process;
    Future<List<int>>? stdout;
    Future<String>? stderr;
    var phase = 'start';
    String? helperStage;
    String? helperType;
    String? helperCode;
    try {
      process = await Process.start(helper.path, ['--private-file-operation']);
      stdout = process.stdout.fold<List<int>>(<int>[], (bytes, chunk) {
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          throw const FormatException('Protected file output too large');
        }
        bytes.addAll(chunk);
        return bytes;
      });
      stderr = process.stderr.transform(utf8.decoder).join();
      phase = 'send_request';
      process.stdin.write(
        jsonEncode({
          'operation': operation,
          'path': path,
          'ownerSid': ownerSid,
          'readerSid': readerSid,
          'data': data,
        }),
      );
      phase = 'close_request';
      await process.stdin.close().timeout(const Duration(seconds: 10));
      phase = 'wait_for_helper';
      final code = await process.exitCode.timeout(const Duration(seconds: 10));
      phase = 'collect_output';
      final helperStderr = await stderr;
      final result = utf8.decode(await stdout);
      if (code != 0) {
        phase = 'helper_rejected';
        final diagnostic = RegExp(
          r'VENTIO_PRIVATE_HELPER_FAILURE:([A-Za-z_]{1,64}):([A-Za-z]{1,64}):(0x[0-9A-Fa-f]{8})',
        ).firstMatch('$helperStderr\n$result');
        helperStage = diagnostic?.group(1);
        helperType = diagnostic?.group(2);
        helperCode = diagnostic?.group(3);
        if (Platform.environment['VENTIO_PRIVATE_FILES_DIAGNOSTICS'] == '1') {
          if (diagnostic != null) {
            print(
              'Windows private-file helper: ${diagnostic[1]} '
              '${diagnostic[2]} ${diagnostic[3]}',
            );
          }
        }
        throw StateError('Protected file operation failed');
      }
      if (operation == 'read' || operation.startsWith('witness-read')) {
        return utf8.decode(base64Decode(result.trim()));
      }
      return result;
    } catch (error) {
      if (phase == 'start' &&
          Platform.environment['VENTIO_PRIVATE_FILES_DIAGNOSTICS'] == '1') {
        final detail = error is ProcessException
            ? 'ProcessException ${error.errorCode}'
            : error.runtimeType.toString();
        print('Windows private-file process start: $detail');
      }
      final child = process;
      if (child != null) {
        child.kill();
        try {
          await child.exitCode.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          // Do not delay reporting a private-file helper failure indefinitely.
        }
      }
      try {
        await stderr!;
        await stdout!;
      } catch (_) {
        // Drain failures are deliberately excluded from public error text.
      }
      throw WindowsPrivateFileFailure(
        operation,
        phase,
        helperStage: helperStage,
        helperType: helperType,
        helperCode: helperCode,
      );
    }
  }
}
