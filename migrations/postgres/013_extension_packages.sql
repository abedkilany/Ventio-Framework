CREATE TABLE ventio_extension_packages (
  tenant_id text NOT NULL CHECK (length(trim(tenant_id)) BETWEEN 1 AND 256),
  module_id text NOT NULL CHECK (module_id ~ '^[a-z][a-z0-9]*([._-][a-z0-9]+)*$' AND length(module_id) <= 128),
  version text NOT NULL CHECK (version ~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'),
  package_sha256 text NOT NULL CHECK (package_sha256 ~ '^[0-9a-f]{64}$'),
  package_json jsonb NOT NULL CHECK (jsonb_typeof(package_json) = 'object' AND octet_length(package_json::text) <= 2097152),
  status text NOT NULL DEFAULT 'SUBMITTED' CHECK (status IN ('SUBMITTED', 'APPROVED', 'REVOKED')),
  submitted_by text NOT NULL CHECK (length(trim(submitted_by)) BETWEEN 1 AND 256),
  submitted_company_id text NOT NULL CHECK (length(trim(submitted_company_id)) BETWEEN 1 AND 256),
  submitted_branch_id text NOT NULL CHECK (length(trim(submitted_branch_id)) BETWEEN 1 AND 256),
  submitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  approved_by text,
  approved_at timestamptz,
  revoked_by text,
  revoked_at timestamptz,
  revoke_reason text,
  PRIMARY KEY (tenant_id, module_id, version),
  CHECK (package_json #>> '{manifest,moduleId}' = module_id),
  CHECK (package_json #>> '{manifest,version}' = version),
  CHECK ((status = 'SUBMITTED' AND approved_by IS NULL AND approved_at IS NULL AND revoked_by IS NULL AND revoked_at IS NULL AND revoke_reason IS NULL) OR
         (status = 'APPROVED' AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND revoked_by IS NULL AND revoked_at IS NULL AND revoke_reason IS NULL) OR
         (status = 'REVOKED' AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND revoked_by IS NOT NULL AND revoked_at IS NOT NULL AND revoke_reason IS NOT NULL))
)
