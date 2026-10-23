import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_postgres/ventio_postgres.dart';

Future<void> main() async {
  final url = Platform.environment['VENTIO_DATABASE_URL'];
  if (url == null || url.isEmpty) {
    stderr.writeln('VENTIO_DATABASE_URL is required');
    exitCode = 2;
    return;
  }
  final dir = Directory(Platform.environment['VENTIO_MIGRATIONS_DIR'] ??
      '../../migrations/postgres');
  final conn = await pg.Connection.openFromUrl(url);
  try {
    final applied = await PostgresMigrationRunner(conn, dir).apply();
    stdout.writeln(
        'Applied ${applied.length} migration(s): ${applied.join(', ')}');
  } finally {
    await conn.close();
  }
}
