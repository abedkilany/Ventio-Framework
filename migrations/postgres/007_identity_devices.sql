CREATE TABLE ventio_identity_devices (
  tenant_id text NOT NULL,
  device_id text NOT NULL CHECK (length(trim(device_id)) BETWEEN 1 AND 256),
  actor_id text NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (tenant_id, device_id),
  UNIQUE (tenant_id, device_id, actor_id),
  FOREIGN KEY (tenant_id, actor_id) REFERENCES ventio_identity_users (tenant_id, actor_id)
)
