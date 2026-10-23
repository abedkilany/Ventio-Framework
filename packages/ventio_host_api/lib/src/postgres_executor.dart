import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host/ventio_host.dart';

import 'host_api.dart';
import 'authentication.dart';

/// One owned connection per command, bounded by HostApi admission limits.
/// Pooling and production authorization persistence remain separate work.
class PostgresCommandExecutor implements CommandExecutor {
  final Future<pg.Connection> Function() connect;
  final ModuleRegistry modules;
  final DocTypeRegistry docTypes;
  final List<TrustedCommandBinding> bindings;

  PostgresCommandExecutor({
    required this.connect,
    required this.modules,
    required this.docTypes,
    required Iterable<TrustedCommandBinding> bindings,
  }) : bindings = List.unmodifiable(bindings);

  @override
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    AuthenticatedSession session,
  ) async {
    // Persistent credentials must never fall back to a snapshot-based executor.
    if (session.credentialDigest != null) {
      throw StateError('Persistent session requires PersistentCommandExecutor');
    }
    final principal = session.principal;
    final connection = await connect();
    try {
      await connection.execute("SET statement_timeout = '15s'");
      await connection.execute("SET lock_timeout = '5s'");
      final host = DurableCommandHost(
        connection: connection,
        modules: modules,
        docTypes: docTypes,
      );
      for (final binding in bindings) {
        host.registerTrustedCreateBinding(binding);
      }
      return await host.execute(command, principal);
    } finally {
      await connection.close();
    }
  }
}
