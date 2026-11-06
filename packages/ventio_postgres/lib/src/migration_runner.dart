import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;

/// Migration identity is independent of checkout line endings on each OS.
String canonicalMigrationSql(String source) =>
    source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

String migrationChecksum(String source) =>
    sha256.convert(utf8.encode(canonicalMigrationSql(source))).toString();

const _legacyMigrationChecksums = <String, Set<String>>{
  '026_identity_pairing.sql': {
    'af5f7a72fd9affc38c1ead156ca607dd89308998035985fa0259ae4e2cf39421',
  },
  '027_identity_pairings.sql': {
    'a7ef70e7f6ea623e39dd668b5506bc5a1ddd641a0fee8d99aba2f9273541c9c6',
  },
  '028_identity_pairing_rate_index.sql': {
    '6c975a92942a3e53abe50da9441f94b9fb7b68f2bda5932792c610814dcd6f68',
  },
};

/// Recognize the published hashes of the original pairing migrations so hosts
/// that applied those statements through an earlier deployment process can
/// upgrade without rewriting their migration ledger.
bool migrationChecksumIsAccepted({
  required String filename,
  required String appliedChecksum,
  required String currentChecksum,
}) =>
    appliedChecksum == currentChecksum ||
    (_legacyMigrationChecksums[filename]?.contains(appliedChecksum) ?? false);

/// Only application-owned, vetted .sql files are accepted as migrations.
/// Each file contains precisely ONE SQL statement; never user-provided SQL.
class PostgresMigrationRunner {
  final pg.Connection connection;
  final Directory migrationsDirectory;

  PostgresMigrationRunner(this.connection, this.migrationsDirectory);

  Future<List<String>> apply() async {
    return connection.runTx((tx) => applyInTransaction(tx));
  }

  /// Applies the vetted migration batch inside a caller-owned transaction.
  /// Recovery-aware Host upgrades use this to make the migration ledger and
  /// schema changes atomic with the independent Recovery Authority protocol.
  Future<List<String>> applyInTransaction(pg.Session tx) async {
    if (!await migrationsDirectory.exists()) {
      throw StateError(
        'Migration directory is missing: ${migrationsDirectory.path}',
      );
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
    final sources = <String, String>{};
    final checksums = <String, String>{};
    final versions = <String>{};
    for (final file in files) {
      final filename = _filename(file);
      if (!RegExp(r'^[0-9]{3}_[a-z0-9_]+\.sql$').hasMatch(filename) ||
          !versions.add(filename.substring(0, 3))) {
        throw StateError('Invalid or duplicate migration version: $filename');
      }
      final sql = canonicalMigrationSql(await file.readAsString());
      if (sql.trim().isEmpty) throw StateError('Empty migration: $filename');
      sources[filename] = sql;
      checksums[filename] = migrationChecksum(sql);
    }
    final applied = <String>[];
    // One lock and transaction span preflight AND the entire vetted batch.
    // An older checkout cannot silently accept a newer/missing ledger entry;
    // a later SQL failure cannot leave earlier new migrations committed.
    await tx.execute('SELECT pg_advisory_xact_lock(726341, 1)');
    await tx.execute('''CREATE TABLE IF NOT EXISTS ventio_schema_migrations (
        name text PRIMARY KEY, sha256 text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now()
      )''');
    final ledger = await tx.execute(
      'SELECT name,sha256 FROM ventio_schema_migrations ORDER BY name',
    );
    final known = <String>{};
    for (final row in ledger) {
      final name = row[0] as String;
      if (!checksums.containsKey(name) ||
          !migrationChecksumIsAccepted(
            filename: name,
            appliedChecksum: row[1] as String,
            currentChecksum: checksums[name]!,
          )) {
        throw StateError(
          'Missing, unknown or modified applied migration: $name',
        );
      }
      known.add(name);
    }
    for (final entry in sources.entries) {
      if (known.contains(entry.key)) continue;
      await tx.execute(entry.value);
      await tx.execute(
        pg.Sql.named('''INSERT INTO ventio_schema_migrations(name,sha256)
          VALUES (@name,@checksum)'''),
        parameters: {'name': entry.key, 'checksum': checksums[entry.key]},
      );
      applied.add(entry.key);
    }
    return applied;
  }

  String _filename(File f) => f.uri.pathSegments.last;
}
