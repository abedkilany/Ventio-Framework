CREATE TABLE ventio_identity_role_assignments (
  tenant_id text NOT NULL,
  actor_id text NOT NULL,
  company_id text NOT NULL,
  branch_id text NOT NULL,
  role_id text NOT NULL,
  PRIMARY KEY (tenant_id, actor_id, company_id, branch_id, role_id),
  FOREIGN KEY (tenant_id, actor_id) REFERENCES ventio_identity_users (tenant_id, actor_id),
  FOREIGN KEY (tenant_id, company_id, branch_id)
    REFERENCES ventio_identity_branches (tenant_id, company_id, branch_id),
  FOREIGN KEY (tenant_id, role_id) REFERENCES ventio_identity_roles (tenant_id, role_id)
)
