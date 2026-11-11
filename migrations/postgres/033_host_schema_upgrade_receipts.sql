-- Durable commit evidence for a Recovery Authority-coordinated Host schema
-- upgrade. Receipts contain no identity or credential material and are
-- intentionally excluded from recovery_fingerprint(): they attest to one
-- already-fingerprinted migration batch so a pending independent witness can
-- distinguish a committed upgrade from an interrupted transaction.
-- Security ownership and forced RLS are applied by bootstrap.sql on fresh
-- installs and schema_profile.sql on upgrades, after Ventio roles exist.
CREATE TABLE public.host_schema_upgrade_receipts (
  operation_id text PRIMARY KEY
    CHECK (operation_id ~ '^upgrade_[0-9a-f]{32}$'),
  prior_fingerprint text NOT NULL CHECK (prior_fingerprint ~ '^[0-9a-f]{64}$'),
  resulting_fingerprint text NOT NULL CHECK (resulting_fingerprint ~ '^[0-9a-f]{64}$'),
  migration_manifest_sha256 text NOT NULL
    CHECK (migration_manifest_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
