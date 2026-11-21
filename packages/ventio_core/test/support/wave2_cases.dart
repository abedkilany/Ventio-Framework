import 'dart:async';
import 'dart:io';

import 'package:ventio_core/ventio_core.dart';

// No tests run on import. Case IDs bind executable assertions to the matrix.
class W2Cases {
  int count = 0;
  Future<void> run(
    String id,
    String capabilities,
    String requirement,
    FutureOr<void> Function() body,
  ) async {
    try {
      await body();
      count++;
      stdout.writeln('PASS $id [$capabilities] $requirement');
    } catch (_) {
      // Never print raw SQL/HTTP errors, tokens, payloads or protected values.
      stderr.writeln('FAIL $id [$capabilities] $requirement');
      rethrow;
    }
  }
}

void w2Expect(bool condition, String explanation) {
  if (!condition) throw StateError(explanation);
}

void w2Equal(Object? actual, Object? expected, String explanation) =>
    w2Expect(canonicalJson(actual) == canonicalJson(expected), explanation);

void w2Contract(void Function() action, {String? code}) {
  ContractError? caught;
  try {
    action();
  } on ContractError catch (error) {
    caught = error;
  }
  w2Expect(
    caught != null && (code == null || caught.code == code),
    'Expected the specified ContractError',
  );
}
