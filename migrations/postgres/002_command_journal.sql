CREATE TABLE IF NOT EXISTS ventio_command_journal (
  tenant_id text NOT NULL,
  command_id text NOT NULL,
  company_id text NOT NULL,
  branch_id text NOT NULL,
  actor_id text NOT NULL,
  device_id text NOT NULL,
  fingerprint text NOT NULL,
  receipt jsonb NOT NULL CHECK (jsonb_typeof(receipt) = 'object'),
  accepted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, command_id)
)
