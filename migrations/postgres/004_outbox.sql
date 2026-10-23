CREATE TABLE IF NOT EXISTS ventio_outbox (
  outbox_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id text NOT NULL,
  company_id text NOT NULL,
  branch_id text NOT NULL,
  command_id text NOT NULL,
  event_type text NOT NULL,
  payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  inserted_at timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz
)
