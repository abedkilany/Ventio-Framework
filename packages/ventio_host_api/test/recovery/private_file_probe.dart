// Test-only process used to verify helper timeout cleanup without changing the
// interpreter path or environment of the main integration runner.
import 'dart:io';
import 'package:ventio_host_api/ventio_host_api.dart';

Future<void> main(List<String> args) async {
  try {
    await PrivateFiles.read(args.single);
    exitCode = 3;
  } catch (_) {
    stdout.writeln('EXPECTED_PRIVATE_STORAGE_FAILURE');
  }
}
