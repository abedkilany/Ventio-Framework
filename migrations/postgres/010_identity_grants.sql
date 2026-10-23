CREATE TABLE ventio_identity_grants (
  tenant_id text NOT NULL,
  actor_id text NOT NULL,
  company_id text NOT NULL,
  branch_id text NOT NULL,
  permission text NOT NULL CHECK (permission ~ '^[a-z][a-z0-9_.]+$' AND length(permission) <= 256),
  PRIMARY KEY (tenant_id, actor_id, company_id, branch_id, permission),
  FOREIGN KEY (tenant_id, actor_id) REFERENCES ventio_identity_users (tenant_id, actor_id),
  FOREIGN KEY (tenant_id, company_id, branch_id)
    REFERENCES ventio_identity_branches (tenant_id, company_id, branch_id)
)
