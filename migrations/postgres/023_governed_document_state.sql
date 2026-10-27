ALTER TABLE public.ventio_records
  ADD COLUMN IF NOT EXISTS document_status smallint NOT NULL DEFAULT 0
    CHECK (document_status IN (0, 1, 2)),
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

CREATE INDEX IF NOT EXISTS ventio_records_live_reference_lookup
  ON public.ventio_records
    (tenant_id, company_id, branch_id, module_id, doc_type, record_id)
  WHERE deleted_at IS NULL;
