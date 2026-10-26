import 'package:postgres/postgres.dart' as pg;

/// Runs one database operation on an owned connection or a bounded pool lease.
/// The callback must finish all connection work before it returns.
Future<T> withPostgresConnection<T>({
  required Future<pg.Connection> Function()? connect,
  required pg.Pool? pool,
  required Future<T> Function(pg.Connection connection) action,
}) async {
  if ((connect == null) == (pool == null)) {
    throw ArgumentError('Provide exactly one PostgreSQL connection source.');
  }
  if (pool != null) return pool.withConnection(action);

  final connection = await connect!();
  try {
    return await action(connection);
  } finally {
    await connection.close();
  }
}
