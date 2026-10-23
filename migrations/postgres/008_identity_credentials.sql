CREATE TABLE ventio_identity_credentials (
  token_digest text PRIMARY KEY CHECK (token_digest ~ '^[0-9a-f]{64}$'),
  tenant_id text NOT NULL,
  credential_id text NOT NULL CHECK (length(trim(credential_id)) BETWEEN 1 AND 256),
  actor_id text NOT NULL,
  device_id text NOT NULL,
  issued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL CHECK (isfinite(expires_at)),
  revoked_at timestamptz,
  UNIQUE (tenant_id, credential_id),
  FOREIGN KEY (tenant_id, device_id, actor_id)
    REFERENCES ventio_identity_devices (tenant_id, device_id, actor_id),
  CHECK (expires_at > issued_at)
)
