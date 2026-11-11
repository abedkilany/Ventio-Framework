ALTER TABLE public.ventio_records
  ADD COLUMN IF NOT EXISTS document_status smallint NOT NULL DEFAULT 0
    CHECK (document_status IN (0, 1, 2)),
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
