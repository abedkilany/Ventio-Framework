CREATE INDEX IF NOT EXISTS ventio_outbox_pending_idx
  ON ventio_outbox (tenant_id, outbox_id)
  WHERE delivered_at IS NULL
