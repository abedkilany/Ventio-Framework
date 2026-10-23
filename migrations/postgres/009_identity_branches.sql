CREATE TABLE ventio_identity_branches (
  tenant_id text NOT NULL CHECK (length(trim(tenant_id)) BETWEEN 1 AND 256),
  company_id text NOT NULL CHECK (length(trim(company_id)) BETWEEN 1 AND 256),
  branch_id text NOT NULL CHECK (length(trim(branch_id)) BETWEEN 1 AND 256),
  PRIMARY KEY (tenant_id, company_id, branch_id)
)
