import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Versioned password verifier shared by Host and the protected offline cache.
/// Work is isolated from the native UI and HTTP event loop. Never log inputs.
class AccountPassword {
  static final _shape = RegExp(
    r'^pbkdf2-sha256:600000:[A-Za-z0-9_-]{43}:[A-Za-z0-9_-]{43}$',
  );

  static bool validUsername(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.@-]{2,63}$').hasMatch(value);

  static bool validPassword(String value) =>
      value.runes.length >= 15 && utf8.encode(value).length <= 1024;

  static bool validVerifier(String value) => _shape.hasMatch(value);

  static Future<String> hash(String password) async {
    if (!validPassword(password)) {
      throw ArgumentError(
          'Use a password of at least 15 characters (1024 bytes maximum).');
    }
    final random = Random.secure();
    final salt = List.generate(32, (_) => random.nextInt(256));
    final key = await Isolate.run(() => _derive(password, salt));
    return 'pbkdf2-sha256:600000:${_encode(salt)}:${_encode(key)}';
  }

  static Future<bool> verify(String password, String verifier) async {
    if (!validVerifier(verifier) || utf8.encode(password).length > 1024)
      return false;
    final parts = verifier.split(':');
    final salt = base64Url.decode(base64Url.normalize(parts[2]));
    final expected = base64Url.decode(base64Url.normalize(parts[3]));
    final actual = await Isolate.run(() => _derive(password, salt));
    var difference = actual.length ^ expected.length;
    for (var i = 0; i < actual.length; i++) {
      difference |= actual[i] ^ expected[i];
    }
    return difference == 0;
  }

  static Future<List<int>> _derive(String password, List<int> salt) async =>
      (await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 600000, bits: 256)
              .deriveKey(
                  secretKey: SecretKey(utf8.encode(password)), nonce: salt))
          .extractBytes();

  static String _encode(List<int> value) =>
      base64Url.encode(value).replaceAll('=', '');
}
