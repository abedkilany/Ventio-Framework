import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;

/// Only application-owned, vetted .sql files are accepted as migrations.
/// Each file contains precisely ONE SQL statement; never user-provided SQL.
class PostgresMigrationRunner {
  final pg.Connection connection;
  final Directory migrationsDirectory;

  PostgresMigrationRunner(this.connection, this.migrationsDirectory);

  Future<List<String>> apply() async {
    if (!await migrationsDirectory.exists()) {
      throw StateError(
          'Migration directory is missing: ${migrationsDirectory.path}');
    }
    final files = await migrationsDirectory
        .list(followLinks: false)
        .where((e) => e is File && e.path.endsWith('.sql'))
        .cast<File>()
        .toList();
    files.sort((a, b) => _filename(a).compareTo(_filename(b)));
    if (files.isEmpty) throw StateError('No migration files were found');
    if (files.map(_filename).toSet().length != files.length) {
      throw StateError('Duplicate migration filenames');
    }
    final applied = <String>[];
    for (final file in files) {
      final filename = _filename(file);
      if (!RegExp(r'^[0-9]{3}_[a-z0-9_]+\.sql$').hasMatch(filename)) {
        throw StateError('Invalid migration filename: $filename');
      }
      final sql = await file.readAsString();
      if (sql.trim().isEmpty) throw StateError('Empty migration: $filename');
      final checksum = sha256.convert(utf8.encode(sql)).toString();
      await connection.runTx((tx) async {
        // Serialize concurrent migrators and protect the check/insert pair.
        await tx.execute('SELECT pg_advisory_xact_lock(726341, 1)');
        await tx
            .execute('''CREATE TABLE IF NOT EXISTS ventio_schema_migrations (
          name text PRIMARY KEY,
          sha256 text NOT NULL,
          applied_at timestamptz NOT NULL DEFAULT now()
        )''');
        final existing = await tx.execute(
            pg.Sql.named(
                'SELECT sha256 FROM ventio_schema_migrations WHERE name = @name'),
            parameters: {'name': filename});
        if (existing.isNotEmpty) {
          if (existing.first.toColumnMap()['sha256'] != checksum) {
            throw StateError('Migration checksum mismatch: $filename');
          }
          return;
        }
        // Single-statement files avoid unsafe homegrown SQL splitting.
        await tx.execute(sql);
        await tx.execute(pg.Sql.named('''INSERT INTO ventio_schema_migrations
          (name, sha256) VALUES (@name, @checksum)'''),
            parameters: {'name': filename, 'checksum': checksum});
        applied.add(filename);
      });
    }
    return applied;
  }

  String _filename(File f) => f.uri.pathSegments.last;
}
