CREATE TABLE ventio_identity_roles (
  tenant_id text NOT NULL CHECK (length(trim(tenant_id)) BETWEEN 1 AND 256),
  role_id text NOT NULL CHECK (role_id ~ '^[a-z][a-z0-9_.-]*$' AND length(role_id) <= 128),
  display_name text NOT NULL CHECK (length(trim(display_name)) BETWEEN 1 AND 120),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (tenant_id, role_id)
)
