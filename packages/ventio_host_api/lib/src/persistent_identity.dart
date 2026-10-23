import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host/ventio_host.dart';

import 'authentication.dart';
import 'host_api.dart';
import 'identity_store.dart';

/// Refuses owners, superusers, bypass roles, extra memberships and excess ACLs.
Future<void> verifyRuntimeConnection(pg.Connection connection) async {
  await connection.execute('SELECT ventio_security.assert_runtime()');
}

Future<void> _configure(pg.Connection connection) async {
  await verifyRuntimeConnection(connection);
  await connection.execute("SET statement_timeout = '15s'");
  await connection.execute("SET lock_timeout = '5s'");
}

/// Resolves an opaque token from PostgreSQL on EVERY HTTP request. There is no
/// in-memory permission cache or development-identity fallback on DB failure.
class PersistentTokenAuthenticator implements HostAuthenticator {
  final Future<pg.Connection> Function() connect;
  const PersistentTokenAuthenticator({required this.connect});

  @override
  Future<AuthenticatedSession?> authenticate(String token) async {
    if (!OpaqueToken.isValid(token)) return null;
    final digest = OpaqueToken.digest(token);
    final connection = await connect();
    try {
      await _configure(connection);
      final principal = await connection.runTx(
          (tx) => const PostgresIdentityStore().resolve(tx, digest),
          settings: pg.TransactionSettings(
              isolationLevel: pg.IsolationLevel.readCommitted));
      if (principal == null) return null;
      return AuthenticatedSession.persistent(principal, digest);
    } finally {
      await connection.close();
    }
  }
}

/// Identity and permissions are re-read and locked INSIDE the command's own
/// transaction, before journal access. This closes the authentication-to-command
/// race and applies equally to fresh commands and accepted-receipt retries.
class PersistentCommandExecutor implements CommandExecutor {
  final Future<pg.Connection> Function() connect;
  final ModuleRegistry modules;
  final DocTypeRegistry docTypes;
  final List<TrustedCommandBinding> bindings;

  PersistentCommandExecutor(
      {required this.connect,
      required this.modules,
      required this.docTypes,
      required Iterable<TrustedCommandBinding> bindings})
      : bindings = List.unmodifiable(bindings);

  @override
  Future<Map<String, dynamic>> execute(
      CommandEnvelope command, AuthenticatedSession session) async {
    final digest = session.credentialDigest;
    if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      return CommandReceipt(
              commandId: command.commandId,
              status: 'REJECTED',
              reasonCode: 'AUTHENTICATION_REQUIRED')
          .toJson();
    }
    final connection = await connect();
    try {
      await _configure(connection);
      final host = DurableCommandHost(
          connection: connection, modules: modules, docTypes: docTypes);
      for (final binding in bindings) {
        host.registerTrustedCreateBinding(binding);
      }
      return await host.executeAuthorized(
          command,
          (tx) => const PostgresIdentityStore()
              .resolve(tx, digest, command: command));
    } finally {
      await connection.close();
    }
  }
}
