CREATE TABLE ventio_extension_package_events (
  event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id text NOT NULL CHECK (length(trim(tenant_id)) BETWEEN 1 AND 256),
  module_id text NOT NULL CHECK (module_id ~ '^[a-z][a-z0-9]*([._-][a-z0-9]+)*$' AND length(module_id) <= 128),
  version text NOT NULL CHECK (version ~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'),
  event_type text NOT NULL CHECK (event_type IN ('SUBMITTED', 'APPROVED', 'REVOKED')),
  actor_id text NOT NULL CHECK (length(trim(actor_id)) BETWEEN 1 AND 256),
  company_id text NOT NULL CHECK (length(trim(company_id)) BETWEEN 1 AND 256),
  branch_id text NOT NULL CHECK (length(trim(branch_id)) BETWEEN 1 AND 256),
  package_sha256 text NOT NULL CHECK (package_sha256 ~ '^[0-9a-f]{64}$'),
  details jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details) = 'object'),
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
)
