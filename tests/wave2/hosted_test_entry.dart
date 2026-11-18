// Reuse the existing CI token-owner scope without changing privileges or policy.
import 'dart:io';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows ||
      Platform.environment['GITHUB_ACTIONS'] != 'true' ||
      Platform.environment['RUNNER_ENVIRONMENT'] != 'github-hosted' ||
      args.length != 1 ||
      !{'windows', 'windows-recovery', 'desktop'}.contains(args.single)) {
    throw StateError('Approved hosted Windows fixture entry only');
  }
  final process = await Process.start(
    'python.exe',
    ['tests/wave2/run_hosted_tests.py', args.single],
    mode: ProcessStartMode.inheritStdio,
  );
  exit(await process.exitCode);
}
