CREATE TABLE ventio_identity_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id text NOT NULL,
  database_actor text NOT NULL DEFAULT session_user,
  operator_label text NOT NULL,
  action text NOT NULL,
  subject_id text NOT NULL,
  details jsonb NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
)
