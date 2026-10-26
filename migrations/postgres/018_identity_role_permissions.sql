CREATE TABLE ventio_identity_role_permissions (
  tenant_id text NOT NULL,
  role_id text NOT NULL,
  permission text NOT NULL CHECK (permission ~ '^[a-z][a-z0-9_.]+$' AND length(permission) <= 256),
  PRIMARY KEY (tenant_id, role_id, permission),
  FOREIGN KEY (tenant_id, role_id) REFERENCES ventio_identity_roles (tenant_id, role_id)
)
