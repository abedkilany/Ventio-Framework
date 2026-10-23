CREATE TABLE ventio_identity_users (
  tenant_id text NOT NULL CHECK (length(trim(tenant_id)) BETWEEN 1 AND 256),
  actor_id text NOT NULL CHECK (length(trim(actor_id)) BETWEEN 1 AND 256),
  disabled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (tenant_id, actor_id)
)
