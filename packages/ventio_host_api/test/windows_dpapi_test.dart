import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/src/windows_dpapi.dart';

Future<void> main() async {
  if (!Platform.isWindows) {
    stdout.writeln('SKIP: Windows DPAPI integration requires Windows.');
    return;
  }
  const operationId = 'reissue_0123456789abcdef0123456789abcdef';
  final clear = Uint8List.fromList(utf8.encode('disposable-test-token-value'));
  final cipher = const WindowsDpapi();
  final protected = cipher.protect(clear, operationId);
  if (protected.isEmpty || protected.length == clear.length) {
    throw StateError('DPAPI did not produce an encrypted test envelope.');
  }
  final restored = cipher.unprotect(protected, operationId);
  if (base64.encode(restored) != base64.encode(clear)) {
    throw StateError('DPAPI round trip did not preserve the test bytes.');
  }
  var wrongEntropyRejected = false;
  try {
    cipher.unprotect(protected, 'reissue_ffffffffffffffffffffffffffffffff');
  } on StateError {
    wrongEntropyRejected = true;
  }
  if (!wrongEntropyRejected) {
    throw StateError(
      'DPAPI accepted a credential envelope with wrong entropy.',
    );
  }
  clear.fillRange(0, clear.length, 0);
  restored.fillRange(0, restored.length, 0);
  protected.fillRange(0, protected.length, 0);
  stdout.writeln(
    'PASS: Windows DPAPI protects, restores, and entropy-binds the test envelope.',
  );
}
