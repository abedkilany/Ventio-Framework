CREATE TABLE IF NOT EXISTS ventio_records (
  tenant_id text NOT NULL CHECK (length(tenant_id) > 0),
  company_id text NOT NULL CHECK (length(company_id) > 0),
  branch_id text NOT NULL CHECK (length(branch_id) > 0),
  doc_type text NOT NULL CHECK (length(doc_type) > 0),
  record_id text NOT NULL CHECK (length(record_id) > 0),
  revision integer NOT NULL CHECK (revision > 0),
  record_data jsonb NOT NULL CHECK (jsonb_typeof(record_data) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, company_id, branch_id, doc_type, record_id)
)
