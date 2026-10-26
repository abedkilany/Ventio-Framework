import 'package:ventio_postgres/src/migration_runner.dart';

void main() {
  const lf = 'CREATE TABLE example (id integer);\n';
  const crlf = 'CREATE TABLE example (id integer);\r\n';
  const cr = 'CREATE TABLE example (id integer);\r';
  final expected = migrationChecksum(lf);
  if (migrationChecksum(crlf) != expected ||
      migrationChecksum(cr) != expected) {
    throw StateError(
      'Migration checksums must not depend on platform newlines.',
    );
  }
  if (canonicalMigrationSql(crlf) != lf || canonicalMigrationSql(cr) != lf) {
    throw StateError('Migration SQL must be normalized before execution.');
  }
  print(
    'PASS: Migration SQL and checksums are stable across Windows and Unix line endings',
  );
}
