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
  const legacyChecksums = {
    '026_identity_pairing.sql': (
      'af5f7a72fd9affc38c1ead156ca607dd89308998035985fa0259ae4e2cf39421',
      '2f2a71d5086622d4f7fad971e1f7c3404d05e8e5705cc48e418b6c3f34eaa7df',
    ),
    '027_identity_pairings.sql': (
      'a7ef70e7f6ea623e39dd668b5506bc5a1ddd641a0fee8d99aba2f9273541c9c6',
      '568eb70d6cb2e961da4d4e12e9e6b29764aebda5f1ac7e3acf574a79e677f046',
    ),
    '028_identity_pairing_rate_index.sql': (
      '6c975a92942a3e53abe50da9441f94b9fb7b68f2bda5932792c610814dcd6f68',
      '42b3a71d92420deb65be566c67d1b8d04d8ed47bfd55b20d0cb0928183eb7ace',
    ),
  };
  if (legacyChecksums.entries.any(
        (entry) => !migrationChecksumIsAccepted(
          filename: entry.key,
          appliedChecksum: entry.value.$1,
          currentChecksum: entry.value.$2,
        ),
      ) ||
      migrationChecksumIsAccepted(
        filename: '026_identity_pairing.sql',
        appliedChecksum: 'not-a-published-checksum',
        currentChecksum:
            '2f2a71d5086622d4f7fad971e1f7c3404d05e8e5705cc48e418b6c3f34eaa7df',
      )) {
    throw StateError(
      'Only explicitly published legacy migration checksums are accepted.',
    );
  }
  print(
    'PASS: Migration SQL and checksums are stable across Windows and Unix line endings',
  );
}
