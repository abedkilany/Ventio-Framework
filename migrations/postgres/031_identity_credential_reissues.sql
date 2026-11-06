CREATE TABLE ventio_identity_credential_reissues (
  operation_id text PRIMARY KEY CHECK (operation_id ~ '^reissue_[0-9a-f]{32}$'),
  tenant_id text NOT NULL,
  actor_id text NOT NULL,
  device_id text NOT NULL,
  company_id text NOT NULL,
  branch_id text NOT NULL,
  operator_actor_id text NOT NULL,
  source_credential_id text NOT NULL,
  replacement_credential_id text NOT NULL,
  replacement_token_digest text NOT NULL UNIQUE
    CHECK (replacement_token_digest ~ '^[0-9a-f]{64}$'),
  allowed_permissions text[] NOT NULL
    CHECK (cardinality(allowed_permissions) BETWEEN 1 AND 128),
  approved_removals text[] NOT NULL DEFAULT '{}',
  delivery_ciphertext bytea
    CHECK (octet_length(delivery_ciphertext) BETWEEN 1 AND 8192),
  state text NOT NULL DEFAULT 'PREPARED'
    CHECK (state IN ('PREPARED','FINALIZED','EXPIRED','REJECTED')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL,
  finalized_at timestamptz,
  FOREIGN KEY (tenant_id, device_id, actor_id)
    REFERENCES ventio_identity_devices (tenant_id, device_id, actor_id),
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '20 minutes'),
  CHECK ((state = 'FINALIZED') = (finalized_at IS NOT NULL)),
  CHECK ((state = 'PREPARED') = (delivery_ciphertext IS NOT NULL))
);
