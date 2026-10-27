CREATE TABLE IF NOT EXISTS ventio_document_number_series (
  tenant_id text NOT NULL CHECK (length(tenant_id) > 0),
  company_id text NOT NULL CHECK (length(company_id) > 0),
  branch_id text NOT NULL CHECK (length(branch_id) > 0),
  module_id text NOT NULL CHECK (length(module_id) > 0),
  doc_type text NOT NULL CHECK (length(doc_type) > 0),
  series_id text NOT NULL CHECK (series_id ~ '^[a-z][a-z0-9_-]{0,63}$'),
  prefix text NOT NULL CHECK (length(prefix) <= 24 AND prefix ~ '^[A-Z0-9._/-]*$'),
  padding smallint NOT NULL CHECK (padding BETWEEN 1 AND 12),
  next_number bigint NOT NULL CHECK (next_number > 0),
  PRIMARY KEY (tenant_id, company_id, branch_id, module_id, doc_type, series_id)
)
