import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:ventio_core/ventio_core.dart';

/// Authentication is independent of the untrusted command body.
abstract interface class HostAuthenticator {
  Future<Principal?> authenticate(String token);
}

/// Controlled development identity. Never load these from client command JSON.
class DevelopmentCredential {
  final String tokenDigest;
  final Principal principal;
  final DateTime expiresAt;

  DevelopmentCredential({
    required this.tokenDigest,
    required this.principal,
    required this.expiresAt,
  }) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(tokenDigest) ||
        [
          principal.actorId,
          principal.deviceId,
          principal.tenantId,
          ...principal.companyIds,
          ...principal.branchIds
        ].any((value) => value.trim().isEmpty)) {
      throw ArgumentError('Invalid development credential');
    }
  }

  /// Provision tokens externally using at least 32 cryptographically random bytes.
  static String digest(String token) =>
      sha256.convert(utf8.encode(token)).toString();
}

/// In-memory development credentials only; no login, JWT, or production claims.
/// The HTTP server cannot bind outside loopback, regardless of authenticator.
class DevelopmentTokenAuthenticator implements HostAuthenticator {
  final Map<String, DevelopmentCredential> _credentials;
  final Set<String> _revoked = {};
  final DateTime Function() _clock;

  DevelopmentTokenAuthenticator(Iterable<DevelopmentCredential> credentials,
      {DateTime Function()? clock})
      : _credentials = {},
        _clock = clock ?? DateTime.now {
    for (final credential in credentials) {
      if (_credentials.containsKey(credential.tokenDigest)) {
        throw ArgumentError('Duplicate credential digest');
      }
      _credentials[credential.tokenDigest] = credential;
    }
  }

  void revokeDigest(String digest) => _revoked.add(digest);

  @override
  Future<Principal?> authenticate(String token) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(token)) return null;
    final digest = DevelopmentCredential.digest(token);
    final credential = _credentials[digest];
    if (credential == null ||
        _revoked.contains(digest) ||
        !_clock().toUtc().isBefore(credential.expiresAt.toUtc())) return null;
    return credential.principal;
  }
}
