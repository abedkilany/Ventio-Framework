CREATE TABLE IF NOT EXISTS ventio_audit_entries (
  audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id text NOT NULL,
  company_id text NOT NULL,
  branch_id text NOT NULL,
  actor_id text NOT NULL,
  command_id text NOT NULL,
  event_type text NOT NULL,
  details jsonb NOT NULL CHECK (jsonb_typeof(details) = 'object'),
  recorded_at timestamptz NOT NULL DEFAULT now()
)
